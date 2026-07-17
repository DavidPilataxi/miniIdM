#!/bin/bash
# =============================================================================
# nodo3_setup.sh
# Rol: Balanceador de carga (HAProxy) + Webserver Flask (TLS + Kerberos)
#
# Se ejecuta DENTRO del contenedor nodo3, con systemd arriba.
#
# Uso (desde el host):
#   docker exec -it nodo3 bash /opt/scripts/nodo3_setup.sh
#
# Requisitos previos (docker-compose.yml de nodo3 debe montar):
#   - ./pki:/opt/pki
#   - ./scripts:/opt/scripts
#   - ./shared:/opt/shared
#   - .:/opt/miniidm            (repo completo: app/, config.py, requirements.txt, .env)
#
# Requisitos previos de ejecucion:
#   - nodo1_setup.sh + nodo1_complement.sh ya corridos en nodo1 (incluye copia
#     de webserver.keytab a /opt/shared)
#   - nodo2_setup.sh ya corrido en nodo2 (para que el failover de LDAP/KDC
#     tenga sentido en las pruebas)
# =============================================================================
set -e

REALM="FIS.EPN.EC"
PKI_DIR="/opt/pki"
SHARED_DIR="/opt/miniidm/shared"  # incluye svc-admin.keytab si nodo1 ya lo genero
APP_DIR="/opt/miniidm"

echo "=== [0/7] Habilitando arranque real de servicios ==="
rm -f /usr/sbin/policy-rc.d

echo "=== [1/7] Instalando HAProxy, Python y cliente Kerberos ==="
DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    haproxy \
    python3 \
    python3-venv \
    python3-pip \
    krb5-user

