# MiniIdM - Infraestructura de Identidad Segura para la FIS

Proyecto de Computación Distribuida (FIS-EPN). Implementa una infraestructura
de identidad centralizada con **Kerberos**, **LDAP**, **PKI** y **Alta
Disponibilidad**, en 4 contenedores Docker con `systemd` real (permite usar
`systemctl start/stop/enable` igual que en una VM).

Realm Kerberos: `FIS.EPN.EC` | Base DN LDAP: `dc=fis,dc=epn,dc=ec`

## Arquitectura

| Nodo | Rol | Hostname / alias |
|------|-----|-------------------|
| nodo1 | CA raíz + LDAP Master + KDC primario | `ldap1.fis.epn.ec`, `kdc1.fis.epn.ec` |
| nodo2 | LDAP réplica + KDC secundario | `ldap2.fis.epn.ec`, `kdc2.fis.epn.ec` |
| nodo3 | HAProxy + Webserver Flask (TLS) | `lb.fis.epn.ec`, `webserver.fis.epn.ec`, `ldap.fis.epn.ec` |
| nodo4 | Cliente Linux + Prometheus + Grafana | `client1.fis.epn.ec`, `monitor.fis.epn.ec` |

```
Balanceador (nodo3: HAProxy)
   |
LDAP Master (nodo1) <--syncrepl--> LDAP Réplica (nodo2)
   |                                    |
KDC Primario (nodo1) <--kprop/60s--> KDC Secundario (nodo2)
   |
Webserver Flask TLS (nodo3) + Cliente/Monitoreo (nodo4)
```

La app (`app/`) centraliza identidades: crear un usuario desde el panel de
admin da de alta simultáneamente la cuenta LDAP y el principal Kerberos.

> **Nota de diseño (punto 5):** el login web usa usuario+contraseña validado
> contra Kerberos vía `kinit` internamente, no SPNEGO/GSSAPI del navegador.
> Decisión consciente, documentada también en el informe.

## Requisitos previos

- Docker + Docker Compose v2
- Linux/WSL2 con soporte para contenedores **privilegiados** (systemd real +
  `NET_ADMIN`/`NET_RAW` para las pruebas con `iptables`)
- ~4 GB de RAM libres

## Estructura

```
app/        # Flask (routes, services, templates)
pki/        # CA raíz y certificados (ver nota de seguridad)
scripts/    # Provisionamiento por nodo + monitoreo
shared/     # Artefactos entre nodos (keytabs, stash)
admin.ldif  # Ejemplo de modificación LDAP
crash_test.sh
docker-compose.yml / Dockerfile / Makefile / requirements.txt
```

## ⚠️ Nota de seguridad: `pki/`

El repo incluye la llave privada de la CA (`pki/ca/ca.key`) y las llaves de
los certificados de hoja. No sería aceptable en producción, pero aquí es
necesario: no existe script que genere la CA desde cero, solo
`gen_ldap2_cert.sh` que firma con una CA ya existente. Sin esas llaves, el
proyecto no se puede levantar desde cero.

## Despliegue

**1. Variables de entorno** — crear `.env` en la raíz:

```bash
cat > .env <<EOF
SECRET_KEY=cambia-esto-por-algo-aleatorio
LDAP_ADMIN_PASSWORD=Fis2026LdapAdmin!
EOF
```

(`LDAP_ADMIN_PASSWORD` debe coincidir con `LDAP_ADMIN_PASS` hardcodeado en
`scripts/nodo1_setup.sh`.)

**2. Levantar contenedores:** `make up`

**3. Provisionar en orden:**

```bash
make nodo1-setup   # CA + LDAP master + KDC primario + complemento (replicación)
make nodo2-setup   # LDAP réplica + KDC secundario
make nodo3-setup   # HAProxy + app Flask
make nodo4-setup   # Cliente + Prometheus + Grafana
```

Si `nodo2-setup` falla buscando `stash`/`kdc.conf`, vuelve a correr
`nodo1_complement.sh` (parte de `nodo1-setup`) primero.

**4. (Opcional) node_exporter en todos los nodos:** `make node-exporter-all`

## Verificación rápida

```bash
docker exec nodo4 bash -c 'kinit jperez <<< "Fis2026Kerb!" && klist'
docker exec nodo4 ldapsearch -x -H ldaps://ldap.fis.epn.ec -b "dc=fis,dc=epn,dc=ec"
curl -k https://localhost:8443/
```

- Prometheus: http://localhost:9090
- Grafana: http://localhost:3000 (`admin`/`admin`, pide cambiarla; dashboard
  "MiniIdM - Infraestructura FIS" se provisiona solo)

