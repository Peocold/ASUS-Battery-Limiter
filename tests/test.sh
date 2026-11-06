#!/usr/bin/env bash
# 离线测试：用假 sysfs 验证 status / set 的参数校验与写入逻辑。
# 不需要 root，也不会触碰真实硬件（ASUS_BAT_SYSFS 钩子会跳过 root 检查）。
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$root/asus-battery-limit"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export ASUS_BAT_SYSFS="$tmp/sys"
export DEFAULT_LIMIT=80

mkdir -p "$ASUS_BAT_SYSFS/BAT0"
printf '75\n'        > "$ASUS_BAT_SYSFS/BAT0/capacity"
printf 'Discharging\n' > "$ASUS_BAT_SYSFS/BAT0/status"
printf '70243000\n'  > "$ASUS_BAT_SYSFS/BAT0/energy_full"
printf '73000000\n'  > "$ASUS_BAT_SYSFS/BAT0/energy_full_design"
printf '100\n'       > "$ASUS_BAT_SYSFS/BAT0/charge_control_end_threshold"

pass=0 fail=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

expect_out() { # desc, substring, command...
	local desc="$1" needle="$2"; shift 2
	local out
	if out="$("$@" 2>&1)" && grep -qF -- "$needle" <<<"$out"; then
		ok "$desc"
	else
		bad "$desc (output: $out)"
	fi
}

expect_fail() { # desc, command...
	local desc="$1"; shift
	if "$@" >/dev/null 2>&1; then
		bad "$desc (expected non-zero exit)"
	else
		ok "$desc"
	fi
}

threshold="$ASUS_BAT_SYSFS/BAT0/charge_control_end_threshold"

printf 'status\n'
expect_out "shows charge level" "75%" "$bin" status
expect_out "shows health"       "96.2%" "$bin" status
expect_out "shows limit"        "100%" "$bin" status

printf 'set\n'
expect_out "set 80"  "" "$bin" set 80
[ "$(cat "$threshold")" = 80 ] && ok "80 written" || bad "80 written"
expect_out "set 100" "" "$bin" set 100
[ "$(cat "$threshold")" = 100 ] && ok "100 written" || bad "100 written"

printf 'validation\n'
expect_fail "rejects 39"  "$bin" set 39
expect_fail "rejects 101" "$bin" set 101
expect_fail "rejects abc" "$bin" set abc
expect_fail "rejects empty" "$bin" set ""
[ "$(cat "$threshold")" = 100 ] && ok "invalid values leave file untouched" || bad "invalid values leave file untouched"

printf 'help\n'
expect_out "help mentions set" "set <pct>" "$bin" help

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