echo "=== [2/7] Configurando /etc/krb5.conf con failover a ambos KDCs ==="
cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = ${REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = false
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true
    proxiable = true
    rdns = false

[realms]
    ${REALM} = {
        kdc = kdc1.fis.epn.ec
        kdc = kdc2.fis.epn.ec
        admin_server = kdc1.fis.epn.ec
    }

[domain_realm]
    .fis.epn.ec = ${REALM}
    fis.epn.ec = ${REALM}
EOF

echo "=== [3/7] Verificando certificados y keytab compartidos ==="
for f in "${PKI_DIR}/ca/ca.crt" "${PKI_DIR}/certs/webserver.crt" "${PKI_DIR}/certs/webserver.key"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: falta $f (verifica que ./pki este montado y que la PKI ya se genero en nodo1)"
        exit 1
    fi
done

if [ -f "${SHARED_DIR}/webserver.keytab" ]; then
    mkdir -p /etc/krb5kdc/keytabs
    cp "${SHARED_DIR}/webserver.keytab" /etc/krb5kdc/keytabs/webserver.keytab
    chmod 600 /etc/krb5kdc/keytabs/webserver.keytab
    echo "  webserver.keytab copiado desde ${SHARED_DIR}."
else
    echo "  ADVERTENCIA: no se encontro ${SHARED_DIR}/webserver.keytab."
    echo "  La app sigue funcionando (usa kinit interactivo, no este keytab),"
    echo "  pero si mas adelante necesitas autenticacion de servicio, corre"
    echo "  primero el complemento de nodo1 que lo copia a /opt/shared."
fi

echo "=== [4/7] Preparando entorno Python de la app (venv) ==="
if [ ! -f "${APP_DIR}/config.py" ]; then
    echo "ERROR: no se encuentra ${APP_DIR}/config.py. Verifica el mount '.:/opt/miniidm'."
    exit 1
fi
if [ ! -f "${APP_DIR}/.env" ]; then
    echo "ERROR: no se encuentra ${APP_DIR}/.env (SECRET_KEY / LDAP_ADMIN_PASSWORD)."
    echo "       Confirma que el archivo existe en la raiz del repo en el host."
    exit 1
fi

python3 -m venv "${APP_DIR}/venv"
"${APP_DIR}/venv/bin/pip" install --upgrade pip
"${APP_DIR}/venv/bin/pip" install -r "${APP_DIR}/requirements.txt"

echo "=== [5/7] Creando servicio systemd para la app Flask ==="
cat > /etc/systemd/system/miniidm-web.service <<EOF
[Unit]
Description=MiniIdM - Webserver Flask (TLS + autenticacion Kerberos)
After=network.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
Environment=PYTHONPATH=${APP_DIR}
Environment=KRB5CCNAME=/tmp/krb5cc_miniidm_web
ExecStart=${APP_DIR}/venv/bin/python3 -m app.app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "=== [6/7] Configurando HAProxy (LDAPS passthrough + TLS passthrough web) ==="
cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    maxconn 2000
    daemon

defaults
    log     global
    mode    tcp
    option  dontlognull
    timeout connect 5s
    timeout client  50s
    timeout server  50s
    retries 3

# --- Front-end LDAPS: ldap.fis.epn.ec:636 -> ldap1 (master) / ldap2 (backup) ---
# ldap1 recibe todo el trafico normalmente (incluye escrituras del admin).
# ldap2 solo entra como backup si ldap1 no responde el health check TCP,
# lo cual es consistente con la prueba de HA del punto 6 del enunciado:
# lecturas continuan si el master cae, las escrituras se documentan como
# no garantizadas durante ese lapso.
frontend ldaps_front
    bind *:636
    default_backend ldaps_back

backend ldaps_back
    balance roundrobin
    option tcp-check
    server ldap1 ldap1.fis.epn.ec:636 check
    server ldap2 ldap2.fis.epn.ec:636 check backup

# --- Front-end HTTP: redirige todo a HTTPS ---
frontend http_front
    mode http
    bind *:80
    redirect scheme https code 301 if !{ ssl_fc }

# --- Front-end HTTPS: pasa el TLS intacto al webserver Flask local ---
# El TLS se termina en la propia app Flask (usa webserver.crt/key via
# ssl_context), asi que HAProxy solo hace tcp passthrough en el puerto 443.
frontend https_front
    bind *:443
    default_backend webserver_back

backend webserver_back
    option tcp-check
    server webserver_local 127.0.0.1:5000 check
EOF

haproxy -c -f /etc/haproxy/haproxy.cfg

echo "=== [7/7] Habilitando e iniciando servicios ==="
systemctl daemon-reload
systemctl enable miniidm-web haproxy
systemctl restart miniidm-web
sleep 2
systemctl restart haproxy
sleep 1

if ! systemctl is-active --quiet miniidm-web; then
    echo "ERROR: miniidm-web no arranco. Revisando logs:"
    journalctl -u miniidm-web --no-pager -n 40
    exit 1
fi
if ! systemctl is-active --quiet haproxy; then
    echo "ERROR: haproxy no arranco. Revisando logs:"
    journalctl -u haproxy --no-pager -n 40
    exit 1
fi

echo ""
echo "================================================================"
echo " nodo3 configurado:"
echo "   - HAProxy escuchando en :636 (LDAPS -> ldap1/ldap2) y :443 (web)"
echo "   - App Flask (miniidm-web.service) en 127.0.0.1:5000 (TLS)"
echo ""
echo " Verificar desde dentro del contenedor:"
echo "   openssl s_client -connect ldap.fis.epn.ec:636 -CAfile ${PKI_DIR}/ca/ca.crt"
echo "   curl -k https://webserver.fis.epn.ec/"
echo ""
echo " Verificar desde el host (puertos publicados 8080/8443):"
echo "   curl -k https://localhost:8443/"
echo ""
echo " Prueba de failover LDAP (desde el host):"
echo "   docker exec nodo1 systemctl stop slapd"
echo "   docker exec nodo3 ldapsearch -x -H ldaps://ldap.fis.epn.ec -b 'dc=fis,dc=epn,dc=ec' -s base dn"
echo "================================================================"