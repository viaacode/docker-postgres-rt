#!/usr/bin/env bash

[ -z "$1" ] && exit 1

case  $(basename $0) in
    hotstandby*)
        HOTSTANDBY='on' ;;
    *)
        HOTSTANDBY='off' ;;
esac
    
if [ ! -s "$PGDATA/PG_VERSION" ]; then

    SRCDATADIR="$1"
    SRCXLOGDIR=${2:-$SRCDATADIR/pg_xlog}
    Time=${3:-null}

    PGDATADIR="$RECOVERY_AREA/$(basename $SRCDATADIR)"
    PGUID=$(id -u postgres)
    REPORT="$RECOVERY_AREA/recovery_report.txt"
    [ -e $REPORT ] && rm -f $REPORT

    # Clean up
    rm -fr $PGDATADIR
    rm -f  $RECOVERY_AREA/[0-9A-F]*[0-9A-F]
    # Do not recover pg_xlog (this is needed when not symlinked outside)
    #echo "$SRCDATADIR/pg_xlog/**" >$RECOVERY_AREA/exclude.lst
    echo "$(date '+%m/%d %H:%M:%S'): Recovering Database files"
    cat <<EOF | socat -,ignoreeof $RECOVERY_SOCKET
    { \
        "client": "$HOSTNAME", \
        "path": "$SRCDATADIR", \
        "uid": "$PGUID", \
        "time": "$Time", \
        "exclude": ["$SRCDATADIR/pg_xlog/**"] \
    }
EOF
    # logs are restored in $RECOVERY_AREA, postgres must be able to mv them
    chown postgres $RECOVERY_AREA
    
    # if pg_xlog is a symlink, replace it by a directory:
    [ -L $PGDATADIR/pg_xlog ] && rm $PGDATADIR/pg_xlog
    [ -d $PGDATADIR/pg_xlog ] || gosu postgres mkdir $PGDATADIR/pg_xlog
    
    for i in $PGDATADIR/*; do ln -s $i $PGDATA/; done
    
    # Create recovery.conf file
    gosu postgres cat <<-EOF >$PGDATA/recovery.conf
        standby_mode=$HOTSTANDBY
        restore_command='echo ''{"client": "$HOSTNAME", "path": "$SRCXLOGDIR/%f", "uid": "$PGUID"}'' | sudo socat -,ignoreeof $RECOVERY_SOCKET; mv $RECOVERY_AREA/%f $PGDATA/%p'
	EOF
    [ "$Time" != "null" ] && echo "recovery_target_time='$Time'" >>$PGDATA/recovery.conf

    [ -e $PGDATA/pg_ident.conf ] || gosu postgres touch $PGDATA/pg_ident.conf
    gosu postgres cp /usr/share/postgresql/postgresql.conf.sample $PGDATA/postgresql.conf
    gosu postgres sed -ri "s/#? *hot_standby *= *\\w+/hot_standby = $HOTSTANDBY/" $PGDATA/postgresql.conf 
    gosu postgres sed -ri 's/#? *max_connections *= *\w+/max_connections = 500/' $PGDATA/postgresql.conf 
    gosu postgres echo "host all all samenet trust" > "$PGDATA/pg_hba.conf"
    gosu postgres echo "local all all trust"  >> "$PGDATA/pg_hba.conf"
    
    echo -e "\n$(date '+%m/%d %H:%M:%S'): Recovery report for $HOSTNAME:\n" >>$REPORT
    cat $PGDATADIR/backup_label 2>&1 | tee -a $REPORT
    echo "$(date '+%m/%d %H:%M:%S'): Starting postgres recovery (hot_standby = $HOTSTANDBY)"

    # When not called as hotstandby, recover the datavase and stop
    if [ $HOTSTANDBY == 'off' ]; then
        echo "$(date '+%m/%d %H:%M:%S'): Starting postgres recovery"
        # Start postgres without listening on a tcp socket
        coproc tailcop { exec docker-entrypoint.sh -h '' 2>&1; }

        # initiate a timeout killer that will stop popstgres if recovery takes too long
        sleep 10800 && echo "$(date '+%m/%d %H:%M:%S'): Timeout during recovery" && kill $tailcop_PID &

        # Show progress while waiting untill recovery is complete
        while read -ru ${tailcop[0]} line; do
            echo $line
            [ $(expr "$line" : 'LOG:\s*redo') -gt 0 ] && echo $line >>$REPORT
            [ $(expr "$line" : 'LOG:\s*last completed transaction was at log time') -gt 0 ] && echo $line >>$REPORT
            [ $(expr "$line" : 'LOG:\s*consistent recovery state reached') -gt 0 ] && echo $line >>$REPORT
            [ $(expr "$line" : 'LOG:\s*database system is ready to accept connections') -gt 0 ] && break
        done

        # non-zero exit code occurs when the tailcop file descriptor was closed before 
        # we broke out of the loop
        # for example, postgres stopped or was stopped by the timeout killer 
        [ $? -ne 0 ] && echo "$(date '+%m/%d %H:%M:%S'): Database recovery failed" | tee -a $REPORT && exit 1

        # Recovery completed, kill the timeout killer
        # A bit rough, but hey we are in a container there will be only one sleep
        pkill -x sleep

        echo "$(date '+%m/%d %H:%M:%S'): Checking database integrity"
        gosu postgres pg_dumpall -v -f /dev/null 
        RC=$? # save rc
        echo "$(date '+%m/%d %H:%M:%S'): Database integrity check endend with exit code $RC" | tee -a $REPORT
        [ $RC -ne 0 ] && echo "$(date '+%m/%d %H:%M:%S'): Database integrity check failed" && exit $RC

        echo "$(date '+%m/%d %H:%M:%S'): Shutting down postgres"
        # Stop the coprocess and show it's output while waiting for it to stop
        kill $tailcop_PID
        cat <&${tailcop[0]}
        exit 0
    fi
fi

# Xhen called as hotstandby or with docker start with existing PGDATA,
# just start postgres and keep running
exec docker-entrypoint.sh postgres

