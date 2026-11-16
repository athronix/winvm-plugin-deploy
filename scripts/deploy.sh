#!/usr/bin/env bash
# deploy.sh · 从零部署 WinVM Bridge（一个命令，5 步，无可选分支）
#
#   1 建 host↔VM 免密 SSH 通道      ─┐ 并行
#   2 取包 + 装 host 端插件          ─┘
#   3 起 winvm-tunnel service 并验证 ─┐ 并行（需 1+2）
#   4 装 VM 端 + 起 mcp/a2a service  ─┘
#   5 verify（三探针 + 终态矩阵）
#
# 用法：
#   VM_HOST=172.16.100.2 bash scripts/deploy.sh                 # 全链
#   VM_HOST=... bash scripts/deploy.sh --only 3                 # 只跑某一步（定点重跑）
#   VM_HOST=... bash scripts/deploy.sh --from 3                 # 从第 3 步起
#   VM_HOST=... bash scripts/deploy.sh --serial                 # 关并行（排障用）
#   VM_HOST=... RELEASE_TAG=V1.4.30 bash scripts/deploy.sh      # 锁版本
#
# 首次运行会在第 1 步打印一条「用户只需要做这一件事」的命令并退出（rc=2）。
# 用户在 VM 粘贴执行后，**重跑同一条命令**即可；已完成的步骤幂等跳过。
set -u
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]:-$0}")/_common.sh"

ONLY=""; FROM=1; SERIAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="$2"; shift ;;
    --from) FROM="$2"; shift ;;
    --serial) SERIAL=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac; shift
done
[ -n "$ONLY" ] && FROM="$ONLY"

resolve_env; need_node; need_py; need_bash
require_host
state_set VM_HOST "$VM_HOST"; state_set VM_USER "$VM_USER"; state_set VM_SSH_PORT "$VM_SSH_PORT"

echo "════════════════════════════════════════════════════════════"
echo " WinVM Bridge 部署  host=$VM_HOST user=$VM_USER port=$VM_SSH_PORT"
echo " 运行目录: $VMDEPLOY_RUN_DIR"
echo " 并行: $([ "$SERIAL" = "1" ] && echo off || echo on)   起点: 第 $FROM 步$([ -n "$ONLY" ] && echo "（只跑第 $ONLY 步）")"
echo "════════════════════════════════════════════════════════════"

run_step() { # run_step <n> → 返回该步 rc
  local n="$1" s
  case "$n" in
    1) s="deploy-1-ssh.sh" ;;
    2) s="deploy-2-host.sh" ;;
    3) s="deploy-3-tunnel.sh" ;;
    4) s="deploy-4-vm.sh" ;;
    5) s="deploy-5-verify.sh" ;;
    *) echo "无此步骤: $n" >&2; return 2 ;;
  esac
  bash "$SCRIPTDIR/$s"
}

stage() { # stage <name> <n1> [n2]
  local name="$1" a="$2" b="${3:-}"
  echo
  log "━━━ 阶段 $name ━━━"
  if [ -z "$b" ] || [ "$SERIAL" = "1" ]; then
    run_step "$a"; return $?
  fi
  run_step "$a" & local p1=$!
  run_step "$b" & local p2=$!
  wait $p1; local r1=$?
  wait $p2; local r2=$?
  [ $r1 -ne 0 ] && return $r1
  return $r2
}

RC=0
if [ -n "$ONLY" ]; then
  run_step "$ONLY"; RC=$?
else
  if [ "$FROM" -le 2 ]; then
    if [ "$FROM" -le 1 ]; then stage "A（第 1‖2 步）" 1 2; else stage "A（第 2 步）" 2; fi
    RC=$?
    if [ $RC -eq 2 ]; then
      echo
      echo "════════════════════════════════════════════════════════════"
      echo " ⏸  需要你在 VM 里做一件事（上面第 1 步已打印那条命令）"
      echo "    · VM 恢复/重建后 authorized_keys 会丢，通道必须重建"
      echo "    · 做完后【重跑同一条命令】即可，已完成的步骤不会重复做"
      echo "════════════════════════════════════════════════════════════"
      steps_report
      exit 2
    fi
    [ $RC -ne 0 ] && { err "阶段 A 失败（rc=$RC）"; steps_report; exit $RC; }
  fi
  if [ "$FROM" -le 4 ]; then
    if [ "$FROM" -le 3 ]; then stage "B（第 3‖4 步）" 3 4; else stage "B（第 4 步）" 4; fi
    RC=$?
    [ $RC -ne 0 ] && { err "阶段 B 失败（rc=$RC）"; steps_report; exit $RC; }
  fi
  if [ "$FROM" -le 5 ]; then
    stage "C（第 5 步 verify）" 5
    RC=$?
  fi
fi

# ── 收尾：只有全链零失败才把探针 stamp 升为可复用 ──
STAMP="${VMDEPLOY_PROBE_STAMP:-$HOME/wbtmp/winvm-probes-stamp.txt}"
if [ $RC -eq 0 ] && [ -f "$STAMP" ]; then
  "$NODE" -e 'const fs=require("fs"),p=process.argv[1];let s=fs.readFileSync(p,"utf8");s=s.replace(/^deploy_ok=.*$/m,"deploy_ok=1");if(!/^deploy_ok=/m.test(s))s+="deploy_ok=1\n";fs.writeFileSync(p,s)' "$STAMP" 2>/dev/null || true
fi
steps_report
echo
if [ $RC -eq 0 ]; then
  echo "DEPLOY=PASS  (host: 插件+连接器+skills · tunnel: health=200 · VM: mcp+a2a · verify: 通过)"
  echo "ALL_DONE=1  RUN_DIR=$VMDEPLOY_RUN_DIR"
else
  echo "DEPLOY=FAIL rc=$RC  失败段日志见 $LOGD"
fi
exit $RC
