#!/usr/bin/env bash
# deploy-1p-autokey.sh · 用 VM 账户「能登录的凭据」**自动**建立免密通道（deploy 第 1 步的 1p 阶段）
#
# 用户口径（2026-11-18 B1，明确要求）：
#   「第一步中判断是否可以 ssh 用户密码登陆，包括 用户名+无密码登陆 的 case，只要可以登陆 ssh 就好；
#     但 ssh 登陆后如何以管理员身份来构建 ssh 免密通道，就要自己设计方案；实在不能才退回让用户在
#     VM 端执行 oneclick 脚本。」
#   ⇒ 本阶段的**准入判据只有一个：能登录**（口令 或 空口令 任一）。登录后提权/落公钥的路径由本脚本设计。
#
# ── 设计：登录后如何拿到「写管理员授权文件」的权限（不弹 UAC、不重启 sshd）──
# Windows OpenSSH 对 **Administrators 组成员**默认下发**完整令牌**（不做 UAC 分裂，也无提权弹窗），
# 判据 `net session` 即代表「已具备管理员权限」。因此只要登录账户在 Administrators 组，
# 就能直接写 `%ProgramData%\ssh\administrators_authorized_keys`——这是 sshd_config 里
# `Match Group administrators` 分支真正读取的授权文件（写用户级 .ssh 反而会被忽略）。
# 非管理员账户则 `Match Group administrators` 不命中，**用户级** `~\.ssh\authorized_keys`
# 才是生效文件，且该文件本来就不需要管理员权限即可写。
# ⇒ 两条路都不需要 UAC、不需要重启 sshd（authorized_keys 改动即时生效），因此不会断连。
#
# 三级策略（逐级降级，前一级成功即止）：
#   S1 直写授权文件（按是否管理员选路）→ 立即回验 key。**常态路径，约 2~4s。**
#   S2 若 key 仍不通（sshd 把 AuthorizedKeysFile 指到别处 / PubkeyAuthentication=no /
#      ACL 策略拦），用同一口令会话跑 oneclick（含配置修正 + 重启 sshd）→ 回验。
#      注意：oneclick 会重启 sshd ⇒ 当前会话必断，rc!=0 是**预期**。
#   S3 仍不通 ⇒ exit 2 回退 1c（请用户在 VM 内以管理员执行 oneclick，即用户说的兜底路径）。
#
# 凭据纪律：口令只经环境变量 / tty 不回显 / 用户自建文件；**绝不落盘、绝不进日志、
#          绝不出现在命令行参数里**（本脚本不创建任何含口令的文件）。
#
# 用法：
#   WINVM_SSH_PASSWORD='***' bash scripts/deploy-1p-autokey.sh   # 口令登录
#   WINVM_SSH_ALLOW_EMPTY=1 bash scripts/deploy-1p-autokey.sh     # 允许尝试「空口令登录」
#   bash scripts/deploy-1p-autokey.sh                             # tty 下交互读口令（直接回车=按无密码尝试）
#   WINVM_PASSWORD_FILE=~/.winvm-pass bash scripts/...            # 读用户自建文件（脚本不写它）
#   SKIP_PASSWORD_BOOTSTRAP=1 bash scripts/deploy-1-ssh.sh        # 显式禁用本阶段
#
# 退出码：0=免密通道已可用 / 2=需人工（NEED_USER_ACTION，调用方回退 1c）/ 1=硬失败
set -u
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]:-$0}")/_common.sh"

resolve_env; need_node; require_host
# shellcheck disable=SC1091
. "$SCRIPTDIR/vm-conn.sh"

KEY="$WINVM_VM_KEY"
PS1_LOCAL="$SCRIPTDIR/winvm-sshd-oneclick.ps1"
# 远端落点用用户临时目录：ProgramData 子目录对管理员可写但 ACL 偶有继承问题，
# 临时目录零风险；oneclick 脚本自己会把自己复制到 ProgramData 长久留存。
PS1_REMOTE="C:/Users/${VM_USER}/AppData/Local/Temp/winvm-sshd-oneclick.ps1"
# 管理员分支的授权文件（Match Group administrators 真正读取的那个）
AK_ADMIN='C:/ProgramData/ssh/administrators_authorized_keys'
# 用户级授权文件（非管理员分支生效的那个）
AK_USER="C:/Users/${VM_USER}/.ssh/authorized_keys"

