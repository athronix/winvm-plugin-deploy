#!/usr/bin/env bash
# selfcheck.sh · 技能离线自检门禁（不需要 VM，改完/发布前必跑）
#
# 断言面（全部结构化，不做"字样在场"式假绿）：
#   1  syntax        现行 .sh 全部 bash -n
#   2  control       文本文件无控制字符（dist/*.zip 豁免）
#   3  frontmatter   name 与 SemVer
#   4  inventory     SKILL.md 脚本清单 ↔ scripts/ 实际文件一致（漏改名/漏入包）
#   5  no-grep-c     禁 `grep -c ... || echo 0`（零匹配吐两个 0 ⇒ 假红 F-17）
#   6  tsv-contract  _common.sh 的 st_end 真写 steps.tsv 且判定取值受控
#   7  ssh-4-steps   deploy-1-ssh.sh 具备 1a/1b/1c/1d 且用新建连接实测判据
#   8  probe-count   deploy-5-verify.sh 解析真实 x/y + 项数断言 + 取不到即 FAIL
#   9  keep-default  undeploy-3-ssh.sh 默认 --remove-ssh-tunnel=no
#  10  payload       ps-run.sh 的 _payload 注入 VM_PS_TIMEOUT（F-26 不变量）
#  11  parallel      deploy.sh 阶段 A=1‖2 / B=3‖4 / C=5
#  12  no-rebuild    卸载脚本不出现建通道字样
#  13  links         SKILL.md 相对链接目标存在
#  14  oneclick      VM 单脚本具备自归位 + 公钥文件回填 + 固定 -Rollback 路径
#
# 用法：
#   bash scripts/selfcheck.sh                  # 末行 SELFCHECK=ALL_GREEN checks=N fails=0
#   bash scripts/selfcheck.sh --mutate         # 变异自证（6 组缺陷必须被对应断言抓到）
#   SELFCHECK_WORK=<dir> bash scripts/selfcheck.sh
#
# 退出码：0 全绿 / 1 有 FAIL / 2 前置缺失
set -u
_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PY=/data/service/hnp/bin/python3
[ -x "$PY" ] || PY="$(command -v python3 2>/dev/null || true)"
[ -n "$PY" ] && [ -x "$PY" ] || { echo "SELFCHECK=PRECONDITION_MISSING reason=no-python3"; exit 2; }
MUTATE=0
[ "${1:-}" = "--mutate" ] && MUTATE=1
: "${SELFCHECK_WORK:=${HOME}/wbtmp/selfcheck-$(date +%Y%m%d-%H%M%S)}"
: "${SKILL_SELFCHECK_OUT:=${HOME}/wbtmp/winvm-plugin-deploy-selfcheck.txt}"
mkdir -p "$SELFCHECK_WORK" 2>/dev/null || true

"$PY" - "$_here/.." "$MUTATE" "$SELFCHECK_WORK" "$SKILL_SELFCHECK_OUT" <<'PYEOF'
import os, re, sys, io, shutil, subprocess

ROOT = os.path.abspath(sys.argv[1])
MUTATE = sys.argv[2] == '1'
WORK = sys.argv[3]
OUT = sys.argv[4]

# 现行脚本（legacy 不进断言面：留档即冻结）
ACTIVE = ['_common.sh', 'deploy.sh', 'deploy-1-ssh.sh', 'deploy-2-host.sh',
          'deploy-3-tunnel.sh', 'deploy-4-vm.sh', 'deploy-5-verify.sh',
          'undeploy.sh', 'undeploy-1-host.sh', 'undeploy-2-vm.sh',
          'undeploy-3-ssh.sh', 'verify.sh', 'env-detect.sh', 'download-verify.sh',
          'pkg-root.sh', 'ps-run.sh', 'vm-conn.sh', 'selfcheck.sh']


def read(p):
    with io.open(p, encoding='utf-8', errors='replace') as f:
        return f.read()


def strip_comments(txt):
    """剔注释行，避免"注释里的字样"蒙混结构化断言（F-21 变异实证）。"""
    return '\n'.join(l for l in txt.splitlines() if not l.lstrip().startswith('#'))


