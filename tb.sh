#!/bin/bash

# based on ideas from:
# https://blog.interlinked.org/tutorials/rsync_time_machine.html
# https://nicaw.wordpress.com/2013/04/18/bash-backup-rotation-script/
# Synology Time Backup, Apple Time Machine and others

# v 0.1 alpha 10


###############################################################################
#
# Variables
#
###############################################################################

# Source
src=''
# Source Remote Host (ex 192.168.0.1 or backupuser@myserver.local) - requires ssh-key-setup
srchost=''
# Source Path (ex. /mnt/user) - will be passed to rsync as is
srcpath=''
# Destination
dst=''
# Destination Remote Host (same as $srchost)
dsthost=''
# Destination Path - With trailing Slash
dstpath=''
# Loglevel defines how much is logged:
# 0 = nothing
# 1 = basic status info
# 2 = more detailed infos (debug/technical stuff)
# 3 = even more debug info
loglevel=0
# rsync options (more are set depending on above vars)
rsyncopts='--archive --delete'
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









#remote exec command - set by script!
rexec=''

#some internal folder naming stuff
fdate=$(date +"%Y-%m-%d_%H-%M-%S")
fdatetouch=$(date +"%Y%m%d%H%M.%S")
findpattern=[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]-[0-9][0-9]_

#Lockfile
LOCKFILE=''

#old symlink target
oldlink=''


#getrsyncopts
while [[ $# -gt 1 ]]; do
	case $1 in
		-l|--loglevel)
			loglevel=$2
			shift 2
		;;
		-e|--exclude)
			rsyncopts="$rsyncopts --delete-excluded --exclude-from=$2"
			shift 2
		;;
		-o|--options)
			rsyncopts="$rsyncopts $2"
			shift 2
		;;
		-*)
			_log "unknown option $1. exiting." 0
			exit 1
		;;
		*)
			src=$1
			srchost=$(echo "${1%:*}" | grep -v "$1")
			srcpath="${1##*:}"
			dst=$2
			dsthost=$(echo "${2%:*}" | grep -v "$2")
			dstpath="${2##*:}"
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
		echo $(date "+%F %T") "--" $1
	fi
}

_log "==================================================" 1
_log " New Backup Started                               " 1
_log "==================================================" 1

_log "SRC: $src" 1
_log "DST: $dst" 1

### lockfile
LOCKFILE="/var/run/tb.$(echo "$srchost$srcpath$dsthost$dstpath" | tr -cd 'A-Za-z0-9_').lock"
if [ -e ${LOCKFILE} ] && kill -0 `cat ${LOCKFILE}`; then
	_log "Lockfile already exists!" 0
    exit 103
fi

# make sure the lockfile is removed when we exit and then claim it
trap "rm -f ${LOCKFILE}; exit 100" INT TERM
trap "rm -f ${LOCKFILE}" EXIT
echo $$ > ${LOCKFILE}
_log "Lockfile created" 2

#Dest: remote host set? 
if [ -n "$dsthost" ]; then
	rexec="ssh $dsthost"
fi

## rsync options
if [ $loglevel -ge 3 ]; then
	rsyncopts="$rsyncopts --progress"
fi
if [ $loglevel -ge 3 ]; then
	rsyncopts="$rsyncopts --stats"
fi
if [ $loglevel -ge 2 ]; then
	rsyncopts="$rsyncopts --verbose"
fi
if [ $loglevel -eq 0 ]; then
	rsyncopts="$rsyncopts --quiet"
fi

#if something is remote…
if [ -n "$srchost" ] || [ -n "$dsthost" ]; then
	rsyncopts="$rsyncopts --partial --append-verify --compress --timeout=600 --rsh=\"ssh\""
fi

### check for older version at destination
if $rexec [ -d "$dstpath$current" ]; then 
	_log "setting link-dest (../$current)" 2
	rsyncopts="$rsyncopts --link-dest=../$current/"
else
	_log "no previous version available - first backup." 1
fi


### create destination folder if needed
# just using $incomplete here to allow resuming
if $rexec [ ! -d "$dstpath$incomplete" ]; then
	
	_log "creating destination folder ($incomplete)" 2

	$rexec mkdir -p "$dstpath$incomplete"
	if [ $? -ne 0 ]; then 
		_log "Cant create $dstpath$incomplete. exiting." 0
		exit 104
	fi

	$rexec chmod $chperm "$dstpath$incomplete"
	if [ $? -ne 0 ]; then
		_log "Cant chmod $dstpath$incomplete" 0
		#exit 105
	fi

	$rexec chown $chuser:$chgroup "$dstpath$incomplete"
	if [ $? -ne 0 ]; then
		_log "Cant chown $dstpath$incomplete" 0
		#exit 106
	fi

	_log "destination folder created" 2
else
	_log "destination folder ($dstpath$incomplete) already exists - resuming." 1
fi



### backing up…
_log "copying files" 1
_log "cmd: rsync $rsyncopts $src $dst$incomplete/" 2

_log "rsync output:" 2
_log "==================================================" 2
rsync $rsyncopts $src $dst$incomplete/
if [ $? -ne 0 ]; then
	_log "cant complete backup. exiting." 1
	exit 107
fi
_log "==================================================" 2
_log "copying successful" 1


_log "rsync -a preserves mtime, change for root folder" 3
$rexec touch -t $fdatetouch $dstpath$incomplete
if [ $? -ne 0 ]; then
	_log "Cant touch $dstpath$incomplete" 0
	warncount=$(expr $warncount + 1)
fi

#_log "fixing permissions" 1
#$rexec chmod -R $chperm $dstpath$incomplete

# check if anything has changed since last backup
# doing it after copying is much easier and rsync should only copy changed files anyway…
if [ -z "$($rexec diff -r $dstpath$incomplete $dstpath$current)" ]; then 
	_log "nothing changed since last backup." 1
else

	#@TODO yearly?
	#move to correct subfolder
	if [ -z "$($rexec find $dstpath -type d -maxdepth 1 -name "*_$fnamemonth" -mtime -30)" ]; then
		_log "Creating monthly Backup…" 3
		mvdst="$dstpath$(echo $fdate)_$fnamemonth"
	elif [ -z "$($rexec find $dstpath -type d -maxdepth 1 -name "*_$fnameweek" -mtime -7)" ]; then
		_log "Creating weekly Backup" 3
		mvdst="$dstpath$(echo $fdate)_$fnameweek"
	elif [ -z "$($rexec find $dstpath -type d -maxdepth 1 -name "*_$fnameday" -mtime -1)" ]; then
		_log "Creating daily Backup" 3
		mvdst="$dstpath$(echo $fdate)_$fnameday"
	else
		_log "Creating hourly Backup" 3
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
	fi
fi


#cleanup function, deletes old backups
function _cleanup {
	found="$($rexec find $dstpath -maxdepth 1 -mtime +$1 -name "$2" -type d)"
	for f in $found; do
		_log "deleting $f" 1
		$rexec rm -r "$f"
	done
}
_log "cleaning up." 1
if $rexec [ -d "$dstpath$incomplete" ]; then 
	_log "deleting $dstpath$incomplete" 1
	$rexec rm -r "$dstpath$incomplete"
fi
_cleanup "$keephourly" "$findpattern$fnamehour*"
_cleanup "$keepdaily" "$findpattern$fnameday*"
_cleanup "$keepweekly" "$findpattern$fnameweek*"
_cleanup "$keepmonthly" "$findpattern$fnamemonth*"


_log "done." 1
exit 0


