#!/bin/bash

# based on ideas from:
# https://blog.interlinked.org/tutorials/rsync_time_machine.html
# https://nicaw.wordpress.com/2013/04/18/bash-backup-rotation-script/

# v 0.1 alpha 7


###############################################################################
#
# Variables
#
###############################################################################

# Source Remote Host (ex 192.168.0.1 or backupuser@myserver.local) - requires ssh-key-setup
srchost=''
# Source Path (ex. /mnt/user) - will be passed to rsync as is
srcpath=''
# Destination Remote Host (same as $srchost)
dsthost=''
# Destination Path - With trailing Slash
dstpath=''
# Loglevel defines how much is logged:
# 0 = nothing
# 1 = basic status info + rsync --verbose
# 2 = more detailed infos (debug/technical stuff) + rsync --stats
# 3 = even more debug info + rsync --progress
loglevel=0
# rsync options (more are set depending on above vars)
opts='--archive --delete'
# folder name for incomplete backups
incomplete=incomplete
# name for symlink to current backup
current=current
# folder permissions for $incomplete & current (not implemented)
chperm=777
# folder user for $incomplete & $current (not implemented)
chuser=nobody
# folder group for $incomplete & $current (not implemented)
chgroup=users
# suffix for monthly, weekly, daily & hourly backups
fnamemonth='m'
fnameweek='w'
fnameday='d'
fnamehour='h'
# keep backups n days, used with -mtime
keephourly=1
keepdaily=14
keepweekly=56 #8 * 7
keepmonthly=504 # 18 * 4 * 7

#rsync source & destination and remote exec command - set by script!
rsyncsrc=''
rsyncdst=''
rexec=''

#some internal folder naeming stuff
fdate=$(date +"%Y-%m-%d_%H-%M-%S")
fdatetouch=$(date +"%Y%m%d%H%M.%S")
findpattern=[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]-[0-9][0-9]_

#warnings counter
warncount=0

#Lockfile
LOCKFILE=''

#rsync loop 
retcode=1
tries=2

#old symlink target
oldlink=''

#getopts
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
			_log "unknown option $1. exiting." 0
			exit 1
		;;
		*)
			srcpath=$1
			dstpath=$2
			shift 2
	esac
done


if [ -z "$srcpath" ]; then
	_log "no srcpath. exiting." 0
	exit 101
fi
if [ -z "$dstpath" ]; then
	_log "no dstpath. exiting." 0
	exit 102
fi



### log function to add timestamp before string
function _log {
	if [ $loglevel -ge $2 ]; then
		echo $(date "+%Y-%m-%d %H:%M:%S") "--" $1
	fi
}

#cleanup function, deletes old backups
function _cleanup {
	found="$($rexec find $dstpath -maxdepth 1 -mtime +$1 -name "$2" -type d)"
	for f in $found; do
		warncount=$(($warncount + 1))
		_log "deleting $f" 1
		#rm -r "$f"
	done
}

_log "==================================================" 1
_log "New Backup Started                                " 1
_log "==================================================" 1

### lockfile
LOCKFILE="/var/run/tb.$(echo "$srchost$srcpath$dsthost$dstpath" | tr -cd 'A-Za-z0-9_').lock"
if [ -e ${LOCKFILE} ] && kill -0 `cat ${LOCKFILE}`; then
	_log "Lockfile already exists! exiting." 0
    exit 103
fi

# make sure the lockfile is removed when we exit and then claim it
trap "rm -f ${LOCKFILE}; exit" INT TERM EXIT
echo $$ > ${LOCKFILE}
_log "Lockfile created" 2


## rsync options
_log "setting rsync output options for Loglevel $loglevel" 2
if [ $loglevel -ge 3 ]; then
	opts="$opts --progress"
fi
if [ $loglevel -ge 2 ]; then
	opts="$opts --stats"
fi
if [ $loglevel -ge 1 ]; then
	opts="$opts --verbose"
fi
if [ $loglevel -eq 0 ]; then
	opts="$opts --quiet"
fi


#Source: remote host set?
if [ -n "$srchost" ]; then
	rsyncsrc=$srchost:$srcpath
else
	rsyncsrc=$srcpath
fi
_log "SRC: $rsyncsrc" 1


#Dest: remote host set?
if [ -n "$dsthost" ]; then
	rexec="ssh $dsthost"
	rsyncdst=$dsthost:$dstpath
else
	rexec=''
	rsyncdst=$dstpath
fi
_log "DST: $rsyncdst" 1

#if something is remote…
if [ -n "$srchost" ] || [ -n "$dsthost" ]; then
	opts="$opts --partial --append-verify --compress --rsh=\"ssh\""
fi



### check for older version at destination
if $rexec [ -d "$dstpath$current" ]; then 
	_log "setting link-dest (../$current)" 2
	opts="$opts --link-dest=../$current/"
else
	_log "no previous version available - first backup." 1
