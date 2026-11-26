#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/tree/package"

for profile in libwrt-25.12-nss immortalwrt-viking-owrt-ppe; do
  stable=$(bash scripts/load-profile.sh "$profile")
  honk=$(bash scripts/load-profile.sh "$profile-ebpf")
  grep -Fxq 'SOFTWARE_POLICY=aurora-homeproxy' <<< "$stable"
  grep -Fxq 'SOFTWARE_POLICY=aurora-honk' <<< "$honk"
  grep -Fxq "CACHE_NAMESPACE=$profile-ebpf" <<< "$honk"
  for field in SOURCE_REPO SOURCE_BRANCH SOURCE_PINS PROFILE_CONFIG ACCELERATION_POLICY PROFILE_ADAPTER; do
    [ "$(grep "^$field=" <<< "$stable")" = "$(grep "^$field=" <<< "$honk")" ]
  done
  notes=$(bash scripts/release-notes.sh "$profile-ebpf")
  grep -Fq 'Honk + Doona' <<< "$notes"
  if grep -Fq sing-box <<< "$notes"; then
    echo 'Honk release notes describe the original proxy stack' >&2
    exit 1
  fi
  grep -Fq '已在 256 MB 原厂设备完成真机验收' <<< "$notes"
  if grep -Fq '无法启动' <<< "$notes"; then
    echo "$profile-ebpf wrongly claims a startup failure" >&2
    exit 1
  fi
done

cat > "$tmp/tree/.config" <<'CONFIG'
CONFIG_PACKAGE_sing-box=y
CONFIG_PACKAGE_luci-app-homeproxy=y
CONFIG_PACKAGE_luci-theme-aurora=y
CONFIG_KERNEL_DEBUG_INFO_REDUCED=y
# CONFIG_KERNEL_DEBUG_INFO is not set
CONFIG
bash scripts/honk-profile.sh prepare "$tmp/tree"
bash scripts/honk-profile.sh config "$tmp/tree"
cmp package/honk/Makefile "$tmp/tree/package/honk/Makefile"
[ "$(grep -c 'DEBUG_INFO_REDUCED' "$tmp/tree/.config")" -eq 1 ]
printf 'CONFIG_PACKAGE_sing-box=m\n' >> "$tmp/tree/.config"
if bash scripts/honk-profile.sh config "$tmp/tree" 2>/dev/null; then
  echo 'Honk accepted an injected sing-box module' >&2
  exit 1
fi
sed -i '/^CONFIG_PACKAGE_sing-box=m$/d' "$tmp/tree/.config"
# bpftool is a variant package: only bpftool-minimal/bpftool-full exist, so a
# bare CONFIG_PACKAGE_bpftool=y is silently dropped by defconfig and the image
# ships without the only tool that can read TCX links and pinned maps back out.
if grep -Eq '^CONFIG_PACKAGE_bpftool=' configs/honk-ebpf.config; then
  echo 'Honk fragment selects the non-existent bare bpftool symbol' >&2
  exit 1
fi
sed -i '/^CONFIG_PACKAGE_bpftool-minimal=y$/d' "$tmp/tree/.config"
if bash scripts/honk-profile.sh config "$tmp/tree" 2>/dev/null; then
  echo 'Honk accepted a tree without bpftool' >&2
  exit 1
fi
printf 'CONFIG_PACKAGE_bpftool-minimal=y\n' >> "$tmp/tree/.config"
if bash scripts/honk-profile.sh kernel "$tmp/tree" 2>/dev/null; then
  echo 'Honk accepted a missing kernel' >&2
  exit 1
fi
kernel="$tmp/tree/build_dir/target-aarch64/linux-qualcommax_ipq60xx/linux-6.18"
mkdir -p "$kernel"
for symbol in BPF BPF_SYSCALL BPF_JIT CGROUPS CGROUP_BPF DEBUG_INFO_BTF NET_SCHED NET_CLS_ACT NET_XGRESS NET_NS FUNCTION_TRACER DYNAMIC_FTRACE; do
  printf 'CONFIG_%s=y\n' "$symbol"
done > "$kernel/.config"
printf '__attribute__((section(".BTF"))) const char fixture[] = "fixture";\n' |
  cc -x c -c -o "$kernel/vmlinux" -
bash scripts/honk-profile.sh kernel "$tmp/tree"
sed -i '/CONFIG_NET_XGRESS=y/d' "$kernel/.config"
if bash scripts/honk-profile.sh kernel "$tmp/tree" 2>/dev/null; then
  echo 'Honk accepted a kernel without TCX' >&2
  exit 1
