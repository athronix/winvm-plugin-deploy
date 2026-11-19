#!/usr/bin/env bash
# undeploy-2-vm.sh · 停 VM 端 winvm service + 卸 VM 端模块（undeploy 第 2 步，与第 1 步并行）
#
# 只经现役 ssh 通道；通道不在 = 正常输入，**绝不为此重建通道**。
# 通道不在时本步如实报 SKIP 并给出用户手工命令（第 3 步会把两份命令合并展示）。
#
# 用法：bash scripts/undeploy-2-vm.sh [--purge-workspace] [--keep-upstreams]
#                                    [--purge-all] [--keep-winvmdeploy]
#
#   --purge-all        追加 2e 运行时深清：node 运行时（C:\nodejs + nvm）、codebuddy、
#                      VM 侧 ~/.ssh 私钥、npm 缓存、死 PATH、残留任务与防火墙。
#                      不碰 sshd（停 sshd 会杀掉执行它的会话 ⇒ 归第 3 步 SYSTEM 任务）。
#   --keep-winvmdeploy 2e 时保留 C:\ProgramData\WinVMDeploy（第 3 步 3b 还要用里面
#                      的 oneclick 脚本做 -Rollback 与 MSI 缓存；由 3b 最后删掉）。
set -u
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]:-$0}")/_common.sh"

PURGE=0; KEEP_UP=0; PURGE_ALL=0; KEEP_WD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --purge-workspace) PURGE=1 ;;
    --keep-upstreams) KEEP_UP=1 ;;
    --purge-all) PURGE_ALL=1 ;;
    --keep-winvmdeploy) KEEP_WD=1 ;;
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
# --purge-all 时多推一个 vm-purge-runtime.ps1（node/codebuddy/keys/npm-cache 深清），
# 它必须在本步跑完——通道一断就没入口了，所以绝不能留到第 3 步之后。
PUSH_LIST="vm-remove-local.ps1"
[ "$PURGE_ALL" = "1" ] && PUSH_LIST="$PUSH_LIST vm-purge-runtime.ps1"
SRC=0
for _f in $PUSH_LIST; do
  ( set +u; . "$SCRIPTDIR/vm-conn.sh"; \
    vmscp "$SCRIPTDIR/$_f" "${VM_USER}@${VM_HOST}:$_f" ) \
    >> "$(sub_log vmscp)" 2>&1 || SRC=$?
  [ $SRC -ne 0 ] && break
done
if [ $SRC -ne 0 ]; then
  tail -5 "$(sub_log vmscp)"
  st_end $SRC FAIL "scp rc=$SRC"
  echo "VM_SIDE_PENDING=1"
  die "推卸载脚本失败" "通道瞬态窗或权限" "$(sub_log vmscp)" \
      "稍后重跑本步；不要为此重建通道"
fi
st_end 0 PASS "$PUSH_LIST 已就位"

st_begin 2c "停服务 + 卸模块（vm-remove-local.ps1 -Apply）"
PARGS="-Apply"; [ "$PURGE" = "1" ] && PARGS="$PARGS -PurgeWorkspace"
[ "$KEEP_UP" = "1" ] && PARGS="$PARGS -KeepUpstreams"
RAL="$(sub_log vm-remove)"
bash "$SCRIPTDIR/ps-run.sh" -c "& .\\vm-remove-local.ps1 $PARGS" > "$RAL" 2>&1; VRC=$?
grep -E 'MODE=|VM_CLEANUP_DONE|BRIDGE_DIR=|TASK_EXISTS=|PORT_LISTEN=|BRIDGE_NODE_LEFT=|UPSTREAM_LEFT=|\[WARN\]' "$RAL" | tail -14 || true
if [ $VRC -ne 0 ] || ! grep -q 'VM_CLEANUP_DONE' "$RAL" 2>/dev/null; then
  tail -12 "$RAL"
  st_end $VRC FAIL "rc=$VRC 且无 VM_CLEANUP_DONE"
  die "VM 端卸载未完成" "服务停不掉 / 文件占用 / 通道瞬态" "$RAL" \
      "看 $RAL；确认 C:\\WinVMBridge 已删、计划任务已删、18443 不再监听"
