#!/bin/bash

# ==== Enable debug output
# 0 = off
# 1 = on
DEBUG=1

# ==== Define Date format for log output
LOG_DATE_FORMAT="+%F %T"











# ===============================================================
# Do _NOT_ change anything below this Line


# ===============================================================
# Nah, really!


# ===============================================================
# go away!


# ===============================================================
# leave britney alone!
















# ===============================================================
# Declaring some helper functions


# logs all given arguments to stdout, prepend them with date
log_message() { 
  echo [$(date "$LOG_DATE_FORMAT")] "$*"
}
# logs all given arguments to stdout, dim & prepend them with date
debug_message() { 
  [[ $DEBUG -gt 0 ]] && echo -e "\033[2m"[$(date "$LOG_DATE_FORMAT")] [DEBUG] "$*""\033[0m"
}


# ===============================================================
# Declaring getter functions for arguments 'n stuff

get_work_dir() {
  WORK_DIR="$(pwd)"
}
get_bkp_source() {
  BKP_SOURCE="$@"
}
get_bkp_destination() {
  BKP_DESTINATION="$1"
}


# ===============================================================
# Declaring other functions


bkp_cleanup() {
  found="$($rexec find $dstpath -maxdepth 1 -mtime +$1 -name "$2" -type d)"
  for f in $found; do
    _log "deleting $f" 1
    $rexec rm -r "$f"
  done
}


# ===============================================================
# Finding real script path…


debug_message "Finding real script path…"
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  SCRIPT_TARGET="$(readlink "$SCRIPT_SOURCE")"
  if [[ $SCRIPT_TARGET == /* ]]; then
    debug_message "SCRIPT_SOURCE '$SCRIPT_SOURCE' is an absolute symlink to '$SCRIPT_TARGET'"
    SOURCE="$SCRIPT_TARGET"
  else
    SCRIPT_DIR="$( dirname "$SCRIPT_SOURCE" )"
    debug_message "SCRIPT_SOURCE '$SCRIPT_SOURCE' is a relative symlink to '$SCRIPT_TARGET' (relative to '$SCRIPT_DIR')"
    SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_TARGET" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
  fi
done
debug_message "SCRIPT_SOURCE is '$SCRIPT_SOURCE'"
SCRIPT_RDIR="$( dirname "$SCRIPT_SOURCE" )"
SCRIPT_DIR="$( cd -P "$( dirname "$SCRIPT_SOURCE" )" && pwd )"
if [ "$SCRIPT_DIR" != "$SCRIPT_RDIR" ]; then
  debug_message "SCRIPT_DIR '$SCRIPT_RDIR' resolves to '$SCRIPT_DIR'"
fi
debug_message "SCRIPT_DIR is '$SCRIPT_DIR'"
debug_message "…done"


# ===============================================================
# set Variables 


get_work_dir
get_bkp_source "$1"
get_bkp_destination "$2"


# ===============================================================


# lets go
log_message 'Starting Backup'
log_message 'Working:' $WORK_DIR
log_message 'Sources:' $BKP_SOURCE
for s in $BKP_SOURCE; do
  log_message 'Source:' $s
done
log_message 'Destination:' $BKP_DESTINATION


# ===============================================================
# lockfile


LOCKFILE=$SCRIPT_DIR"/tb.lock"
debug_message "Logfile is $LOCKFILE"
if [ -e "$LOCKFILE" ] && kill -0 `cat "$LOCKFILE"`; then
  log_message "Lockfile already exists!"
  exit 103
fi

# make sure the lockfile is removed when we exit and then claim it
trap "rm -f \"$LOCKFILE\";debug_message SIGTERM or SIGINT detected;exit 100" INT TERM
trap "rm -f \"$LOCKFILE\";debug_message Lockfile deleted" EXIT
echo $$ > "$LOCKFILE"
debug_message "Lockfile created"


# ===============================================================


### check for older version at destination
if $rexec [ -d "$dstpath$current" ]; then 
  debug_message "setting link-dest (../$current)"
  rsyncopts="$rsyncopts --link-dest=../$current/"
else
  debug_message "no previous version available - first backup."
fi


# ===============================================================


echo 1
sleep 1


# ===============================================================


echo 2
sleep 1


# ===============================================================

exit