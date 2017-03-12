#!/bin/bash

# based on ideas from:
# https://blog.interlinked.org/tutorials/rsync_time_machine.html
# https://nicaw.wordpress.com/2013/04/18/bash-backup-rotation-script/

# v 0.1 alpha 5



### user options
srchost=''
srcpath=''
dsthost=''
dstpath=''
loglevel=0
opts='--archive --delete'

while [[ $# -gt 1 ]]; do
	case $1 in
		-s|--srchost)
			srchost=$2
			shift 2
		;;
		-d|--dsthost)
			dsthost=$2
			shift 2
		;;
		-l|--loglevel)
			loglevel=$2
			shift 2
		;;
		-e|--exclude)
			opts="$opts --delete-excluded --exclude-from=$2"
			shift 2
		;;
		-o|--options)
			opts="$opts $2"
			shift 2
		;;
		-*)
			_log "unknown option $1" 0
			exit 1
		;;
		*)
			srcpath=$1
			dstpath=$2
			shift 2
	esac
done

if [ -z "$srcpath" ]; then
	_log "no srcpath" 0
	exit 1
fi
if [ -z "$dstpath" ]; then
	_log "no dstpath" 0
	exit 1
fi

incomplete=incomplete
current=current
chperm=777
chuser=nobody
chgroup=users
fnamemonth='monthly'
fnameweek='weekly'
fnameday='daily'
fnamehour='hourly'



rsyncsrc=''
rsyncdst=''
rexec=''


# echo $srchost
# echo $srcpath
# echo $dsthost
# echo $dstpath
# echo $loglevel
# exit 0


### functions
function _log {
	if [ $loglevel -ge $2 ]; then
		echo `date "+%Y-%m-%d %H:%M:%S"` "--" $1
	fi
}



### variables
day_of_month=$(date +"%d")
hour_of_month=$(expr $(expr $(expr $day_of_month - 1) \* 24) + $(date +"%H"))
day_of_week=$(date +"%u")
hour_of_week=$(expr $(expr $(expr $day_of_week - 1) \* 24) + $(date +"%H"))
hour_of_day=$(date +"%H")
fdate=$(date +"%Y-%m-%d %H-%M-%S")
fdatetouch=$(date +"%Y%m%d%H%M.%S")


### lockfile
LOCKFILE="/var/run/tb.$(echo "$srchost$srcpath$dsthost$dstpath" | tr -cd 'A-Za-z0-9_').lock"
_log "creating lockfile ($LOCKFILE)" 1
exec 200>$LOCKFILE
flock -n 200 || exit 1
echo $$ 1>&200



## rsync options
_log "setting options" 1
if [ $loglevel -ge 3 ]; then
	opts="$opts --progress"
fi
if [ $loglevel -eq 2 ]; then
	opts="$opts --verbose"
fi
if [ $loglevel -ge 2 ]; then
	opts="$opts --stats"
fi
if [ $loglevel -eq 0 ]; then
	opts="$opts --quiet"
fi


#Source: remote host set?
if [ -n "$srchost" ]; then
	_log "backup FROM remote: $srchost:$srcpath" 1
	rsyncsrc=$srchost:$srcpath
else
	_log "backup FROM local: $srcpath " 1
	rsyncsrc=$srcpath
fi


#Dest: remote host set?
if [ -n "$dsthost" ]; then
	_log "backup TO remote: $dsthost:$dstpath" 1
	rexec="ssh $dsthost"
	rsyncdst=$dsthost:$dstpath
else
	_log "backup TO local: $dstpath" 1
	rexec=''
	rsyncdst=$dstpath
fi

#if something is remote…
if [ -n "$srchost" ] || [ -n "$dsthost" ]; then
	opts="$opts --partial --append-verify --compress --rsh=\"ssh\""
fi



### check for older version at destination
if $rexec [ -d "$dstpath/$current" ]; then 
	_log "setting link-dest (../$current)" 1
	opts="$opts --link-dest=../$current/"