def walk_files(base):
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if d not in ('.git', 'legacy', 'dist', 'node_modules')]
        for fn in filenames:
            yield os.path.join(dirpath, fn)


# ─────────────────────────── 断言 ───────────────────────────
def c_syntax(root):
    bad = []
    for fn in ACTIVE:
        p = os.path.join(root, 'scripts', fn)
        if not os.path.exists(p):
            bad.append('%s: missing' % fn); continue
        r = subprocess.run(['bash', '-n', p], capture_output=True, text=True)
        if r.returncode != 0:
            bad.append('%s: %s' % (fn, (r.stderr or '').strip().splitlines()[:1]))
    return bad


def c_control(root):
    bad = []
    for p in walk_files(root):
        rel = os.path.relpath(p, root)
        if rel.endswith(('.zip', '.png', '.jpg', '.ico')):
            continue
        try:
            data = open(p, 'rb').read()
        except Exception:
            continue
        if b'\x00' in data:
            bad.append(rel + ': NUL byte'); continue
        try:
            txt = data.decode('utf-8')
        except UnicodeDecodeError:
            bad.append(rel + ': not utf-8'); continue
        for ch in txt:
            o = ord(ch)
            if o < 0x09 or o in (0x0b, 0x0c) or 0x0e <= o <= 0x1f:
                bad.append('%s: ctrl U+%04X' % (rel, o)); break
    return bad


def c_frontmatter(root):
    bad = []
    txt = read(os.path.join(root, 'SKILL.md'))
    m = re.search(r'^---\s*$(.*?)^---\s*$', txt, re.S | re.M)
    if not m:
        return ['SKILL.md: no frontmatter block']
    fm = m.group(1)
    if not re.search(r'^name:\s*winvm-plugin-deploy\s*$', fm, re.M):
        bad.append('frontmatter name != winvm-plugin-deploy')
    vm = re.search(r'^version:\s*(\S+)\s*$', fm, re.M)
    if not vm:
        bad.append('frontmatter version missing')
    elif not re.match(r'^\d+\.\d+\.\d+$', vm.group(1)):
        bad.append('version not SemVer: %s' % vm.group(1))
    return bad


def c_inventory(root):
    """SKILL.md 提到的每个脚本名都必须真实存在（防改名漏改文档/漏入包）。"""
    bad = []
    txt = read(os.path.join(root, 'SKILL.md'))
    names = set(re.findall(r'`([A-Za-z0-9_\-]+\.(?:sh|ps1|mjs))`', txt))
    for n in sorted(names):
        cands = [os.path.join(root, 'scripts', n), os.path.join(root, 'scripts', 'legacy', n)]
        if not any(os.path.exists(c) for c in cands):
            bad.append('SKILL.md 引用了不存在的脚本: %s' % n)
    return bad


def c_no_grep_c(root):
    bad = []
    for p in walk_files(os.path.join(root, 'scripts')):
        if not p.endswith(('.sh', '.ps1')):
            continue
        for i, l in enumerate(read(p).splitlines(), 1):
            if l.lstrip().startswith('#'):
                continue
            if re.search(r'grep\s+-c\b.*\|\|\s*echo\s+0', l):
                bad.append('%s:%d %s' % (os.path.relpath(p, root), i, l.strip()[:70]))
    return bad


def c_tsv_contract(root):
    bad = []
    body = strip_comments(read(os.path.join(root, 'scripts', '_common.sh')))
    if 'steps.tsv' not in body:
        bad.append('_common.sh 未定义 steps.tsv')
    if not re.search(r"printf\s+'%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n'", body):
        bad.append('st_end 未按 6 列写 steps.tsv')
    for v in ('PASS', 'FAIL', 'SKIP', 'WAIT_USER'):
        if v not in body:
            bad.append('st_end 判定缺少取值 %s' % v)
    return bad