# ── 口令来源解析（优先级：env > VM_PASSWORD > 用户文件 > tty）──
# 返回 0 = 有「登录意图」（含显式空口令，此时 WINVM_SSH_PASSWORD_EMPTY=1）
resolve_password() {
  if [ -n "${WINVM_SSH_PASSWORD:-}" ]; then return 0; fi
  if [ -n "${VM_PASSWORD:-}" ]; then
    WINVM_SSH_PASSWORD="$VM_PASSWORD"; export WINVM_SSH_PASSWORD; return 0
  fi
  if [ -n "${WINVM_PASSWORD_FILE:-}" ] && [ -f "${WINVM_PASSWORD_FILE}" ]; then
    WINVM_SSH_PASSWORD="$(tr -d '\r\n' < "$WINVM_PASSWORD_FILE")"
    export WINVM_SSH_PASSWORD
    [ -n "$WINVM_SSH_PASSWORD" ] && return 0
  fi
  if [ -t 0 ]; then
    local p=""
    printf 'VM 账户 %s@%s 的口令（不回显；直接回车=按「无密码登录」尝试）: ' "$VM_USER" "$VM_HOST" >&2
    IFS= read -rs p || true
    printf '\n' >&2
    if [ -n "$p" ]; then
      WINVM_SSH_PASSWORD="$p"; export WINVM_SSH_PASSWORD; return 0
    fi
    # 直接回车 ⇒ 用户表达的正是「该账户无密码」，属显式意图，允许空口令尝试
    WINVM_SSH_PASSWORD=""; WINVM_SSH_PASSWORD_EMPTY=1
    export WINVM_SSH_PASSWORD WINVM_SSH_PASSWORD_EMPTY
    return 0
  fi
  return 1
}

# 口令模式下把 ssh2 后端切到「纯口令」并让 vm-conn 的二进制兜底也走 askpass。
enter_password_mode() {
  export WINVM_SSH_AUTH=password
  export VM_CHANNEL=password
  # oneclick 写 ACL + 重启 sshd，25s 默认窗不够；这条是**载荷预算**（见 _common.sh F-26）
  export VM_SSH_EXEC_TIMEOUT="${VM_SSH_EXEC_TIMEOUT_OVERRIDE:-180}"
}
leave_password_mode() {
  unset WINVM_SSH_AUTH WINVM_SSH_PASSWORD WINVM_SSH_PASSWORD_EMPTY VM_CHANNEL 2>/dev/null || true
}

# 用 python 生成 UTF-16LE base64（-EncodedCommand 形态，零引号风险；ASCII 载荷）
ps_encoded() { # ps_encoded <ps 单行文本> → stdout base64
  "$PY" - "$1" <<'PY'
import base64, sys
print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode('ascii'))
PY
}

# 单发口令 ping（不吃 vmssh 的 3 试 + 间隔：口令错是确定性失败，重试只把降级从 ~1s 拖到 ~15s）
ping_password_auth() {
  local ok=0 i
  for i in 1 2; do
    channel_ready 8000 && { ok=1; break; }
    [ "$i" -lt 2 ] && sleep 4
  done
  [ "$ok" = "1" ]
}

# ═══════════════════════ 1p.1 凭据可达（口令 / 空口令，任一即过） ═══════════════════════
if [ "${SKIP_PASSWORD_BOOTSTRAP:-0}" = "1" ]; then
  echo "SKIP_PASSWORD_BOOTSTRAP=1 → 本阶段按用户要求跳过"
  exit 2
fi
st_begin 1p.1 "登录凭据可达性（口令 / 空口令，任一可登录即通过）"
if ! resolve_password; then
  # 无口令且未允许空口令 → 只剩 S3 兜底，不浪费往返
  if [ "${WINVM_SSH_ALLOW_EMPTY:-0}" != "1" ]; then
    st_end 0 SKIP "未提供口令（NEED_PASSWORD）→ 回退 1c 人工命令"
    echo "NEED_PASSWORD=1（口令可选：WINVM_SSH_PASSWORD / VM_PASSWORD / WINVM_PASSWORD_FILE / tty）"
    echo "                无密码账户：WINVM_SSH_ALLOW_EMPTY=1 允许尝试空口令登录"
    exit 2
  fi
  WINVM_SSH_PASSWORD=""; WINVM_SSH_PASSWORD_EMPTY=1
  export WINVM_SSH_PASSWORD WINVM_SSH_PASSWORD_EMPTY
fi

enter_password_mode
AUTH_KIND="password"
[ "${WINVM_SSH_PASSWORD_EMPTY:-0}" = "1" ] && AUTH_KIND="empty-password"
if ! ping_password_auth; then
  st_end 1 FAIL "${AUTH_KIND} 不可达（2 发 ping 均未 ready）"
  leave_password_mode
  echo "PASSWORD_AUTH_UNAVAILABLE=1 → 回退 1c 人工命令"
  if [ "$AUTH_KIND" = "empty-password" ]; then
    echo "  空口令被拒是 Windows 出厂默认（sshd PermitEmptyPasswords no + 本地策略 LimitBlankPasswordUse=1），非本脚本缺陷。"
    echo "  要在 VM 内放开（需管理员，且会降低安全性）："
    echo "    Set-ItemProperty 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Lsa' LimitBlankPasswordUse 0"
    echo "    在 sshd_config 设 PermitEmptyPasswords yes 后 Restart-Service sshd"
  fi
  exit 2
