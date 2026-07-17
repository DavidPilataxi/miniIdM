#!/bin/bash
# =============================================================================
# nodo1_setup.sh
# Rol: CA Raiz (ya montada via /opt/pki) + LDAP Master + KDC Primario
#
# Este script se ejecuta DENTRO del contenedor nodo1, una vez que ya esta
# arriba con systemd corriendo (no durante el build de la imagen).
#
# Uso (desde el host, con ./scripts montado en /opt/scripts):
#   docker exec -it nodo1 bash /opt/scripts/nodo1_setup.sh
#
# Credenciales de prueba documentadas (para README.md del proyecto):
#   - Admin LDAP:        cn=admin,dc=fis,dc=epn,dc=ec / <ver LDAP_ADMIN_PASS>
#   - Usuarios LDAP/Krb:  jperez, malvan, dpilataxi / <ver USER_KRB_PASS>
#   - Master key KDC:    ver KDC_MASTER_PASS (solo para respaldo/restauracion)
# =============================================================================
set -e

# --- Variables de credenciales (documentar tambien en el README del repo) ---
LDAP_ADMIN_PASS="Fis2026LdapAdmin!"
USER_KRB_PASS="Fis2026Kerb!"
KDC_MASTER_PASS="Fis2026KdcStash!"

REALM="FIS.EPN.EC"
BASE_DN="dc=fis,dc=epn,dc=ec"
PKI_DIR="/opt/pki"

echo "=== [0/6] Habilitando arranque real de servicios (quitando policy-rc.d) ==="
# La imagen base de systemd trae este archivo que bloquea el arranque
# automatico de servicios durante "apt install". Lo quitamos porque aqui
# SI queremos que los servicios arranquen igual que en una VM real.
rm -f /usr/sbin/policy-rc.d

echo "=== [1/6] Instalando OpenLDAP de forma no interactiva ==="
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

# Aseguramos que slapd quede arriba antes de continuar (con reintento)
systemctl enable slapd
systemctl restart slapd
sleep 2
if ! systemctl is-active --quiet slapd; then
    echo "ERROR: slapd no arranco. Revisando logs:"
    journalctl -u slapd --no-pager -n 30
    exit 1
fi
echo "slapd activo correctamente."

echo "=== [2/6] Configurando TLS en LDAP (ldaps) con los certificados de la CA ==="
mkdir -p /etc/ldap/certs
cp "${PKI_DIR}/ca/ca.crt"        /etc/ldap/certs/ca.crt
cp "${PKI_DIR}/certs/ldap1.crt"  /etc/ldap/certs/ldap1.crt
cp "${PKI_DIR}/certs/ldap1.key"  /etc/ldap/certs/ldap1.key
chown -R openldap:openldap /etc/ldap/certs
chmod 640 /etc/ldap/certs/ldap1.key
chmod 644 /etc/ldap/certs/ldap1.crt /etc/ldap/certs/ca.crt

cat > /tmp/tls_config.ldif <<EOF
dn: cn=config
changetype: modify
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: /etc/ldap/certs/ca.crt
-
replace: olcTLSCertificateFile
olcTLSCertificateFile: /etc/ldap/certs/ldap1.crt
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /etc/ldap/certs/ldap1.key
EOF
ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/tls_config.ldif

# Habilitar tambien el listener ldaps:// ademas de ldap://
sed -i 's|^SLAPD_SERVICES=.*|SLAPD_SERVICES="ldap:/// ldaps:/// ldapi:///"|' /etc/default/slapd
systemctl restart slapd

# Hacer que el CLIENTE ldap (ldapsearch, ldapadd, etc.) confie en nuestra CA
# por defecto, sin necesitar exportar LDAPTLS_CACERT cada vez.
if ! grep -q "TLS_CACERT" /etc/ldap/ldap.conf 2>/dev/null; then
    echo "TLS_CACERT /etc/ldap/certs/ca.crt" >> /etc/ldap/ldap.conf
fi

echo "=== [3/6] Cargando arbol LDAP (OUs, grupos y usuarios) ==="
USER_HASH=$(slappasswd -s "${USER_KRB_PASS}")

cat > /tmp/init.ldif <<EOF
dn: ou=People,${BASE_DN}
objectClass: organizationalUnit
ou: People

dn: ou=Groups,${BASE_DN}
objectClass: organizationalUnit
ou: Groups