def c_ssh_4steps(root):
    bad = []
    body = strip_comments(read(os.path.join(root, 'scripts', 'deploy-1-ssh.sh')))
    for tag in ('1a', '1b', '1c', '1d'):
        if tag not in body:
            bad.append('deploy-1-ssh.sh 缺 %s 段' % tag)
    # 分段结构性断言：1a（判）与 1d（验）都必须用新建连接实测，不能是常量或注释
    seg1a = re.search(r'st_begin 1a\b(.*?)\n\s*st_end', body, re.S)
    if not seg1a or 'channel_ready' not in seg1a.group(1):
        bad.append('1a 段未用 channel_ready 做判据')
    seg1d = re.search(r'st_begin "1d[^\n]*\n(.*?)\n\s*st_end', body, re.S)
    if not seg1d or 'channel_ready' not in seg1d.group(1):
        bad.append('1d 段未用 channel_ready 做验证')
    if 'while' not in body or 'prepare_key' not in body:
        bad.append('缺"验证失败回 1b"的循环/备钥调用')
    return bad


def c_probe_count(root):
    bad = []
    body = strip_comments(read(os.path.join(root, 'scripts', 'deploy-5-verify.sh')))
    if not re.search(r"grep\s+-oE\s+'\[0-9\]\+/\[0-9\]\+'", body):
        bad.append('未解析真实 x/y 计数')
    if 'EXP_TOTAL' not in body or 'EXP_SKIP' not in body:
        bad.append('缺 EXP_TOTAL/EXP_SKIP 项数断言')
    if 'SKIP deep' not in body:
        bad.append('未解析 SKIP deep（分级失效=静默少测）')
    # 结构化：每个「取计数」分支的 else 必须真的把问题记进 PROBLEMS（不是靠字样在场）
    blocks = re.findall(r'if \[ -n "\$PT" \]; then(.*?)else(.*?)fi', body, re.S)
    if not blocks:
        bad.append('找不到"有计数/无计数"分支结构（判据可能被改写）')
    else:
        if len(blocks) < 2:
            bad.append('计数分支 <2（冷跑与复用两条路都必须判）')
        for i, (thenb, elseb) in enumerate(blocks, 1):
            if 'PROBLEMS' not in elseb:
                bad.append('第 %d 个计数分支的 else 未记 PROBLEMS（无计数照样 PASS=假绿）' % i)
            if 'PROBLEMS' in thenb:
                bad.append('第 %d 个分支误在 then 里记失败' % i)
    # 复用路径必须读「上一轮日志目录」：只记 pkg+epoch 时，新 run_dir 下无日志 →
    # 三探针全 meter-missing → 0/0 假 FAIL（2026-11-16 实测）
    if 'logd=' not in body:
        bad.append('stamp 未记 logd（复用会读空目录）')
    if not re.search(r'"\$S_LOGD/\$pr\.log"', body):
        bad.append('复用分支未从 S_LOGD 读日志')
    return bad


def c_keep_default(root):
    bad = []
    body = strip_comments(read(os.path.join(root, 'scripts', 'undeploy-3-ssh.sh')))
    if not re.search(r'^REMOVE="no"', body, re.M):
        bad.append('undeploy-3-ssh.sh 默认 --remove-ssh-tunnel 不是 no')
    if '--remove-ssh-tunnel' not in body:
        bad.append('未识别 --remove-ssh-tunnel 参数')
    return bad


def c_payload(root):
    body = strip_comments(read(os.path.join(root, 'scripts', 'ps-run.sh')))
    m = re.search(r'^_payload\(\)\s*\{(.*?)\}', body, re.S | re.M)
    if not m:
        return ['ps-run.sh 无 _payload 函数']
    inner = m.group(1)
    bad = []
    if 'VM_PS_TIMEOUT' not in inner:
        bad.append('_payload 未注入 VM_PS_TIMEOUT（载荷预算回退 → 假红 F-26）')
    if 'VM_SSH_EXEC_TIMEOUT' not in inner:
        bad.append('_payload 未覆盖 VM_SSH_EXEC_TIMEOUT')
    return bad


def c_parallel(root):
    bad = []
    body = strip_comments(read(os.path.join(root, 'scripts', 'deploy.sh')))
    pats = [('A', r'stage\s+"A[^"]*"\s+1\s+2'),
            ('B', r'stage\s+"B[^"]*"\s+3\s+4'),
            ('C', r'stage\s+"C[^"]*"\s+5\s*$')]
    for tag, pat in pats:
        if not re.search(pat, body, re.M):
            bad.append('阶段 %s 未按预期组合' % tag)
    return bad


