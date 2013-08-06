#!/bin/bash
#
# MineCraft server daemon starting and world backuping script
# Version: 0.2
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

MAXIMUM_BACKUPS=48 # total backups
BACKUP_INTERVAL=$[3600/2] # seconds
BACKUPS_DIR="./backups"

export GZIP=-9 # level of gzip compression

if [ ! -f "./server.properties" ]; then
    echo "[ FATAL ERROR ] File \"server.properties\" is not exists. " \
         "At first required initialize your world manually. " \
         "Try: \"java -jar minecraft_server.jar nogui\"" 1>&2
    exit 1
fi
LEVEL_NAME="`grep "level-name=" "./server.properties" | sed 's/level-name=//'`"

mkdir -p "$BACKUPS_DIR/"

SERVER_IN_PIPE="./.pipe_server_in"
SERVER_OUT_PIPE="./.pipe_server_out"
DAEMONS_PIDS_FILE="./.daemons_pids"

terminate_subdaemon ()
{
    while read LINE; do
        PID=`echo "$LINE" | cut -d ":" -f 3`
        DESCRIPTION=`echo "$LINE" | cut -d ":" -f 2`

        if [ -f "/proc/$PID/exe" ]; then
            echo "Sending SIGTERM to subdaemon \"$DESCRIPTION\" (pid: $PID)..."
            kill -TERM "$PID" > /dev/null
            if [ "$?" -eq "0" ]; then
                echo "Subdaemon \"$DESCRIPTION\" (pid: $PID) is terminated"
            else
                echo "[ ERROR ] Terminating subdaemon \"$DESCRIPTION\" (pid: $PID) error" 1>&2
            fi
        else
            echo "[ WARNING ] Subdaemon \"$DESCRIPTION\" (pid: $PID) is not started" 1>&2
        fi
    done
}

subdaemon_pid_by_id ()
{
    cat "$DAEMONS_PIDS_FILE" | grep "$1" | cut -d ':' -f 3
}

terminate_subdaemon_id ()
{
    echo "Terminating daemon by id \"$1\"..."
    if [ "`cat "$DAEMONS_PIDS_FILE" | grep "$1" | wc -l`" -eq "0" ]; then
        echo "[ ERROR ] Daemon by id \"$1\" not found" 1>&2
    else
        cat "$DAEMONS_PIDS_FILE" | grep "$1" | terminate_subdaemon
    fi
}

server_daemon ()
{
    cat "$SERVER_IN_PIPE" \
        | java -Xmx1024M -Xms1024M -jar minecraft_server.jar nogui \
        1> "$SERVER_OUT_PIPE" 2>&1 &

    JAVASERVER="$!"
    echo "JAVASERVER:MineCraft server:$JAVASERVER" >> "$DAEMONS_PIDS_FILE"

    while [ -f "/proc/$JAVASERVER/exe" ]; do
        sleep 1
    done

    echo "Minecraft server is terminated"

    terminate_subdaemon_id GENERALAPP
}

exit_handler ()
{
    echo "Exit handler triggered..."

    echo "Terminating subdaemons..."
    cat "$DAEMONS_PIDS_FILE" \
        | grep -v GENERALAPP \
        | grep -v MCSERVERD \
        | grep -v JAVASERVER \
        | grep -v SUBDAEMONS \
        | terminate_subdaemon

    MCSERVERD="`subdaemon_pid_by_id MCSERVERD`"
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

    echo "Removing temp file \"$DAEMONS_PIDS_FILE\"..."
    rm "$DAEMONS_PIDS_FILE"
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

    tar -czf "$BACKUP_PATH" "$LEVEL_NAME/"

    if [ "$?" -eq "0" ]; then
        echo "World backup is created: \"$BACKUP_PATH\""
    else
        echo "[ ERROR ] Creating backup error, trying again" 1>&2
        sleep 1
        create_backup
    fi
}

backuping ()
{
    removing_old_backups

    create_backup

    echo "Next backup after $BACKUP_INTERVAL seconds"
    sleep "$BACKUP_INTERVAL"

    backuping
}

start_subdaemons ()
{
    echo "Waiting for MineCraft server ready..."

    cat "$SERVER_OUT_PIPE" | while read LINE; do
        echo "$LINE"
        echo "$LINE" | grep "\[INFO\] Done" > /dev/null
        if [ "$?" -eq 0 ]; then
            echo "MineCraft server is ready!"

            echo "Starting backuping daemon..."
            backuping &
            echo "BACKUPING:Backuping daemon:$!" >> "$DAEMONS_PIDS_FILE"

            echo "Starting MineCraft server logging daemon..."
            server_logging &
            echo "LOGGING:MineCraft server logging daemon:$!" >> "$DAEMONS_PIDS_FILE"

            break
        fi
    done
}

if [ -f "$DAEMONS_PIDS_FILE" ]; then
    echo "[ FATAL ERROR ] Found subdaemons pids file \"$DAEMONS_PIDS_FILE\"," \
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
mkfifo "$SERVER_IN_PIPE" && exec 3<> "$SERVER_IN_PIPE"
mkfifo "$SERVER_OUT_PIPE"
touch "$DAEMONS_PIDS_FILE"

trap exit_handler EXIT

echo "World name is \"$LEVEL_NAME\""

echo "GENERALAPP:General application:$$" >> "$DAEMONS_PIDS_FILE"

echo "Starting subdaemons..."
start_subdaemons &
echo "SUBDAEMONS:Subdaemons caller:$!" >> "$DAEMONS_PIDS_FILE"

echo "Starting MineCraft server daemon..."
server_daemon &
echo "MCSERVERD:MineCraft server daemon:$!" >> "$DAEMONS_PIDS_FILE"

while read CMD; do
    echo "$CMD" > "$SERVER_IN_PIPE"
done

# vim:set ts=4 sw=4 expandtab:
