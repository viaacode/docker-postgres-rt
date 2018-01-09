FROM postgres:9.4

RUN apt-get update \
    && apt-get install -y file socat sudo \
    && rm -rf /var/lib/apt/lists/*

RUN echo "postgres ALL=(root) NOPASSWD:/usr/bin/socat" >/etc/sudoers.d/socat

COPY import.sh /docker-entrypoint-initdb.d/10-import.sh
COPY load.sh /
COPY recover.sh /
RUN ln /recover.sh /hotstandby.sh 

ENV RECOVERY_AREA /recovery_area
ENV RECOVERY_SOCKET "unix:/recovery_socket"

