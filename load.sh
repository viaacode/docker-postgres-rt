#!/usr/bin/env bash

[ -z "$1" ] && exit 1

# Recover the dump unless it has been recovered before
if [ ! -s "$PGDATA/PG_VERSION" ]; then

    ORIGDUMP=$1
    DumpBaseName=$(basename $ORIGDUMP)
    DUMPFILE="$RecoveryArea/$DumpBaseName"
    Time=${2:-null}
    
    # Recover the dump file(s) name it (them) pgdump
    echo "$(date '+%m/%d %H:%M:%S'): Recovering dump file: $DUMPFILE"
    [ -r $DUMPFILE ] && rm -fr $DUMPFILE
    cat <<EOF  | socat  -,ignoreof $RecoverySocket
    { \
        "client": "$HOSTNAME", \
        "path": "$ORIGDUMP", \
        "uid": "$(id -u postgres)", \
        "time": "$Time" \
    }
EOF
    [ -r $DUMPFILE ] || exit 5
    ln -s "$DUMPFILE" "/docker-entrypoint-initdb.d/10-$DumpBaseName"
    echo "$(date '+%m/%d %H:%M:%S'): Starting postgres init"
    # Start postgres without listening on a tcp socket
    coproc tailcop { exec docker-entrypoint.sh -h '' 2>&1; }

    # initiate a timeout killer that will stop popstgres (and the container) if init takes too long
    sleep 10800 && echo "$(date '+%m/%d %H:%M:%S'): Timeout during init" && kill $tailcop_PID &

    # Show progress while waiting untill init is complete
    while read -ru ${tailcop[0]} line; do
        echo $line
        [ $(expr "$line" : 'PostgreSQL init process complete; ready for start up') -gt 0 ] && break
    done
    # non-zero exit code occurs when the tailcop file descriptor was closed before 
    # we broke out of the loop
    # for example, postgres stopped or was stopped by the timeout killer 
    [ $? -ne 0 ] && echo "$(date '+%m/%d %H:%M:%S'): Database init failed" &&  exit 1

    while read -ru ${tailcop[0]} line; do
        echo $line
        [ $(expr "$line" : 'LOG:\s*database system is ready to accept connections') -gt 0 ] && break
    done
    [ $? -ne 0 ] && echo "$(date '+%m/%d %H:%M:%S'): Database init failed" &&  exit 1
    sleep 1

    # Init completed, kill the timeout killer
    # A bit rough, but hey we are in a container there will be only one sleep
    pkill -x sleep
    echo "$(date '+%m/%d %H:%M:%S'): Shutting down postgres"
    # Stop the coprocess and show it's output while waiting for it to stop
    kill $tailcop_PID
    cat <&${tailcop[0]}
else
    # delegate control to docker-io/postgres container implementation"
    exec docker-entrypoint.sh postgres
fi
