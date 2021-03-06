#!/bin/bash
#
# MineCraft server daemon starting and world backuping script
# Version: 0.3.1
# Author: Viacheslav Lotsmanov (unclechu) <lotsmanov89@gmail.com>
# WWW: https://github.com/unclechu/minecraft-start-server
# License: MIT
#
# The MIT License (MIT)
#
# Copyright (c) 2013 Viacheslav Lotsmanov
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

cd "`dirname "$0"`"
THIS_FILENAME="`basename "$0"`"

usage ()
{
cat << EOF
Usage: $THIS_FILENAME

`sed -n '3,7p' < "$THIS_FILENAME" | sed 's/^# //g'`

OPTIONS:
  -h   Show this message
  -d   Start with default configuration
EOF
}

DEFAULT_CONFIGURATION=0
while getopts "h:d" OPTION; do
    case "$OPTION" in
        h)
            usage
            exit 0
            ;;
        d)
            DEFAULT_CONFIGURATION=1
            ;;
        ?)
            usage
            exit 1
            ;;
    esac
done

CONFIG_FILE="./start_server.cfg"

if [ ! -f "./server.properties" ]; then
    echo "[ FATAL ERROR ] File \"server.properties\" is not exists. " \
         "At first required initialize your world manually. " \
         "Try: \"java -jar minecraft_server.jar nogui\"" 1>&2
    exit 1
fi
LEVEL_NAME="`grep "level-name=" "./server.properties" | sed 's/level-name=//' \
            | sed 's/^\s\+//g' | sed 's/\s\+$//g'`"
if [ "$LEVEL_NAME" == "" ]; then
    echo "[ FATAL ERROR ] Empty level name." \
         "Check your server properties file: \"server.properties\"" 1>&2
    exit 1
fi

# Default config values
MAXIMUM_BACKUPS=48 # maximum backups count
BACKUP_INTERVAL=$[3600/2] # in seconds
BACKUPS_DIR="./backups" # path to backups dir
FILES_TO_BACKUP="$LEVEL_NAME/ server.properties"
GZIP_LEVEL="-9" # level of compression, "-9" is best compression
TERM_TIMEOUT=5 # seconds of process terminating timeout
SERVER_IN_PIPE="./.pipe_server_in"
SERVER_OUT_PIPE="./.pipe_server_out"
SUBPROC_PIDS_FILE="./.subproc_pids"
APP_EXITING_FILE="./.app_exiting"

if [ "$DEFAULT_CONFIGURATION" -eq "0" ]; then
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "[ FATAL ERROR ] Config file \"$CONFIG_FILE\" not found." \
             "Copy example of config \"start_server.cfg.example\"" \
             "to your work dir as \"$CONFIG_FILE\"" \
             "or run this script with -d flag" \
             "for start with default configuration." 1>&2
        exit 1
    else
        source "$CONFIG_FILE"
    fi
fi

export GZIP="$GZIP_LEVEL" # level of gzip compression

mkdir -p "$BACKUPS_DIR/"

# Send SIGTERM or SIGKILL to process and wait when process terminate
# Args:
#   $1 - PID
#   $2 - "TERM" or "KILL"
send_kill_signal ()
{
    PID="$1"
    SIG="$2"
    DESCRIPTION="$3"

    if [ "$PID" == "" ]; then
        echo "[ FATAL ERROR ] \"send_kill_signal\": PID is empty" 1>&2
        exit 1
    fi

    if [ "$SIG" == "KILL" ]; then
        MSG_STATUS="killing"
        MSG_STATUS_PAST_TENSE="killed"
    else
        SIG="TERM"
        MSG_STATUS="terminating"
        MSG_STATUS_PAST_TENSE="terminated"
    fi

    if [ "$DESCRIPTION" != "" ]; then
        DESCRIPTION=" \"$DESCRIPTION\""
    fi

    if [ -f "/proc/$PID/exe" ]; then
        echo "Sending SIG$SIG to process$DESCRIPTION (pid: $PID)..."
        kill -"$SIG" "$PID" > /dev/null
        if [ "$?" -eq "0" ]; then
            echo "Waiting for $MSG_STATUS process$DESCRIPTION (pid: $PID)..."
            I=0
            while [ -f "/proc/$PID/exe" ]; do
                if [ "$I" -ge "$TERM_TIMEOUT" ]; then
                    echo "[ ERROR ] Timeout of $MSG_STATUS process$DESCRIPTION (pid: $PID)" 1>&2
                    if [ "$SIG" != "KILL" ]; then
                        I=-1
                    else
                        I=-2
                    fi
                    break
                fi
                sleep 1
                I="$[$I+1]"
            done
            if [ "$I" -eq "-1" ]; then
                send_kill_signal "$PID" KILL "$3"
                exit "$?"
            elif [ "$I" -eq "-2" ]; then
                echo "[ ERROR ] Killing process$DESCRIPTION error (pid: $PID)" 1>&2
                exit 1
            else
                echo "Process$DESCRIPTION (pid: $PID) is $MSG_STATUS_PAST_TENSE"
                exit 0
            fi
        else
            echo "[ ERROR ] ${MSG_STATUS^} process$DESCRIPTION (pid: $PID) error." \
                 "\"kill\" command was terminated with exit code \"$?\"." 1>&2
            exit 1
        fi
    else
        echo "[ WARNING ] Hasn't process$DESCRIPTION (pid: $PID)" 1>&2
        exit 0
    fi
}

