#!/usr/bin/env bash
# isolation-test.sh -- local/runner isolation test for the rd network pool.
#
# Builds a 4-slot pool (net-pool.sh), puts A on rd-net-00 and B on rd-net-01,
# then asserts the L2/L3 tenant boundary and its inverse control:
#   (a) L2: A must NOT get an ARP reply from B across separate bridges
#   (b) L3: A must NOT ping B; A MUST ping 8.8.8.8 (egress intact)
#   (c) CONTROL: A2/B2 on ONE shared icc=false network -- A2 DOES get an ARP
#       reply from B2. The documented proof that icc=false alone is not L2
#       isolation; only separate networks are.
#   (d) raw non-IP ethertype: a 0x88B5 broadcast from A must not reach B --
#       gated behind a positive self-test on the shared net, because some
#       kernels/bridges (and this dev sandbox) do not propagate custom
#       ethertypes even where ARP flows, which would make the probe a false
#       pass. Skipped-not-failed when the self-test shows no propagation.
#
# ARP reachability is the authoritative discriminating L2 probe: it is real
# wire traffic (scapy srp, not cache), works wherever a bridge forwards
# broadcast, and cleanly separates isolated from non-isolated. nmap is NOT
# used -- its capability-wrapped binary is denied exec under a hardened
# seccomp/no-new-privs sandbox, which silently reads as "host down".
#
# Usage: isolation-test.sh [image]   (default: ctfd-remote-desktop:latest;
# any image with python3+scapy and iputils-ping works)
#
# Cleans up everything it created. Prints PASS/FAIL per assertion and exits
# nonzero on any hard failure.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${1:-ctfd-remote-desktop:latest}"
CTL_NET="rd-isotest-ctl"
CREATED_NETS=()
FAILED=0

report() {
    if [[ "$1" -eq 0 ]]; then
        echo "PASS: $2"
    else
        echo "FAIL: $2"
        FAILED=1
    fi
}

cleanup() {
    echo "--- cleanup ---"
    docker rm -f rd-isotest-a rd-isotest-b rd-isotest-a2 rd-isotest-b2 >/dev/null 2>&1
    docker network rm "$CTL_NET" >/dev/null 2>&1
    local n
    for n in "${CREATED_NETS[@]}"; do
        docker network rm "$n" >/dev/null 2>&1
    done
}
trap cleanup EXIT

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "image '$IMAGE' not found; pass an image with python3-scapy + ping as \$1" >&2
    exit 2
fi

# arp_replies <container> <target_ip> -- count of ARP replies over the wire
arp_replies() {
    docker exec -u 0 "$1" python3 -c "
from scapy.all import ARP, Ether, srp
ans, _ = srp(Ether(dst='ff:ff:ff:ff:ff:ff')/ARP(pdst='$2'),
             iface='eth0', timeout=3, verbose=False)
print(len(ans))
" 2>/dev/null
}

# capture_frames <container> -- captured 0x88B5 frame count during a send window
# echoes the count; caller runs the sender while this blocks
capture_frames() {
    docker exec -u 0 "$1" sh -c \
        'timeout 6 tcpdump -l -n -c 1 -i eth0 ether proto 0x88b5 2>/dev/null | grep -c "88b5\|8:5\|length" || true'
}

send_frames() {
    docker exec -u 0 "$1" python3 -c "
from scapy.all import Ether, Raw, sendp
sendp(Ether(dst='ff:ff:ff:ff:ff:ff', type=0x88B5)/Raw(b'RDISOTESTPAYLOAD'),
      iface='eth0', count=5, verbose=False)
" 2>/dev/null
}

echo "--- setup: 4-slot pool + containers A/B ---"
for i in 0 1 2 3; do
    docker network inspect "rd-net-0$i" >/dev/null 2>&1 || CREATED_NETS+=("rd-net-0$i")
done
if ! RD_POOL_SIZE=4 RD_POOL_BASE=10.77.0.0/26 "$SCRIPT_DIR/../net-pool.sh"; then
    echo "net-pool.sh failed" >&2
    exit 2
fi

docker run -d --name rd-isotest-a --network rd-net-00 --entrypoint sleep "$IMAGE" infinity >/dev/null || exit 2
docker run -d --name rd-isotest-b --network rd-net-01 --entrypoint sleep "$IMAGE" infinity >/dev/null || exit 2
B_IP="$(docker inspect -f '{{ (index .NetworkSettings.Networks "rd-net-01").IPAddress }}' rd-isotest-b)"
echo "A on rd-net-00, B on rd-net-01 ($B_IP)"

echo "--- (a) L2: A must not get an ARP reply from B across separate bridges ---"
n="$(arp_replies rd-isotest-a "$B_IP")"
[[ "$n" == "0" ]]
report $? "(a) B ($B_IP) answers no ARP from A (got ${n:-err} replies)"

echo "--- (b) L3: A cannot ping B, but egress works ---"
if docker exec -u 0 rd-isotest-a ping -c1 -W2 "$B_IP" >/dev/null 2>&1; then
    report 1 "(b1) B is not pingable from A"
else
    report 0 "(b1) B is not pingable from A"
fi
docker exec -u 0 rd-isotest-a ping -c1 -W3 8.8.8.8 >/dev/null 2>&1
report $? "(b2) ping 8.8.8.8 from A succeeds (egress intact)"

echo "--- (c) CONTROL: shared icc=false network, ARP must answer ---"
docker network create --driver bridge \
    --opt com.docker.network.bridge.enable_icc=false "$CTL_NET" >/dev/null || exit 2
docker run -d --name rd-isotest-a2 --network "$CTL_NET" --entrypoint sleep "$IMAGE" infinity >/dev/null || exit 2
docker run -d --name rd-isotest-b2 --network "$CTL_NET" --entrypoint sleep "$IMAGE" infinity >/dev/null || exit 2
B2_IP="$(docker inspect -f "{{ (index .NetworkSettings.Networks \"$CTL_NET\").IPAddress }}" rd-isotest-b2)"
n="$(arp_replies rd-isotest-a2 "$B2_IP")"
[[ "${n:-0}" -ge 1 ]]
report $? "(c) CONTROL: B2 answers ARP on shared icc=false net (got ${n:-err} replies) -- icc=false is not L2 isolation"

echo "--- (d) raw 0x88B5 ethertype (gated on shared-net propagation self-test) ---"
: >/dev/null
cap="$(capture_frames rd-isotest-b2 & tdpid=$!; sleep 2; send_frames rd-isotest-a2; wait $tdpid)"
if [[ "${cap:-0}" -ge 1 ]]; then
    # environment propagates custom ethertypes: run the real negative on separate nets
    cap2="$(capture_frames rd-isotest-b & tdpid=$!; sleep 2; send_frames rd-isotest-a; wait $tdpid)"
    [[ "${cap2:-0}" -eq 0 ]]
    report $? "(d) 0x88B5 broadcast from A not captured by B across separate bridges (got ${cap2:-err})"
else
    echo "SKIP: (d) this environment does not propagate 0x88B5 even on the shared control net; ARP (a/c) is authoritative here"
fi

echo "---------------"
if [[ "$FAILED" -ne 0 ]]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
exit 0
