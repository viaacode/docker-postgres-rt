FROM postgres:9.4
MAINTAINER Herwig Bogaert

ARG RecoveryAreaGid=4

RUN apt-get update \
    && apt-get install -y file socat \
    && rm -rf /var/lib/apt/lists/*

#   local postgres user can write to the recovery socket and access the recovery area
RUN usermod -G $RecoveryAreaGid postgres

COPY import.sh /docker-entrypoint-initdb.d/10-import.sh
COPY load.sh /usr/local/bin/
COPY recover.sh /usr/local/bin/
RUN ln /usr/local/bin/recover.sh /usr/local/bin/hotstandby.sh

ENV RecoveryArea /recovery_area
ENV RecoverySocket "unix:/recovery_socket"

USER postgres
