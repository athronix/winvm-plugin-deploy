#!/bin/sh
# hos-winvm-ssh-tunnel / 宿主机侧验证（四段，按"能不能被冒名登录"排序）
#   1) TCP 可达
#   2) none 认证必须被拒   <- 最关键：判定"真公钥免密"还是"匿名通道"
#   3) 服务端通告了哪些认证方式（证明「密码登录是否仍被允许」）
#   4) 纯公钥免密登录是否真的可用
# 用法：sh verify-tunnel.sh [vm_ip] [vm_user] [key_path] [port]
#   例：sh verify-tunnel.sh 172.16.100.2 User ~/.ssh/id_ed25519_winvm 22
set -u

IP="${1:-172.16.100.2}"
USER="${2:-User}"
KEY="${3:-$HOME/.ssh/id_ed25519_winvm}"
PORT="${4:-22}"

# 注意：绝不能加 -F ~/.ssh/config（hmdfs 上放不了 config），也不能省 PreferredAuthentications。
SSH_BASE="-F /dev/null -p $PORT -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 -o LogLevel=ERROR"

echo "[*] 目标：$USER@$IP:$PORT   密钥：$KEY"
[ -f "$KEY" ] || { echo "[x] 私钥不存在：$KEY（先在宿主机跑 host-generate-key.sh）"; exit 1; }

FAIL=0

# ---------- 1) TCP ----------
echo ""
echo "=== [1/4] TCP 可达性 ==="
if command -v nc >/dev/null 2>&1; then
  if nc -z -w 3 "$IP" "$PORT" 2>/dev/null; then
    echo "[+] TCP $IP:$PORT 可连"
  else
    echo "[x] TCP $IP:$PORT 不通 —— 先查 VM 是否开机 / sshd 是否在跑 / 防火墙是否放行本机 IP"
    echo "$IP $PORT" >/dev/null
    FAIL=1
  fi
else
  echo "[!] 没有 nc，跳过 TCP 探测（继续用 ssh 直接试）"
fi

# ---------- 2) none 认证必须被拒 ----------
# 背景（2026-11-10 实测踩到，务必保留此段）：
#   OpenSSH 的 auth2-none.c 规定「账户密码为空 且 PermitEmptyPasswords=yes」时 none 认证直接成功。
#   ssh 客户端**总是先发 none**，所以只要服务器接受，后面的 publickey 根本不会被执行 ——
#   表面上"免密登录成功"，实际是"无凭据匿名登录"，公钥从未参与。
#   因此这一段的结论优先级高于第 4 段：第 2 段不过，第 4 段的成功是假的。
echo ""
echo "=== [2/4] none 认证必须被拒（不通过 => 公钥免密是假象） ==="
NONE_OUT=$(ssh $SSH_BASE -o BatchMode=yes -o PubkeyAuthentication=no \
             -o PreferredAuthentications=none -o NumberOfPasswordPrompts=0 \
             "$USER@$IP" 'echo WB_NONE_AUTH_ACCEPTED' 2>&1)
case "$NONE_OUT" in
  *WB_NONE_AUTH_ACCEPTED*)
    echo "[x] 严重：服务器接受 none 认证 —— 不需要任何凭据就能登录！"
    echo "    => 第 4 段的\"免密成功\"是假象，公钥从未被使用。"
    echo "    => 修法：sshd_config 写 PermitEmptyPasswords no 并重启 sshd（脚本默认值即是）。"
    FAIL=1
    ;;
  *"Permission denied ("*)
    METHODS=$(printf '%s' "$NONE_OUT" | sed -n 's/.*Permission denied (\([^)]*\)).*/\1/p')
    echo "[+] none 认证被拒（正确：无凭据不能登录）"
    echo "[*] sshd 通告的认证方式：$METHODS"
    case ",$METHODS," in
      *,password,*)  echo "[+] 密码认证已开放（password）—— 符合「密码登录仍被允许」的要求" ;;
      *)             echo "[!] 未通告 password —— 若要求保留密码登录，检查是否误加了 -Harden" ;;
    esac
    case ",$METHODS," in
      *,publickey,*) echo "[+] 公钥认证已开放（publickey）" ;;
      *)             echo "[x] 未通告 publickey —— PubkeyAuthentication 被关了，免密不可能成功"; FAIL=1 ;;
    esac
    ;;
  *)
    printf '%s\n' "$NONE_OUT" | sed -n '1,4p'
    echo "[!] 无法判定 none 是否被接受（连接未走到认证阶段）"
    FAIL=1
    ;;
