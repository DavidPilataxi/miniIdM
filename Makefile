cat > Makefile <<'EOF'
.PHONY: up down setup nodo1 nodo2 nodo3 nodo4 status clean test

up:
	docker compose up -d --build

down:
	docker compose down

setup: nodo1 nodo2 nodo3 nodo4

nodo1:
	docker exec -it nodo1 bash /opt/scripts/nodo1_setup.sh
	docker exec -it nodo1 bash /opt/scripts/nodo1_complement.sh

nodo2:
	docker exec -it nodo2 bash /opt/scripts/nodo2_setup.sh

nodo3:
	docker exec -it nodo3 bash /opt/scripts/nodo3_setup.sh

nodo4:
	docker exec -it nodo4 bash /opt/scripts/nodo4_setup.sh

status:
	docker compose ps
	docker exec nodo1 systemctl is-active slapd krb5-kdc
	docker exec nodo2 systemctl is-active slapd krb5-kdc kpropd
	docker exec nodo3 systemctl is-active haproxy miniidm-web
	docker exec nodo4 systemctl is-active prometheus grafana-server

test:
	bash crash_test.sh

clean:
	docker compose down -v
EOF