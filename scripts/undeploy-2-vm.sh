#!/usr/bin/env bash
# undeploy-2-vm.sh · 停 VM 端 winvm service + 卸 VM 端模块（undeploy 第 2 步，与第 1 步并行）
#
# 只经现役 ssh 通道；通道不在 = 正常输入，**绝不为此重建通道**。
# 通道不在时本步如实报 SKIP 并给出用户手工命令（第 3 步会把两份命令合并展示）。
#
# 用法：bash scripts/undeploy-2-vm.sh [--purge-workspace]
set -u
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]:-$0}")/_common.sh"

PURGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --purge-workspace) PURGE=1 ;;
    --pkg) shift ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac; shift
done

resolve_env; need_node; require_host

st_begin 2a "通道状态（只判不建）"
if ! channel_ready 6000; then
  st_end 0 SKIP "channel=DOWN（卸载的正常输入）"
  echo "VM_SIDE_PENDING=1"
  echo "VM 端未卸载（通道不在）。等通道可用后重跑本步，或在 VM 里手工执行："
  echo '  schtasks /End /TN WinVMBridge.Service & schtasks /Delete /TN WinVMBridge.Service /F'
  echo '  Remove-Item C:\WinVMBridge -Recurse -Force -ErrorAction SilentlyContinue'
  steps_report
  exit 2
fi
st_end 0 PASS "channel=READY"

st_begin 2b "推 VM 侧卸载脚本"
# 用 vm-conn.sh 的 vmscp（双后端一致）
( set +u; . "$SCRIPTDIR/vm-conn.sh"; \
  vmscp "$SCRIPTDIR/vm-remove-local.ps1" "${VM_USER}@${VM_HOST}:vm-remove-local.ps1" ) \
  > "$(sub_log vmscp)" 2>&1; SRC=$?
if [ $SRC -ne 0 ]; then
  tail -5 "$(sub_log vmscp)"
  st_end $SRC FAIL "scp rc=$SRC"
  echo "VM_SIDE_PENDING=1"
  die "推卸载脚本失败" "通道瞬态窗或权限" "$(sub_log vmscp)" \
      "稍后重跑本步；不要为此重建通道"
fi
st_end 0 PASS "vm-remove-local.ps1 已就位"

st_begin 2c "停服务 + 卸模块（vm-remove-local.ps1 -Apply）"
PARGS="-Apply"; [ "$PURGE" = "1" ] && PARGS="$PARGS -PurgeWorkspace"
RAL="$(sub_log vm-remove)"
bash "$SCRIPTDIR/ps-run.sh" -c "& .\\vm-remove-local.ps1 $PARGS" > "$RAL" 2>&1; VRC=$?
grep -E 'MODE=|VM_CLEANUP_DONE|BRIDGE_DIR=|TASK_EXISTS=|PORT_LISTEN=|BRIDGE_NODE_LEFT=|\[WARN\]' "$RAL" | tail -12 || true
if [ $VRC -ne 0 ] || ! grep -q 'VM_CLEANUP_DONE' "$RAL" 2>/dev/null; then
  tail -12 "$RAL"
  st_end $VRC FAIL "rc=$VRC 且无 VM_CLEANUP_DONE"
  die "VM 端卸载未完成" "服务停不掉 / 文件占用 / 通道瞬态" "$RAL" \
      "看 $RAL；确认 C:\\WinVMBridge 已删、计划任务已删、18443 不再监听"
fi
st_end 0 PASS "$(grep -E 'VM_CLEANUP_DONE|TASK_EXISTS=|PORT_LISTEN=' "$RAL" | tr '\n' ' ' | cut -c1-140)"

st_begin 2d "VM 终态五点"
TL="$(sub_log vm-terminal)"
bash "$SCRIPTDIR/ps-run.sh" -c '$a=Test-Path C:\WinVMBridge; $null=(schtasks /query /tn WinVMBridge.Service 2>$null); $b=($LASTEXITCODE -eq 0); $c=@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -eq 18443 }).Count; $s=(Get-Service sshd).Status; $e=Test-Path C:\WinVMWorkspace; Write-Output ("expect False False 0 * True => " + $a + " " + $b + " " + $c + " " + $s + " " + $e)' \
  > "$TL" 2>&1; TRC=$?
tr -d '\r' < "$TL" | tail -3
_LINE="$(tr -d '\r' < "$TL" | grep -oE '=> .*' | tail -1)"
if [ $TRC -ne 0 ] || [ -z "$_LINE" ]; then
  st_end 0 SKIP "VM 终态行取不到（环境瞬态窗，不算功能失败）"
  echo "VM_TERMINAL=PENDING"
else
  set -- $_LINE
  # $1='=>' $2=bridge $3=task $4=listen $5=sshd $6=ws
  _ok=0
  [ "$2" = "False" ] || _ok=1
  [ "$3" = "False" ] || _ok=1
  [ "$4" = "0" ] || _ok=1
  st_end $_ok "$([ $_ok -eq 0 ] && echo PASS || echo FAIL)" "$_LINE"
  [ $_ok -eq 0 ] || die "VM 终态不干净" "残留 $([ "$2" != "False" ] && echo '程序目录 ')$([ "$3" != "False" ] && echo '计划任务 ')$([ "$4" != "0" ] && echo '18443 仍监听')" "$TL" \
      "重跑 2c；仍不清则查 vm-remove.log 的 [WARN] 行"
fi
state_set VM_INSTALLED 0
steps_report
