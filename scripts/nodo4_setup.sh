#!/bin/bash
# =============================================================================
# nodo4_setup.sh
# Rol: Cliente Linux generico + Monitoreo (Prometheus + Grafana + node_exporter)
#
# Uso (desde el host):
#   docker exec -it nodo4 bash /opt/scripts/nodo4_setup.sh
#
# Requisitos previos:
#   - docker-compose.yml de nodo4 debe montar ./pki, ./scripts, ./shared
#     (ver diff mas arriba)
#   - nodo1/nodo2/nodo3 ya funcionando
#   - Recomendado: correr antes install_node_exporter.sh en nodo1, nodo2, nodo3
# =============================================================================
set -e

REALM="FIS.EPN.EC"
BASE_DN="dc=fis,dc=epn,dc=ec"
PKI_DIR="/opt/pki"
LDAP_ADMIN_PASS="Fis2026LdapAdmin!"

echo "=== [0/7] Habilitando arranque real de servicios ==="
rm -f /usr/sbin/policy-rc.d

echo "=== [1/7] Instalando cliente Kerberos + LDAP + herramientas base ==="
DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    krb5-user ldap-utils curl wget gnupg2 apt-transport-https software-properties-common

echo "=== [2/7] Configurando /etc/krb5.conf (failover a kdc1 y kdc2) ==="
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

echo "=== [3/7] Configurando cliente LDAP para confiar en la CA (TLS) ==="
mkdir -p /etc/ldap/certs
cp "${PKI_DIR}/ca/ca.crt" /etc/ldap/certs/ca.crt
sed -i '/^#\?TLS_CACERT/d' /etc/ldap/ldap.conf 2>/dev/null || true
echo "TLS_CACERT /etc/ldap/certs/ca.crt" >> /etc/ldap/ldap.conf

echo "=== [4/7] Instalando node_exporter en este nodo ==="
bash /opt/scripts/install_node_exporter.sh

echo "=== [5/7] Instalando Prometheus ==="
DEBIAN_FRONTEND=noninteractive apt-get install -y prometheus

mkdir -p /etc/prometheus
cat > /etc/prometheus/prometheus.yml <<EOF
global:
  scrape_interval: 10s
  evaluation_interval: 10s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node_exporter'
    static_configs:
      - targets:
          - 'nodo1.fis.epn.ec:9100'
          - 'nodo2.fis.epn.ec:9100'
          - 'nodo3.fis.epn.ec:9100'
          - 'nodo4.fis.epn.ec:9100'
        labels:
          project: 'miniIdM'
EOF

systemctl enable prometheus
systemctl restart prometheus
sleep 1
systemctl is-active --quiet prometheus || { journalctl -u prometheus --no-pager -n 30; exit 1; }

echo "=== [6/7] Instalando Grafana (repo oficial) + datasource provisionado ==="
if [ ! -f /etc/apt/keyrings/grafana.gpg ]; then
    mkdir -p /etc/apt/keyrings
    wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
fi
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list

DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y grafana

mkdir -p /etc/grafana/provisioning/datasources
cat > /etc/grafana/provisioning/datasources/prometheus.yml <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
EOF

systemctl enable grafana-server
systemctl restart grafana-server
sleep 1
systemctl is-active --quiet grafana-server || { journalctl -u grafana-server --no-pager -n 30; exit 1; }

echo "=== Provisionando dashboard de Grafana ==="
mkdir -p /etc/grafana/provisioning/dashboards
cp /opt/scripts/grafana-provisioning/dashboard.yml /etc/grafana/provisioning/dashboards/dashboard.yml
cp /opt/scripts/grafana-provisioning/miniidm-overview.json /etc/grafana/provisioning/dashboards/miniidm-overview.json
systemctl restart grafana-server

echo "=== [7/7] Configurando timer para la metrica de retardo de replicacion LDAP ==="
cat > /etc/systemd/system/ldap-repl-lag.service <<EOF
[Unit]
Description=Calcula el retardo de replicacion LDAP (contextCSN ldap1 vs ldap2)

[Service]
Type=oneshot
ExecStart=/bin/bash /opt/scripts/ldap_repl_lag.sh
EOF

cat > /etc/systemd/system/ldap-repl-lag.timer <<EOF
[Unit]
Description=Ejecuta ldap-repl-lag.service cada 15 segundos

[Timer]
OnBootSec=10s
OnUnitActiveSec=15s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now ldap-repl-lag.timer

echo ""
echo "================================================================"
echo " nodo4 configurado:"
echo "   - Cliente Linux: krb5.conf con failover, LDAP con TLS"
echo "   - Prometheus:  http://<host>:9090"
echo "   - Grafana:     http://<host>:3000  (admin/admin, pedira cambiarla)"
echo "   - node_exporter: :9100 (incluye ldap_replication_lag_seconds)"
echo ""
echo " Verificar cliente:"
echo "   docker exec -it nodo4 kinit jperez"
echo "   docker exec -it nodo4 ldapsearch -x -H ldaps://ldap.fis.epn.ec -b '${BASE_DN}'"
echo ""
echo " Verificar metrica custom:"
echo "   docker exec -it nodo4 curl -s localhost:9100/metrics | grep ldap_replication"
echo "================================================================"