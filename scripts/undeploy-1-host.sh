#!/usr/bin/env bash
# undeploy-1-host.sh · 停隧道 + 卸 host 端插件（undeploy 第 1 步，与第 2 步并行）
#
# 不需要 ssh 通道，纯宿主本地动作。
# 关键：uninstall.mjs 是「双端」脚本，会自己去找 VM 目标（vm-conn.json / env / 包根 .env
# 四级回退）。这里必须把它锁成 host-only，否则会偷偷跑一遍 VM 卸载（与第 2 步重复，
# 通道坏时还会挂死）。做法=临时移走三处 VM 目标 + trap 保证任何退出路径都还原。
#
# 用法：bash scripts/undeploy-1-host.sh
set -u
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]:-$0}")/_common.sh"

resolve_env; need_node

st_begin 1a "停 winvm-tunnel service"
VMC="$WINVM_HOME/vm-conn.json"
PKG=""; resolve_pkg_root >/dev/null 2>&1 && PKG="$PKG_RESOLVED"
if [ -n "$PKG" ] && [ -f "$PKG/delivery/winvm-plugin.mjs" ]; then
  ( cd "$PKG" && timeout 90 "$NODE" delivery/winvm-plugin.mjs tunnel stop ) > "$(sub_log tunnel-stop)" 2>&1 \
    || warn "tunnel stop 返回非零（可能本就没起）"
else
  warn "无包根：跳过 CLI stop，直接按 pid 兜底"
fi
# pid 兜底（不 kill -f：会误伤同命令行的其它进程）
# tunnel.pid 是 JSON，必须走 tunnel_pid 解析（早期 tr -dc '0-9' 会拼成一串错误 pid）
_pid="$(tunnel_pid)"
if [ "$_pid" != "0" ] && kill -0 "$_pid" 2>/dev/null; then
  kill "$_pid" 2>/dev/null || true
  sleep 1
  kill -0 "$_pid" 2>/dev/null && warn "隧道 pid $_pid 仍在（可能自愈重启，稍后 health 复判）"
fi
HC="$(health_code "${WINVM_TUNNEL_LOCAL_PORT:-18443}" 6)"
sleep 1; HC2="$(health_code "${WINVM_TUNNEL_LOCAL_PORT:-18443}" 6)"
[ "$HC2" = "000" ] && st_end 0 PASS "health=$HC→$HC2（daemon 已停）" || st_end 0 SKIP "health=$HC2（daemon 仍在，由后续判定）"

st_begin 1b "卸 host 端插件（uninstall.mjs host-only）"
# ── 屏蔽三处 VM 目标（任何退出路径都还原）──
HID_VMC=""; HID_ENV=""
restore_targets() {
  [ -n "$HID_VMC" ] && [ -f "$HID_VMC" ] && { "$NODE" -e 'require("fs").renameSync(process.argv[1],process.argv[2])' "$HID_VMC" "$VMC" 2>/dev/null || mv -f "$HID_VMC" "$VMC"; }
  [ -n "$HID_ENV" ] && [ -f "$HID_ENV" ] && { "$NODE" -e 'require("fs").renameSync(process.argv[1],process.argv[2])' "$HID_ENV" "${HID_ENV%.undeploy-host-hidden}" 2>/dev/null || mv -f "$HID_ENV" "${HID_ENV%.undeploy-host-hidden}"; }
  return 0
}
trap restore_targets EXIT INT TERM
# 留一份给第 2/3 步与下次 deploy 用的连接快照（undeploy 不删真相源，只临时移开）
if [ -f "$VMC" ]; then
  cp -f "$VMC" "$VMC.roundtrip" 2>/dev/null || true
  HID_VMC="$VMC.undeploy-host-hidden"
  if ! "$NODE" -e 'require("fs").renameSync(process.argv[1],process.argv[2])' "$VMC" "$HID_VMC" 2>/dev/null; then
    if mv -f "$VMC" "$HID_VMC" 2>/dev/null; then :; else HID_VMC=""; warn "vm-conn.json 无法临时移走（继续）"; fi
  fi
fi
if [ -n "$PKG" ] && [ -f "$PKG/.env" ]; then
  HID_ENV="$PKG/.env.undeploy-host-hidden"
  if ! "$NODE" -e 'require("fs").renameSync(process.argv[1],process.argv[2])' "$PKG/.env" "$HID_ENV" 2>/dev/null; then
    if mv -f "$PKG/.env" "$HID_ENV" 2>/dev/null; then :; else HID_ENV=""; warn ".env 无法临时移走（继续）"; fi
  fi
fi

AL="$(sub_log uninstall-host)"
if [ -n "$PKG" ]; then
  ( cd "$PKG" && unset WINVM_VM_HOST WINVM_VM_USER WINVM_VM_SSH_PORT && \
    timeout 180 "$NODE" delivery/uninstall.mjs --apply > "$AL" 2>&1 ); HRC=$?
else
  HRC=1; echo "[HOST] 无包根：本机可能从未装过" > "$AL"
fi
restore_targets; trap - EXIT INT TERM

# 判据只看 HOST 行（host-only 时总 rc=1 是设计内：VM 相位 skipped 计一次失败）
HPASS="$(awk '/\[PASS\] HOST/{n++} END{print n+0}' "$AL" 2>/dev/null)"; : "${HPASS:=0}"
HFAIL="$(awk '/\[FAIL\] HOST/{n++} END{print n+0}' "$AL" 2>/dev/null)"; : "${HFAIL:=0}"
VMINHOST="$(awk '/^--- VM: .* pushed via scp/{n++} END{print n+0}' "$AL" 2>/dev/null)"; : "${VMINHOST:=0}"
grep -E '\[FAIL\] HOST|APPLY' "$AL" | head -6 || true
echo "  HOST_PASS=$HPASS HOST_FAIL=$HFAIL VM_PHASE_IN_HOST=$VMINHOST uninstall_rc=$HRC"
if [ "$HFAIL" != "0" ] || [ "${HPASS:-0}" -lt 11 ] || [ "$VMINHOST" != "0" ]; then
  st_end 1 FAIL "HOST_PASS=$HPASS HOST_FAIL=$HFAIL VM_PHASE=$VMINHOST"
  die "host 端卸载未达判据" "$([ "$VMINHOST" != "0" ] && echo 'VM 目标未屏蔽干净，host 相位跑成了双端' || echo 'host 清理项有失败')" \
      "$AL" "看 $AL；VM_PHASE!=0 说明 .env/vm-conn.json 屏蔽失败"
fi
st_end 0 PASS "HOST_PASS=$HPASS HOST_FAIL=0 VM_PHASE=0"

st_begin 1c "host 端清空复核"
_C1=0
HC3="$(health_code "${WINVM_TUNNEL_LOCAL_PORT:-18443}" 5)"
[ "$HC3" = "000" ] || { warn "health=$HC3（隧道仍在）"; _C1=1; }
LEFT="$("$NODE" -e 'try{const j=require(process.env.HOME+"/.workbuddy/mcp.json");const k=Object.keys(j.mcpServers||{}).filter(x=>/winvm/i.test(x));process.stdout.write(k.join(","))}catch{process.stdout.write("")}' 2>/dev/null)"
[ -z "$LEFT" ] && echo "  mcp.json 无 winvm 条目" || { warn "mcp.json 仍留 $LEFT"; _C1=1; }
st_end $_C1 "$([ $_C1 -eq 0 ] && echo PASS || echo FAIL)" "health=$HC3 mcp_left=${LEFT:-none}"
state_set HOST_INSTALLED 0
steps_report
exit $_C1
