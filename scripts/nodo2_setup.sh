#!/bin/bash
# =============================================================================
# nodo2_setup.sh
# Rol: LDAP Replica (syncrepl, refreshAndPersist) + KDC Secundario (kpropd)
#
# Se ejecuta DENTRO del contenedor nodo2, con systemd arriba.
#
# Uso (desde el host):
#   docker exec -it nodo2 bash /opt/scripts/nodo2_setup.sh
#
# Requisitos previos:
#   - nodo1_setup.sh Y nodo1_complement.sh ya ejecutados en nodo1
#   - docker-compose.yml de nodo2 monta ./pki:/opt/pki y ./shared:/opt/shared
#   - pki/certs/ldap2.crt / .key generados con scripts/gen_ldap2_cert.sh
# =============================================================================
set -e

LDAP_ADMIN_PASS="Fis2026LdapAdmin!"      # debe coincidir con nodo1
REPLICATOR_PASS="Fis2026LdapRepl!"       # debe coincidir con nodo1_complement.sh
REALM="FIS.EPN.EC"
BASE_DN="dc=fis,dc=epn,dc=ec"
PKI_DIR="/opt/pki"
SHARED_DIR="/opt/shared"

echo "=== [0/8] Habilitando arranque real de servicios ==="
rm -f /usr/sbin/policy-rc.d

echo "=== [1/8] Instalando OpenLDAP (arranca vacio; se llena via syncrepl) ==="
debconf-set-selections <<EOF
slapd slapd/internal/adminpw password ${LDAP_ADMIN_PASS}
slapd slapd/internal/generated_adminpw password ${LDAP_ADMIN_PASS}
slapd slapd/password2 password ${LDAP_ADMIN_PASS}
slapd slapd/password1 password ${LDAP_ADMIN_PASS}
slapd slapd/domain string fis.epn.ec
slapd shared/organization string FIS
slapd slapd/purge_database boolean true
slapd slapd/move_old_database boolean true
slapd slapd/no_configuration boolean false
slapd slapd/backend select MDB
EOF
DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y slapd ldap-utils

systemctl enable slapd
systemctl restart slapd
sleep 2
if ! systemctl is-active --quiet slapd; then
    echo "ERROR: slapd no arranco."; journalctl -u slapd --no-pager -n 30; exit 1
fi

echo "=== [2/8] Configurando TLS en LDAP con el certificado de ldap2 ==="
mkdir -p /etc/ldap/certs
cp "${PKI_DIR}/ca/ca.crt"        /etc/ldap/certs/ca.crt
cp "${PKI_DIR}/certs/ldap2.crt"  /etc/ldap/certs/ldap2.crt
cp "${PKI_DIR}/certs/ldap2.key"  /etc/ldap/certs/ldap2.key
chown -R openldap:openldap /etc/ldap/certs
chmod 640 /etc/ldap/certs/ldap2.key
chmod 644 /etc/ldap/certs/ldap2.crt /etc/ldap/certs/ca.crt

cat > /tmp/tls_config.ldif <<EOF
dn: cn=config
changetype: modify
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: /etc/ldap/certs/ca.crt
-
replace: olcTLSCertificateFile
olcTLSCertificateFile: /etc/ldap/certs/ldap2.crt
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /etc/ldap/certs/ldap2.key
EOF
ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/tls_config.ldif

sed -i 's|^SLAPD_SERVICES=.*|SLAPD_SERVICES="ldap:/// ldaps:/// ldapi:///"|' /etc/default/slapd
systemctl restart slapd

sed -i '/^#\?TLS_CACERT/d' /etc/ldap/ldap.conf
echo "TLS_CACERT /etc/ldap/certs/ca.crt" >> /etc/ldap/ldap.conf

echo "=== [3/8] Configurando syncrepl (consumer, refreshAndPersist) hacia nodo1 ==="
MDB_DN=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config -LLL '(objectClass=olcMdbConfig)' dn \
         | grep '^dn:' | sed 's/^dn: //')
echo "  usando base: ${MDB_DN}"

