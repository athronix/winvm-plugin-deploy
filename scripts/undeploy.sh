#!/usr/bin/env bash
# undeploy.sh · 卸载 WinVM Bridge（3 步，单命令）
#
#   1 停 winvm-tunnel service + 卸 host 端插件   ─┐ 并行（互不依赖）
#   2 停 VM 端 service + 卸 VM 端模块            ─┘
#   3 拆 SSH 通道（--remove-ssh-tunnel yes|no，默认 no）← 需第 2 步完成
#
# 用法：
#   VM_HOST=172.16.100.2 bash scripts/undeploy.sh                        # 默认保留通道
#   VM_HOST=... bash scripts/undeploy.sh --remove-ssh-tunnel yes         # 连通道一起拆
#   VM_HOST=... bash scripts/undeploy.sh --purge-workspace               # 连 C:\WinVMWorkspace 一起删
#   VM_HOST=... bash scripts/undeploy.sh --dry-run                       # 只打印计划
#   VM_HOST=... bash scripts/undeploy.sh --only 2                        # 定点重跑
#
# 通道不在是卸载的正常输入，本脚本绝不重建通道、绝不重启 VM。
set -u
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]:-$0}")/_common.sh"

RM_TUNNEL="no"; PURGE=0; DRY=0; ONLY=""; SERIAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --remove-ssh-tunnel) RM_TUNNEL="${2:-no}"; shift ;;
    --remove-ssh-tunnel=*) RM_TUNNEL="${1#*=}" ;;
    --purge-workspace) PURGE=1 ;;
    --dry-run) DRY=1 ;;
    --only) ONLY="$2"; shift ;;
    --serial) SERIAL=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac; shift
done
case "$RM_TUNNEL" in yes|no) ;; *) echo "--remove-ssh-tunnel 只接受 yes|no" >&2; exit 2 ;; esac

resolve_env; need_node; require_host

echo "════════════════════════════════════════════════════════════"
echo " WinVM Bridge 卸载  host=$VM_HOST user=$VM_USER"
echo " 1 host 端（停隧道+卸插件） ‖ 2 VM 端（停服务+卸模块） → 3 SSH 通道（$RM_TUNNEL）"
echo " purge_workspace=$PURGE  运行目录: $VMDEPLOY_RUN_DIR"
echo "════════════════════════════════════════════════════════════"

if [ "$DRY" = "1" ]; then
  echo "DRY-RUN：不加 --dry-run 即执行。预计 3 段："
  echo "  1a tunnel stop  1b uninstall.mjs --apply(host-only)  1c host 复核"
  echo "  2a 通道判定    2b scp 卸载脚本  2c schtasks+删目录  2d VM 五点"
  echo "  3  --remove-ssh-tunnel=$RM_TUNNEL $([ "$RM_TUNNEL" = "yes" ] && echo '(SYSTEM post 动作或用户命令)')"
  echo "CHANNEL_UP=$(channel_ready 5000 && echo 1 || echo 0)  REBUILD=NO"
  exit 0
fi

run_step() {
  case "$1" in
    1) bash "$SCRIPTDIR/undeploy-1-host.sh" ;;
    2) bash "$SCRIPTDIR/undeploy-2-vm.sh" $([ "$PURGE" = "1" ] && echo --purge-workspace) ;;
    3) bash "$SCRIPTDIR/undeploy-3-ssh.sh" --remove-ssh-tunnel "$RM_TUNNEL" ;;
    *) echo "无此步骤: $1" >&2; return 2 ;;
  esac
}

RC=0; PENDING=0
export VMDEPLOY_STEPS_QUIET=1   # 子脚本不再各打一遍计时表
if [ -n "$ONLY" ]; then
  log "━━━ 只跑第 $ONLY 步 ━━━"
  run_step "$ONLY"; RC=$?
  [ $RC -eq 2 ] && PENDING=1
else
  log "━━━ 阶段 A（第 1‖2 步）━━━"
  if [ "$SERIAL" = "1" ]; then
    run_step 1; R1=$?
    run_step 2; R2=$?
  else
    run_step 1 & P1=$!
    run_step 2 & P2=$!
    wait $P1; R1=$?
    wait $P2; R2=$?
  fi
  [ $R1 -eq 2 ] && PENDING=1
  [ $R2 -eq 2 ] && PENDING=1
  [ $R1 -ne 0 ] && [ $R1 -ne 2 ] && { RC=$R1; }
  [ $R2 -ne 0 ] && [ $R2 -ne 2 ] && { RC=$R2; }
  [ $RC -eq 0 ] && {
    log "━━━ 阶段 B（第 3 步）━━━"
    run_step 3; RC=$?
    [ $RC -eq 2 ] && { PENDING=1; RC=0; }
  }
fi

VMDEPLOY_STEPS_QUIET=0 steps_report
echo
if [ $RC -ne 0 ]; then
  echo "UNDEPLOY=FAIL rc=$RC  日志 $LOGD"
elif [ $PENDING -eq 1 ]; then
  echo "UNDEPLOY=PENDING_USER（有需要用户在 VM 里执行的动作，见上面的命令块）"
else
  echo "UNDEPLOY=PASS  host=clean vm=clean tunnel=$RM_TUNNEL"
fi
echo "ALL_DONE=1 RUN_DIR=$VMDEPLOY_RUN_DIR"
exit $RC