fi



### create destination folder if needed
# just using $incomplete here to allow resuming (no more needed)
if $rexec [ ! -d "$dstpath$incomplete" ]; then
	
	_log "creating destination folder ($incomplete)" 2

	$rexec mkdir "$dstpath$incomplete"
	if [ $? -ne 0 ]; then 
		_log "Cant create $dstpath$incomplete. exiting." 0
		exit 104
	fi

	$rexec chmod $chperm "$dstpath$incomplete"
	if [ $? -ne 0 ]; then
		_log "Cant chmod $dstpath$incomplete" 0
		$warncount=$(expr $warncount + 1)
		#exit 105
	fi

	$rexec chown $chuser:$chgroup "$dstpath$incomplete"
	if [ $? -ne 0 ]; then
		_log "Cant chown $dstpath$incomplete" 0
		$warncount=$(expr $warncount + 1)
		#exit 106
	fi

	_log "destination folder created" 2
else
	_log "destination folder ($dstpath$incomplete) already exists - resuming." 1
fi



### backing up…
_log "backing up files (rsync $opts $rsyncsrc $rsyncdst$incomplete/)" 2

# @TODO: needs testing ! (and refactor…)
while [ $retcode -ne 0 ] && [ $tries -gt 0 ]; do
	_log "rsync output:" 1
	_log "==================================================" 1
	rsync $opts $rsyncsrc $rsyncdst$incomplete/
	retcode=$?
	_log "==================================================" 1
	if [ $retcode -ne 0 ]; then
		_log "rsync failed, tries left: $tries" 1
		$warncount=$(expr $warncount + 1)
		tries=$(expr $tries - 1)
		if [ $tries -ge 0 ]; then
			_log "sleeping 5min" 1
			sleep 5m
		fi
	fi
done

if [ $retcode -ne 0 ]; then
	_log "cant complete backup. exiting." 1
	exit 107
fi

_log "rsync -a preserves mtime, change for root folder" 3
$rexec touch -t $fdatetouch $dstpath$incomplete
if [ $? -ne 0 ]; then
	_log "Cant touch $dstpath$incomplete" 0
	$warncount=$(expr $warncount + 1)
fi

#_log "fixing permissions" 1
#$rexec chmod -R $chperm $dstpath/$incomplete_$FDATE


#@TODO yearly?
#move to correct subfolder
if [ -z "$($rexec find $dstpath -type d -maxdepth 1 -name "*_$fnamemonth" -mtime -30)" ]; then
	_log "Creating monthly Backup…" 2
	mvdst="$dstpath$(echo $fdate)_$fnamemonth"
elif [ -z "$($rexec find $dstpath -type d -maxdepth 1 -name "*_$fnameweek" -mtime -7)" ]; then
	_log "Creating weekly Backup" 2
	mvdst="$dstpath$(echo $fdate)_$fnameweek"
elif [ -z "$($rexec find $dstpath -type d -maxdepth 1 -name "*_$fnameday" -mtime -1)" ]; then
	_log "Creating daily Backup" 2
	mvdst="$dstpath$(echo $fdate)_$fnameday"
else
	_log "Creating hourly Backup" 2
	mvdst="$dstpath$(echo $fdate)_$fnamehour"
fi

_log "Saving Backup as $mvdst" 1
$rexec mv -f "$dstpath$incomplete" "$mvdst"
if [ $? -ne 0 ]; then
	_log "Cant move $dstpath$incomplete to $mvdst. exiting." 0
	exit 108
fi


if $rexec [ -d "$dstpath$current" ]; then 
	oldlink=$($rexec readlink $dstpath$current)
	_log "deleting symlink ($oldlink)" 2
	$rexec rm -f "$dstpath$current"
	if [ $? -ne 0 ]; then
		_log "Cant delete symlink $oldlink. exiting." 0
		exit 109
	fi
fi

_log "recreating symlink to $mvdst" 2
$rexec ln -s "$mvdst" "$dstpath$current"
if [ $? -ne 0 ]; then
	_log "Cant create new symlink. exiting." 0
	if [ -n "$oldlink"]; then
		_log "Trying to restore the old one." 0
		$rexec ln -s "$oldlink" "$dstpath$current"
	fi
	exit 110
fi
$rexec chown -h $chuser:$chgroup "$dstpath$current"
if [ $? -ne 0 ]; then
	_log "Cant chown $dstpath$current" 0
	$warncount=$(expr $warncount + 1)
fi


_log "cleaning up." 1
_cleanup "$keephourly" "$findpattern$fnamehour*"
_cleanup "$keepdaily" "$findpattern$fnameday*"
_cleanup "$keepweekly" "$findpattern$fnameweek*"
_cleanup "$keepmonthly" "$findpattern$fnamemonth*"


_log "done." 1
rm -f ${LOCKFILE}
_log "exiting with code $warncount" 1
exit $warncount


