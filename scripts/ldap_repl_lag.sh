#!/bin/bash
# =============================================================================
# ldap_repl_lag.sh
# Calcula el retardo de replicacion LDAP comparando el contextCSN
# (timestamp de la ultima operacion sincronizada) entre nodo1 (master)
# y nodo2 (replica). Escribe la metrica en formato Prometheus.
#
# Se ejecuta en nodo4 via systemd timer (cada 15s).
# =============================================================================
set -u

LDAP_ADMIN_PASS="Fis2026LdapAdmin!"
BASE_DN="dc=fis,dc=epn,dc=ec"
OUT_DIR="/var/lib/prometheus/node-exporter/textfile_collector"
OUT_FILE="${OUT_DIR}/ldap_replication.prom"
TMP_FILE="${OUT_FILE}.$$"

mkdir -p "${OUT_DIR}"

get_csn_epoch() {
    local host="$1"
    local csn
    csn=$(ldapsearch -x -H "ldaps://${host}:636" \
            -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PASS}" \
            -b "${BASE_DN}" -s base contextCSN -LLL 2>/dev/null \
          | grep '^contextCSN:' | head -n1 | awk '{print $2}')
    [ -z "$csn" ] && return 1
    local ts="${csn%%.*}"   # 20260717120000
    date -u -d "${ts:0:8} ${ts:8:2}:${ts:10:2}:${ts:12:2}" +%s
}

MASTER_EPOCH=$(get_csn_epoch "ldap1.fis.epn.ec" || true)
REPLICA_EPOCH=$(get_csn_epoch "ldap2.fis.epn.ec" || true)

{
    echo "# HELP ldap_replication_lag_seconds Retardo de replicacion (contextCSN ldap1 - ldap2)"
    echo "# TYPE ldap_replication_lag_seconds gauge"
    echo "# HELP ldap_replication_up 1 si se pudo leer contextCSN en ambos nodos"
    echo "# TYPE ldap_replication_up gauge"
    if [ -n "${MASTER_EPOCH:-}" ] && [ -n "${REPLICA_EPOCH:-}" ]; then
        echo "ldap_replication_lag_seconds $((MASTER_EPOCH - REPLICA_EPOCH))"
        echo "ldap_replication_up 1"
    else
        echo "ldap_replication_lag_seconds NaN"
        echo "ldap_replication_up 0"
    fi
} > "${TMP_FILE}"

mv "${TMP_FILE}" "${OUT_FILE}"