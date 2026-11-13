#!/bin/sh
# destroy-tunnel.sh —— 「destroy」：销毁整条免密通道，精确还原到"本次构建之前"的状态
#
# 顺序（很重要）：先撤 VM 侧（通道一断就再也进不去），再撤宿主机侧。
#   VM 侧  ：删本通道公钥行 → 还原 sshd_config（.wb-orig）→ 还原网络配置档 → 还原本通道改过的
#            防火墙规则 → 卸载"本次安装的" OpenSSH（构建前已存在则保留）→ 残留自检
#   宿主机 ：删除本 skill 创建的密钥 / known_hosts 记录 / 基线文件（原有的一律不动）
#
# 判定"成功"的标准不是"22 端口关了"，而是【免密登录不再可用】。
#   构建前 sshd 就存在的机器，destroy 后 22 依然开着 —— 那是**正确还原**，不是残留。
#
# 用法：
#   DRYRUN=1 sh destroy-tunnel.sh                     # 预演，只打印计划
#   sh destroy-tunnel.sh                              # 全销毁（含卸载本次装的 sshd）
#   KEEP=1 sh destroy-tunnel.sh                       # 保留 sshd 程序与服务，只撤配置/公钥/防火墙
#   sh destroy-tunnel.sh 172.16.100.2 User ~/.ssh/k2 2222
set -u

VMIP="${1:-172.16.100.2}"
VMUSER="${2:-User}"
KEY="${3:-$HOME/.ssh/id_ed25519_winvm}"
PORT="${4:-22}"
SKILLDIR="$(cd "$(dirname "$0")/.." && pwd)"
TPL="$SKILLDIR/scripts/winvm-setup-sshd-and-key.ps1"
DRYRUN="${DRYRUN:-0}"
KEEP="${KEEP:-0}"

# 回滚脚本落点：远端用户主目录。不用 ProgramData\ssh——SSH 会话是**非提权**令牌，
# Administrators 在过滤令牌里是 deny-only，写那里会 Permission denied。
# 主目录在运行时从 VM 现取（RB_SCP 用 scp 的相对路径，RB_WIN 用取回的真实路径），
# 这样脚本里不写死任何账户名。
RB_NAME="wb-rollback.ps1"
RB_SCP="$RB_NAME"

RB_ARGS="-Rollback"
[ "$KEEP" = "1" ] && RB_ARGS="$RB_ARGS -KeepService"

SSHOPT="-F /dev/null -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=6"

probe()     { timeout 5 bash -c "exec 3<>/dev/tcp/$VMIP/$PORT" 2>/dev/null; }
pubkey_ok() { ssh $SSHOPT "$VMUSER@$VMIP" "echo ok" >/dev/null 2>&1; }

echo "=============================================="
echo " destroy: $VMUSER@$VMIP:$PORT   DRYRUN=$DRYRUN  KEEP=$KEEP"
echo "=============================================="

echo ""
echo "[1/2] VM 侧回滚"

if ! probe; then
  echo "    22 端口不可达 -> VM 侧已无通道可销毁（或 sshd 从未装/已卸载）"
  echo "    若确认 VM 上仍有残留（配置/公钥/防火墙/服务），在 VM【管理员】PowerShell 执行："
  echo "      cd <回滚脚本所在目录>; powershell -NoProfile -ExecutionPolicy Bypass -File .\\$RB_NAME $RB_ARGS"
  echo "    （找不到该文件说明回滚脚本早已清理；残留仍可疑就跑一次 -Continue 体检）"
elif ! pubkey_ok; then
  echo "    22 端口可达，但【免密登录已不通】-> 无法远程执行回滚（通道已断的常见现场）"
  echo "    请二选一："
  echo "      a) 先重建再 destroy（最省事）： sh $SKILLDIR/scripts/host-generate-key.sh"
  echo "      b) 直接在 VM【管理员】PowerShell 执行（-Rollback 不校验公钥，模板可直接用）："
  echo "         cd <回滚脚本所在目录>; powershell -NoProfile -ExecutionPolicy Bypass -File .\\$RB_NAME $RB_ARGS"
  echo "         该文件不存在时，把 $TPL 传到 VM 后带 $RB_ARGS 执行即可"
elif [ "$DRYRUN" = "1" ]; then
  echo "    [DryRun] 将执行："
  echo "      scp 模板 -> $VMUSER@$VMIP:~/$RB_NAME"
  echo "      schtasks /Create /TN WbTunnelRollback /TR \"powershell ... -File <远端主目录>\\$RB_NAME $RB_ARGS\" /RL HIGHEST /RU SYSTEM /F"
  echo "      schtasks /Run /TN WbTunnelRollback"
  echo "      轮询：免密登录失效（最长 120s）"
else
  VMHOME=$(ssh $SSHOPT "$VMUSER@$VMIP" 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r\n')
  case "$VMHOME" in
    *:*\\*) RB_WIN="$VMHOME\\$RB_NAME" ;;
    *)      echo "    ! 取不到远端主目录 -> 请在 VM 上手工放一份 $RB_NAME 再执行 $RB_ARGS"; exit 1 ;;
  esac
  if ! scp $SSHOPT "$TPL" "$VMUSER@$VMIP:$RB_SCP" 2>/dev/null; then
    echo "    ! 上传回滚脚本失败 -> 请在 VM 上手工放一份再执行 $RB_ARGS"
  else
    echo "    - 回滚脚本已上传：$RB_SCP（远端主目录）"
    TR="powershell -NoProfile -ExecutionPolicy Bypass -File $RB_WIN $RB_ARGS"
    timeout 20 ssh $SSHOPT "$VMUSER@$VMIP" \
      "schtasks /Create /TN WbTunnelRollback /TR \"$TR\" /SC ONCE /ST 00:00 /RL HIGHEST /RU SYSTEM /F && schtasks /Run /TN WbTunnelRollback" 2>&1 | sed 's/^/      /'
    echo "    - 已触发（计划任务以 SYSTEM 运行，SSH 断开不影响它继续跑）"
    i=0
    while [ $i -lt 24 ]; do
      sleep 5
      i=$((i + 1))
      if ! pubkey_ok; then
        echo "    + 免密登录已失效（第 $((i * 5)) 秒）—— VM 侧回滚生效"
        break
      fi
    done
    if pubkey_ok; then
      echo "    ! 免密登录仍然可用：回滚可能没跑起来。到 VM 上查："
      echo "        schtasks /Query /TN WbTunnelRollback /V /FO LIST"
      echo "        type C:\\ProgramData\\ssh\\wb-tunnel-state.json"
    fi
  fi
  if probe; then
    echo "    注：22 端口仍开着 -> KEEP=1 或构建前 sshd 本就存在，属**正确还原**，不是残留"
  else
    echo "    注：22 端口已关闭 -> sshd 已被卸载"
  fi
fi

echo ""
echo "[2/2] 宿主机侧回滚"
DRYRUN="$DRYRUN" sh "$SKILLDIR/scripts/host-rollback.sh" "$KEY" "$VMIP"

echo ""
echo "[+] destroy 流程结束。干净的标准（三条，缺一不算）："
echo "    1. 免密登录不通： sh $SKILLDIR/scripts/verify-tunnel.sh $VMIP $VMUSER $KEY $PORT"
echo "                      -> 第 3 段必须 Permission denied；第 2 段仍列出 password 属正常（密码通道是保留项）"
echo "    2. VM 在线未受损： ping $VMIP"
echo "    3. 可重建       ： sh $SKILLDIR/scripts/host-generate-key.sh   # 紧接着再建一次应当成功"
