#!/usr/bin/env bash
# Run production network provisioning and adversarial probes inside a nested,
# privileged Docker daemon. This is intentionally not a docker-exec substitute
# for student access: every allow/deny assertion below originates through a
# real container network and Docker-published host port.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
name=rd-network-e2e-dind
dind_image=docker:28.3.3-dind@sha256:a56b3bdde89315ed2cc0e4906e582b5033d93bf20d9cb9510c2cdd4e7f7690b1
probe_base=alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

docker run --privileged --detach --name "$name" \
  --env DOCKER_TLS_CERTDIR= "$dind_image" --tls=false >/dev/null
for _ in $(seq 1 90); do
  docker exec "$name" docker info >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$name" docker info >/dev/null
docker exec "$name" apk add --no-cache bash curl iproute2 jq nftables python3 >/dev/null
docker exec "$name" mkdir -p /work
docker cp "$repo/provisioning" "$name":/work/provisioning
docker exec "$name" sh -c "printf '%s' '$probe_base' >/run/rd-probe-base"

# Alpine has no systemd. This narrow mock executes the policy loader when the
# installer starts/reloads its unit; real unit dependency/order is separately
# checked by systemd-analyze in the non-privileged gate.
docker exec -i "$name" sh -c 'install -m 0755 /dev/stdin /usr/local/bin/systemctl' <<'SYSTEMCTL'
#!/bin/sh
case " $* " in
  *" is-active "*)
    [ -e /run/rd-network-policy-active ]
    ;;
  *" start rd-network-policy.service "* | *" reload rd-network-policy.service "*)
    /usr/local/lib/rd-network-policy-load.sh
    touch /run/rd-network-policy-active
    ;;
  *) exit 0 ;;
esac
SYSTEMCTL

docker exec -i "$name" bash -s <<'INNER'
set -euo pipefail

fail() { echo "privileged-network-e2e: $*" >&2; exit 1; }
bind_ip=$(ip -4 -o address show dev eth0 | awk 'NR == 1 { split($4,a,"/"); print a[1] }')
[ -n "$bind_ip" ] || fail 'could not determine nested runner bind address'

cat >/etc/rd-egress-test.nft <<'NFT'
define CTFD_HOST = { 1.1.1.1 }
define DNS_SERVERS = { 8.8.8.8, 1.1.1.1 }
define NTP_SERVERS = { 1.1.1.1 }
define APT_MIRRORS = { 1.1.1.1 }
define CHALLENGE_TARGETS = { 100.64.0.0/10 }
define BLOCKED_DST = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }
NFT
sed -n '/^table ip rd_egress/,$p' /work/provisioning/network/nftables/rd-egress.nft.template >>/etc/rd-egress-test.nft

export RD_POOL_BASE=10.77.240.0/26 RD_POOL_SIZE=4 RD_BIND_IP="$bind_ip"
export RD_PROXY_CIDRS=172.30.0.2/32 RD_RUNNER_PEER_CIDRS="$bind_ip/32"
export RD_EGRESS_POLICY=/etc/rd-egress-test.nft

# Broad trusted-source ranges and pool drift must fail before daemon/network/
# nft mutation.
before_networks=$(docker network ls -q | sort)
before_rules=$(nft list ruleset | sha256sum)
if RD_PROXY_CIDRS=172.30.0.0/24 /work/provisioning/network/install.sh; then
  fail 'broad proxy CIDR passed production preflight'
fi
if RD_RUNNER_PEER_CIDRS=172.16.0.0/12 /work/provisioning/network/install.sh; then
  fail 'broad runner-peer CIDR passed production preflight'
fi
if RD_POOL_BASE=10.88.0.0/20 /work/provisioning/network/install.sh; then
  fail 'pool outside protected 10.77/16 passed production preflight'
fi
[ "$before_networks" = "$(docker network ls -q | sort)" ] || fail 'failed preflight mutated networks'
[ "$before_rules" = "$(nft list ruleset | sha256sum)" ] || fail 'failed preflight mutated nftables'

/work/provisioning/network/install.sh
/work/provisioning/network/net-pool.sh --verify
systemctl reload rd-network-policy.service

# A malformed reload must preserve the entire prior atomic ruleset.
rules_before=$(nft list ruleset | sha256sum)
printf 'this is not nft syntax\n' >/tmp/bad-policy.nft
if RD_NETWORK_POLICY_FILE=/tmp/bad-policy.nft /usr/local/lib/rd-network-policy-load.sh; then
  fail 'malformed nftables transaction was accepted'
fi
[ "$rules_before" = "$(nft list ruleset | sha256sum)" ] || fail 'failed nftables transaction changed live rules'

# Simulate a distro nftables flush/reboot, then exercise the installed loader.
nft destroy table bridge rd_iso
nft destroy table ip rd_egress
/usr/local/lib/rd-network-policy-load.sh

# Build a small probe image locally in the nested daemon.
probe_base=$(cat /run/rd-probe-base)
docker run -d --name rd-probe-build --entrypoint sleep "$probe_base" infinity >/dev/null
docker exec rd-probe-build apk add --no-cache curl iputils py3-pip python3 tcpdump >/dev/null
docker exec rd-probe-build pip install --break-system-packages --no-cache-dir scapy==2.6.1 >/dev/null
docker commit rd-probe-build rd-network-probe:local >/dev/null
docker rm -f rd-probe-build >/dev/null

# Model physical/WireGuard ingress with separate network namespaces and veth
# links. Docker bridges would hit DOCKER-ISOLATION and never exercise the
# production external-source path.
ip netns add rd-proxy
ip link add rdpxh type veth peer name rdpx0
ip link set rdpx0 netns rd-proxy
ip address add 172.30.0.1/30 dev rdpxh
ip link set rdpxh up
ip -n rd-proxy address add 172.30.0.2/30 dev rdpx0
ip -n rd-proxy link set lo up
ip -n rd-proxy link set rdpx0 up
ip -n rd-proxy route add default via 172.30.0.1

ip netns add rd-attacker
ip link add rdath type veth peer name rdat0
ip link set rdat0 netns rd-attacker
ip address add 172.30.0.5/30 dev rdath
ip link set rdath up
ip -n rd-attacker address add 172.30.0.6/30 dev rdat0
ip -n rd-attacker link set lo up
ip -n rd-attacker link set rdat0 up
ip -n rd-attacker route add default via 172.30.0.5

docker run -d --name rd-web --network rd-net-01 \
	-p "$bind_ip:46080:6080" -p "$bind_ip:45900:5900" \
	--entrypoint sh rd-network-probe:local \
	-c 'python3 -m http.server 6080 >/tmp/web.log 2>&1 & exec python3 -m http.server 5900' >/dev/null
sleep 2
web_port=$(docker port rd-web 6080/tcp | awk -F: 'NR == 1 {print $NF}')
vnc_port=$(docker port rd-web 5900/tcp | awk -F: 'NR == 1 {print $NF}')

ip netns exec rd-proxy curl --fail --max-time 5 "http://$bind_ip:$web_port/" >/dev/null ||
	fail 'trusted proxy could not reach published web service'
if ip netns exec rd-attacker curl --fail --max-time 3 "http://$bind_ip:$web_port/" >/dev/null 2>&1; then
	fail 'untrusted source reached published web service'
fi
if ip netns exec rd-proxy curl --fail --max-time 3 "http://$bind_ip:$vnc_port/" >/dev/null 2>&1; then
  fail 'trusted proxy reached forbidden raw VNC service'
fi

docker run -d --name rd-student --network rd-net-00 --entrypoint sleep rd-network-probe:local infinity >/dev/null
if docker exec rd-student curl --fail --max-time 3 "http://$bind_ip:$web_port/" >/dev/null 2>&1; then
  fail 'student bypassed isolation through runner published port'
fi
docker exec rd-student curl --fail --max-time 8 https://example.com/ >/dev/null ||
  fail 'student internet egress was broken by runner-peer policy'

/work/provisioning/network/tests/isolation-test.sh rd-network-probe:local
echo 'privileged-network-e2e: PASS'
INNER