def c_no_rebuild(root):
    bad = []
    for fn in ('undeploy-1-host.sh', 'undeploy-2-vm.sh', 'undeploy-3-ssh.sh'):
        body = strip_comments(read(os.path.join(root, 'scripts', fn)))
        for kw in ('channel.sh ensure', 'host-generate-key.sh', 'deploy-1-ssh.sh'):
            if kw in body:
                bad.append('%s 出现重建通道迹象: %s' % (fn, kw))
    return bad


def c_links(root):
    bad = []
    txt = read(os.path.join(root, 'SKILL.md'))
    for m in re.finditer(r'\[[^\]]*\]\(([^)#]+?)\)', txt):
        t = m.group(1).strip()
        if re.match(r'^(https?:|mailto:)', t):
            continue
        if not os.path.exists(os.path.normpath(os.path.join(root, t))):
            bad.append('SKILL.md 死链: %s' % t)
    return bad


def c_oneclick(root):
    p = os.path.join(root, 'scripts', 'winvm-sshd-oneclick.ps1')
    if not os.path.exists(p):
        return ['缺 winvm-sshd-oneclick.ps1']
    body = read(p)
    bad = []
    if 'InstallDir' not in body or 'SelfPathFinal' not in body:
        bad.append('缺自归位（InstallDir/SelfPathFinal）')
    if '$PublicKeyFile' not in body:
        bad.append('缺 -PublicKeyFile 回填')
    if not re.search(r'\[switch\]\$Rollback', body):
        bad.append('缺 -Rollback 开关')
    if 'winvm-sshd-oneclick.ps1' not in body:
        bad.append('缺固定留存路径字样')
    return bad


def c_vmcheck_assert(root):
    """4c 必须自己断言判据。

    vmcheck.ps1 是纯报告器（无退出码逻辑）⇒ 只判 ps-run 的 rc，等于「脚本跑完就 PASS」，
    拿不到 task_state/listen_count 也绿（v2.0.0 真机首跑实测假绿）。故：
    必须解析 JSON + 逐项断言；且不得回退成「把日志行摘录当判据」。
    """
    bad = []
    body = strip_comments(read(os.path.join(root, 'scripts', 'deploy-4-vm.sh')))
    if not re.search(r"""grep -o '\{\.\*\}'""", body):
        bad.append('4c 未从日志提取判据 JSON')
    if 'need_py' not in body:
        bad.append('4c 未声明 need_py（解析器依赖未门禁）')
    for k in ('task_state', 'listen_count', 'side_json', 'bridge_dir'):
        if k not in body:
            bad.append('4c 未断言 %s' % k)
    if '"FAIL|' not in body:
        bad.append('4c 无「断言失败」出口（无法 FAIL）')
    # 反向：判据不得取自日志摘录（老实现 st_end 0 PASS "$(grep -E 'listen_count' ...)"）
    if re.search(r"st_end 0 PASS \"\$\(grep", body):
        bad.append('4c 仍以日志摘录当判据（假绿回归）')
    return bad


CHECKS = [
    ('syntax', c_syntax), ('control', c_control), ('frontmatter', c_frontmatter),
    ('inventory', c_inventory), ('no-grep-c', c_no_grep_c), ('tsv-contract', c_tsv_contract),
    ('ssh-4-steps', c_ssh_4steps), ('probe-count', c_probe_count),
    ('keep-default', c_keep_default), ('payload', c_payload), ('parallel', c_parallel),
    ('no-rebuild', c_no_rebuild), ('links', c_links), ('oneclick', c_oneclick),
    ('vmcheck-assert', c_vmcheck_assert),
]


def run_all(root):
    total, fails, lines = 0, [], []
    for name, fn in CHECKS:
        total += 1
        try:
            bad = fn(root)
        except Exception as e:
            bad = ['assertion crashed: %r' % (e,)]
        if bad:
            fails.extend('%s: %s' % (name, b) for b in bad)
            lines.append('  [FAIL] %-14s %s' % (name, bad[0][:110]))
        else:
            lines.append('  [ ok ] %-14s' % name)
    return total, fails, lines


# ─────────────────────── 变异自证（注缺陷必须被抓） ───────────────────────
# 注入串分片构造：字面缺陷串若出现在本文件同一行，会被 no-grep-c 扫到自己（自伤）
_M1_TAIL = 'grep -c foo /dev/null'
_M1_OR = ' || echo 0'

