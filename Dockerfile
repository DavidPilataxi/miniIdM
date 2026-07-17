FROM jrei/systemd-ubuntu:22.04

# Evita prompts interactivos de apt (region horaria, keyboard, etc.)
ENV DEBIAN_FRONTEND=noninteractive

# Paquetes base que van a necesitar TODOS los nodos.
# Los paquetes especificos de cada rol (slapd, krb5-kdc, haproxy, etc.)
# se instalan luego desde los scripts de aprovisionamiento de cada nodo
# (scripts/nodo1_setup.sh, scripts/nodo2_setup.sh, etc.), no aqui,
# para mantener la imagen base liviana y reusable por los 4 nodos.
RUN apt-get update && apt-get install -y \
    iproute2 \
    iptables \
    net-tools \
    iputils-ping \
    dnsutils \
    curl \
    wget \
    openssl \
    vim \
    less \
    sudo \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# systemd necesita estos targets habilitados para arrancar limpio en contenedor
RUN systemctl set-default multi-user.target

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
