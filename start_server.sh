#!/bin/bash
# MineCraft server daemon starting and world backuping script
# Version: 0.1
# Author: Viacheslav Lotsmanov (unclechu) <lotsmanov89@gmail.com>
# WWW: https://github.com/unclechu/minecraft-start-server
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

MINECRAFTD_PID="$$"
BACKUPD_PID=0

export GZIP=-9 # level of gzip compression

if [ ! -f "./server.properties" ]; then
    echo "File \"server.properties\" is not exists" 1>&2
    echo "At first required initialize your world manually" 1>&2
    echo "Try: java -jar minecraft_server.jar nogui" 1>&2
    exit 1
fi
LEVEL_NAME="`grep level-name "./server.properties" | sed 's/level-name=//'`"

mkdir -p "$BACKUPS_DIR/"

start_daemon ()
{
    java -Xmx1024M -Xms1024M -jar minecraft_server.jar nogui
}

exit_handler ()
{
    echo "Exit handler..."
    if [ "$BACKUPD_PID" -ne "0" ]; then
        echo "Send SIGTERM to backuping daemon pid: \"$BACKUPD_PID\""
        kill -TERM "$BACKUPD_PID"
        if [ "$?" -eq "0" ]; then
            echo "Backuping daemon was terminated"
        else
            echo "Terminating backuping daemon error" 1>&2
            exit 1
        fi
    fi
}

backup_loop ()
{
    echo "Creating backup of the world"

    if [ ! -f "/proc/$MINECRAFTD_PID/exe" ]; then
        echo "General daemon fallen, stopping backuping daemon" 1>&2
        exit 1
    fi

    echo "Removing old backups"
    BACKUPS_COUNT=`ls -X "$BACKUPS_DIR/" \
        | grep "^${LEVEL_NAME}_backup_.*\.tar\.gz$" \
        | wc -l`
    if [ "$BACKUPS_COUNT" -ge "$MAXIMUM_BACKUPS" ]; then
        ls -X "$BACKUPS_DIR/" \
            | grep "^${LEVEL_NAME}_backup_.*\.tar\.gz$" \
            | head -n "-$[MAXIMUM_BACKUPS-1]" \
            | xargs -I {} sh -c "echo 'Removing backup-file \"{}\"';\
                                 rm "$BACKUPS_DIR/{}""
    fi

    tar -czf \
        "$BACKUPS_DIR/${LEVEL_NAME}_backup_`date '+%F-%H-%M-%S'`.tar.gz" \
        "$LEVEL_NAME/"
    if [ "$?" -ne "0" ]; then
        echo "Creating backup error" 1>&2
    fi

    echo "Next backup after $BACKUP_INTERVAL seconds"
    sleep "$BACKUP_INTERVAL"
    backup_loop
}

backup_loop &
BACKUPD_PID="$!"

trap 'exit_handler' EXIT

start_daemon

# vim:set ts=4 sw=4 expandtab:
