#!/bin/sh
# SPDX-FileCopyrightText: 2020 Loetkolben
# SPDX-License-Identifier: MIT
set -eu

# Absolute path to $0's directory, resolving all symlinks in the path
readonly SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# Absolute path to $0's directory, not resolving any symlinks
readonly EXEC_DIR="$(cd "$(dirname "$0")"; pwd)"


###
# Config Section
# I belive these are sensible defaults.
# You may override these settings in a file ctlconf.sh in the EXEC_DIR.
# It will be automatically sourced if it exists.
###

# Server directory
SERVER_DIR="$EXEC_DIR"

# Java Config
JAVA_PATH="java"
JAVA_MEM_ARGS="-Xms512M -Xmx1G"
JAVA_OTHER_ARGS="-XX:+UnlockExperimentalVMOptions -XX:MaxGCPauseMillis=100 -XX:+DisableExplicitGC -XX:TargetSurvivorRatio=90 -XX:G1NewSizePercent=50 -XX:G1MaxNewSizePercent=80 -XX:G1MixedGCLiveThresholdPercent=35 -XX:+AlwaysPreTouch -XX:+ParallelRefProcEnabled"

# Minecraft server config
SERVER_JAR=$(ls -v | grep -i "FTBServer.*jar\|minecraft_server.*jar\|server.jar" | head -n 1)
SERVER_ARGS="nogui"

# Server nice adjustment. Increases process niceness by x.
# (Higher niceness = "less" priority)
NICE_ADJ=10

# Name of the screen the server is to be run in
SCREEN_NAME="$(basename "$SERVER_DIR")"

# Server (Java) PID File. Used to check if the server is alive.
SERVER_PID_FILE="$SERVER_DIR/server.pid"

# Screen PID File. Required for systemd.
# If you change this, remember to change the service file as well.
SCREEN_PID_FILE="$SERVER_DIR/screen.pid"

# Backup config
# What tool to use for backups. `no`/`none` disables. Unkown values produce warnings.
# `cp` = Just copy the source to the destination. Useful if there are alredy incremental host backups.
# `rdiff-backup` = Do backups with rdiff-backup.
BACKUP_METHOD="cp"

# Where to store the backups
BACKUP_DEST_PATH="$SERVER_DIR/BACKUPS"

# The folder to be backuped
BACKUP_SRC_PATH="$SERVER_DIR/$(grep level-name "$SERVER_DIR/server.properties" 2>/dev/null | cut -d '=' -f 2)" || BACKUP_SRC_PATH="$SERVER_DIR/world"

# When thining out backups after performing a backup, how how many backups to keep.
BACKUPS_TO_KEEP="25"

# Storage space in kB that must be available on the disk that contains $BACKUP_DEST_PATH and $BACKUP_SRC_PATH
# If there is less space available, stop the server gracefully before we ecounter world curruption
# because the server cannot save anymore.
DISKPANIC_THRESHOLD=2097152  # 2GB * 1024 MB/GB * 1024 kB/MB = 2097152 kB


###
# Load instance-specific config
###

if [ -f "$EXEC_DIR/ctlconf.sh" ]; then
	echo "Loading config $EXEC_DIR/ctlconf.sh"
	# We alredy have all variables defined above, this is just for optional overrides.
	# shellcheck disable=SC1090
	. "$EXEC_DIR/ctlconf.sh"
fi


###
# Generic function definitions
###

die() {
  echo "$@"
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null || die "Missing command '$1'"
}

# Check if server is running (something with $SERVER_PID_FILE exists)
serverpid_isrunning() {
	# Check if pid file exists
	[ -e "$SERVER_PID_FILE" ] || return 1

	# Check if a proccess exists at $SERVER_PID_FILE
	ps -p "$(cat "$SERVER_PID_FILE")" > /dev/null || return 1

	return 0
}

screen_isrunning() {
	# Check if pid file exists
	[ -e "$SCREEN_PID_FILE" ] || return 1

	# Check if a screen proccess exists at $SCRREN_PID_FILE
	[ "screen" = "$(ps -o comm= -p "$(cat "$SCREEN_PID_FILE")")" ] || return 1

	return 0
}

die_screennotrunning() {
	if ! screen_isrunning; then
		if serverpid_isrunning; then
			die "Server not running in screen. Cannot control."
		else
			die "Server not running."
		fi
	fi
}

# Runs $0 fg in a screen with the configured name
screen_start() {
	if ! screen_isrunning; then
		# Die also if server is running outside of screen (manual testing or so...)
		serverpid_isrunning && die "Server already running"

		echo "Running '$0' 'fg' in screen $SCREEN_NAME"
		screen -dmS "$SCREEN_NAME" "$0" "fg"
	else
		echo "NOT starting the server: screen pid file exists and corresponding process is running"
		echo "See 'screen -ls' output (our screen pid is '$(cat "$SCREEN_PID_FILE")'):"
		screen -ls
		exit 1
	fi
}

# Requests the server to stop and waits for it to shut down
screen_stop() {
	if screen_isrunning; then
		echo "Requesting server to stop."
		srv_stop

		echo "Waiting for server to terminate..."
		while screen_isrunning; do
			sleep 1
		done

		rm -- "$SCREEN_PID_FILE"
		rm -- "$SERVER_PID_FILE"

		echo "  Server terminated."
	else
		if serverpid_isrunning; then
			die "Connot control. Server is running (something with the servers pid exists), but not in screen."
		else
			die "Cannot stop. Server not running (at all)."
		fi
	fi
}

start_in_fg(){
	cd -- "$SERVER_DIR"

	# Server PID file
	echo $$ > "$SERVER_PID_FILE"

	# Screen PID file (if we are running in a screen)
	if [ "$(ps -p $PPID -o comm=)" = "screen" ]; then
		echo $PPID > "$SCREEN_PID_FILE"
	else
		rm -f -- "$SCREEN_PID_FILE"
	fi

	srv_exec
}


