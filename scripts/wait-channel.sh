#!/usr/bin/env bash
# winvm-plugin-deploy · 通道判稳器 v1.5.0（run13 沉淀 + F-09 修复）
# 用法：VM_HOST=<ip> [VM_USER=User] [VM_SSH_PORT=22] bash wait-channel.sh [连击数=3] [轮数=10]
# 语义：每发【新建连接】实测（vm-conn.sh 的 vmssh / ssh2 快路径，复用三级密钥链），
#       需【连续】N 次成功才判稳退出 0；轮间 sleep 75s（自毒纪律：密集重试让 VM 侧
#       半开 auth 槽不释放，稀疏反通）。
# v1.5.0 F-09（审计实锤）：旧版裸 `ssh -o BatchMode=yes` 完全绕过 vm-conn.sh——
#   既不带 -i $WINVM_VM_KEY / IdentitiesOnly，也不认 VM_SSH_BACKEND=ssh2；
#   路 B 专用钥场景必然 UNSTABLE，鸿蒙沙箱 OpenSSH 认证段相位挂时更被误判成
#   「通道不存在」。现统一：export VM_SSH_BACKEND=ssh2 + source vm-conn.sh + vmssh whoami。
# 预算：单轮最坏 ~70s（vmssh 自带 timeout + 三试）+75s；外层 timeout 必须 ≥ rounds×145
#   （如 2 连击×4 轮 → 给 ≥580s；给 400s 会在第 3 轮前误杀成「判稳失败」假象）。
# 重启后纪律：Windows 冷启+sshd+域解析实测 ~5-8min 才通，首轮 poll 前先 sleep ≥240s。
set -u
_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${VMDEPLOY_ENV_SH:=${HOME}/wbtmp/vmdeploy-env.sh}"; [ -f "$VMDEPLOY_ENV_SH" ] && . "$VMDEPLOY_ENV_SH"
export VM_SSH_BACKEND="${VM_SSH_BACKEND:-ssh2}"     # F-02/F-09：vm-conn.sh 在 source 时读它
# shellcheck disable=SC1090
. "$_here/vm-conn.sh"
: "${VM_HOST:?VM_HOST 未设}"
: "${VM_USER:=User}"; : "${VM_SSH_PORT:=22}"
export VM_HOST VM_USER VM_SSH_PORT WINVM_VM_KEY VM_CHANNEL VM_SSH_BACKEND
# 先定 VM_CHANNEL（key 后端兜底路径需要它）；ssh2 快路径本就是单发 ping 新建连接。
vm_channel_probe >/dev/null 2>&1 || true
NEED="${1:-3}"; ROUNDS="${2:-10}"; ok=0
for r in $(seq 1 "$ROUNDS"); do
  # vmssh 每次都是新建连接（ssh2-conn.mjs exec / ssh 二进制），符合口径
  # 「窗口判定必用新建连接实测，长连健康 != 新建可用」。
  if vmssh whoami >/dev/null 2>&1; then
    ok=$((ok+1)); echo "[$(date +%H:%M:%S)] poll$r OK consec=$ok/$NEED backend=$VM_SSH_BACKEND"
    [ "$ok" -ge "$NEED" ] && { echo "CHANNEL_STABLE"; exit 0; }
  else
    [ "$ok" -ne 0 ] && echo "[$(date +%H:%M:%S)] poll$r FAIL 连击清零"
    ok=0; echo "[$(date +%H:%M:%S)] poll$r DOWN/挂起（新建连接实测 key=$WINVM_VM_KEY backend=$VM_SSH_BACKEND）"
  fi
  [ "$r" -lt "$ROUNDS" ] && sleep 75
done
echo "CHANNEL_UNSTABLE：轮询 ${ROUNDS} 轮未达 ${NEED} 连击（新建连接实测口径）。"
echo "  权威复核：bash scripts/channel.sh confirm（ssh2 ping 单发；二进制/连击判稳失败 != 通道不存在）。"
echo "  复核也失败 = 环境瞬态窗：等健康窗再续跑；【绝不自启 VM / guest 重启】。"
echo "  若宿主 http://127.0.0.1:18443/health 仍 200（MCP 隧道健在）→ 见 SKILL.md『通道自救路径』。"
exit 1