cat > /tmp/syncrepl.ldif <<EOF
dn: ${MDB_DN}
changetype: modify
add: olcSyncrepl
olcSyncrepl: rid=001
  provider=ldaps://ldap1.fis.epn.ec:636
  bindmethod=simple
  binddn="cn=replicator,${BASE_DN}"
  credentials=${REPLICATOR_PASS}
  searchbase="${BASE_DN}"
  scope=sub
  schemachecking=on
  type=refreshAndPersist
  retry="5 5 30 +"
-
add: olcUpdateRef
olcUpdateRef: ldaps://ldap1.fis.epn.ec:636
EOF
ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/syncrepl.ldif

systemctl restart slapd
sleep 3

echo "=== [4/8] Verificando replicacion inicial ==="
ldapsearch -x -H ldaps://ldap2.fis.epn.ec -b "${BASE_DN}" -s base dn || \
    echo "  ADVERTENCIA: aun no hay datos replicados; revisa 'journalctl -u slapd' y que ldap1.fis.epn.ec resuelva desde nodo2"

echo "=== [5/8] Instalando Kerberos (solo KDC, SIN admin server) ==="
debconf-set-selections <<EOF
krb5-config krb5-config/default_realm string ${REALM}
krb5-config krb5-config/kerberos_servers string kdc1.fis.epn.ec kdc2.fis.epn.ec
krb5-config krb5-config/admin_server string kdc1.fis.epn.ec
EOF
DEBIAN_FRONTEND=noninteractive apt-get install -y krb5-kdc krb5-user krb5-kpropd

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

echo "=== [6/8] Copiando kdc.conf y stash (master key) desde nodo1 via /opt/shared ==="
mkdir -p /etc/krb5kdc /var/lib/krb5kdc
cp "${SHARED_DIR}/kdc.conf" /etc/krb5kdc/kdc.conf
cp "${SHARED_DIR}/stash"    /etc/krb5kdc/stash
chmod 600 /etc/krb5kdc/stash
echo "*/admin@${REALM}     *" > /etc/krb5kdc/kadm5.acl

# IMPORTANTE: NO correr 'kdb5_util create' aqui. La base de datos de
# principals la crea kpropd automaticamente en el primer push desde nodo1,
# usando este mismo stash (para que las claves sean legibles/consistentes
# con el primario).

echo "=== [7/8] Configurando kpropd (recibe la propagacion enviada por nodo1) ==="
cp "${SHARED_DIR}/nodo2-host.keytab" /tmp/nodo2-host.keytab
ktutil <<EOF
rkt /tmp/nodo2-host.keytab
wkt /etc/krb5.keytab
quit
EOF
chmod 600 /etc/krb5.keytab
rm -f /tmp/nodo2-host.keytab

echo "host/nodo1.fis.epn.ec@${REALM}" > /etc/krb5kdc/kpropd.acl

cat > /etc/systemd/system/kpropd.service <<EOF
[Unit]
Description=Recibe la base de datos de Kerberos propagada desde nodo1 (kpropd)
After=network.target

[Service]
Type=simple
# -f = archivo temporal donde llega el dump; kpropd invoca kdb5_util load
#      internamente para cargarlo en la base real (definida en kdc.conf)
ExecStart=/usr/sbin/kpropd -S -f /var/lib/krb5kdc/from-nodo1
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now kpropd

echo "=== [8/8] Habilitando el KDC secundario (sin kadmind) ==="
systemctl enable krb5-kdc
# krb5-kdc necesita que exista /var/lib/krb5kdc/principal, que lo crea
# kpropd en su primer push (hasta 60s despues de que nodo1 este listo).
systemctl restart krb5-kdc || \
    echo "  (esperado si aun no llega el primer kprop desde nodo1; reintenta en ~60s)"

echo ""
echo "================================================================"
echo " nodo2 configurado:"
echo "   - LDAP replica: ldaps://ldap2.fis.epn.ec (syncrepl activo)"
echo "   - KDC secundario: recibe DB via kpropd (~60s) desde nodo1"
echo ""
echo " Verificar LDAP:"
echo "   ldapsearch -x -H ldaps://ldap2.fis.epn.ec -b '${BASE_DN}'"
echo " Verificar Kerberos (despues de que kprop corra al menos una vez):"
echo "   kinit -c /tmp/t2 jperez   # deberia funcionar pidiendole a kdc2"
echo "   systemctl status krb5-kdc"
echo "================================================================"