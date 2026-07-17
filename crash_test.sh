#!/bin/bash
set -uo pipefail

echo "===== Estado inicial ====="
docker exec nodo1 systemctl is-active krb5-kdc

echo "===== Disparando kill -9 y capturando timestamp exacto ====="
docker exec nodo1 bash -c '
  PID=$(pgrep krb5kdc)
  echo "PID a matar: $PID"
  date +%s.%N > /tmp/crash_ts
  kill -9 $PID
'
CRASH_TS=$(docker exec nodo1 cat /tmp/crash_ts)
echo "Crash disparado en: $CRASH_TS"

echo "===== Bombardeando kinit en nodo4 hasta que tenga exito ====="
docker exec nodo4 bash -c '
INICIO=$(date +%s.%N)
INTENTOS=0
while true; do
  INTENTOS=$((INTENTOS+1))
  kdestroy 2>/dev/null
  if kinit jperez <<< "Fis2026Kerb!" > /tmp/kinit_out 2>&1; then
    FIN=$(date +%s.%N)
    echo "Exito en el intento numero: $INTENTOS"
    echo "Tiempo total (desde el primer intento post-crash): $(echo "$FIN - $INICIO" | bc) s"
    break
  fi
  sleep 0.05
done
'

echo "===== Estado final de krb5-kdc en nodo1 (deberia estar activo de nuevo) ====="
docker exec nodo1 systemctl status krb5-kdc --no-pager | head -5