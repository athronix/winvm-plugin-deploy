#!/usr/bin/env bash
# undeploy-3-ssh.sh · 拆除 SSH 免密通道（undeploy 第 3 步，需第 2 步完成）
#
# 参数：--remove-ssh-tunnel yes|no   默认 no（保留通道）
#
#   no  ：什么也不做，只打印"通道保留"，并说明下次 deploy 会直接跳过第 1 步。
#   yes ：拆。两条路，automatic 优先：
#           a) 通道在 → 把 VM 上**已经存好的** winvm-sshd-oneclick.ps1 以 SYSTEM 计划任务
#              触发 -Rollback（避免拆 sshd 时自断通道），宿主侧同步清本技能建的私钥/known_hosts
#           b) 通道不在 → 打印用户在 VM 管理员 PowerShell 里执行的那一条命令
#
# 注意：绝不为了拆通道而重建通道；绝不重启 VM。
#
# 用法：bash scripts/undeploy-3-ssh.sh [--remove-ssh-tunnel yes|no]
set -u
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]:-$0}")/_common.sh"

REMOVE="no"
while [ $# -gt 0 ]; do
  case "$1" in
    --remove-ssh-tunnel) REMOVE="${2:-no}"; shift ;;
    --remove-ssh-tunnel=*) REMOVE="${1#*=}" ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac; shift
done
case "$REMOVE" in yes|no) ;; *) echo "--remove-ssh-tunnel 只接受 yes|no（当前:$REMOVE）" >&2; exit 2 ;; esac

resolve_env; need_node
VM_SCRIPT_WIN='C:\ProgramData\WinVMDeploy\winvm-sshd-oneclick.ps1'
USER_CMD="powershell -NoProfile -ExecutionPolicy Bypass -File $VM_SCRIPT_WIN -Rollback"

# ── 保留通道（默认）──
if [ "$REMOVE" = "no" ]; then
  st_begin 3a "SSH 通道处理（--remove-ssh-tunnel no）"
  st_end 0 SKIP "通道保留（下次 deploy 第 1 步会直接判定 READY 并跳过）"
  echo "TUNNEL=KEPT"
  steps_report
  exit 0
fi

# ── 拆通道 ──
st_begin 3a "通道状态（只判不建）"
if channel_ready 6000; then CH=1; st_end 0 PASS "channel=READY → 走 SYSTEM post 动作"; else CH=0; st_end 0 SKIP "channel=DOWN → 走用户命令"; fi

HOST_STATE="${WB_TUNNEL_STATE_DIR:-$HOME/.workbuddy/.state/winvm-tunnel}/host-state.json"

# 宿主侧精确回滚：只删本技能建的钥 + 恢复 known_hosts（基线来自 deploy 第 1 步）
host_rollback() {
  st_begin 3c "宿主侧回滚（私钥 / known_hosts）"
  local created=1 existed=1
  if [ -f "$HOST_STATE" ]; then
    created="$("$NODE" -e 'try{process.stdout.write(String(require(process.argv[1]).keyCreatedBySkill))}catch{process.stdout.write("true")}' "$HOST_STATE" 2>/dev/null)"
    existed="$("$NODE" -e 'try{process.stdout.write(String(require(process.argv[1]).knownHostsEntryExistedBefore))}catch{process.stdout.write("true")}' "$HOST_STATE" 2>/dev/null)"
  fi
  if [ "$created" = "true" ] && [ -f "$WINVM_VM_KEY" ]; then
    "$NODE" -e 'const fs=require("fs");for(const s of ["","\.pub"]){try{fs.unlinkSync(process.argv[1]+s)}catch{}}' "$WINVM_VM_KEY" 2>/dev/null \
      && echo "  已删本技能生成的私钥/公钥: $WINVM_VM_KEY" || warn "私钥删除失败（保留）"
  else
    echo "  私钥非本技能创建，保留: $WINVM_VM_KEY"
  fi
  if [ "$existed" = "false" ] && [ -f "$HOME/.ssh/known_hosts" ]; then
    local tmp="$HOME/.ssh/known_hosts.wbnew.$$"
    awk -v h="$VM_HOST" 'index($0,h)==0' "$HOME/.ssh/known_hosts" > "$tmp" 2>/dev/null \
      && mv -f "$tmp" "$HOME/.ssh/known_hosts" && echo "  已清 known_hosts 中 $VM_HOST 的条目（部署前不存在）" \
      || warn "known_hosts 清理失败（保留原文件）"
  elif [ "$existed" = "true" ]; then
    echo "  known_hosts 条目部署前已存在，保留"
  fi
  st_end 0 PASS "host key state cleaned"
}