### Usuarios de prueba

| Usuario | Rol | Password |
|---------|-----|----------|
| `dpilataxi` | admin | `Fis2026Kerb!` |
| `jperez` | user | `Fis2026Kerb!` |
| `malvan` | user | `Fis2026Kerb!` |

LDAP admin (`cn=admin,dc=fis,dc=epn,dc=ec`): `Fis2026LdapAdmin!`

## Guía de pruebas por punto del PDF

**1. LDAP:**
```bash
docker exec nodo1 ldapsearch -x -H ldaps://ldap1.fis.epn.ec -b "dc=fis,dc=epn,dc=ec"
```

**2. PKI:**
```bash
openssl verify -CAfile pki/ca/ca.crt pki/certs/ldap1.crt
openssl x509 -in pki/certs/ldap1.crt -noout -text | grep -A1 "Public Key Algorithm"
```

**3. Kerberos:**
```bash
docker exec nodo4 bash -c 'kinit jperez <<< "Fis2026Kerb!" && klist'
docker exec nodo1 kadmin.local -q "listprincs"
```

**4. Integración LDAP-Kerberos:** crear un usuario desde el panel web
(`https://localhost:8443/`, login `dpilataxi`/`Fis2026Kerb!`) y confirmar que
aparece en ambos:
```bash
docker exec nodo1 ldapsearch -x -H ldaps://ldap1.fis.epn.ec -b "dc=fis,dc=epn,dc=ec" "(uid=testuser)"
docker exec nodo4 bash -c 'kinit testuser <<< "<password-que-pusiste>" && klist'
```

**5. TLS:**
```bash
curl -k https://localhost:8443/
docker exec nodo3 openssl s_client -connect webserver.fis.epn.ec:443 -CAfile /opt/pki/ca/ca.crt </dev/null
```

**6. Replicación LDAP:**
```bash
docker exec nodo1 systemctl stop slapd
docker exec nodo2 ldapsearch -x -H ldaps://ldap2.fis.epn.ec -b "dc=fis,dc=epn,dc=ec" -s base dn
docker exec nodo1 systemctl start slapd
```

**7. HA de Kerberos:**
```bash
docker exec nodo1 systemctl stop krb5-kdc
docker exec nodo4 bash -c 'kdestroy; time kinit jperez <<< "Fis2026Kerb!" && klist'
docker exec nodo1 systemctl start krb5-kdc
```

**8. Balanceo de carga:**
```bash
docker exec nodo1 systemctl stop slapd
docker exec nodo3 ldapsearch -x -H ldaps://ldap.fis.epn.ec -b "dc=fis,dc=epn,dc=ec" -s base dn
docker exec nodo1 systemctl start slapd
```

**9. Inyección de fallos:**
```bash
# Crash + medición de tiempo (automatizado)
bash crash_test.sh

# Partición de red
docker exec nodo2 iptables -A INPUT -s 172.20.0.11 -j DROP
docker exec nodo2 iptables -F   # revertir

# Certificado expirado
docker exec nodo1 cp /opt/pki/certs/ldap1_expired.crt /etc/ldap/certs/ldap1.crt
docker exec nodo1 cp /opt/pki/certs/ldap1_expired.key /etc/ldap/certs/ldap1.key
docker exec nodo1 systemctl restart slapd
docker exec nodo3 openssl s_client -connect ldap.fis.epn.ec:636 -CAfile /opt/pki/ca/ca.crt </dev/null
# restaurar:
docker exec nodo1 cp /opt/pki/certs/backup/ldap1.crt.valido /etc/ldap/certs/ldap1.crt
docker exec nodo1 cp /opt/pki/certs/backup/ldap1.key.valido /etc/ldap/certs/ldap1.key
docker exec nodo1 systemctl restart slapd
```

**10. Monitoreo:**
```bash
curl -s http://localhost:9090/api/v1/targets | grep -o '"health":"[a-z]*"'
docker exec nodo4 curl -s localhost:9100/metrics | grep ldap_replication
```
Confirmar en Grafana (`localhost:3000`) el dashboard con CPU/memoria de los
4 nodos y `ldap_replication_lag_seconds`.


## Uso de herramientas de IA

Durante el desarrollo de este proyecto se utilizaron herramientas de inteligencia artificial como apoyo para:
- investigación técnica
- comprensión de conceptos
- depuración
- documentación

Toda la implementación, adaptación, pruebas y comprensión del código fueron realizadas y verificadas manualmente.

## Autor

David Pilataxi — Computación Distribuida