else
	_log "no previous version available - first backup?" 1
fi



### create destination folder if needed
# just using $incomplete here to allow resuming (no more needed)
if $rexec [ ! -d "$dstpath/$incomplete" ]; then
	_log "creating destination folder ($incomplete)" 1
	$rexec mkdir "$dstpath/$incomplete"
	$rexec chmod $chperm "$dstpath/$incomplete"
	$rexec chown $chuser:$chgroup "$dstpath/$incomplete"
else
	_log "destination folder ($dstpath/$incomplete) already exists?!" 1
fi



### backing up…
_log "backing up files (rsync $opts $rsyncsrc/ $rsyncdst/$incomplete/)" 1

# @TODO: NEEDS TESTING !!! (and refactor…)
retcode=1
tries=3
while [ $retcode -ne 0 ] && [ $tries -gt 0 ]; do
	_log "rsync output start ===================================" 2
	rsync $opts $rsyncsrc/ $rsyncdst/$incomplete/
	_log "rsync output end =====================================" 2
	retcode=$?
	if [ $retcode -ne 0 ]; then
		_log "rsync failed, tries left: $tries" 2
		tries=$(expr $tries - 1)
		if [ $tries -gt 0 ]; then
			_log "sleeping 5min" 1
			sleep 5m
		fi
	fi
done

if [ $retcode -ne 0 ]; then
	_log "cant complete backup, exiting" 1
	exit 1
fi

_log "rsync -a preserves mtime, change for root folder" 3
$rexec touch -t $fdatetouch $dstpath/$incomplete

#_log "fixing permissions" 1
#$rexec chmod -R $chperm $dstpath/$incomplete_$FDATE

#@TODO mehrfahraufruf es scripts abfangen (ordner jeweils überschreiben)
#@TODO yearly?
#move to correct subfolder
_log "Hour of Month: $hour_of_month" 2
if [ $hour_of_month -eq 272 ]; then # 11. 8:00
	mvdst="$dstpath/$fdate $fnamemonth"
else
	_log "Hour of Week: $hour_of_week" 2
	if [ $hour_of_week -eq 153 ]; then # So 9:00
		mvdst="$dstpath/$fdate $fnameweek"
	else
		_log "Hour of Day: $hour_of_day" 2
		if [ $hour_of_day -eq 10 ]; then # 10:00
			mvdst="$dstpath/$fdate $fnameday"
		else
			mvdst="$dstpath/$fdate $fnamehour"
		fi
	fi
fi

_log "moving $dstpath/$incomplete to $mvdst" 1
$rexec mv -f "$dstpath/$incomplete" "$mvdst"

if $rexec [ -d "$dstpath/$current" ]; then 
	_log "deleting symlink ($(readlink $dstpath/$current))" 1
	$rexec rm -f "$dstpath/$current"
fi

_log "recreating symlink to $mvdst" 1
$rexec ln -s "$mvdst" "$dstpath/$current"
$rexec chown -h $chuser:$chgroup "$dstpath/$current"


_log "cleaning up" 1
#@TODO: print deleted folders

#hourly (keep 24h)
$rexec find $dstpath/ -maxdepth 1 -mmin +1440 -name "\*$fnamehour\*" -type d -exec rm -r {} \;
#daily (keep 14 days)
$rexec find $dstpath/ -maxdepth 1 -mtime +14 -name "\*$fnameday\*" -type d -exec rm -r {} \;
#weekly (keep 8+ weeks)
$rexec find $dstpath/ -maxdepth 1 -mtime +60 -name "\*$fnameweek\*" -type d -exec rm -r {} \;
#montly (keep ~13 month)
$rexec find $dstpath/ -maxdepth 1 -mtime +400 -name "\*$fnamemonth\*" -type d -exec rm -r {} \;

_log "done." 1


