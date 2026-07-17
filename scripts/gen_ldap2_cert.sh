#!/bin/bash
# =============================================================================
# gen_ldap2_cert.sh
# Genera el certificado ECDSA para ldap2.fis.epn.ec, firmado por la CA raiz
# de la FIS (pki/ca/ca.key). Se ejecuta EN EL HOST (WSL Ubuntu), no dentro de
# un contenedor: openssl esta disponible nativamente y ./pki ya esta en el repo.
#
# Uso (desde la raiz del repo):
#   ./scripts/gen_ldap2_cert.sh
# =============================================================================
set -e

PKI_DIR="./pki"
CA_KEY="${PKI_DIR}/ca/ca.key"
CA_CRT="${PKI_DIR}/ca/ca.crt"
CERTS_DIR="${PKI_DIR}/certs"
CN="ldap2.fis.epn.ec"

if [[ ! -f "${CA_KEY}" || ! -f "${CA_CRT}" ]]; then
    echo "ERROR: no se encontro ${CA_KEY} o ${CA_CRT}."
    echo "Corre este script desde la raiz del repo (~/miniIDM)."
    exit 1
fi

mkdir -p "${CERTS_DIR}"

echo "=== [1/4] Generando llave privada ECDSA para ${CN} ==="
openssl ecparam -name prime256v1 -genkey -noout -out "${CERTS_DIR}/ldap2.key"

echo "=== [2/4] Generando CSR ==="
openssl req -new -key "${CERTS_DIR}/ldap2.key" \
    -out "${CERTS_DIR}/ldap2.csr" \
    -subj "/C=EC/ST=Pichincha/L=Quito/O=FIS-EPN/CN=${CN}"

echo "=== [3/4] Creando extensiones (SAN) ==="
cat > "${CERTS_DIR}/ldap2.ext" <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=@alt_names

[alt_names]
DNS.1 = ${CN}
DNS.2 = nodo2.fis.epn.ec
DNS.3 = kdc2.fis.epn.ec
IP.1  = 172.20.0.12
EOF

echo "=== [4/4] Firmando el certificado con la CA raiz ==="
openssl x509 -req -in "${CERTS_DIR}/ldap2.csr" \
    -CA "${CA_CRT}" -CAkey "${CA_KEY}" -CAcreateserial \
    -out "${CERTS_DIR}/ldap2.crt" -days 825 -sha256 \
    -extfile "${CERTS_DIR}/ldap2.ext"

chmod 600 "${CERTS_DIR}/ldap2.key"

echo ""
echo "================================================================"
echo " Certificado generado: ${CERTS_DIR}/ldap2.crt"
echo " Verificar con:"
echo "   openssl verify -CAfile ${CA_CRT} ${CERTS_DIR}/ldap2.crt"
echo "================================================================"
