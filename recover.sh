#!/usr/bin/env bash

case  $(basename $0) in
    hotstandby*)
        HOTSTANDBY='on' ;;
    *)
        HOTSTANDBY='off' ;;
esac

while getopts ":d:l:t:" opt; do
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
    rm -f  $RecoveryArea/[0-9A-F]*[0-9A-F].backup*
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
    # Set parameters that depend on memory size
    MemoryLimit=$(cat /sys/fs/cgroup/memory.max)
    if [ -n "$MemoryLimit" ]; then
        # Take half our memory limit for shared buffers
        sed -ri "s/#?\s*(shared_buffers\s*=)[^#]*/\1 $((MemoryLimit/2048))kB/" $PGDATA/postgresql.conf
        # Set Workmem to 1/32 of the memory size
        sed -ri "s/#?\s*(work_mem\s*=)[^#]*/\1 $((MemoryLimit/32768))kB /" $PGDATA/postgresql.conf
    fi
    sed -ri 's/#?\s*(max_connections\s*=)[^#]*/\1 2000 /' $PGDATA/postgresql.conf
    sed -ri 's/#?\s*(max_standby_archive_delay\s*=)[^#]*/\1 -1 /' $PGDATA/postgresql.conf

    # Set recovery configuration
    # Start database in read/only mode until consistency checks have completed
    touch $PGDATA/standby.signal
    if [ "$Time" != "null" ]; then
	# When recovery_target_time is given, postgres may need to examine wal records that have been
	# archived later then the given timestamp in order to find the first commit after the timestamp
	# given. Therfore we shift the time window in which we are looking for backups for 4 hours.
        RPOEpoch=$(date -d "$Time" +%s)
        WalTimeEpoch=$((RPOEpoch + 4*3600))
        AvWalTime=$(date -d @$WalTimeEpoch -Ins)
        WalTime=$(date -ud @$RPOEpoch -Is)  # This is in UTC
    else
        AvWalTime="$Time"
    fi
    cat <<EOF >>$PGDATA/postgresql.conf
    restore_command='echo ''{"client": "$HOSTNAME", "path": "$SRCXLOGDIR/%f", "uid": "$PGUID", "time": "$AvWalTime"}'' | socat -,ignoreeof $RecoverySocket; mv $RecoveryArea/%f $PGDATA/%p'
EOF
    # Set recovery target (Use UTC timestamp)
    # Let recovery_target_action at the default value of 'pause'
    # We only promote after running consistency checks
    if [ "$Time" != "null" ]; then
        echo "recovery_target_time='$WalTime'" >>$PGDATA/postgresql.conf
	echo "recovery_target_inclusive = false" >>$PGDATA/postgresql.conf
    else
        # If $Time is not set, we recover until consistent
        echo "recovery_target = 'immediate'" >>$PGDATA/postgresql.conf
    fi
    echo "host all all samenet trust" > "$PGDATA/pg_hba.conf"
    echo "local all all trust"  >> "$PGDATA/pg_hba.conf"

    echo -e "\n$(date '+%m/%d %H:%M:%S'): Recovery report for $HOSTNAME:\n" >>$REPORT
    if [ $PG_MAJOR -ge 14 ]; then
      # only non-exclusive backups in version 14 and above
      # First recover the backup label
      BACKUP_LABEL_FILE=$(cat $PGDATADIR/backup.info)
      cat <<EOF | socat -,ignoreeof $RecoverySocket
      { \
          "client": "$HOSTNAME", \
          "path": "$BACKUP_LABEL_FILE", \
          "uid": "$PGUID", \
          "time": "$Time" \
      }
EOF
      mv $RecoveryArea/$(basename "$BACKUP_LABEL_FILE") "$PGDATA/backup_label"
    fi
    cat $PGDATA/backup_label 2>&1 | tee -a $REPORT
    echo "$(date '+%m/%d %H:%M:%S'): Starting postgres recovery (hot_standby = $HOTSTANDBY)"

    # Start postgres without listening on a tcp socket
    coproc tailcop { exec docker-entrypoint.sh -h '' 2>&1; }

    # Show progress while waiting untill consistent recovery state reached
    while read -ru ${tailcop[0]} line; do
        echo $line
        # Break when recover is finished
        [ $(expr "$line" : '.*LOG:\s*recovery stopping ') -gt 0 ] && break
        # Extract certain log entries for the recovery report
        [ $(expr "$line" : '.*LOG:.*\sredo\s') -gt 0 ] && echo $line >>$REPORT
        [ $(expr "$line" : '.*LOG:\s*consistent recovery state reached') -gt 0 ] && echo $line >>$REPORT
    done
    # non-zero exit code occurs when the tailcop file descriptor was closed before
    # we broke out of the loop
    # for example, postgres stopped
    [ $? -ne 0 ] && echo "$(date '+%m/%d %H:%M:%S'): Database recovery failed" | tee -a $REPORT && exit 1

    # continue reading and showing stdout of the coprocess
    # redirecting from ${tailcop[0]} directly to cat does not work, use exec
    exec 3<&${tailcop[0]}
    cat <&3 &
    # Report recovery timestamp
    psql -qAtc "select 'Last replay timestamp: ' || pg_last_xact_replay_timestamp();" | tee -a $REPORT

    # Check integrity unless recovery target is given or hotstandby is on
    if [ "$Time" == "null"  -a $HOTSTANDBY != 'on' ]; then
      echo "$(date '+%m/%d %H:%M:%S'): Checking database integrity"
      pg_dumpall -v --no-sync -f /dev/null
      RC=$? # save rc
      echo "$(date '+%m/%d %H:%M:%S'): Database integrity check endend with exit code $RC" | tee -a $REPORT
      [ $RC -ne 0 ] && echo "$(date '+%m/%d %H:%M:%S'): Database integrity check failed" && exit $RC
    fi

    # Leave temporary read-only mode (promote) when hotstandby is not requested
    # When hotstandby, we do not promote and leave the recovery pauzed such
    # that recovery can be continued
    # by altering the recovery target and restarting the container.
    if [ $HOTSTANDBY != 'on' ]; then
      kill $!  # Stop the cat process reading the output of our coprocces
      psql -qAc "select pg_wal_replay_resume();" # This will promote if recovery target has been reached
      # Wait until promotion is completed.
      while read -ru ${tailcop[0]} line; do
          echo $line
          [ $(expr "$line" : '.*LOG:\s*database system is ready to accept .*connections') -gt 0 ] && break
      done
    fi

    # Shut down the database in order to restart it using the original postgresql container's
    # entrypoint. At this point, postgres will start listening on its public TCP socket
    # signaling that recovery is completed.
    echo "$(date '+%m/%d %H:%M:%S'): Shutting down postgres"
    # Stop the coprocess and wait for it to shutdown
    [ -n "$tailcop_PID" ] && kill $tailcop_PID && wait $tailcop_PID
fi
# When started with existing PGDATA, just start postgres and keep running
exec docker-entrypoint.sh postgres
