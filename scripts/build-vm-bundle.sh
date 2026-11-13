#!/usr/bin/env bash
# winvm-plugin-deploy · v1.5.0 · build the MERGED VM-side bundle for the
# "SSH channel already down" uninstall path (user ruling 2026-11-13).
#
# undeploy = 3 parts: HOST removal + VM removal + SSH-tunnel removal.
# When the channel is down, WorkBuddy does the HOST part locally and hands the
# user ONE directory containing the other two parts merged:
#   vm-remove-local.ps1   - removes WinVMBridge on the VM
#   wb-rollback.ps1       - built-in winvm-setup-sshd-and-key.ps1 (-Rollback)
#   RUN-ME.ps1            - one entry point; the tunnel rollback is registered
#                           as a VM-side SYSTEM post action (survives ssh loss)
# Nothing here rebuilds a channel. No VM reboot. No key guessing.
set -u
_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# v1.6.0: the tunnel lifecycle is INTERNAL (hos-winvm-ssh-tunnel v2.3.0
# merged into this skill). HOS_TUNNEL_SKILL stays a backward-compatible
# override pointing at a standalone skill root; default = THIS skill root,
# so every "$HOS/scripts/..." resolves to our own scripts/ directory.
HOS="${HOS_TUNNEL_SKILL:-$(dirname "$_here")}"
TS="$(date +%Y%m%d-%H%M%S)"
D="${VMDEPLOY_RUN_DIR:-$HOME/wbtmp}/vm-remove-bundle-$TS"
mkdir -p "$D" || { echo "MKDIR_FAILED $D" >&2; exit 1; }
cp -f "$_here/vm-remove-local.ps1" "$D/vm-remove-local.ps1" || { echo "COPY_LOCAL_PS1_FAILED" >&2; exit 1; }

HAS_RB=0
if [ -f "$HOS/scripts/winvm-setup-sshd-and-key.ps1" ]; then
  cp -f "$HOS/scripts/winvm-setup-sshd-and-key.ps1" "$D/wb-rollback.ps1" && HAS_RB=1
fi

cat > "$D/RUN-ME.ps1" <<'PS1'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Output '=== WinVM VM-side removal (HOST side already removed by WorkBuddy) ==='
& (Join-Path $here 'vm-remove-local.ps1') -Apply -ScheduleTunnelRollback
Write-Output '=== VM removal done. Tunnel rollback runs as SYSTEM task WbTunnelRollback ==='
Write-Output '=== Verify later: schtasks /Query /TN WbTunnelRollback /V /FO LIST ==='
PS1

if [ "$HAS_RB" = "1" ]; then
  RB_LINE='3. 通道回滚由 VM 自己以 SYSTEM 计划任务 WbTunnelRollback 执行（-Rollback），会在会话断开后继续跑完；成功判据=免密登录不再可用（不是 22 端口关了）。'
else
  RB_LINE='3. ⚠ 本技能包内缺少内置回滚模板 winvm-setup-sshd-and-key.ps1，故跳过 SSH 通道回滚；请重新取 winvm-plugin-deploy v1.6.0+ 技能包（通道能力已内置，无需另装 skill），把 scripts/winvm-setup-sshd-and-key.ps1 复制为本目录 wb-rollback.ps1 再重跑 RUN-ME.ps1。'
fi

cat > "$D/PASTE-THIS.txt" <<TXT
WinVM 卸载 · VM 侧合并包（SSH 通道已不在，无需重建）
=====================================================
宿主（鸿蒙 WorkBuddy）侧已由 WorkBuddy 本地卸载完毕。剩下 VM 侧两件事合并到本目录，一次执行即可：
  1) 卸载 VM 端 WinVMBridge（计划任务 / 进程 / C:\\WinVMBridge / junction / PATH / side.json；默认保留 C:\\WinVMWorkspace）
  2) 卸载 SSH 免密通道（内置 winvm-setup-sshd-and-key.ps1 -Rollback，按 journal 精确还原，他人密钥无损）

执行（在 VM 上，管理员 PowerShell）：
  cd <本目录拷贝到的路径>
  powershell -NoProfile -ExecutionPolicy Bypass -File .\\RUN-ME.ps1

如需连工作区一起删（破坏性，先确认）：把 RUN-ME.ps1 里的调用改为
  -Apply -PurgeWorkspace -ScheduleTunnelRollback

$RB_LINE

注意：
  · 不要重启 VM；不要手工删 sshd / 别人的公钥。
  · 宿主私钥已由 WorkBuddy 侧的内置 host-rollback.sh 精确撤销（只撤本技能创建的那份），与本包执行顺序无关。
  · 判据：VM_CLEANUP_DONE + POST STATUS 里 BRIDGE_DIR=False / TASK_EXISTS=False / PORT_LISTEN=False / BRIDGE_NODE_LEFT=False，
    且 SSHD 状态不加区分（构建前就装了 sshd 的机器应仍为 Running）。
TXT

echo "VM_BUNDLE=$D"
echo "NEED_USER_ACTION=1 HAS_TUNNEL_ROLLBACK=$HAS_RB"
echo "FILES: $(ls -1 "$D" | tr '\n' ' ')"
echo "---- tell the user: copy '$D' to the VM and run RUN-ME.ps1 as Administrator ----"