###
# srv_ function definitions
###

# exec's the server (in other words: the server runs with our pid)
srv_exec(){
	# Auto-accept eula
	if [ ! -f "$SERVER_DIR/eula.txt" ]; then
		echo "Auto-Accepting EULA."
		echo "eula=true" > "$SERVER_DIR/eula.txt"
	fi

	# execute server
	# shellcheck disable=2086  # some arguments must be split
	exec nice -n $NICE_ADJ "$JAVA_PATH" $JAVA_MEM_ARGS $JAVA_OTHER_ARGS -jar "$SERVER_JAR" $SERVER_ARGS
}

srv_runcmd() {
	die_screennotrunning
	screen -p 0 -x "$(cat "$SCREEN_PID_FILE")" -X stuff "$*$(printf \\r)"
}

srv_stop(){
	srv_runcmd "stop"
}

srv_saveoff() {
	srv_runcmd "save-off"
	srv_runcmd "save-all"
	sleep 5
}

srv_saveon() {
	srv_runcmd "save-on"
}

srv_saybackupbegin() {
	srv_runcmd "say SERVER BACKUP STARTING. Server going readonly..."
}

srv_saybackupsuccess() {
	srv_runcmd "say SERVER BACKUP COMPLETED. Server going read-write..."
}

srv_saybackupfailed() {
	srv_runcmd "say §4!!! SERVER BACKUP FAILED !!!§r Server going read-write..."
}

srv_diskpanic(){
	srv_runcmd "say §4-----  -----  -----  -----  -----  -----  -----"
	srv_runcmd "say §4DISK PANIC! Disk almost full."
	srv_runcmd "say §4Shutting down server in 30 seconds to prevent world corruption ..."
	srv_runcmd "say §4-----  -----  -----  -----  -----  -----  -----"
	sleep 20
	srv_runcmd "say §4Shutting down server in 10 seconds ..."
	sleep 10
	srv_stop
}


###
# Backup function definitions
###

backup_dobackup() {
	echo "Backing up $BACKUP_SRC_PATH to $BACKUP_DEST_PATH"

	case "$BACKUP_METHOD" in
		cp)
			readonly dest="$BACKUP_DEST_PATH/$(date +%F_%H-%M-%S_%Z)"
			mkdir -p -- "$dest"
			cp -r -- "$BACKUP_SRC_PATH" "$dest"
			;;
		rdiff-backup)
			command_exists rdiff-backup || return $?
			rdiff-backup "$BACKUP_SRC_PATH" "$BACKUP_DEST_PATH"
			;;
		*)
			echo "Unkown backup method '$BACKUP_METHOD'"
			return 1
	esac

	echo "Backup complete."
}

backup_thinout() {
	echo "Thining out backups..."

	case "$BACKUP_METHOD" in
		cp)
			cd "$BACKUP_DEST_PATH"
			ls -tp | tail -n +2 | tail -n +$BACKUPS_TO_KEEP | xargs -I {} rm -r -- {}
			;;
		rdiff-backup)
			command_exists rdiff-backup || return $?
			rdiff-backup --remove-older-than "${BACKUPS_TO_KEEP}B" --force "$BACKUP_DEST_PATH"
			;;
		*)
			echo "Unkown backup method '$BACKUP_METHOD'"
			return 1
	esac
}

backup_checkdiskspace(){
	# free_* is in kb
	free_server=$(stat -f --printf="%a * %s / 1024\n" "$SERVER_DIR" | bc)
	free_backup=$(stat -f --printf="%a * %s / 1024\n" "$BACKUP_DEST_PATH" | bc)
	[ "$free_server" -lt "$DISKPANIC_THRESHOLD" ] && return 1
	[ "$free_backup" -lt "$DISKPANIC_THRESHOLD" ] && return 1
	return 0
}

backup_main() {
	if [ "$BACKUP_METHOD" = "no" ] || [ "$BACKUP_METHOD" = "none" ]; then
		echo "Server backup not enabled."
		return
	fi

	die_screennotrunning
	command_exists bc || die "FATAL: bc comannd is missing"

	echo "Starting server backup at $(date)"
	[ -d "$BACKUP_DEST_PATH" ] || mkdir -p "$BACKUP_DEST_PATH"

	# Check if disk is full. Check before we backup to not accidentally fill up the disk...
	if backup_checkdiskspace; then
			echo "Disk space seems fine..."
	else
			echo "DISK PANIC! Disk almost full! Shutting down server..."
			srv_diskpanic
			echo "Server backup canceled b/c disk panic, now it's $(date)"
			exit 1
	fi

	backup_failed_recover() {
		echo "Server backup failed!"
		srv_saybackupfailed
		srv_saveon
	}

	# Always re-enable save if the backup fails for some reason
	trap backup_failed_recover EXIT

	srv_saybackupbegin
	srv_saveoff

	if backup_dobackup; then
		srv_saybackupsuccess
		srv_saveon

		trap - EXIT

		# Only thin out backups if new backup succeeded
		if ! backup_thinout; then
			echo "Thining out backups completed"
		fi

	else
		backup_failed_recover
		trap - EXIT
	fi

	echo "Server backup completed, now it's $(date)"
}


###
# "Main"
###

if [ "$#" -ne "1" ]; then
	echo "Give one (and only one) command."
	exit 1
fi

case $1 in
	fg|foreground)
		start_in_fg
		;;

	start|start-screen)
		screen_start
		;;

	stop|stop-screen)
		screen_stop
		;;

	backup)
		backup_main
		;;

	*)
		echo "Invalid commad."
		exit 1
		;;
esac
