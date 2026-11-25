#!/bin/sh

DEV="/dev/trng_esp"
BAUD="115200"
PIDFILE="/var/run/esp-trng-feeder.pid"
STATFILE="/tmp/esp_trng_stats.json"
TMPSTAT="/tmp/esp_trng_stats.json.tmp"
DDLOG="/tmp/esp_trng_dd.log"

echo $$ > "$PIDFILE"
DD_PID=""

write_stat() {
    printf '{"status": "%s", "total_bytes": %s, "speed_bps": %s, "start_ts": %s, "updated_ts": %s}\n' \
        "$1" "$2" "$3" "$4" "$(date +%s)" > "$TMPSTAT"
    mv -f "$TMPSTAT" "$STATFILE"
}

cleanup() {
    [ -n "$DD_PID" ] && kill "$DD_PID" 2>/dev/null
    rm -f "$PIDFILE" "$STATFILE" "$TMPSTAT" "$DDLOG"
    exit 0
}
trap cleanup INT TERM EXIT

while true; do
    if [ -c "$DEV" ]; then
        START_TS=$(date +%s)
        LAST_BYTES=0
        LAST_TS=$START_TS
        STALL_COUNT=0

        : > "$DDLOG"
        exec 3< "$DEV"
        stty -f "$DEV" "$BAUD" raw cs8 -cstopb -parenb -crtscts -ixon -ixoff clocal
        dd bs=32 of=/dev/random <&3 2>"$DDLOG" &
        DD_PID=$!

        write_stat "starting" 0 0 "$START_TS"

        while kill -0 "$DD_PID" 2>/dev/null; do
            sleep 5
            if [ ! -c "$DEV" ]; then
                kill "$DD_PID" 2>/dev/null
                break
            fi

            kill -INFO "$DD_PID" 2>/dev/null
            sleep 0.2

            CUR_BYTES=$(awk '/bytes transferred/ {val=$1} END {print val+0}' "$DDLOG")
            NOW_TS=$(date +%s)
            DT=$((NOW_TS - LAST_TS))
            [ "$DT" -le 0 ] && DT=1

            if [ "$CUR_BYTES" -gt "$LAST_BYTES" ]; then
                DIFF=$((CUR_BYTES - LAST_BYTES))
                SPEED=$(awk -v d="$DIFF" -v t="$DT" 'BEGIN {printf "%.2f", d/t}')
                write_stat "running" "$CUR_BYTES" "$SPEED" "$START_TS"
                LAST_BYTES=$CUR_BYTES
                LAST_TS=$NOW_TS
                STALL_COUNT=0
            else
                STALL_COUNT=$((STALL_COUNT + 1))
                if [ "$STALL_COUNT" -ge 3 ]; then
                    write_stat "stalled" "$CUR_BYTES" 0 "$START_TS"
                    logger -t esp-trng "Watchdog: UART stream stalled at ${CUR_BYTES}B, resetting port"
                    kill "$DD_PID" 2>/dev/null
                    break
                fi
            fi
        done

        wait "$DD_PID" 2>/dev/null
        DD_PID=""
        exec 3<&-
    fi
    sleep 2
done