dn: cn=estudiantes,ou=Groups,${BASE_DN}
objectClass: posixGroup
cn: estudiantes
gidNumber: 10000

dn: cn=profesores,ou=Groups,${BASE_DN}
objectClass: posixGroup
cn: profesores
gidNumber: 10001

dn: uid=dpilataxi,ou=People,${BASE_DN}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
cn: David Pilataxi
sn: Pilataxi
uid: dpilataxi
uidNumber: 20000
gidNumber: 10000
homeDirectory: /home/dpilataxi
loginShell: /bin/bash
mail: dpilataxi@fis.epn.ec
userPassword: ${USER_HASH}
employeeType: admin

dn: uid=jperez,ou=People,${BASE_DN}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
cn: Juan Perez
sn: Perez
uid: jperez
uidNumber: 20001
gidNumber: 10001
homeDirectory: /home/jperez
loginShell: /bin/bash
mail: jperez@fis.epn.ec
userPassword: ${USER_HASH}

dn: uid=malvan,ou=People,${BASE_DN}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
cn: Maria Alvan
sn: Alvan
uid: malvan
uidNumber: 20002
gidNumber: 10001
homeDirectory: /home/malvan
loginShell: /bin/bash
mail: malvan@fis.epn.ec
userPassword: ${USER_HASH}
EOF

ldapadd -x -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PASS}" -H ldap:/// -f /tmp/init.ldif

echo "=== [4/6] Instalando Kerberos (KDC + servidor de administracion) ==="
debconf-set-selections <<EOF
krb5-config krb5-config/default_realm string ${REALM}
krb5-config krb5-config/kerberos_servers string kdc1.fis.epn.ec
krb5-config krb5-config/admin_server string kdc1.fis.epn.ec
EOF
DEBIAN_FRONTEND=noninteractive apt-get install -y krb5-kdc krb5-admin-server krb5-user

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
        admin_server = kdc1.fis.epn.ec
    }

[domain_realm]
    .fis.epn.ec = ${REALM}
    fis.epn.ec = ${REALM}
EOF

mkdir -p /etc/krb5kdc
cat > /etc/krb5kdc/kdc.conf <<EOF
[kdcdefaults]
    kdc_ports = 88
    kdc_tcp_ports = 88

[realms]
    ${REALM} = {
        database_name = /var/lib/krb5kdc/principal
        admin_keytab = FILE:/etc/krb5kdc/kadm5.keytab
        acl_file = /etc/krb5kdc/kadm5.acl
        key_stash_file = /etc/krb5kdc/stash
        kdc_ports = 88
        kdc_tcp_ports = 88
        max_life = 24h
        max_renewable_life = 7d
        default_principal_flags = +preauth
    }
EOF

echo "*/admin@${REALM}     *" > /etc/krb5kdc/kadm5.acl

echo "=== [5/6] Creando base de datos del realm y principals ==="
kdb5_util create -s -r "${REALM}" -P "${KDC_MASTER_PASS}"

kadmin.local -q "addprinc -pw ${USER_KRB_PASS} dpilataxi"
kadmin.local -q "addprinc -pw ${USER_KRB_PASS} jperez"
kadmin.local -q "addprinc -pw ${USER_KRB_PASS} malvan"
kadmin.local -q "addprinc -randkey ldap/ldap1.fis.epn.ec"
kadmin.local -q "addprinc -randkey http/webserver.fis.epn.ec"

mkdir -p /etc/krb5kdc/keytabs
kadmin.local -q "ktadd -k /etc/krb5kdc/keytabs/ldap1.keytab ldap/ldap1.fis.epn.ec"
kadmin.local -q "ktadd -k /etc/krb5kdc/keytabs/webserver.keytab http/webserver.fis.epn.ec"

echo "=== [6/6] Habilitando e iniciando servicios ==="
systemctl enable slapd krb5-kdc krb5-admin-server
systemctl restart slapd krb5-kdc krb5-admin-server

echo ""
echo "================================================================"
echo " nodo1 configurado: LDAP master (ldaps://ldap1.fis.epn.ec) +"
echo " KDC primario para el realm ${REALM}"
echo " Verificar con:"
echo "   ldapsearch -x -H ldaps://ldap1.fis.epn.ec -b '${BASE_DN}'"
echo "   kinit jperez   (password: ${USER_KRB_PASS})"
echo "================================================================"