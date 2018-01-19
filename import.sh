#!/usr/bin/env bash
DUMPFILE=$1

echo "$(date '+%m/%d %H:%M:%S'): Importing Dump files"
cd $RecoveryArea
[ -d pgdump ] && FILES="pgdump/*" || FILES="pgdump"

for dump in $FILES; do
  DBNAME=$(pg_restore -l "$dump" | grep dbname: | cut -f2 -d: | tr -d ' ')
  echo "  $(date '+%m/%d %H:%M:%S'): Importing $DBNAME from $dump"
  [ "$DBNAME" == 'postgres' ] && OPT="--clean" || OPT="-C"
  pg_restore $OPT --no-acl --no-owner -j 4 -d postgres $RecoveryArea/$dump
done
echo "$(date '+%m/%d %H:%M:%S'): Finisched import dumpfiles"
