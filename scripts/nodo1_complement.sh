#!/bin/bash
# =============================================================================
# nodo1_complement.sh
# Complementa nodo1 (ya funcionando, nodo1_setup.sh ya ejecutado) con:
#   - Replicacion LDAP en tiempo real hacia nodo2 (syncprov + syncrepl
#     refreshAndPersist -> el consumer mantiene una conexion persistente,
#     por eso se comporta como "push" en tiempo real).
#   - Propagacion automatica de la base de Kerberos hacia nodo2 (kprop),
#     cada 60s via un timer de systemd.
#
# NO reinstala ni reconfigura nada de lo que ya funciona en nodo1_setup.sh.
# Es idempotente: se puede volver a correr sin romper nada si algo ya existe.
#
# Uso (desde el host):
#   docker exec -it nodo1 bash /opt/scripts/nodo1_complement.sh
#
# Requisitos previos:
#   - nodo1_setup.sh ya ejecutado exitosamente
#   - docker-compose.yml de nodo1 debe montar ./shared:/opt/shared
#     (ver docker-compose-DIFF.md)
# =============================================================================
set -e

LDAP_ADMIN_PASS="Fis2026LdapAdmin!"     # debe coincidir con nodo1_setup.sh
REPLICATOR_PASS="Fis2026LdapRepl!"      # nueva cuenta, solo lectura
REALM="FIS.EPN.EC"
BASE_DN="dc=fis,dc=epn,dc=ec"
SHARED_DIR="/opt/shared"

mkdir -p "${SHARED_DIR}"

echo "=== [0/8] Agregando kdc2 a /etc/krb5.conf (failover del lado cliente) ==="
if [[ ! -f /etc/krb5.conf ]] || ! systemctl is-active --quiet slapd; then
    echo "ERROR: no se detecta una instalacion valida de nodo1_setup.sh"
    echo "(falta /etc/krb5.conf o slapd no esta activo)."
    echo "Corre primero: docker exec -it nodo1 bash /opt/scripts/nodo1_setup.sh"
    exit 1
fi
if ! grep -q "kdc2.fis.epn.ec" /etc/krb5.conf; then
    sed -i '/kdc = kdc1.fis.epn.ec/a\        kdc = kdc2.fis.epn.ec' /etc/krb5.conf
fi

echo "=== [1/8] Detectando el DN de la base de datos mdb en cn=config ==="
MDB_DN=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config -LLL '(objectClass=olcMdbConfig)' dn \
         | grep '^dn:' | sed 's/^dn: //')
echo "  usando: ${MDB_DN}"

echo "=== [2/8] Habilitando el modulo syncprov en OpenLDAP ==="
cat > /tmp/syncprov_module.ldif <<EOF
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: syncprov.la
EOF
ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/syncprov_module.ldif || \
    echo "  (syncprov.la ya estaba cargado, continuando)"

echo "=== [3/8] Agregando el overlay syncprov a la base mdb ==="
cat > /tmp/syncprov_overlay.ldif <<EOF
dn: olcOverlay=syncprov,${MDB_DN}
changetype: add
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: syncprov
olcSpCheckpoint: 100 10
olcSpSessionLog: 100
EOF
ldapadd -Y EXTERNAL -H ldapi:/// -f /tmp/syncprov_overlay.ldif || \
    echo "  (overlay syncprov ya existia, continuando)"

echo "=== [4/8] Creando cuenta dedicada de replicacion (solo lectura) ==="
REPL_HASH=$(slappasswd -s "${REPLICATOR_PASS}")
cat > /tmp/replicator.ldif <<EOF
dn: cn=replicator,${BASE_DN}
changetype: add
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: replicator
description: Cuenta de solo lectura usada por nodo2 para syncrepl
userPassword: ${REPL_HASH}
EOF
ldapadd -x -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PASS}" -H ldap:/// \
    -f /tmp/replicator.ldif || echo "  (cn=replicator ya existia, continuando)"

echo "=== [5/8] Restringiendo 'replicator' a solo lectura sobre el arbol ==="
cat > /tmp/replicator_acl.ldif <<EOF
dn: ${MDB_DN}
changetype: modify
add: olcAccess
olcAccess: {0}to * by dn.exact="cn=replicator,${BASE_DN}" read by * break
EOF
ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/replicator_acl.ldif || \
    echo "  (ACL de replicator ya configurada, continuando)"

systemctl restart slapd
sleep 1

echo "=== [6/8] Creando principals de host para GSSAPI mutuo (kprop/kpropd) ==="
kadmin.local -q "addprinc -randkey host/nodo1.fis.epn.ec" || true
kadmin.local -q "addprinc -randkey host/nodo2.fis.epn.ec" || true

# host/nodo1 -> keytab local (lo usa 'kprop' como identidad de cliente)
kadmin.local -q "ktadd -k /etc/krb5.keytab host/nodo1.fis.epn.ec"

# host/nodo2 -> se deja en /opt/shared, nodo2_setup.sh lo recoge desde ahi
kadmin.local -q "ktadd -k ${SHARED_DIR}/nodo2-host.keytab host/nodo2.fis.epn.ec"
chmod 644 "${SHARED_DIR}/nodo2-host.keytab"

echo "=== [7/8] Compartiendo stash + kdc.conf (nodo2 los necesita identicos) ==="
cp /etc/krb5kdc/stash    "${SHARED_DIR}/stash"
cp /etc/krb5kdc/kdc.conf "${SHARED_DIR}/kdc.conf"
chmod 600 "${SHARED_DIR}/stash"

echo "=== [8/8] Configurando kprop.timer (propagacion cada 60s hacia nodo2) ==="
cat > /etc/systemd/system/kprop.service <<EOF
[Unit]
Description=Propagar base de datos de Kerberos hacia nodo2 (kprop)

[Service]
Type=oneshot
ExecStartPre=/usr/sbin/kdb5_util dump /var/lib/krb5kdc/replica_datatrans
ExecStart=/usr/sbin/kprop -f /var/lib/krb5kdc/replica_datatrans nodo2.fis.epn.ec
EOF

cat > /etc/systemd/system/kprop.timer <<EOF
[Unit]
Description=Ejecutar kprop.service cada 60 segundos

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now kprop.timer

echo ""
echo "================================================================"
echo " nodo1 complementado:"
echo "   - syncprov activo -> LDAP se replica en tiempo real hacia nodo2"
echo "   - cn=replicator,${BASE_DN} creado (solo lectura, para syncrepl)"
echo "   - kprop.timer activo, propagando Kerberos cada 60s hacia nodo2"
echo ""
echo " NOTA: hasta que nodo2 este arriba con kpropd escuchando,"
echo "'systemctl status kprop.service' mostrara fallos periodicos"
echo " (Connection refused) - es normal y esperado."
echo "================================================================"