esac

# ---------- 3) 纯公钥免密 ----------
echo ""
echo "=== [3/4] 纯公钥免密登录（IdentitiesOnly + PreferredAuthentications=publickey） ==="
# 必须同时给 IdentitiesOnly 与 PreferredAuthentications=publickey：
#   少任何一个，在"空密码 + PermitEmptyPasswords yes"的机器上都会静默退化成 none/空密码登录，
#   看起来成功，实际根本没验公钥。
if ssh $SSH_BASE -i "$KEY" \
      -o IdentitiesOnly=yes -o BatchMode=yes -o PreferredAuthentications=publickey \
      "$USER@$IP" 'whoami & hostname & echo WB_PUBKEY_OK'; then
  echo "[+] 公钥登录成功（零交互）"
else
  echo "[x] 公钥登录失败"
  FAIL=1
fi

# ---------- 4) 汇总 ----------
echo ""
echo "=== [4/4] 结论 ==="
if [ "$FAIL" -eq 0 ]; then
  echo "[+] 全部通过：仅凭公钥可登录，且无凭据无法登录（真免密通道）"
  echo ""
  echo "补充验证（可选，值得各做一次）："
  echo "    exit 码透传： ssh $SSH_BASE -i $KEY -o BatchMode=yes $USER@$IP 'exit 42'; echo \$?   # 期望 42"
  echo "    scp 双向    ： scp -F /dev/null -i $KEY 本地文件 $USER@$IP:Downloads/ && scp -i $KEY $USER@$IP:Downloads/文件 ."
  echo "    密码通道    ： 本次不自动试（空密码会被 PermitEmptyPasswords no 拒，属预期）"
  exit 0
fi

echo "[x] 有检查项未通过，按此顺序排查："
printf '%s\n' '    1. sshd 是否运行/自启：  sc query sshd'
printf '%s\n' '    2. 配置关键行：          type C:\ProgramData\ssh\sshd_config | findstr /I "Port ListenAddress Pubkey Password PermitEmpty Match"'
printf '%s\n' '       * PermitEmptyPasswords 必须是 no —— 否则 none 认证直接放行（本脚本第2段会报）'
printf '%s\n' '    3. 公钥落点是否正确：    管理员->C:\ProgramData\ssh\administrators_authorized_keys'
printf '%s\n' '                             非管理员->%USERPROFILE%\.ssh\authorized_keys'
printf '%s\n' '    4. ACL 是否收紧：        icacls C:\ProgramData\ssh\administrators_authorized_keys'
printf '%s\n' '    5. 来源/监听是否收窄过度：netstat -an | findstr ":22 "'
printf '%s\n' '                             若只监听某个内网 IP，从别的网段连必然失败'
printf '%s\n' '    6. 防火墙来源限制：      Get-NetFirewallRule | Where-Object {$_.DisplayName -match "SSH|OpenSSH"} |'
printf '%s\n' '                              ForEach-Object { $_.Name; ($_ | Get-NetFirewallAddressFilter).RemoteAddress }'
printf '%s\n' '    7. 服务端日志（ETW）：   Get-WinEvent -LogName OpenSSH/Operational -MaxEvents 30'
printf '%s\n' '                             看 "Accepted publickey" 还是 "Accepted none"'
printf '%s\n' '                             MSI 版 10.x 不写 C:\ProgramData\ssh\Logs\sshd.log'
printf '%s\n' '    8. 若第2段报"接受 none"：把 PermitEmptyPasswords 改成 no 再重启 sshd'
exit 1