MUTATIONS = [
    ('M1 grep-c 假红回归', 'scripts/_common.sh',
     "printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n'",
     "printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' ; X=$(" + _M1_TAIL + _M1_OR + ")"),
    ('M2 探针无计数不判FAIL', 'scripts/deploy-5-verify.sh',
     'PROBLEMS="$PROBLEMS $pr:no-count"', 'true'),
    ('M3 卸载默认拆通道', 'scripts/undeploy-3-ssh.sh', 'REMOVE="no"', 'REMOVE="yes"'),
    ('M4 载荷预算回退', 'scripts/ps-run.sh',
     '_payload() { VM_SSH_EXEC_TIMEOUT="$VM_PS_TIMEOUT" VM_SSH_TRIES=2 "$@"; }',
     '_payload() { "$@"; }'),
    ('M5 1a 判据改成常量', 'scripts/deploy-1-ssh.sh',
     'st_begin 1a "判断 host↔VM 免密通道"\nif channel_ready 5000; then',
     'st_begin 1a "判断 host↔VM 免密通道"\nif true; then'),
    ('M6 版本非 SemVer', 'SKILL.md', 'version: 2.0.0', 'version: 2.0'),
    # 4c 判据断言化是 v2.0.0 真机首跑抓到的假绿（vmcheck 纯报告器 + 只看 rc）。
    # 去掉解析器门禁 ⇒ vmcheck-assert 必须报「未声明 need_py」。
    ('M7 4c 判据退化为看 rc', 'scripts/deploy-4-vm.sh', 'need_py', 'true'),
]


def make_copy(src_root, dst_root):
    s = os.path.join(src_root, 'SKILL.md')
    if os.path.exists(s):
        shutil.copy2(s, os.path.join(dst_root, 'SKILL.md'))
    ignore = shutil.ignore_patterns('legacy', '__pycache__')
    for d in ('scripts', 'references'):
        sp = os.path.join(src_root, d)
        if os.path.isdir(sp):
            shutil.copytree(sp, os.path.join(dst_root, d), ignore=ignore, dirs_exist_ok=True)


def main():
    n, fails, lines = run_all(ROOT)
    print('\n'.join(lines))
    if MUTATE:
        print('\n== 变异自证 ==')
        caught = 0
        for label, rel, old, new in MUTATIONS:
            dst = os.path.join(WORK, 'mut-' + re.sub(r'\W+', '-', label))
            if not os.path.isdir(dst):
                os.makedirs(dst, exist_ok=True)
                make_copy(ROOT, dst)
            target = os.path.join(dst, rel)
            if not os.path.exists(target):
                print('  [MISS]   %-24s 目标不存在 %s' % (label, rel)); continue
            txt = read(target)
            if txt.count(old) != 1:
                print('  [MISS]   %-24s 注入点不唯一 count=%d' % (label, txt.count(old))); continue
            io.open(target, 'w', encoding='utf-8').write(txt.replace(old, new, 1))
            _n, mfails, _l = run_all(dst)
            io.open(target, 'w', encoding='utf-8').write(txt)   # 还原，不删目录
            if mfails:
                caught += 1
                print('  [CAUGHT] %-24s <- %s' % (label, mfails[0][:88]))
            else:
                print('  [MISSED] %-24s 注入后仍全绿 ⇒ 该断言是假绿' % label)
        verdict = 'ALL_CAUGHT' if caught == len(MUTATIONS) else 'NOT_ALL_CAUGHT'
        print('MUTATION_RESULT=%s %d/%d' % (verdict, caught, len(MUTATIONS)))
        if caught != len(MUTATIONS):
            fails = list(fails) + ['mutations %d/%d' % (caught, len(MUTATIONS))]
    io.open(OUT, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
    print('\nSELFCHECK=%s checks=%d fails=%d' % ('ALL_GREEN' if not fails else 'FAILED', n, len(fails)))
    if fails:
        print('WORK_DIR=' + WORK)
        for f in fails[:20]:
            print('  - ' + f)
    sys.exit(0 if not fails else 1)


main()
PYEOF
