#!/usr/bin/env bash

case  $(basename $0) in
    hotstandby*)
        HOTSTANDBY='on' ;;
    *)
        HOTSTANDBY='off' ;;
esac

while getopts ":d:l:s:t:" opt; do
    case $opt in
        d) SRCDATADIR=$OPTARG
            ;;
        l) SRCXLOGDIR=$OPTARG
            ;;
        t) Time=$OPTARG
            ;;
        :) exit 1
    esac
done

if [ ! -s "$PGDATA/PG_VERSION" ]; then

    [ -n "$SRCDATADIR" ] || exit 2
    SRCXLOGDIR=${SRCXLOGDIR:=$SRCDATADIR/pg_wal}
    Time=${Time:=null}

    PGDATADIR="$RecoveryArea/$(basename $SRCDATADIR)"
    PGUID=$(id -u postgres)
    REPORT="$RecoveryArea/recovery_report.txt"
    [ -e $REPORT ] && rm -f $REPORT

    # Clean up
    rm -fr $PGDATADIR
    rm -f  $RecoveryArea/[0-9A-F]*[0-9A-F]
    # Do not recover pg_wal (this is needed when not symlinked outside)
    echo "$(date '+%m/%d %H:%M:%S'): Recovering Database files"
    cat <<EOF | socat -,ignoreeof $RecoverySocket
    { \
        "client": "$HOSTNAME", \
        "path": "$SRCDATADIR", \
        "uid": "$PGUID", \
        "time": "$Time", \
        "exclude": ["$SRCDATADIR/pg_wal/**"] \
    }
EOF
    # if pg_wal is a symlink, replace it by a directory:
    [ -L $PGDATADIR/pg_wal ] && rm $PGDATADIR/pg_wal
    [ -d $PGDATADIR/pg_wal ] || mkdir $PGDATADIR/pg_wal

    for i in $PGDATADIR/*; do ln -s $i $PGDATA/; done

    [ -e $PGDATA/pg_ident.conf ] || touch $PGDATA/pg_ident.conf
    cp /usr/share/postgresql/postgresql.conf.sample $PGDATA/postgresql.conf
    # Disable autovacuuum and statistics collection
    sed -ri 's/#?\s*(autovacuum\s*=)[^#]*/\1 off/' $PGDATA/postgresql.conf
    sed -ri 's/#?\s*(track_activities\s*=)[^#]*/\1 off/' $PGDATA/postgresql.conf
    sed -ri 's/#?\s*(track_counts\s*=)[^#]*/\1 off/' $PGDATA/postgresql.conf
    # Take 2 thirds of our memory limit for shared buffers
    MemoryLimit=$(cat /sys/fs/cgroup/memory.max)
    [ -n "$MemoryLimit" ] && sed -ri "s/#?\s*(shared_buffers\s*=)[^#]*/\1 $((MemoryLimit/4096))kB/" $PGDATA/postgresql.conf
    sed -ri 's/#?\s*(max_connections\s*=)[^#]*/\1 2000 /' $PGDATA/postgresql.conf
    sed -ri 's/#?\s*(max_standby_archive_delay\s*=)[^#]*/\1 -1 /' $PGDATA/postgresql.conf

    # Set recovery configuration
    # Start database in read/only mode until consistency checks have completed
    if [ $PG_MAJOR -lt 12 ] ; then
	ConfFile=recovery.conf
    else
	ConfFile=postgresql.conf
        touch $PGDATA/standby.signal
    fi
   if [ "$Time" != "null" ]; then
	# When recovery_target_time is given, postgres may need to examine wal records that have been
	# archived later then the given timestamp in order to find the first commit after the timestamp
	# given. Therfore we shift the time window in which we are looking for backups for 4 hours.
        RPOEpoch=$(date -d "$Time" +%s)
        WalTimeEpoch=$((RPOEpoch + 4*3600))
        WalTime=$(date -d @$WalTimeEpoch -Ins)
    else
        WalTime="$Time"
    fi
    cat <<EOF >>$PGDATA/$ConfFile
    restore_command='echo ''{"client": "$HOSTNAME", "path": "$SRCXLOGDIR/%f", "uid": "$PGUID", "time": "$WalTime"}'' | socat -,ignoreeof $RecoverySocket; mv $RecoveryArea/%f $PGDATA/%p'
