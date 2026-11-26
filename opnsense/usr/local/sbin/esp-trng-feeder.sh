#!/bin/sh

DEV="/dev/trng_esp"
BAUD="115200"
PIDFILE="/var/run/esp-trng-feeder.pid"
STATFILE="/tmp/esp_trng_stats.json"
TMPSTAT="/tmp/esp_trng_stats.json.tmp"
DDPIPE="/tmp/esp_trng_dd.pipe"
DDBYTES="/tmp/esp_trng_bytes"

echo $$ > "$PIDFILE"
DD_PID=""
READER_PID=""

write_stat() {
    printf '{"status": "%s", "total_bytes": %s, "speed_bps": %s, "start_ts": %s, "updated_ts": %s}\n' \
        "$1" "$2" "$3" "$4" "$(date +%s)" > "$TMPSTAT"
    mv -f "$TMPSTAT" "$STATFILE"
}

stop_pipeline() {
    [ -n "$DD_PID" ] && kill "$DD_PID" 2>/dev/null
    [ -n "$DD_PID" ] && wait "$DD_PID" 2>/dev/null
    [ -n "$READER_PID" ] && kill "$READER_PID" 2>/dev/null
    [ -n "$READER_PID" ] && wait "$READER_PID" 2>/dev/null
    DD_PID=""
    READER_PID=""
    exec 3<&- 2>/dev/null
    rm -f "$DDPIPE" "$DDBYTES"
}

cleanup() {
    [ -n "$DD_PID" ] && kill "$DD_PID" 2>/dev/null
    [ -n "$READER_PID" ] && kill "$READER_PID" 2>/dev/null
    exec 3<&- 2>/dev/null
    # Remove shared files only if no newer instance has taken over PIDFILE
    if [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ]; then
        rm -f "$PIDFILE" "$STATFILE" "$TMPSTAT" "$DDPIPE" "$DDBYTES"
    fi
    exit 0
}
trap cleanup INT TERM EXIT

while true; do
    if [ -c "$DEV" ]; then
        START_TS=$(date +%s)
        LAST_BYTES=0
        LAST_TS=$START_TS
        STALL_COUNT=0

        rm -f "$DDPIPE" "$DDBYTES"
        mkfifo "$DDPIPE" || { sleep 2; continue; }
        printf '0\n' > "$DDBYTES"

        # Background SIGINFO parser (0% idle CPU, pure POSIX sh, no awk/sed)
        (
            while IFS= read -r line; do
                case "$line" in
                    *"bytes transferred"*)
                        set -- $line
                        printf '%s\n' "$1" > "$DDBYTES"
                        ;;
                esac
            done < "$DDPIPE"
        ) &
        READER_PID=$!

        # Hold fd 3 open so stty raw settings persist across dd lifecycle
        exec 3< "$DEV" || { stop_pipeline; sleep 2; continue; }
        stty -f "$DEV" "$BAUD" raw cs8 -cstopb -parenb -crtscts -ixon -ixoff clocal

        # Feed entropy blocks into FreeBSD Fortuna/ChaCha20 CSPRNG
        dd bs=32 of=/dev/random <&3 2>"$DDPIPE" &
        DD_PID=$!

        write_stat "starting" 0 0 "$START_TS"

        while kill -0 "$DD_PID" 2>/dev/null; do
            sleep 5
            if [ ! -c "$DEV" ]; then
                break
            fi

            kill -INFO "$DD_PID" 2>/dev/null
            sleep 0.1

            CUR_BYTES=$(cat "$DDBYTES" 2>/dev/null)
            CUR_BYTES=${CUR_BYTES:-0}
            NOW_TS=$(date +%s)
            DT=$((NOW_TS - LAST_TS))
            [ "$DT" -le 0 ] && DT=1

            if [ "$CUR_BYTES" -gt "$LAST_BYTES" ]; then
                DIFF=$((CUR_BYTES - LAST_BYTES))
                # Integer math for 0.01 B/s precision without spawning awk
                SPEED_X100=$(( (DIFF * 100) / DT ))
                SPEED_INT=$(( SPEED_X100 / 100 ))
                SPEED_FRAC=$(( SPEED_X100 % 100 ))
                [ "$SPEED_FRAC" -lt 10 ] && SPEED_FRAC="0${SPEED_FRAC}"
                SPEED="${SPEED_INT}.${SPEED_FRAC}"

                write_stat "running" "$CUR_BYTES" "$SPEED" "$START_TS"
                LAST_BYTES=$CUR_BYTES
                LAST_TS=$NOW_TS
                STALL_COUNT=0
            else
                STALL_COUNT=$((STALL_COUNT + 1))
                if [ "$STALL_COUNT" -ge 3 ]; then
                    write_stat "stalled" "$CUR_BYTES" 0 "$START_TS"
                    logger -t esp-trng "Watchdog: UART stream stalled at ${CUR_BYTES}B, resetting port"
                    break
                fi
            fi
        done

        stop_pipeline
    fi
    sleep 2
done