fi
# Without FUNCTION_TRACER honk degrades: the UDP receive-trace fallback cannot
# attach and every socket loses its receive-priority metadata path.
printf 'CONFIG_NET_XGRESS=y\n' >> "$kernel/.config"
sed -i '/CONFIG_FUNCTION_TRACER=y/d' "$kernel/.config"
if bash scripts/honk-profile.sh kernel "$tmp/tree" 2>/dev/null; then
  echo 'Honk accepted a kernel without the UDP receive-trace fallback' >&2
  exit 1
fi

source scripts/validate-profile-output.sh
printf '%s - fixture\n' honk v2ray-geoip v2ray-geosite luci-theme-aurora firewall4 > "$tmp/manifest"
validate_profile_manifest "$tmp/manifest" ppe aurora-honk
printf '%s - fixture\n' sing-box-tiny >> "$tmp/manifest"
if validate_profile_manifest "$tmp/manifest" ppe aurora-honk 2>/dev/null; then
  echo 'Honk accepted mixed proxy packages' >&2
  exit 1
fi

package=package/honk/files
jq -e '
  .["luci-app-honk"].read.file == {"/usr/libexec/zn-m2-honk-status":["exec"]}
  and .["luci-app-honk"].write.file == {"/etc/init.d/honk":["exec"]}
' "$package/luci/acl.d/luci-app-honk.json" >/dev/null
jq -e '.["admin/services/honk"].depends.acl == ["luci-app-honk"]' \
  "$package/luci/menu.d/luci-app-honk.json" >/dev/null
sh -n "$package/honk.init" "$package/honk.status"
IPKG_INSTROOT="$tmp/rootfs" sh -eu -c '
  enable() { exit 1; }
  disable() { echo disabled; }
  . "$1"
  enable
' sh "$package/honk.init" | grep -Fxq disabled
IPKG_INSTROOT= sh -eu -c '
  enable() { echo enabled; }
  disable() { exit 1; }
  . "$1"
  enable
' sh "$package/honk.init" | grep -Fxq enabled
if sh "$package/honk.status" unexpected; then
  echo 'LuCI read-only status script accepted an argument' >&2
  exit 1
fi
grep -Fq 'nfqueue_enable: false' "$package/config.dae"
grep -Fq 'pname(dnsmasq)' "$package/config.dae"
grep -Fq 'iifname != { "lo", "br-lan" } tcp dport 9527 reject' "$package/honk.nft"
# A killed load leaves the verifier's pins and working set behind, and procd
# then respawns into the same OOM kill. The init script must therefore refuse to
# start on a board that cannot hold the load, cap the respawn count, and reclaim
# the pins of a stopped instance.
grep -Eq '^[[:space:]]*procd_set_param respawn [0-9]+ [0-9]+ [0-9]+' "$package/honk.init" || {
  echo 'Honk respawn is unbounded, so an OOM loop repeats forever' >&2
  exit 1
}
grep -Fq 'mem_min_kb' "$package/honk.init" || {
  echo 'Honk init script has no memory floor' >&2
  exit 1
}
grep -Fq 'service_stopped()' "$package/honk.init" || {
  echo 'Honk init script does not reclaim pinned maps on stop' >&2
  exit 1
}
grep -Fq 'option mem_min_kb' "$package/honk.config" || {
  echo 'Honk UCI config does not document the memory floor' >&2
  exit 1
}
# The state database is what doona needs for import and revision history, and
# the geodata settings require a writable state db too. It must ship enabled,
# otherwise the dashboard reports those features as unavailable out of the box.
grep -Fq "option store 'db'" "$package/honk.config" || {
  echo 'Honk UCI config does not enable the state database' >&2
  exit 1
}

# The memory floor must actually block a start on a board without headroom, and
# the pin reclaim must clear stale maps without touching unrelated bpffs dirs.
mkdir -p "$tmp/memtest/bin" "$tmp/memtest/bpffs"
cat > "$tmp/memtest/bin/awk" <<'EOF'
#!/bin/sh
# Only the MemAvailable probe matters here.
[ -r "$MEMINFO" ] && sed -n 's/^MemAvailable:[[:space:]]*\([0-9]*\).*/\1/p' "$MEMINFO"
EOF
cat > "$tmp/memtest/bin/pidof" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$tmp/memtest/bin/"*
printf 'MemAvailable:       8192 kB\n' > "$tmp/memtest/meminfo.low"
printf 'MemAvailable:      65536 kB\n' > "$tmp/memtest/meminfo.ok"
: > "$tmp/memtest/bpffs/CONN_STATE_MAP"
: > "$tmp/memtest/bpffs/ROUTING_POLICY_ROOT"
mkdir -p "$tmp/memtest/bpffs/some-dir"

if MEMINFO="$tmp/memtest/meminfo.low" PATH="$tmp/memtest/bin:$PATH" \
  sh -c '. "$1"; mem_ok 49152' sh "$package/honk.init"; then
  echo 'Honk accepted a start below the eBPF memory floor' >&2
  exit 1
fi
MEMINFO="$tmp/memtest/meminfo.ok" PATH="$tmp/memtest/bin:$PATH" \
  sh -c '. "$1"; mem_ok 49152' sh "$package/honk.init" || {
  echo 'Honk refused a start with enough memory' >&2
  exit 1
}
# The init script pins BPFFS itself, so point it at the fixture after sourcing.
PATH="$tmp/memtest/bin:$PATH" \
  sh -c '. "$1"; BPFFS="$2"; clear_pins' sh "$package/honk.init" "$tmp/memtest/bpffs"
[ ! -e "$tmp/memtest/bpffs/CONN_STATE_MAP" ] || {
  echo 'Honk left stale pinned maps behind' >&2
  exit 1
}
[ -d "$tmp/memtest/bpffs/some-dir" ] || {
  echo 'Honk removed a bpffs directory it does not own' >&2
  exit 1
}
# The guard has to be wired into the start path, not just defined.
awk '/^start_service\(\)/,/^}/' "$package/honk.init" | grep -Fq 'mem_ok "$mem_min"' || {
  echo 'Honk start path does not consult the eBPF memory floor' >&2
  exit 1
}
awk '/^start_service\(\)/,/^}/' "$package/honk.init" | grep -Fq 'clear_pins' || {
  echo 'Honk start path does not reclaim stale pins' >&2
  exit 1
}

# A response fallback naming the same upstream as the request fallback makes
# every answer re-query that upstream; honk then aborts the traversal with
# "DNS response requery cycle" and serves SERVFAIL for every name.
response_block=$(awk '/response \{/{flag=1} flag{print} flag&&/^[ \t]*\}$/{exit}' \
  "$package/config.dae")
if printf '%s\n' "$response_block" | grep -Eq '^[[:space:]]*fallback: local[[:space:]]*$'; then
  echo 'Honk default config creates a DNS response requery cycle' >&2
  exit 1
fi
printf '%s\n' "$response_block" | grep -Eq '^[[:space:]]*fallback: accept[[:space:]]*$' || {
  echo 'Honk default config does not accept the request-rule answer' >&2
  exit 1
}

# doona reports "geodata update unavailable" until routing loads at least one
# asset. The routing rule is the half that matters; the download URL is left
# out on purpose, because naming one replaces honk's built-in list instead of
# adding a mirror, and the built-in list's jsdelivr fallback is what succeeds
# on networks that filter raw.githubusercontent.com per IPv4 address.
grep -Eq '^[[:space:]]*assets[[:space:]]*\{' "$package/config.dae" || {
  echo 'Honk default config has no assets block, so geodata can never update' >&2
  exit 1
}
if grep -Eq "^[[:space:]]*geosite:[[:space:]]*'https://" "$package/config.dae"; then
  echo 'Honk default config pins one geosite URL, which drops the jsdelivr fallback' >&2
  exit 1
fi
grep -Fq 'domain(geosite: cn) -> direct(must)' "$package/config.dae" || {
  echo 'Honk default config never loads geosite, so the asset stays unloaded' >&2
  exit 1
}
# 1.1.1.1 answers ordinary lookups here but honk's own queries through it fail
# with resolution_failed, which stops every geodata download before TLS.
grep -Fq "bootstrap_resolver: '223.5.5.5:53'" "$package/config.dae" || {
  echo 'Honk bootstrap resolver is not the one its downloader can reach' >&2
  exit 1
}
# honk resolves the download host itself; without this rule its queries follow
# whatever proxy policy the routing table applies.
grep -Fq 'pname(honk-core) && l4proto(udp, tcp) && dport(53) -> direct(must)' "$package/config.dae" || {
  echo 'Honk does not exempt its own resolver egress from proxy routing' >&2
  exit 1
}
# geosite(cn) is not a predicate; honk rejects the file and procd then crash
# loops on every restart.
if grep -Eq '(^|[^a-z])geosite\(cn\)' "$package/config.dae"; then
  echo 'Honk default config uses the invalid geosite() predicate' >&2
  exit 1
fi
# geodata must not land in an apk-owned path, or an update rewrites a package
# file and the next `apk upgrade` reverts it.
grep -Fq 'GEODATA_DIR=/usr/local/share/honk' "$package/honk.init" || {
  echo 'Honk geodata is not seeded outside the apk-managed v2ray tree' >&2
  exit 1
}
awk '/^start_service\(\)/,/^}/' "$package/honk.init" | grep -Fq 'seed_geodata' || {
  echo 'Honk start path never seeds the geodata asset' >&2
  exit 1
}

echo 'PASS: Honk profile pairs, fragment resolution, final kernel gate, package isolation and LuCI ACL'