fi
WHO="$(vmssh 'whoami' 2>&1 | tr -d '\r' | tail -1)"
if [ -z "$WHO" ] || printf '%s' "$WHO" | grep -qiE 'denied|fail|error|timeout|refused'; then
  st_end 1 FAIL "ping 通但 exec 失败（$(printf '%s' "$WHO" | head -c 80)）"
  leave_password_mode
  echo "PASSWORD_EXEC_FAILED=1 → 回退 1c 人工命令"
  exit 2
fi
st_end 0 PASS "auth=${AUTH_KIND} whoami=$WHO"

# ═══════════════════ 1p.2 身份判定（决定写哪个授权文件） ═══════════════════
st_begin 1p.2 "身份判定（管理员 → administrators_authorized_keys；否则 → 用户级 authorized_keys）"
ADM="$(vmssh 'net session >nul 2>&1 && echo ADMIN_YES || echo ADMIN_NO' 2>&1 | tr -d '\r' | grep -oE 'ADMIN_(YES|NO)' | tail -1)"
if [ "$ADM" = "ADMIN_YES" ]; then
  IS_ADMIN=1
  st_end 0 PASS "ADMIN_YES（SSH 会话已持完整令牌，可直接写 ProgramData，无需 UAC）"
else
  IS_ADMIN=0
  # 非管理员**不算失败**：Match Group administrators 不命中 ⇒ 用户级文件才是生效文件，
  # 而它本来就不需要管理员权限。硬失败只留给 1p.5 回验（判据只看「key 能不能登」）。
  st_end 0 PASS "ADMIN_NO（走用户级授权文件；免密登录可达，但需管理员能力的后续步骤仍需人工）"
fi

# ═══════════════════════════ 1p.3 本机公钥就位 ═══════════════════════════
st_begin 1p.3 "本机公钥就位"
mkdir -p "$(dirname "$KEY")" 2>/dev/null || true
if [ ! -f "$KEY" ]; then
  command -v ssh-keygen >/dev/null 2>&1 \
    || die "缺少 ssh-keygen" "无法生成密钥" "command -v ssh-keygen 为空" "装 openssh-client 或手工放置 $KEY"
  ssh-keygen -t ed25519 -N '' -C 'workbuddy-winvm' -f "$KEY" >/dev/null 2>&1 \
    || die "ssh-keygen 失败" "无法写入 $KEY" "见上" "检查 $(dirname "$KEY") 可写性"
  echo "  已生成新密钥：$KEY"
else
  echo "  复用已有密钥：$KEY"
fi
PUB="$(cat "$KEY.pub" 2>/dev/null)"
[ -n "$PUB" ] || die "公钥不可读" "$KEY.pub 为空" "cat 失败" "删掉 $KEY 重跑本脚本"
st_end 0 PASS "pub=sha256:$(ssh-keygen -lf "$KEY.pub" 2>/dev/null | awk '{print $2}')"

# ═════════════╳ S1：直写授权文件 + 立即回验（常态路径） ═════════════╳
# 单行 PS（EncodedCommand）：建目录 → 幂等追加（已含同 key 则不动）→ 按身份收紧 ACL。
# ACL 一律用 SID（*S-1-5-32-544 Administrators / *S-1-5-18 SYSTEM），
# 避免中文系统组名（"管理员"）导致 icacls 解析失败。
st_begin 1p.4 "S1 直写授权文件（不重启 sshd）"
if [ "$IS_ADMIN" = "1" ]; then
  AK="$AK_ADMIN"; OWNER_GRANT=""
else
  AK="$AK_USER"; OWNER_GRANT="/grant \"${VM_USER}:F\" "
fi
PS_WRITE="\$ErrorActionPreference='Stop'; \
\$ak='${AK}'; \
\$dir=Split-Path -Parent \$ak; if(-not (Test-Path \$dir)){New-Item -ItemType Directory -Force -Path \$dir|Out-Null}; \
\$cur=''; if(Test-Path \$ak){\$cur=[IO.File]::ReadAllText(\$ak)}; \
\$pub='${PUB}'; \
if(\$cur -notlike ('*'+\$pub+'*')){ \
  \$sep=''; if(\$cur.Length -gt 0 -and \$cur[\$cur.Length-1] -ne [char]10){\$sep=[Environment]::NewLine}; \
  [IO.File]::AppendAllText(\$ak, \$sep+\$pub+[Environment]::NewLine); 'APPENDED' \
} else { 'ALREADY' }; \
& icacls.exe \$ak /inheritance:r ${OWNER_GRANT}/grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null; \
'ACL_OK '+\$ak"
ENC="$(ps_encoded "$PS_WRITE")"
WRITE_OUT="$(vmssh "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $ENC" 2>&1 | tr -d '\r' | tail -3)"
WRITE_OK=1
case "$WRITE_OUT" in
  *APPENDED*) echo "  已追加公钥 → $AK" ;;
  *ALREADY*)  echo "  公钥已在册（幂等跳过）→ $AK" ;;
  *)          echo "  直写授权文件失败（$(printf '%s' "$WRITE_OUT" | head -c 140)）→ 降级 S2" ; WRITE_OK=0 ;;