fi
# 上游 CLI 默认随插件一起卸（install-vm 4b 装的是本项目组件）；-KeepUpstreams 显式保留。
UP_LEFT="$(tr -d '\r' < "$RAL" | grep -oE 'UPSTREAM_LEFT=[^[:space:]]*' | tail -1 | cut -d= -f2)"
if [ "$KEEP_UP" = "1" ]; then
  st_end 0 PASS "$(grep -E 'VM_CLEANUP_DONE|TASK_EXISTS=' "$RAL" | tr '\n' ' ' | cut -c1-120) 上游保留"
elif [ "${UP_LEFT:-NONE}" != "NONE" ]; then
  st_end 1 FAIL "上游 CLI 仍残留: ${UP_LEFT:-unknown}"
  die "上游 MCP CLI 未卸干净" "npm uninstall -g 失败或 npm 不在 PATH" "$RAL" \
      "看 $RAL 的 [WARN] 行；或手工 npm uninstall -g ${UP_LEFT//,/ }（不需要则加 --keep-upstreams）"
else
  st_end 0 PASS "$(grep -E 'VM_CLEANUP_DONE|TASK_EXISTS=|UPSTREAM_LEFT=' "$RAL" | tr '\n' ' ' | cut -c1-140)"
fi

st_begin 2d "VM 终态五点（+上游）"
TL="$(sub_log vm-terminal)"
bash "$SCRIPTDIR/ps-run.sh" -c '$env:Path=[Environment]::GetEnvironmentVariable("Path","Machine")+";"+[Environment]::GetEnvironmentVariable("Path","User"); $a=Test-Path C:\WinVMBridge; $null=(schtasks /query /tn WinVMBridge.Service 2>$null); $b=($LASTEXITCODE -eq 0); $c=@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -eq 18443 }).Count; $s=(Get-Service sshd).Status; $e=Test-Path C:\WinVMWorkspace; $u=@(); foreach($p in @("agent-browser","agent-desktop")){ if(Get-Command $p -ErrorAction SilentlyContinue){ $u+=$p } }; $ut=if($u.Count -eq 0){"NONE"}else{$u -join ","}; Write-Output ("expect False False 0 * True NONE => " + $a + " " + $b + " " + $c + " " + $s + " " + $e + " " + $ut)' \
  > "$TL" 2>&1; TRC=$?
tr -d '\r' < "$TL" | tail -3
_LINE="$(tr -d '\r' < "$TL" | grep -oE '=> .*' | tail -1)"
if [ $TRC -ne 0 ] || [ -z "$_LINE" ]; then
  st_end 0 SKIP "VM 终态行取不到（环境瞬态窗，不算功能失败）"
  echo "VM_TERMINAL=PENDING"
else
  set -- $_LINE
  # $1='=>' $2=bridge $3=task $4=listen $5=sshd $6=ws $7=upstream
  _ok=0
  [ "$2" = "False" ] || _ok=1
  [ "$3" = "False" ] || _ok=1
  [ "$4" = "0" ] || _ok=1
  [ "${7:-NONE}" = "NONE" ] || [ "$KEEP_UP" = "1" ] || _ok=1
  st_end $_ok "$([ $_ok -eq 0 ] && echo PASS || echo FAIL)" "$_LINE"
  [ $_ok -eq 0 ] || die "VM 终态不干净" "残留 $([ "$2" != "False" ] && echo '程序目录 ')$([ "$3" != "False" ] && echo '计划任务 ')$([ "$4" != "0" ] && echo '18443 仍监听 ')$([ "${7:-NONE}" != "NONE" ] && [ "$KEEP_UP" != "1" ] && echo "上游CLI(${7:-})")" "$TL" \
      "重跑 2c；仍不清则查 vm-remove.log 的 [WARN] 行"
fi
state_set VM_INSTALLED 0

# ── 2e 运行时深清（仅 --purge-all）──
# 补 vm-remove-local.ps1 刻意不碰的部分：node 运行时、codebuddy、VM 侧私钥、
# npm 缓存、死 PATH、残留任务/防火墙。sshd 不在这里（vm-purge-sshd.ps1，由第 3 步
# 的 SYSTEM 任务延迟执行——停 sshd 会杀掉正在跑它的会话）。
if [ "$PURGE_ALL" = "1" ]; then
  st_begin 2e "运行时深清（node / codebuddy / VM 私钥 / npm 缓存）"
  PRL="$(sub_log vm-purge-runtime)"
  KWD_ARG=""; [ "$KEEP_WD" = "1" ] && KWD_ARG=" -KeepWinVMDeploy"
  bash "$SCRIPTDIR/ps-run.sh" -c "& .\\vm-purge-runtime.ps1 -Apply$KWD_ARG" > "$PRL" 2>&1; PRC=$?
  grep -E 'MODE=|SEC_DELETE_|LEFT_DELETE_|CMD_|SSH_FILES_AFTER|KEPT_WINVMDEPLOY|PURGE_RUNTIME_DONE|\[WARN\]' "$PRL" | tail -22 || true
  if [ $PRC -ne 0 ] || ! grep -q 'PURGE_RUNTIME_DONE' "$PRL" 2>/dev/null; then
    tail -12 "$PRL"
    st_end $PRC FAIL "rc=$PRC 且无 PURGE_RUNTIME_DONE"
    die "运行时深清未完成" "文件占用（node 仍在跑）/ 权限 / 通道瞬态" "$PRL" \
        "看 $PRL；确认 node 进程已退出后重跑 --only 2 --purge-all"
  fi
  # 可证伪终态：五个 CLI 必须全部消失，两个运行时目录必须不存在
  _bad=""
  for _k in CMD_NODE CMD_NPM CMD_CODEBUDDY CMD_AGENT_BROWSER CMD_AGENT_DESKTOP; do
    grep -q "^${_k}=MISSING" "$PRL" 2>/dev/null || _bad="$_bad ${_k}#$(tr -d '\r' < "$PRL" | grep -oE "^${_k}=.*" | tail -1 | cut -d= -f2)"
  done
  grep -q '^NODEJS_DIR=False' "$PRL" 2>/dev/null || _bad="$_bad NODEJS_DIR"
  grep -q '^NVM_DIR=False' "$PRL" 2>/dev/null || _bad="$_bad NVM_DIR"
  # 三处运行时都算：C:\nodejs、nvm 根、%LOCALAPPDATA%\nodejs（zip 装的用户级副本）。
  # 2026-11-18 真机只清前两处 ⇒ 后两处残留，Get-Command node/npm 仍能解析。
  grep -q '^LOCAL_NODEJS_DIR=False' "$PRL" 2>/dev/null || _bad="$_bad LOCAL_NODEJS_DIR"
  [ "$KEEP_WD" = "1" ] || grep -q '^WINVMDEPLOY_DIR=False' "$PRL" 2>/dev/null || _bad="$_bad WINVMDEPLOY_DIR"
  if [ -n "$_bad" ]; then
    st_end 1 FAIL "深清后仍残留:$_bad"
    die "运行时深清不彻底" "仍残留:$_bad" "$PRL" \
        "看 $PRL 的 [WARN] 行；占用类残留先结束进程再重跑"
  fi
  st_end 0 PASS "$(tr -d '\r' < "$PRL" | grep -E '^SEC_DELETE_(NODEJS|NVM|LOCAL_NODEJS)=' | tr '\n' ' ' | cut -c1-110)五个 CLI 全 MISSING"
fi

steps_report
