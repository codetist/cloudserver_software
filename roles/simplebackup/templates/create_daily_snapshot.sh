#!/bin/bash
##
# Libs
##
. {{ monitoring_lib_dir }}/metricslib.sh
##
# CONFIG
##

# Formatted date infos
WEEK_OF_YEAR=`date +%U`
DAY_OF_YEAR=`date +%j`
MONTH_OF_YEAR=`date +%m`
YEAR=`date +%Y`
DAY_OF_MONTH=`date +%d`
NAME_OF_MONTH=`date +%b`

# config vars
OWNDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
LOGDIR={{ backup_logs_dir }}
LOGFILE={{ backup_logs_dir }}/snapshot_$YEAR$MONTH_OF_YEAR$DAY_OF_MONTH.log
SYNCDIR={{ backup_sync_dir }}
SYNCFILELIST={{ backup_dir }}/sync_list.txt
SNAPSHOTDIR={{ backup_snapshots_dir }}
SNAPSHOTFILE={{ backup_snapshots_dir }}/snapshot_$YEAR$MONTH_OF_YEAR$DAY_OF_MONTH.tar.gz
SNAPSHOTFILELIST={{ backup_dir }}/snapshot_list.txt
SNAPSHOTHISTORYDIR={{ backup_snapshots_history_dir }}
NOTIFICATIONMAIL={{ backup_mail_recipient }}
SERVERNAME={{ host_name }}
PODMANUSER={{ podman_user }}

################################## FUNC ##################################

log () {

  DATE=`date +%d.%m.%y-%T`
  echo "LOG: $DATE | $1"

  if [ -n "$LOGFILE" ]
  then
    echo "LOG: $DATE | $1" >> $LOGFILE
  fi
}

quit_with_error () {
  ERROR_SUBJECT="Backup failed!"
  incCounter BACKUP_FAIL

  if [ -n "$LOGFILE" ]
  then
    echo -e "See Logs attached:\n\n" | mail -s "$ERROR_SUBJECT" -A $LOGFILE $NOTIFICATIONMAIL
  else
    echo -e "No log file available." | mail -s "$ERROR_SUBJECT" $NOTIFICATIONMAIL
  fi

  exit 1
}

################################## MAIN ##################################

##
# check for root
##
if [[ $EUID -ne 0 ]]; then
    echo "This scripts needs to be run as root." >&2
    exit 1
fi

##
# prepare backup
##
rc=0
touch $LOGFILE
log "Backup started...."

log "Move existing snapshot(s) to history dir..."
mv $SNAPSHOTDIR/*.tar.gz $SNAPSHOTHISTORYDIR
((rc=rc+$?))

log "Creating snapshot..."

if [ $rc -ne 0 ]
then
  log "ERROR: Moving existing snapshots failed!"
  quit_with_error
fi

###
##
## Snapshots
##
###

##
# stop containers
#
{% for compose in composes_to_snapshot %}
sudo -u $PODMANUSER bash -c 'cd {{ containers_root }}/{{ compose }}; podman compose down' >> $LOGFILE
((rc=rc+$?))
{% endfor %}

if [ $rc -ne 0 ]
then
  log "ERROR: Could not stop one or more composes!"
  quit_with_error
fi

##
# do snapshot
##
grep -v '^#' $SNAPSHOTFILELIST | tar -czvpf $SNAPSHOTFILE --exclude='^#' -T -  >> $LOGFILE
((rc=rc+$?))
if [ $rc -ne 0 ]
then
  log "ERROR: Tar failed!"
  quit_with_error
fi

##
# start containers
#
{% for compose in composes_to_snapshot %}
sudo -u $PODMANUSER bash -c 'cd {{ containers_root }}/{{ compose }}; podman compose up -d' $PODMANUSER  >> $LOGFILE
((rc=rc+$?))
{% endfor %}

if [ $rc -ne 0 ]
then
  log "ERROR: Could not start one or more composes!"
  quit_with_error
fi

###
##
## Syncs
##
###

##
# stop containers
#
{% for compose in composes_to_sync %}
sudo -u $PODMANUSER bash -c 'cd {{ containers_root }}/{{ compose }}; podman compose down' >> $LOGFILE
((rc=rc+$?))
{% endfor %}

if [ $rc -ne 0 ]
then
  log "ERROR: Could not stop one or more composes!"
  quit_with_error
fi

##
# do sync
##
log "Syncing files..."
grep -v '^#' "$SYNCFILELIST" > /tmp/syncfilelist.$$
((rc=rc+$?))

while read -r ENTRY; do
  rsync -avR --delete --exclude='.*' "$ENTRY" "$SYNCDIR/"
done < /tmp/syncfilelist.$$ >> $LOGFILE
((rc=rc+$?))

rm -f /tmp/syncfilelist.$$ >> $LOGFILE
((rc=rc+$?))

if [ $rc -ne 0 ]
then
  log "ERROR: Syncing files failed!"
  quit_with_error
fi

##
# start containers
#
{% for compose in composes_to_sync %}
sudo -u $PODMANUSER bash -c 'cd {{ containers_root }}/{{ compose }}; podman compose up -d' $PODMANUSER  >> $LOGFILE
((rc=rc+$?))
{% endfor %}

if [ $rc -ne 0 ]
then
  log "ERROR: Could not start one or more composes!"
  quit_with_error
fi

##
# cleanup
##

log "Cleaning up..."

# Make files readable for other users
chmod u=rw,go=r $LOGDIR/*.log >> $LOGFILE
((rc=rc+$?))
chown -R root:root $SYNCDIR/ >> $LOGFILE
((rc=rc+$?))
chmod -R u=rw,go=r $SYNCDIR/ >> $LOGFILE
((rc=rc+$?))
find "$SYNCDIR" -type d -exec chmod go+x {} \; >> $LOGFILE
((rc=rc+$?))
chmod u=rw,go=r $SNAPSHOTDIR/*.tar.gz >> $LOGFILE
((rc=rc+$?))

# delete old logs and snapshots
find $LOGDIR -name "*.log" -type f -mtime +30 -delete >> $LOGFILE
((rc=rc+$?))
find $SNAPSHOTDIR -name "*.tar.gz" -type f -mtime +60 -delete >> $LOGFILE
((rc=rc+$?))

if [ $rc -ne 0 ]
then
  log "ERROR: There were errors during cleanup!"
  quit_with_error
fi

log "Backup finished...."
incCounter BACKUP_OK

exit 0


