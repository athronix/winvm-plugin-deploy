#!/usr/bin/env bash
# deploy-4-vm.sh · 装 VM 端并起 winvm service（mcp + a2a）（deploy 第 4 步，与第 3 步并行）
#
# 三件：① 补齐 VM 运行时依赖（node，幂等）② 推包 + 装 VM 端 + 起服务 ③ 七判据体检
# 全程只经现役 ssh 通道；不建通道、不重启 VM。
#
# 用法：VM_HOST=... bash scripts/deploy-4-vm.sh [--purge-workspace]
set -u
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]:-$0}")/_common.sh"

resolve_env; need_node; need_bash; require_host
state_load
PKG="${PKG_ROOT:-}"
[ -n "$PKG" ] && [ -f "$PKG/delivery/setup.mjs" ] \
  || die "找不到包根" "第 2 步未完成" "state=$STATE_FILE" "先跑 bash scripts/deploy-2-host.sh"

# ── 通道门禁：有界等健康窗（不重启 VM，只等新建连接可用）──
st_begin 4.0 "通道门禁（新建连接实测，≤${CHANNEL_GATE_S:-60}s）"
GATE="${CHANNEL_GATE_S:-60}"; waited=0
while :; do
  channel_ready 8000 && break
  [ "$waited" -ge "$GATE" ] && {
    st_end 1 FAIL "通道 ${GATE}s 内不可用（WEDGE：长连活着但新建握手超时）"
    die "通道新建连接不可用" "guest sshd 握手段间歇挂起（WEDGE），非网络层" \
        "ping 通但 ssh2 ready 超时" \
        "按红线不自启/重启 VM；等健康窗后重跑 --only 4（第 1~3 步已 PASS，不必重来）"
  }
  sleep 10; waited=$((waited + 10))
  echo "  … 等健康窗 ${waited}s / ${GATE}s"
done
st_end 0 PASS "channel=READY$([ "$waited" -gt 0 ] && echo "（等了 ${waited}s）")"

# ── 4a 依赖补齐（node，幂等；全 SKIP 也要三次往返，故单独成段便于计时）──
st_begin 4a "prepare-vm --ensure-node（VM 运行时依赖）"
PL="$(sub_log prepare-vm)"
_run_prepare() {
  ( cd "$PKG" && "$NODE" delivery/bootstrap.mjs prepare-vm --apply --ensure-node \
      --vm-host "$VM_HOST" --vm-user "$VM_USER" --vm-ssh-port "$VM_SSH_PORT" ) > "$PL" 2>&1
}
_run_prepare; PRC=$?
# 建连类瞬态（握手超时/连接丢失）给一次有界重试：幂等只读动作，重试安全。
if [ $PRC -ne 0 ] && grep -qE 'Connection lost before handshake|ready 超时|Timed out while waiting' "$PL" 2>/dev/null; then
  cp -f "$PL" "${PL%.log}.attempt1.log" 2>/dev/null || true
  echo "  [4a] 建连瞬态 → 等 15s 重试一次（幂等，不改任何东西）"
  sleep 15
  _run_prepare; PRC=$?
fi
grep -E 'SKIP|已就绪|ensure-node|node' "$PL" | tail -6
if [ $PRC -ne 0 ]; then
  tail -10 "$PL"
  st_end $PRC FAIL "prepare-vm rc=$PRC（VM 端可能缺 node）"
  die "VM 依赖补齐失败" "node 安装或路径探测失败" "$PL" \
      "看 $PL；VM 内 node 走 nvm-windows，切换版本会让全局 CLI 消失"
fi
st_end 0 PASS "依赖就绪"

# ── 4b VM 端安装 + 服务启动（BUILD 打 tar → scp → install-vm → VM-START）──
st_begin 4b "setup --only-vm --skip-build（推包+装 VM 端+起服务）"
SL="$(sub_log setup)"
( cd "$PKG" && "$NODE" delivery/setup.mjs --apply --skip-build --only-vm > "$SL" 2>&1 ); SRC=$?
grep -E '部署全部完成|个步骤失败|降级 SKIP|VM_START|TUNNEL|QA-PROBE' "$SL" | tail -8
if [ $SRC -ne 0 ]; then
  tail -14 "$SL"
  st_end $SRC FAIL "setup rc=$SRC"
  die "VM 端安装失败" "相位名见日志（VM / VM-START / QA-PROBE）" "$SL" \
      "看 $SL 的失败相位；420s 未监听=僵尸 start，先行 schtasks /End + /Run"
fi
st_end 0 PASS "setup rc=0"

# ── 4c 七判据（服务在跑 + 端口在听 + 本地 health 通 + a2a 可达）──
st_begin 4c "vmcheck 七判据"
VL="$(sub_log vmcheck)"
( cd "$PKG" && bash "$SCRIPTDIR/ps-run.sh" "$PKG/qa/deploy-probes/vmcheck.ps1" > "$VL" 2>&1 ); VRC=$?
grep -E 'task_state|listen_count|health_http|a2a|ok' "$VL" | tail -6
if [ $VRC -ne 0 ]; then
  tail -12 "$VL"
  st_end $VRC FAIL "vmcheck rc=$VRC"
  die "VM 端服务未达七判据" "服务未起/端口未听/health 不通" "$VL" \
      "Ready 但未监听=scheduled task 僵死：schtasks /End /tn WinVMBridge.Service 后 /Run"
fi
st_end 0 PASS "$(grep -E 'listen_count' "$VL" | tail -1 | cut -c1-120)"
state_set VM_INSTALLED 1
steps_report
