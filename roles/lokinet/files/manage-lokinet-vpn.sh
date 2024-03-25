#!/bin/bash
set -e

# Initialize variables

ping_count=0
ping_failures=0
ping_total=0

systemd-notify --ready --status="LokinetVPN monitor started…"

MAX_FAIL_COUNT=3
MAX_PING_TIME=100
PING_BATCH_SIZE=120

fail_count=0

while true; do
ping_result=$(ping -c 1 8.8.8.8 | awk -F'[=]|[ ]' '/time=/ {print $10}')

if [ -n "$ping_result" ]; then
    if (( $(bc <<< "$ping_result < $MAX_PING_TIME") )); then
        echo "Ping time is under 100ms, lokinet is not being used: $ping_result ms"
        fail_count=$((fail_count + 1))
    else

        fail_count=0
        ping_total=$((ping_total + ping_result))
        ping_count=$((ping_count + 1))

        if ((ping_count == PING_BATCH_SIZE)); then
            avg_ping=$(bc <<< "scale=2; $ping_total / $PING_BATCH_SIZE")
            echo "Average ping for last $PING_BATCH_SIZE pings: $avg_ping ms"
            ping_total=0
            ping_count=0
        fi
    fi

else
    echo "Ping failed"
    fail_count=$((fail_count + 1))
fi

if ((fail_count >= MAX_FAIL_COUNT)); then
    echo "Restarting lokinet.service"
    systemctl restart lokinet.service
    echo "lokinet.service restarted"

    sleep 5

    if [[ -z $LOKI_EXIT_TOKEN ]] ; then
        
        lokinet-vpn --exit $LOKI_EXIT_NODE --up
        
    else

        lokinet-vpn --exit $LOKI_EXIT_NODE --token $LOKI_EXIT_TOKEN --up

    fi

    lokinet-vpn --status

    echo "LokinetVPN activated"

    fail_count=0
fi

sleep 1

done
