#!/usr/bin/bash

retry() {
    local attempts="$1" delay="$2"
    shift 2
    [ "$1" = "--" ] && shift

    local i=0
    while [ "$i" -lt "$attempts" ]; do
        if "$@"; then
            return 0
        fi
        i=$((i + 1))
        sleep "$delay"
    done
    return 1
}