terminate ()
{
    while read LINE; do
        PID=`echo "$LINE" | cut -d ":" -f 3`
        DESCRIPTION=`echo "$LINE" | cut -d ":" -f 2`

        send_kill_signal "$PID" TERM "$DESCRIPTION"
    done
}

pid_by_id ()
{
    cat "$SUBPROC_PIDS_FILE" | grep "$1" | cut -d ':' -f 3
}

terminate_id ()
{
    echo "Terminating process by id \"$1\"..."
    if [ "`cat "$SUBPROC_PIDS_FILE" | grep "$1" | wc -l`" -eq "0" ]; then
        echo "[ WARNING ] Process by id \"$1\" not found" 1>&2
    else
        cat "$SUBPROC_PIDS_FILE" | grep "$1" | terminate
    fi
}

server_daemon ()
{
    cat "$SERVER_IN_PIPE" \
        | java -Xmx1024M -Xms1024M -jar minecraft_server.jar nogui \
        1> "$SERVER_OUT_PIPE" 2>&1 &

    JAVASERVER="$!"
    echo "JAVASERVER:MineCraft server:$JAVASERVER" >> "$SUBPROC_PIDS_FILE"

    while [ -f "/proc/$JAVASERVER/exe" ]; do
        sleep 1
    done

    echo "Minecraft server is terminated"

    if [ ! -f "$APP_EXITING_FILE" ]; then
        terminate_id GENERALAPP &
    fi
}

exit_handler ()
{
    echo "Exit handler triggered..."

    echo "Creating exiting flag file \"$APP_EXITING_FILE\"..."
    touch "$APP_EXITING_FILE"

    echo "Terminating subprocesses..."

    # if application was terminated before MC server ready
    terminate_id SUBPROC

    cat "$SUBPROC_PIDS_FILE" \
        | grep -v GENERALAPP \
        | grep -v MCSERVERD \
        | grep -v JAVASERVER \
        | grep -v SUBPROC \
        | grep -v LOGGING \
        | terminate

    MCSERVERD="`pid_by_id MCSERVERD`"
    if [ -f "/proc/$MCSERVERD/exe" ]; then
        echo "/say Stopping server..." > "$SERVER_IN_PIPE"
        sleep 3
        echo "/stop" > "$SERVER_IN_PIPE"

        while [ -f "/proc/$MCSERVERD/exe" ]; do
            sleep 1
        done
    fi

    echo "Removing pipe file \"$SERVER_IN_PIPE\"..."
    rm "$SERVER_IN_PIPE"

    echo "Removing pipe file \"$SERVER_OUT_PIPE\"..."
    rm "$SERVER_OUT_PIPE"

    echo "Prophylactic terminating logging daemon..."
    terminate_id LOGGING

    echo "Removing temp file \"$SUBPROC_PIDS_FILE\"..."
    rm "$SUBPROC_PIDS_FILE"

    echo "Removing exiting flag file \"$APP_EXITING_FILE\"..."
    rm "$APP_EXITING_FILE"
}

server_logging ()
{
    cat "$SERVER_OUT_PIPE"
    echo "Logging daemon terminated"
}

removing_old_backups ()
{
    echo "Search of old backups..."

    BACKUPS_COUNT="`ls -X "$BACKUPS_DIR/" \
        | grep "^${LEVEL_NAME}_backup_.*\.tar\.gz$" \
        | wc -l`"

    if [ "$BACKUPS_COUNT" -ge "$MAXIMUM_BACKUPS" ]; then
        echo "Old backups found, removing..."
        ls -X "$BACKUPS_DIR/" \
            | grep "^${LEVEL_NAME}_backup_.*\.tar\.gz$" \
            | head -n "-$[MAXIMUM_BACKUPS-1]" \
            | xargs -I {} sh -c "echo 'Removing backup-file \"{}\"...'; \
                                 rm "$BACKUPS_DIR/{}""
    fi
}

create_backup ()
{
    echo "Creating world backup..."

    BACKUP_PATH="$BACKUPS_DIR/${LEVEL_NAME}_backup_`date '+%F-%H-%M-%S'`.tar.gz"

    tar -czf "$BACKUP_PATH" $FILES_TO_BACKUP

    if [ "$?" -eq "0" ]; then
        echo "World backup is created: \"$BACKUP_PATH\""
    else
        echo "[ ERROR ] Creating backup error, trying again" 1>&2
        sleep 1
        create_backup
    fi
}

time_text ()
{
    TIME_TEXT=""

    if [ "$1" -ge "3600" ]; then
        H="$[ $1 / 3600 ]"
        M="$[ $[$1-$[$H*3600]] / 60 ]"
        S="$[ $1 - $[$[$H*3600]+$[$M*60]] ]"
        TIME_TEXT="$H hours"
        if [ "$M" -gt "0" ]; then
            TIME_TEXT="$TIME_TEXT $M minutes"
        fi
        if [ "$S" -gt "0" ]; then
            TIME_TEXT="$TIME_TEXT $S seconds"
        fi
    elif [ "$1" -ge "60" ]; then
        M="$[ $1 / 60 ]"
        S="$[ $1 - $[$M*60] ]"
        TIME_TEXT="$M minutes"
        if [ "$S" -gt "0" ]; then
            TIME_TEXT="$TIME_TEXT $S seconds"
        fi
    else
        TIME_TEXT="$1 seconds"
    fi

    echo $TIME_TEXT
}

backuping ()
{
    removing_old_backups

    create_backup

    echo "Next backup after `time_text "$BACKUP_INTERVAL"`"
    sleep "$BACKUP_INTERVAL"

    backuping
}

start_subprocesses ()
{
    echo "Waiting for MineCraft server ready..."

    cat "$SERVER_OUT_PIPE" | while read LINE; do
        echo "$LINE"
        if [ -f "$APP_EXITING_FILE" ]; then
            server_logging &
            echo "LOGGING:MineCraft server logging daemon:$!" >> "$SUBPROC_PIDS_FILE"
            exit 0
        fi
        echo "$LINE" | grep "\[INFO\] Done" > /dev/null
        if [ "$?" -eq 0 ]; then
            echo "MineCraft server is ready!"

            echo "Starting backuping daemon..."
            backuping &
            echo "BACKUPING:Backuping daemon:$!" >> "$SUBPROC_PIDS_FILE"

            echo "Starting MineCraft server logging daemon..."
            server_logging &
            echo "LOGGING:MineCraft server logging daemon:$!" >> "$SUBPROC_PIDS_FILE"

            break
        fi
    done
}

if [ -f "$SUBPROC_PIDS_FILE" ]; then
    echo "[ FATAL ERROR ] Found subprocesses pids file \"$SUBPROC_PIDS_FILE\"," \
         "server already started?" 1>&2
    exit 1
fi
if [[ -p "$SERVER_IN_PIPE" || -f "$SERVER_IN_PIPE" \
|| -p "$SERVER_OUT_PIPE" || -f "$SERVER_OUT_PIPE" ]]; then
    ERR_PIPE=""
    if [[ -p "$SERVER_IN_PIPE" || -f "$SERVER_IN_PIPE" ]]; then
        ERR_PIPE="$SERVER_IN_PIPE"
    elif [[ -p "$SERVER_OUT_PIPE" || -f "$SERVER_OUT_PIPE" ]]; then
        ERR_PIPE="$SERVER_OUT_PIPE"
    fi
    echo "[ FATAL ERROR ] Found old named pipe \"$ERR_PIPE\"," \
         "server already started?" 1>&2
    exit 1
fi
if [ -f "$APP_EXITING_FILE" ]; then
    echo "[ FATAL ERROR ] Found old exiting flag file \"$APP_EXITING_FILE\", " \
         "server already started?" 1>&2
    exit 1
fi
mkfifo "$SERVER_IN_PIPE" && exec 3<> "$SERVER_IN_PIPE"
mkfifo "$SERVER_OUT_PIPE"
touch "$SUBPROC_PIDS_FILE"

trap exit_handler EXIT

echo "World name is \"$LEVEL_NAME\""

echo "GENERALAPP:General application:$$" >> "$SUBPROC_PIDS_FILE"

echo "Starting subprocesses..."
start_subprocesses &
echo "SUBPROC:Subprocesses starter:$!" >> "$SUBPROC_PIDS_FILE"

echo "Starting MineCraft server daemon..."
server_daemon &
echo "MCSERVERD:MineCraft server daemon:$!" >> "$SUBPROC_PIDS_FILE"

while read CMD; do
    echo "$CMD" > "$SERVER_IN_PIPE"
done

# vim:set ts=4 sw=4 expandtab:
