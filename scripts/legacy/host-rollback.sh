#!/bin/sh
# host-rollback.sh —— 只撤销「宿主机侧、且确实由本 skill 创建」的东西（精确还原，不多删）
#
# 判定依据（优先级）：
#   1) 宿主机状态目录里的 host-state.json 记录的基线：keyExistedBefore / knownHostsEntryExistedBefore / rotatedBackups
#   2) 无基线时降级为「指纹+注释」判定：只删注释为 workbuddy-hos-winvm-tunnel 的密钥
#
# 用法：
#   DRYRUN=1 sh host-rollback.sh              # 预演（只打印将要做什么）
#   sh host-rollback.sh                       # 真回滚（默认 key=~/.ssh/id_ed25519_winvm, ip=172.16.100.2）
#   sh host-rollback.sh ~/.ssh/k2 172.16.100.2
#   KEEP_KEY=1 sh host-rollback.sh            # 保留密钥，只清 known_hosts
#   KEEP_HOSTS=1 sh host-rollback.sh          # 保留 known_hosts
#
# 注意：hmdfs 上 rm/mv 被 shim 拦截（bad interpreter），文件操作统一走 python3。

set -u

KEY="${1:-$HOME/.ssh/id_ed25519_winvm}"
VMIP="${2:-172.16.100.2}"
SKILLDIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${WB_TUNNEL_STATE_DIR:-$HOME/.workbuddy/.state/hos-winvm-ssh-tunnel}"
STATE="$STATE_DIR/host-state.json"
DRYRUN="${DRYRUN:-0}"
KEEP_KEY="${KEEP_KEY:-0}"
KEEP_HOSTS="${KEEP_HOSTS:-0}"

echo "[*] 宿主机侧回滚   key=$KEY  vm=$VMIP  dryrun=$DRYRUN"

python3 - "$KEY" "$VMIP" "$STATE" "$DRYRUN" "$KEEP_KEY" "$KEEP_HOSTS" <<'PY'
import json, os, sys

key, vmip, state_path, dryrun, keep_key, keep_hosts = sys.argv[1:7]
dryrun = dryrun == '1'
keep_key = keep_key == '1'
keep_hosts = keep_hosts == '1'
MARK = 'workbuddy-hos-winvm-tunnel'

st = None
if os.path.exists(state_path):
    try:
        st = json.load(open(state_path, encoding='utf-8'))
    except Exception as e:
        print('[!] 基线文件解析失败：%s' % e)

def rm(p):
    if not os.path.exists(p):
        print('    - 不存在，跳过：%s' % p); return
    if dryrun:
        print('    [DryRun] 将删除：%s' % p); return
    try:
        os.remove(p); print('    - 已删除：%s' % p)
    except Exception as e:
        print('    ! 删除失败 %s：%s' % (p, e))

def mv(src, dst):
    if not os.path.exists(src):
        return False
    if dryrun:
        print('    [DryRun] 将还原：%s -> %s' % (src, dst)); return True
    try:
        os.replace(src, dst); print('    - 已还原：%s -> %s' % (src, dst)); return True
    except Exception as e:
        print('    ! 还原失败 %s：%s' % (src, e)); return False

print('\n[1] 密钥')

# 无基线时用注释做精确判定，避免误删用户自己的钥
def is_ours(k):
    pub = k + '.pub'
    if not os.path.exists(pub):
        return False
    try:
        v = open(pub, encoding='utf-8', errors='ignore').read()
        return MARK in v
    except Exception:
        return False

if keep_key:
    print('    KEEP_KEY=1：保留密钥')
else:
    if st is not None:
        created_by_skill = st.get('keyCreatedBySkill')
        if created_by_skill is None:                     # 兼容旧基线
            created_by_skill = not bool(st.get('keyExistedBefore'))
        if created_by_skill:
            print('    - 基线记录：这把钥由本 skill 创建/拥有 -> 删除（含 ROTATE 备份）')
            rm(key); rm(key + '.pub')
            for f in sorted(os.listdir(os.path.dirname(key) or '.')):
                if f.startswith(os.path.basename(key) + '.old-'):
                    rm(os.path.join(os.path.dirname(key) or '.', f))
        else:
            # 构建前就存在、且不属于本 skill：保留；若期间 ROTATE 过则还原最早的备份
            olds = sorted(
                f for f in os.listdir(os.path.dirname(key) or '.')
                if os.path.basename(f).startswith(os.path.basename(key) + '.old-')
            )
            if olds:
                d = os.path.dirname(key) or '.'
                if mv(os.path.join(d, olds[0]), key):
                    pub = os.path.join(d, olds[0] + '.pub')
                    if os.path.exists(pub):
                        mv(pub, key + '.pub')
                for extra in olds[1:]:
                    rm(os.path.join(d, extra)); rm(os.path.join(d, extra + '.pub'))
            else:
                print('    - 构建前已存在且不属于本 skill：保留不删（精确还原：不碰用户原有钥）')
    else:
        if is_ours(key):
            print('    - 无基线，但公钥注释为 %s -> 判定为本 skill 创建的密钥，删除' % MARK)
            rm(key); rm(key + '.pub')
        else:
            print('    - 无基线且注释不匹配，保守处理：不删除 %s' % key)

print('\n[2] known_hosts')
kh = os.path.expanduser('~/.ssh/known_hosts')
if keep_hosts:
    print('    KEEP_HOSTS=1：保留 known_hosts')
elif not os.path.exists(kh):
    print('    - 无 known_hosts，跳过')
else:
    kh_existed_before = bool(st.get('knownHostsEntryExistedBefore')) if st is not None else None
    if kh_existed_before:
        print('    - 构建前该主机就已在 known_hosts 中：保留（精确还原：不删原有记录）')
    else:
        lines = open(kh, encoding='utf-8', errors='ignore').read().splitlines()
        keep = [l for l in lines if vmip not in l]
        removed = len(lines) - len(keep)
        if removed == 0:
            print('    - 无 %s 的记录，跳过' % vmip)
        elif dryrun:
            print('    [DryRun] 将移除 %d 条 %s 的记录' % (removed, vmip))
        else:
            tmp = kh + '.wb-tmp'
            open(tmp, 'w', encoding='utf-8').write('\n'.join(keep) + ('\n' if keep else ''))
            os.replace(tmp, kh)
            print('    - 已移除 %d 条 %s 的记录' % (removed, vmip))

print('\n[3] 其他残留检查')
cfg = os.path.expanduser('~/.ssh/config')
if os.path.exists(cfg):
    print('    ! 检测到 ~/.ssh/config —— hmdfs 上必然报 Bad owner，会拖垮所有 ssh，应删除')
else:
    print('    - 无 ~/.ssh/config（正常）')

print('\n[4] 基线文件')
if st is None:
    print('    - 无基线文件，跳过')
elif dryrun:
    print('    [DryRun] 将删除基线：%s' % state_path)
else:
    rm(state_path)

print('\n[+] 宿主机侧回滚完成（精确还原：只删本 skill 创建的东西）')
PY
