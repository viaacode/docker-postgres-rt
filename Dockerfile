FROM postgres:9.4
MAINTAINER Herwig Bogaert

ARG RecoverySocketGid=4

RUN apt-get update \
    && apt-get install -y file socat \
    && rm -rf /var/lib/apt/lists/*

#   local postgres user can write to the recovery socket and access the recovery area
RUN usermod -G $RecoverySocketGid postgres

COPY import.sh /docker-entrypoint-initdb.d/10-import.sh
COPY load.sh /usr/local/bin/
COPY recover.sh /usr/local/bin/
RUN ln /usr/local/bin/recover.sh /usr/local/bin/hotstandby.sh

ENV RECOVERY_AREA /recovery_area
ENV RECOVERY_SOCKET "unix:/recovery_socket"

USER postgres