esac
[ "$WRITE_OK" = "1" ] && st_end 0 PASS "目标=$AK" || st_end 1 FAIL "直写失败"

if [ "$WRITE_OK" = "1" ]; then
  st_begin 1p.5 "免密回验（切回 key 认证；未重启 sshd ⇒ 应立即可用）"
  leave_password_mode
  ready=0; waited=0
  while [ "$waited" -lt "${AUTOKEY_QUICK_WAIT_S:-12}" ]; do
    if channel_ready 6000; then ready=1; break; fi
    sleep 2; waited=$((waited + 2))
  done
  if [ "$ready" = "1" ]; then
    st_end 0 PASS "channel=READY（S1 直写，用时 ${waited}s，未重启 sshd）"
    state_set CHANNEL_READY 1
    state_set WINVM_VM_KEY "$KEY"
    echo "AUTOKEY_RESULT=PASS strategy=S1 waited=${waited}s"
    steps_report
    exit 0
  fi
  st_end 1 FAIL "key 回验未通（${AUTOKEY_QUICK_WAIT_S:-12}s）→ 降级 S2"
  echo "  S1 不通的常见原因：sshd_config 把 AuthorizedKeysFile 指到别处 / PubkeyAuthentication no / ACL 策略拦"
fi

# ═════════╳ S2：重锤 oneclick（修配置 + 重启 sshd） ═════════╳
st_begin 1p.6 "S2 oneclick 修正 sshd 配置（会重启 sshd，当前会话必断，属预期）"
enter_password_mode
if [ ! -f "$PS1_LOCAL" ]; then
  SRC="$(sshd_script_url 2>/dev/null || true)"
  if [ -z "$SRC" ]; then
    st_end 1 FAIL "找不到 oneclick 脚本"
    echo "AUTOKEY_RESULT=NEED_USER → 回退 1c 人工"
    exit 2
  fi
  PS_LINE="\$ErrorActionPreference='Stop'; \$d=Join-Path \$env:ProgramData 'WinVMDeploy'; New-Item -ItemType Directory -Force -Path \$d|Out-Null; \$f=Join-Path \$d 'winvm-sshd-oneclick.ps1'; Invoke-WebRequest -UseBasicParsing -Uri '$SRC' -OutFile \$f -TimeoutSec 45; Unblock-File \$f; & \$f -PublicKey '$PUB' -User '$VM_USER' -Port $VM_SSH_PORT"
else
  # shellcheck disable=SC2086
  vmscp "$PS1_LOCAL" "$PS1_REMOTE" 2>&1 | tail -2
  PS_LINE="\$ErrorActionPreference='Stop'; & '$PS1_REMOTE' -PublicKey '$PUB' -User '$VM_USER' -Port $VM_SSH_PORT"
fi
ENC="$(ps_encoded "$PS_LINE")"
vmssh "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $ENC" >/dev/null 2>&1 || true
st_end 0 PASS "已下发（sshd 重启导致本次会话断开属预期）"

# ═══════════════════════════ S2 回验 ═══════════════════════════
st_begin 1p.7 "S2 免密通道回验"
leave_password_mode
ready=0; waited=0
while [ "$waited" -lt "${AUTOKEY_WAIT_S:-90}" ]; do
  if channel_ready 6000; then ready=1; break; fi
  sleep 5; waited=$((waited + 5))
  [ $((waited % 15)) -eq 0 ] && echo "  … 等 sshd 恢复 ${waited}s / ${AUTOKEY_WAIT_S:-90}s"
done
if [ "$ready" = "1" ]; then
  st_end 0 PASS "channel=READY（S2，用时 ${waited}s）"
  state_set CHANNEL_READY 1
  state_set WINVM_VM_KEY "$KEY"
  echo "AUTOKEY_RESULT=PASS strategy=S2 waited=${waited}s"
  steps_report
  exit 0
fi
st_end 2 WAIT_USER "S2 回验未通过（${AUTOKEY_WAIT_S:-90}s）"
echo "AUTOKEY_RESULT=FAIL strategy=S2 → 回退 1c 人工命令（请在 VM 管理员 PowerShell 执行 oneclick）"
exit 2
