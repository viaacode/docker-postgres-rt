#!/usr/bin/env bash
while getopts ":d:l:t:" opt; do
    case $opt in
        d) ORIGDUMP=$OPTARG
            ;;
        t) Time=$OPTARG
            ;;
        :) exit 1
    esac
done

# Recover the dump unless it has been recovered before
if [ ! -s "$PGDATA/PG_VERSION" ]; then
    [ -z "$ORIGDUMP" ] && exit 1 # BackupDir mandatary
    Time=${Time:=null}

    DumpBaseName=$(basename $ORIGDUMP)
    DUMPFILE="$RecoveryArea/$DumpBaseName"
    
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
    cp /usr/share/postgresql/postgresql.conf.sample /var/lib/postgresql/postgresql.conf
    # Disable autovacuuum and statistics collection
    sed -ri 's/#?\s*(autovacuum\s*=)[^#]*/\1 off/' /var/lib/postgresql/postgresql.conf
    sed -ri 's/#?\s*(track_activities\s*=)[^#]*/\1 off/' /var/lib/postgresql/postgresql.conf
    sed -ri 's/#?\s*(track_counts\s*=)[^#]*/\1 off/' /var/lib/postgresql/postgresql.conf
    # Take 2 thirds of our memory limit for shared buffers
    MemoryLimit=$(cat /sys/fs/cgroup/memory.max)
    [ -n "$MemoryLimit" ] && sed -ri "s/#?\s*(shared_buffers\s*=)[^#]*/\1 $((MemoryLimit/4096))kB/" /var/lib/postgresql/postgresql.conf
    # Start postgres without listening on a tcp socket
    export POSTGRES_PASSWORD="$RecoverySecret"
    coproc tailcop { exec docker-entrypoint.sh -h '' -c 'config_file=/var/lib/postgresql/postgresql.conf' 2>&1; }

    # initiate a timeout killer that will stop popstgres (and the container) if init takes too long
    sleep 10800 && echo "$(date '+%m/%d %H:%M:%S'): Timeout during init" && kill $tailcop_PID &

    # Show progress while waiting untill init is complete
    while read -ru ${tailcop[0]} line; do
        echo $line
        [ $(expr "$line" : 'PostgreSQL init process complete; ready for start up') -gt 0 ] && break
    done
    # non-zero exit code occurs when the tailcop file descriptor was closed before 
    # we broke out of the loop
    [ $? -ne 0 ] && echo "$(date '+%m/%d %H:%M:%S'): Database init failed" &&  exit 1

    while read -ru ${tailcop[0]} line; do
        echo $line
        [ $(expr "$line" : '.*LOG:\s*database system is ready to accept connections') -gt 0 ] && break
    done
    [ $? -ne 0 ] && echo "$(date '+%m/%d %H:%M:%S'): Database init failed" &&  exit 1
    # continue reading and showing stdout of the coprocess
    exec 3<&${tailcop[0]}
    cat <&3 &
    echo "$(date '+%m/%d %H:%M:%S'): Shutting down postgres"
    # Stop the coprocess and show it's output while waiting for it to stop
    [ -n "$tailcop_PID" ] && kill $tailcop_PID && wait $tailcop_PID
    # Copy our custom config file to the default config
    cp /var/lib/postgresql/postgresql.conf $PGDATA/postgresql.conf
fi
exec docker-entrypoint.sh postgres