EOF
    if [ "$Time" != "null" ]; then
        echo "recovery_target_time='$Time'" >>$PGDATA/$ConfFile
    else
	# If $Time is not set, we recover until consistent
        echo "recovery_target = 'immediate'" >>$PGDATA/$ConfFile
    fi
    echo "host all all samenet trust" > "$PGDATA/pg_hba.conf"
    echo "local all all trust"  >> "$PGDATA/pg_hba.conf"

    echo -e "\n$(date '+%m/%d %H:%M:%S'): Recovery report for $HOSTNAME:\n" >>$REPORT
    cat $PGDATADIR/backup_label 2>&1 | tee -a $REPORT
    echo "$(date '+%m/%d %H:%M:%S'): Starting postgres recovery (hot_standby = $HOTSTANDBY)"

    # Start postgres without listening on a tcp socket
    coproc tailcop { exec docker-entrypoint.sh -h '' 2>&1; }

    # Show progress while waiting untill recovery is complete
    while read -ru ${tailcop[0]} line; do
        echo $line
	# Break when consistent recovery state is reached
        [ $(expr "$line" : '.*LOG:\s*database system is ready to accept .*connections') -gt 0 ] && break
	# Extract certain log entries for the recovery report
        [ $(expr "$line" : '.*LOG:\s*redo') -gt 0 ] && echo $line >>$REPORT
        [ $(expr "$line" : '.*LOG:\s*last completed transaction was at log time') -gt 0 ] && echo $line >>$REPORT
        [ $(expr "$line" : '.*LOG:\s*consistent recovery state reached') -gt 0 ] && echo $line >>$REPORT
    done
    # non-zero exit code occurs when the tailcop file descriptor was closed before
    # we broke out of the loop
    # for example, postgres stopped
    [ $? -ne 0 ] && echo "$(date '+%m/%d %H:%M:%S'): Database recovery failed" | tee -a $REPORT && exit 1

    # If $Time is set, we need to allow time for recovery to continue until the recovery_target is reached
    if [ "$Time" != "null" ]; then
      while read -ru ${tailcop[0]} line; do
        echo $line
	# Break when recovery is complete:
        [ $(expr "$line" : '.*LOG:\s*recovery stopping ') -gt 0 ] && break
      done
    fi
    # continue reading and showing stdout of the coprocess
    # redirecting from ${tailcop[0]} directly to cat does not work, use exec
    exec 3<&${tailcop[0]}
    cat <&3 &
    # Report recovery timestamp
    psql -qAtc "select 'Last replay timestamp: ' || pg_last_xact_replay_timestamp();" | tee -a $REPORT

    echo "$(date '+%m/%d %H:%M:%S'): Checking database integrity"
    pg_dumpall -v --no-sync -f /dev/null
    RC=$? # save rc
    echo "$(date '+%m/%d %H:%M:%S'): Database integrity check endend with exit code $RC" | tee -a $REPORT
    [ $RC -ne 0 ] && echo "$(date '+%m/%d %H:%M:%S'): Database integrity check failed" && exit $RC

    # Leave temporary read-only mode when hotstandby is not requested
    [ $PG_MAJOR -lt 12 ] &&  psql -qAc "select pg_wal_replay_resume();" # These versions require resume before promote
    [ $HOTSTANDBY != 'on' ] && pg_ctl promote --wait --silent --timeout 120

    echo "$(date '+%m/%d %H:%M:%S'): Shutting down postgres"
    # Stop the coprocess and wait for it to shutdown
    [ -n "$tailcop_PID" ] && kill $tailcop_PID && wait $tailcop_PID
fi
# When started with existing PGDATA, just start postgres and keep running
exec docker-entrypoint.sh postgres