if [ "$CH" = "1" ]; then
  st_begin 3b "VM SYSTEM post 动作（用 VM 上已存的 oneclick -Rollback）"
  PL="$(sub_log tunnel-post)"
  # 脚本必须已在 VM 上（deploy 第 1 步存的）；不在就退回用户命令，绝不 scp 新模板。
  cat > "$PL.ps1" <<'PS1'
$rb = 'C:\ProgramData\WinVMDeploy\winvm-sshd-oneclick.ps1'
if (-not (Test-Path $rb)) { Write-Output 'NO_LOCAL_SCRIPT'; exit 3 }
$tr = 'powershell -NoProfile -ExecutionPolicy Bypass -File ' + $rb + ' -Rollback'
$a1 = @('/Create','/TN','WbTunnelRollback','/TR',$tr,'/SC','ONCE','/ST','00:00','/RL','HIGHEST','/RU','SYSTEM','/F')
& schtasks.exe $a1 | Out-Null
$a2 = @('/Run','/TN','WbTunnelRollback')
& schtasks.exe $a2 | Out-Null
Write-Output 'POST_ROLLBACK_SCHEDULED'
PS1
  bash "$SCRIPTDIR/ps-run.sh" "$PL.ps1" > "$PL" 2>&1; PRC=$?
  tr -d '\r' < "$PL" | tail -4
  if [ $PRC -eq 0 ] && grep -q 'POST_ROLLBACK_SCHEDULED' "$PL" 2>/dev/null; then
    st_end 0 PASS "SYSTEM 任务已触发（VM 在本会话断开后自行完成 -Rollback）"
    host_rollback
    st_begin 3d "等通道消失（判据=免密登录不再可用）"
    gone=0; i=0
    while [ $i -lt 24 ]; do
      i=$((i + 1)); sleep 5
      channel_ready 5000 || { gone=1; break; }
    done
    if [ "$gone" = "1" ]; then st_end 0 PASS "通道已不可用（${i}0s 内）"; TUNNEL=REMOVED
    else st_end 0 SKIP "通道仍可用（SYSTEM 任务可能排队中）"; TUNNEL=SCHEDULED; fi
    echo "TUNNEL=$TUNNEL"
    state_set CHANNEL_READY 0
    steps_report
    exit 0
  fi
  st_end $PRC SKIP "post 动作未成功（转用户命令）"
  grep -q 'NO_LOCAL_SCRIPT' "$PL" 2>/dev/null && echo "  VM 上没有 $VM_SCRIPT_WIN（可能被清理过）"
fi

# 通道不在 / post 失败 → 给用户那一条命令
st_begin 3b "输出用户命令（通道不可用时唯一安全路径）"
cat <<EOF

════════════════════ 卸载通道：在 VM 管理员 PowerShell 里执行这一条 ════════════════════
$USER_CMD
══════════════════════════════════════════════════════════════════════════════════════
（该脚本是 deploy 第 1 步下载并留在 VM 上的；它按 journal 逆序精确还原，可重复执行）
EOF
host_rollback
st_end 0 WAIT_USER "TUNNEL_REMOVE_PENDING_USER"
echo "TUNNEL=PENDING_USER"
echo "NEED_USER_ACTION=1"
state_set CHANNEL_READY 0
steps_report
exit 2
