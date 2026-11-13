#!/bin/sh
# hos-winvm-ssh-tunnel / 宿主机(HarmonyOS)侧：生成密钥 + 输出“可整体粘贴”的 Windows 一键脚本
#
# 用法：
#   sh host-generate-key.sh [key_path] [vm_user] [vm_port] [vm_ip]
#   ROTATE=1 sh host-generate-key.sh          # 强制重新生成（旧钥备份为 .old-<时间戳>）
#   NOHARDEN=1 sh host-generate-key.sh        # 生成「不关密码认证」的脚本（默认已按安全基线收紧）
#
# 可逆性：首次运行时把「变更前基线」写入 $STATE_DIR/host-state.json
#         （记录密钥是否本就有、known_hosts 是否本就有），供 host-rollback.sh 精确撤销。
# 之后把终端打印的整段 PowerShell 复制到 Windows VM 的【管理员】PowerShell 里执行一次。
set -eu

KEY="${1:-$HOME/.ssh/id_ed25519_winvm}"
VMUSER="${2:-User}"
PORT="${3:-22}"
VMIP="${4:-172.16.100.2}"
SKILLDIR="$(cd "$(dirname "$0")/.." && pwd)"
TPL="$SKILLDIR/scripts/winvm-setup-sshd-and-key.ps1"
# 运行期状态放包外：skill 包是分发的只读产物，状态不该进去（也避免被打进 zip）
STATE_DIR="${WB_TUNNEL_STATE_DIR:-$HOME/.workbuddy/.state/hos-winvm-ssh-tunnel}"
STATE="$STATE_DIR/host-state.json"

# ---- 0) 记录"变更前基线"（只在首次构建时写，之后沿用）----
KEY_EXISTED=0
[ -f "$KEY" ] && KEY_EXISTED=1
# 归属判定：公钥注释带本 skill 标记 => 这把钥归本 skill 所有（destroy 时应当删除）
KEY_OURS=0
if [ -f "$KEY.pub" ] && grep -q 'workbuddy-hos-winvm-tunnel' "$KEY.pub" 2>/dev/null; then
  KEY_OURS=1
fi
KNOWN_EXISTED=0
if [ -f "$HOME/.ssh/known_hosts" ] && grep -q -- "$VMIP" "$HOME/.ssh/known_hosts" 2>/dev/null; then
  KNOWN_EXISTED=1
fi

mkdir -p "$STATE_DIR"
python3 - "$STATE" "$KEY" "$KEY_EXISTED" "$KEY_OURS" "$KNOWN_EXISTED" "$VMIP" "$VMUSER" "$PORT" <<'PY'
import json, os, sys, datetime
state_path, key, key_existed, key_ours, known_existed, vmip, vmuser, port = sys.argv[1:9]
if os.path.exists(state_path):
    try:
        st = json.load(open(state_path, encoding='utf-8'))
        print('[*] 已存在基线记录（%s），沿用 keyCreatedBySkill=%s'
              % (st.get('ts'), st.get('keyCreatedBySkill')))
        sys.exit(0)
    except Exception:
        pass
# 文件不存在 => 本次会生成 => 归本 skill；已存在但注释是我们的 => 也归本 skill
created_by_skill = (key_existed == '0') or (key_ours == '1')
st = {
    'ts': datetime.datetime.now().isoformat(timespec='seconds'),
    'keyPath': key,
    'keyExistedBefore': key_existed == '1',
    'keyCreatedBySkill': created_by_skill,
    'knownHostsEntryExistedBefore': known_existed == '1',
    'vmIp': vmip, 'vmUser': vmuser, 'port': port,
    'rotatedBackups': [],
    'createdBy': 'hos-winvm-ssh-tunnel',
}
os.makedirs(os.path.dirname(state_path), exist_ok=True)
json.dump(st, open(state_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print('[+] 已记录宿主机基线 -> %s（keyCreatedBySkill=%s / knownHostsExistedBefore=%s）'
      % (state_path, st['keyCreatedBySkill'], st['knownHostsEntryExistedBefore']))
PY

# ---- 1) 生成 / 复用密钥 ----
if [ -f "$KEY" ] && [ "${ROTATE:-0}" = "1" ]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  python3 - "$KEY" "$TS" <<'PY'
import os, sys, shutil, json
key, ts = sys.argv[1], sys.argv[2]
for p in (key, key + '.pub'):
    if os.path.exists(p):
        dst = p + '.old-' + ts
        shutil.move(p, dst)
        print('[!] 旧钥已备份：%s' % dst)
PY
  python3 - "$STATE" "$TS" <<'PY'
import json, os, sys
state_path, ts = sys.argv[1], sys.argv[2]
if os.path.exists(state_path):
    st = json.load(open(state_path, encoding='utf-8'))
    st.setdefault('rotatedBackups', []).append(ts)
    json.dump(st, open(state_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY
fi

if [ ! -f "$KEY" ]; then
  echo "[*] 生成密钥：$KEY (ed25519, 无 passphrase)"
  mkdir -p "$(dirname "$KEY")"
  ssh-keygen -t ed25519 -N '' -C 'workbuddy-hos-winvm-tunnel' -f "$KEY" >/dev/null
else
  echo "[*] 复用已有密钥：$KEY"
fi

# ---- 2) 私钥权限（hmdfs 上 chmod 可能无效，尽力而为）----
python3 - "$KEY" <<'PY'
import os, sys
k = sys.argv[1]
try:
    os.chmod(k, 0o600)
    st = os.stat(k)
    print('[*] 私钥模式：%s' % oct(st.st_mode & 0o777))
except Exception as e:
    print('[!] chmod 失败（hmdfs 忽略）：%s' % e)
PY

PUB="$(cat "$KEY.pub")"
echo "[*] 公钥：$PUB"
echo "[*] 指纹：$(ssh-keygen -lf "$KEY.pub" 2>/dev/null || echo '(unavailable)')"
echo "[*] 目标：$VMUSER@$VMIP:$PORT"
echo
echo "================ 复制以下全部内容 -> Windows【管理员】PowerShell 粘贴执行 ================"
python3 - "$TPL" "$PUB" "$VMUSER" "$PORT" <<'PY'
import sys, re, os
tpl, pub, user, port = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s = open(tpl, encoding='utf-8').read().lstrip('\ufeff')   # 去模板 BOM，粘贴更干净
s = s.replace('__PUBKEY__', pub)
s = re.sub(r"\[string\]\$User\s*=\s*\$env:USERNAME", "[string]$User      = '%s'" % user, s, count=1)
s = re.sub(r"\[int\]\s*\$Port\s*=\s*22", "[int]   $Port      = %s" % port, s, count=1)
if os.environ.get('NOHARDEN') == '1':
    s = s.replace('[switch]$NoHarden,', '[switch]$NoHarden = $true,', 1)
sys.stdout.write(s)
PY
echo
echo "================ 粘贴结束 ================"
echo
echo "[*] 之后在宿主机验证："
echo "    sh $SKILLDIR/scripts/verify-tunnel.sh $VMIP $VMUSER $KEY $PORT"
echo
echo "[*] 需要销毁（精确还原）："
echo "    sh $SKILLDIR/scripts/destroy-tunnel.sh $VMIP $VMUSER $KEY $PORT      # 先 -DryRun 预演：加 DRYRUN=1"
