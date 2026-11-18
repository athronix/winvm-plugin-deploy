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

# v2.4.0（用户 2026-11-18 裁定）：原 3c「宿主侧私钥/known_hosts 回滚」已删除。
# 理由：① 私钥是可复用资产，删掉会让下次部署重新备钥（多一轮 1b）；
#       ② 该步只在 no-baseline 时才"保守保留"，价值密度低，却占一个环节；
#       ③ 真正的安全边界是「只删自己建的东西」，由 deploy 第 1 步的 host-state.json
#          基线保证——不再主动删，就不存在误删风险。
# 需要手工清私钥时：node -e 'fs.unlinkSync("<KEY>")'（宿主禁 rm）。

if [ "$CH" = "1" ]; then
  st_begin 3b "VM SYSTEM post 动作（用 VM 上已存的 oneclick -Rollback）"
  PL="$(sub_log tunnel-post)"
  # 首选 VM 上已存的那份（deploy 第 1 步留下的）；缺失时**就地下载**再跑，
  # 因为「让用户手敲一条指向不存在文件的命令」是死路（实测踩到）。
  # 绝不 scp 新模板、绝不为拆通道而重建通道。
  # 多源：VM 出口网络与宿主不同，单源 404 会让「拆通道」直接死路，故内联候选数组逐个试。
  SRCS_PS=""
  URL_FOR_VM="$(sshd_script_url || true)"
  if [ -n "$URL_FOR_VM" ] && url_reachable "$URL_FOR_VM"; then
    SRCS_PS="$(sshd_script_srcs_ps 4)"
    echo "  兜底下载源（首个可达）: $URL_FOR_VM（共 $(printf '%s' "$SRCS_PS" | tr ',' '\n' | awk '{n++} END{print n+0}') 个候选）"
  else
    echo "  [WARN] 远端脚本地址不可达，缺文件时将只能给用户手工命令"
  fi
  cat > "$PL.ps1" <<'PS1'
$rb  = 'C:\ProgramData\WinVMDeploy\winvm-sshd-oneclick.ps1'
$src = @(__SRCS__)
if (-not (Test-Path $rb)) {
  if ($src.Count -eq 0) { Write-Output 'NO_LOCAL_SCRIPT_NO_URL'; exit 3 }
  $ok = $false
  foreach ($u in $src) {
    try {
      New-Item -ItemType Directory -Force -Path (Split-Path $rb) | Out-Null
      Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $rb -TimeoutSec 45
      Unblock-File $rb; $ok = $true; break
    } catch { Write-Output ('src-fail: ' + $u) }
  }
  if (-not $ok) { Write-Output 'DOWNLOAD_FAILED: all sources'; exit 4 }
  Write-Output 'DOWNLOADED'
}
$tr = 'powershell -NoProfile -ExecutionPolicy Bypass -File ' + $rb + ' -Rollback'
$a1 = @('/Create','/TN','WbTunnelRollback','/TR',$tr,'/SC','ONCE','/ST','00:00','/RL','HIGHEST','/RU','SYSTEM','/F')
& schtasks.exe $a1 | Out-Null
$a2 = @('/Run','/TN','WbTunnelRollback')
& schtasks.exe $a2 | Out-Null
Write-Output 'POST_ROLLBACK_SCHEDULED'
PS1
  # 占位替换注入 URL（比 unquoted heredoc 转义 PS 变量安全）
  "$NODE" -e 'const fs=require("fs");const p=process.argv[1];fs.writeFileSync(p,fs.readFileSync(p,"utf8").replace("__SRCS__",process.argv[2]))' "$PL.ps1" "${SRCS_PS:-}"
  bash "$SCRIPTDIR/ps-run.sh" "$PL.ps1" > "$PL" 2>&1; PRC=$?
  tr -d '\r' < "$PL" | tail -4
  if [ $PRC -eq 0 ] && grep -q 'POST_ROLLBACK_SCHEDULED' "$PL" 2>/dev/null; then
    st_end 0 PASS "SYSTEM 任务已触发（VM 在本会话断开后自行完成 -Rollback）"
    # v2.4.0：原 3d「等通道消失」已删。理由：拆通道是 SYSTEM 任务的异步结果，
    # 宿主空等 6~27s 只影响"本次是否打印 REMOVED"，不改变任何终态；
    # 真需要确认时重跑 deploy 第 1 步（1a 会实测），比在这里轮询更准。
    TUNNEL=SCHEDULED
    echo "TUNNEL=SCHEDULED（异步；如需确认，重跑 deploy 第 1 步看 1a 判据）"
    state_set CHANNEL_READY 0
    steps_report
    exit 0
  fi
  st_end $PRC SKIP "post 动作未成功（转用户命令）"
  grep -q 'DOWNLOAD_FAILED' "$PL" 2>/dev/null && echo "  VM 侧下载失败：$(tr -d '\r' < "$PL" | grep DOWNLOAD_FAILED | head -1)"
  grep -q 'NO_LOCAL_SCRIPT_NO_URL' "$PL" 2>/dev/null && echo "  VM 上无 $VM_SCRIPT_WIN 且远端地址不可达"
fi

# 通道不在 / post 失败 → 给用户那一条命令
st_begin 3b "输出用户命令（通道不可用时唯一安全路径）"
cat <<EOF

════════════════════ 卸载通道：在 VM 管理员 PowerShell 里执行这一条 ════════════════════
$USER_CMD
══════════════════════════════════════════════════════════════════════════════════════
（该脚本是 deploy 第 1 步下载并留在 VM 上的；它按 journal 逆序精确还原，可重复执行）
EOF
st_end 0 WAIT_USER "TUNNEL_REMOVE_PENDING_USER"
echo "TUNNEL=PENDING_USER"
echo "NEED_USER_ACTION=1"
state_set CHANNEL_READY 0
steps_report
exit 2
