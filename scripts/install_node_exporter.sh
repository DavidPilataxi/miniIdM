#!/bin/bash
# =============================================================================
# install_node_exporter.sh
# Instala prometheus-node-exporter en CUALQUIERA de los 4 nodos.
# Idempotente: se puede volver a correr sin romper nada.
#
# Uso (desde el host, uno por uno):
#   docker exec -it nodo1 bash /opt/scripts/install_node_exporter.sh
#   docker exec -it nodo2 bash /opt/scripts/install_node_exporter.sh
#   docker exec -it nodo3 bash /opt/scripts/install_node_exporter.sh
#   docker exec -it nodo4 bash /opt/scripts/install_node_exporter.sh
# =============================================================================
set -e

rm -f /usr/sbin/policy-rc.d

echo "=== Instalando prometheus-node-exporter ==="
DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y prometheus-node-exporter

TEXTFILE_DIR="/var/lib/prometheus/node-exporter/textfile_collector"
mkdir -p "${TEXTFILE_DIR}"
chown -R prometheus:prometheus /var/lib/prometheus 2>/dev/null || true

echo "=== Habilitando textfile collector (para metricas custom, ej. LDAP lag) ==="
if [ -f /etc/default/prometheus-node-exporter ]; then
    if ! grep -q "textfile.directory" /etc/default/prometheus-node-exporter; then
        sed -i "s|^ARGS=.*|ARGS=\"--collector.textfile.directory=${TEXTFILE_DIR}\"|" \
            /etc/default/prometheus-node-exporter
    fi
fi

systemctl daemon-reload
systemctl enable prometheus-node-exporter
systemctl restart prometheus-node-exporter
sleep 1

if ! systemctl is-active --quiet prometheus-node-exporter; then
    echo "ERROR: prometheus-node-exporter no arranco."
    journalctl -u prometheus-node-exporter --no-pager -n 30
    exit 1
fi

echo "node_exporter activo en :9100 en $(hostname)"