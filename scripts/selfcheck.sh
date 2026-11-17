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
#  19  multi-source  一次性脚本四源候选链：宿主逐个探测 + VM 侧 foreach 循环兜底
#  20  backend-default 通道后端默认 auto（v2.0.0 重构退化成 key 的真机事故）
#  21  iex-safe      载荷无 BOM、首行非 #requires、1c irm 备选做换行归一化
#
# 用法：
#   bash scripts/selfcheck.sh                  # 末行 SELFCHECK=ALL_GREEN checks=N fails=0
#   bash scripts/selfcheck.sh --mutate         # 变异自证（每组缺陷必须被对应断言抓到）
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
    # -AllowFrom 在 VM 侧是防火墙白名单。默认给 $VM_HOST（VM 自身 IP）=
    # 只放行 VM 自己，宿主连不上（真机实测：连接超时）。
    if 'VM_ALLOW_FROM:-$VM_HOST' in body:
        bad.append('ALLOW_FROM 默认 $VM_HOST（VM 自身 IP）→ 防火墙白名单把宿主挡死')
    if 'allow_arg' not in body:
        bad.append('1c 未把 -AllowFrom 做成可选（无 allow_arg 条件拼接）')
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
    # 僵尸服务壳：-Rollback 卸掉 OpenSSH.Server 能力后，sshd 服务注册项仍残留，
    # 此时 sshd.exe 已不在。只看 Get-Service 会误判"已安装"→ Start-Service 必失败。
    seg = re.search(r'function Ensure-OpenSSHServer\s*\{[\s\S]*?\n\}\n', body)
    if not seg:
        bad.append('找不到 Ensure-OpenSSHServer 函数')
    else:
        s = seg.group(0)
        # 必须是「真的去探 sshd.exe」，不能只声明路径变量（变异把探测改成 $true 时会被抓）
        if 'Test-Path $sshdExeProbe' not in s:
            bad.append('Ensure-OpenSSHServer 未真正探测 sshd.exe（僵尸服务壳会被误判已安装）')
        if 'sc.exe delete sshd' not in s:
            bad.append('Ensure-OpenSSHServer 未清壳（sc.exe delete sshd）')
    # irm|iex 自落盘（v2.0.3）：$PSCommandPath 为空时必须能把自己下载到 InstallDir，
    # 否则通道建好了却没有 -Rollback 可执行文件 ⇒ 卸载只能靠人肉重下。
    if '[string[]]$SelfUrl' not in body:
        bad.append('缺 -SelfUrl 参数（irm|iex 自落盘源）')
    if "SelfStageMode = 'fetch'" not in body:
        bad.append('缺 irm|iex 自落盘分支（SelfStageMode=fetch）')
    if not re.search(r'Invoke-WebRequest[^\n]*-OutFile \$script:SelfPathFinal', body):
        bad.append('自落盘分支没有真正落盘（缺 -OutFile $script:SelfPathFinal）')
    if '$NoSelfFetch' not in body:
        bad.append('缺 -NoSelfFetch 离线开关')
    # 相对路径 .\winvm-sshd-oneclick.ps1 在非同一 cwd 下必然找不到 ⇒ 提示必须用绝对路径
    if re.search(r'-File \.\\winvm-sshd-oneclick\.ps1', body):
        bad.append('尾部提示仍用相对路径 .\\winvm-sshd-oneclick.ps1（换个 cwd 就失效）')
    # MSI 缓存（v2.0.3）：卸载→重建会反复下载同一个 OpenSSH MSI（真机 2.9s~60.2s 波动），
    # 是阶段 2 唯一的分钟级单点。缓存必须**真接进下载前判据**，否则等于白写。
    for fn in ('function Restore-MsiCache', 'function Save-MsiCache'):
        if fn not in body:
            bad.append('缺 %s（重建通道会重复下载 MSI）' % fn)
    if '$cacheHit = Restore-MsiCache -Cache $cacheMsi -Dest $MsiFile' not in body:
        bad.append('MSI 缓存未接进下载前判据（cacheHit 恒 false）')
    if '$NoMsiCache' not in body:
        bad.append('缺 -NoMsiCache 逃生开关')
    if "'cache\\OpenSSH-Win64.msi'" not in body:
        bad.append('MSI 缓存路径不在 InstallDir\\cache 下（-Rollback 后应仍在）')
    return bad


def c_tunnel_signal(root):
    """第 3 步判据必须是「隧道本身」，不能是 health。

    health 是 **VM 端 winvm service** 的口径：从零部署时 VM 端服务由第 4 步并行安装，
    第 3 步那一刻 18443 后面没人应答 ⇒ health 必然 000。把它当门槛 = 从零部署假 FAIL
    （2026-11-16 真机实测：3c 空等 123s 后判 FAIL，而 4b/4c 全 PASS）。
    正确判据：本地端口有 listener（port_listening）+ daemon 存活（tunnel_pid）。
    """
    p = os.path.join(root, 'scripts', 'deploy-3-tunnel.sh')
    if not os.path.exists(p):
        return ['缺 deploy-3-tunnel.sh']
    body = strip_comments(read(p))
    bad = []
    parts = body.split('st_begin 3c')
    if len(parts) < 2:
        bad.append('找不到 3c 段')
        return bad
    seg = parts[-1]
    if 'port_listening' not in seg:
        bad.append('3c 未用 port_listening 判隧道（health 是 VM 端服务口径，从零部署必为 000）')
    if 'tunnel_pid' not in seg and 'tunnel_alive' not in seg:
        bad.append('3c 未校验 daemon 存活（只听端口会被"监听但转发已死"骗过）')
    if re.search(r'if\s*\[\s*"\$HC"\s*!=\s*"200"\s*\]', seg):
        bad.append('3c 仍把 health=200 当门槛（从零部署时必然 000 → 假 FAIL）')
    # tunnel.pid 是 JSON：任何 `tr -dc '0-9'` 解析都会把数字拼成一串错误 pid。
    if re.search(r"tunnel\.pid.*tr -dc", body):
        bad.append("用 tr -dc 解析 tunnel.pid（它是 JSON，会拼成错误 pid → kill -0 恒失败）")
    return bad


def c_health_code(root):
    """health_code 必须恒为 3 字符。

    curl -w '%{http_code}' 在连不上时**自己就吐 "000"** 且 rc!=0，
    再 `|| echo 000` 会拼成 "000000"（同 grep -c 双值坑的变体），
    于是调用方 `= "000"` 判不通永不成立 ⇒ undeploy 1c 假 FAIL、阶段 A 中断。
    """
    bad = []
    body = strip_comments(read(os.path.join(root, 'scripts', '_common.sh')))
    m = re.search(r'health_code\(\)\s*\{(.*?)\n\}', body, re.S)
    if not m:
        return ['_common.sh 找不到 health_code() 定义']
    fn = m.group(1)
    if re.search(r'\|\|\s*echo\s+0+', fn):
        bad.append('health_code 里 `|| echo 000` 会与 curl 自带 000 拼成 000000')
    if not re.search(r"printf '000'", fn):
        bad.append('health_code 缺「不通→000」归一分支')
    # 行为断言：肯定不通的端口必须恰好返回 000（比字符串匹配强）
    try:
        out = subprocess.run(['bash', '-c', '. "%s/scripts/_common.sh"; health_code 1 2' % root],
                             capture_output=True, text=True, timeout=25)
        got = (out.stdout or '').strip()
    except Exception as exc:  # noqa: BLE001
        got = 'ERR:%s' % exc
    if got != '000':
        bad.append('health_code 不通端口实测=%r（须恰为 000，不许拼长）' % got)
    return bad


def c_rollback_path(root):
    """拆通道必须真能完成，不能"给一条指向不存在文件的命令"。

    a) VM 上缺 oneclick 脚本时，3b 要**就地下载**再 -Rollback；
    b) 回滚基线在 1a 判 READY 与 1b 备钥两条路上都要写，
       否则「通道本来就活着」的机器永远无基线，undeploy 只能保守不删钥。
    """
    bad = []
    u3 = strip_comments(read(os.path.join(root, 'scripts', 'undeploy-3-ssh.sh')))
    m = re.search(r'st_begin 3b "VM SYSTEM post 动作(.*?)\n\s*st_end [^\n]*SKIP "post 动作未成功', u3, re.S)
    fn = m.group(1) if m else ''
    if not m:
        bad.append('undeploy-3 找不到 3b「SYSTEM post 动作」段')
    if 'Invoke-WebRequest' not in fn:
        bad.append('3b 缺「VM 上无脚本就地下载」分支（用户会敲一条指向不存在文件的命令）')
    if 'sshd_script_url' not in fn:
        bad.append('3b 未复用 sshd_script_url 解析下载源（应与第 1 步同源）')
    if 'POST_ROLLBACK_SCHEDULED' not in fn:
        bad.append('3b 缺 SYSTEM 任务成功判据')

    d1 = strip_comments(read(os.path.join(root, 'scripts', 'deploy-1-ssh.sh')))
    seg1a = re.search(r'st_begin 1a\b(.*?)\n\s*st_end', d1, re.S)
    seg1b = re.search(r'prepare_key\(\)\s*\{(.*?)\n\}', d1, re.S)
    for tag, seg in (('1a READY 路径', seg1a), ('1b 备钥路径', seg1b)):
        if not seg:
            bad.append('deploy-1 找不到 %s 段落' % tag)
        elif 'write_baseline_if_absent' not in seg.group(1):
            bad.append('%s 未写回滚基线（undeploy 将无从判断钥归属）' % tag)

    # sshd_script_url 必须自给自足：步脚本可单独重跑，调用方未必跑过 need_py
    cm = strip_comments(read(os.path.join(root, 'scripts', '_common.sh')))
    fm = re.search(r'sshd_script_url\(\)\s*\{(.*?)\n\}', cm, re.S)
    if not fm:
        bad.append('_common.sh 找不到 sshd_script_url()')
    else:
        # python3 兜底查找按整个文件判（need_py 里就有），不绑单个函数。
        if 'command -v python3' not in cm:
            bad.append('_common.sh 缺 python3 兜底查找（无 PY 时 URL 解析静默失败）')
    # 裸用 $PY 的检查必须覆盖整个文件：tar 解析拆函数后单看 sshd_script_url 会漏（M10 假绿实证）。
    if re.search(r'(?<!\$\{)"\$PY"', cm):
        bad.append('_common.sh 裸用 "$PY"（set -u 下 unbound variable，URL 静默变空）')
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


def c_multi_source(root):
    """远端一次性脚本必须多源可取——这是部署/拆通道最常见的「资源下不下来」死点。

    a) _common.sh 提供候选列表 + 逐个可达性探测 + PS 数组拼接（不许多源退化成单源）；
    b) deploy-1 给用户的命令内含 foreach 多源循环，全失败必须显式抛错；
    c) undeploy-3 的 PS 模板同样多源；
    d) SKILL.md 不得再声称源仓 private（2026-11-17 已转 public），且必须记载 raw 源。
    """
    bad = []
    cm = strip_comments(read(os.path.join(root, 'scripts', '_common.sh')))
    for fn in ('sshd_script_urls()', 'sshd_script_srcs_ps()'):
        if fn not in cm:
            bad.append('_common.sh 缺 %s' % fn)
    if 'raw.githubusercontent.com' not in cm:
        bad.append('_common.sh 候选链缺 GitHub raw（public 后该源最稳）')
    # 两仓彻底解耦（2026-11-17 用户裁定）：oneclick 只从技能仓取。
    # 母项目 release 资产既造成跨仓耦合，又有「资产滞后于脚本」的实测陷阱。
    if 'workbuddy-virtual-win-plugin' in cm:
        bad.append('_common.sh 的 oneclick 候选链仍指向母项目 release（技能仓已 public，应只从技能仓取）')
    if 'releases/latest' in cm:
        bad.append('_common.sh 仍在解母项目 releases/latest（public 后不需要，且多一个网络单点）')
    m = re.search(r'sshd_script_url\(\)\s*\{(.*?)\n\}', cm, re.S)
    body = m.group(1) if m else ''
    if 'while IFS= read -r u' not in body:
        bad.append('sshd_script_url 未逐个探测候选（直接取第一条=单源退化）')
    if 'url_reachable' not in body:
        bad.append('sshd_script_url 未做可达性探测')

    d1 = strip_comments(read(os.path.join(root, 'scripts', 'deploy-1-ssh.sh')))
    # 注：命令行落在 bash heredoc 里，源码含 `\$` 转义（运行期还原成 `$`），
    # 故断言只锚不含 `$` 的片段，避免被转义写法绑架。
    if 'foreach(' not in d1:
        bad.append('deploy-1 用户命令不是多源循环（VM 侧单源失败即卡死）')
    if '@($srcs)' not in d1:
        bad.append('deploy-1 命令未内联候选数组（@($srcs) 缺失）')
    if d1.count('@($srcs)') < 2:
        bad.append('deploy-1 只有一条命令内联候选（-File 主路径与 irm 备选都要多源）')
    if 'DOWNLOAD_ALL_FAILED' not in d1:
        bad.append('deploy-1 缺「全部源失败」显式出口')

    u3 = strip_comments(read(os.path.join(root, 'scripts', 'undeploy-3-ssh.sh')))
    if '$src = @(__SRCS__)' not in u3:
        bad.append('undeploy-3 下载模板未内联多源数组')
    if 'DOWNLOAD_FAILED' not in u3:
        bad.append('undeploy-3 缺下载失败出口')

    sk = strip_comments(read(os.path.join(root, 'SKILL.md')))
    if 'private' in sk:
        bad.append('SKILL.md 仍含 private 表述（源仓 2026-11-17 已转 public）')
    if 'raw.githubusercontent.com' not in sk:
        bad.append('SKILL.md 未记载 GitHub raw 源（文档与实现脱节）')
    return bad


def c_backend_default(root):
    """通道后端默认值必须是 auto —— v2.0.0 重构把它退化成 key 的真机事故。

    现象：鸿蒙宿主机上每一步都先走 OpenSSH 二进制，认证相位挂 rc=124 ⇒
    vm_channel_probe 判 NO_CHANNEL；同一秒 `ssh2-conn.mjs ping` 返 pong ready、
    裸 TCP 190ms 就收到 banner。根因是重构把 `:-ssh2` 写成了 `:-key`。
    """
    bad = []
    vc = strip_comments(read(os.path.join(root, 'scripts', 'vm-conn.sh')))
    m = re.search(r'^VM_SSH_BACKEND="\$\{VM_SSH_BACKEND:-([A-Za-z0-9_]+)\}"', vc, re.M)
    if not m:
        bad.append('vm-conn.sh 未声明 VM_SSH_BACKEND 默认值（调用方须能零配置工作）')
        return bad
    default = m.group(1)
    if default != 'auto':
        bad.append('VM_SSH_BACKEND 默认=%s（必须 auto：ssh2 优先、无 node 降级二进制）' % default)
    # 新旧默认值不许互相矛盾：legacy 层历史上就是 ssh2。
    for rel in ('scripts/legacy/context.sh', 'scripts/legacy/channel.sh',
                'scripts/legacy/roundtrip.sh'):
        p = os.path.join(root, rel)
        if not os.path.exists(p):
            continue
        body = strip_comments(read(p))
        if 'VM_SSH_BACKEND:-ssh2' not in body and 'VM_SSH_BACKEND:=ssh2' not in body:
            bad.append('%s 不再默认 ssh2（新旧后端默认互相矛盾）' % rel)
    # auto 必须真的能降级：无 node 时 _use_ssh2 返回 1，二进制路径仍可用。
    if '_use_ssh2' not in vc:
        bad.append('vm-conn.sh 缺 _use_ssh2（auto 降级判定不存在）')
    return bad


def c_output_hygiene(root):
    """输出层两个真实误判（2026-11-17 真机实测）：

    a) 第 1 步打印完命令后 rc=2 —— 那是「等用户去 VM 粘贴」，被汇总成 DEPLOY=FAIL 会
       让人以为部署失败，实际是正常中间态；
    b) 步脚本与编排层都调 steps_report ⇒ 同一张计时表打印 2~3 遍，把真正的判据行挤走。
    """
    bad = []
    d = strip_comments(read(os.path.join(root, 'scripts', 'deploy.sh')))
    if 'DEPLOY=NEED_USER_ACTION' not in d:
        bad.append('deploy.sh 未把 rc=2 标成 NEED_USER_ACTION（会被误读为部署失败）')
    cm = strip_comments(read(os.path.join(root, 'scripts', '_common.sh')))
    if 'VMDEPLOY_STEPS_QUIET' not in cm:
        bad.append('steps_report 未支持编排期静音（计时表会重复打印）')
    for f in ('deploy.sh', 'undeploy.sh'):
        t = strip_comments(read(os.path.join(root, 'scripts', f)))
        if 'export VMDEPLOY_STEPS_QUIET=1' not in t:
            bad.append('%s 未置 VMDEPLOY_STEPS_QUIET=1（子脚本会再打一遍计时表）' % f)
    return bad


def c_iex_safe(root):
    """irm|iex 兼容性（2026-11-17 真机实测的三个死因，逐个锁死）。

    用户不想先落盘时用备选命令直跑，PS5.1 的解析器在这条路径上比 `-File` 严格：
      a) 文件带 UTF-8 BOM ⇒ 解析器不认首行是 #requires，把它当普通注释，
         于是 param 块不再位于「脚本参数区」，报
         「意外的属性 CmdletBinding」/「表达式或语句中包含意外的标记 param」——
         脚本一行都没执行，用户只看到满屏红字。
      b) 首行 #requires ⇒ scriptblock 上下文不保证支持，统一改运行期版本检查。
      c) Invoke-RestMethod 对 text/plain 可能返回 string[]，
         [scriptblock]::Create 会按 $OFS（空格）拼成**一行** ⇒ 同样解析失败。
         故命令必须先 [string]::Join([char]10, ...) 归一化。
    """
    bad = []
    p = os.path.join(root, 'scripts', 'winvm-sshd-oneclick.ps1')
    raw = open(p, 'rb').read()
    if raw[:3] == b'\xef\xbb\xbf':
        bad.append('winvm-sshd-oneclick.ps1 带 UTF-8 BOM（irm|iex 下 Create 解析必挂）')
    first = raw.split(b'\n', 1)[0].strip().lower()
    if first.startswith(b'#requires'):
        bad.append('oneclick 首行是 #requires（scriptblock 场景不保证支持，改运行期检查）')
    d1 = read(os.path.join(root, 'scripts', 'deploy-1-ssh.sh'))
    if '[string]::Join([char]10' not in d1:
        bad.append('1c 的 irm 备选缺换行归一化（irm 返回 string[] 时会被拼成一行）')
    return bad


CHECKS = [
    ('syntax', c_syntax), ('control', c_control), ('frontmatter', c_frontmatter),
    ('inventory', c_inventory), ('no-grep-c', c_no_grep_c), ('tsv-contract', c_tsv_contract),
    ('ssh-4-steps', c_ssh_4steps), ('probe-count', c_probe_count),
    ('keep-default', c_keep_default), ('payload', c_payload), ('parallel', c_parallel),
    ('no-rebuild', c_no_rebuild), ('links', c_links), ('oneclick', c_oneclick),
    ('vmcheck-assert', c_vmcheck_assert),
    ('health-code', c_health_code), ('rollback-path', c_rollback_path),
    ('tunnel-signal', c_tunnel_signal), ('multi-source', c_multi_source),
    ('backend-default', c_backend_default), ('output-hygiene', c_output_hygiene),
    ('iex-safe', c_iex_safe),
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

_CUR_VER = (re.search(r'^version:\s*(\S+)', read(os.path.join(ROOT, 'SKILL.md')), re.M) or [None, '2.0.2'])[1]

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
    # 版本号会被升版改掉 ⇒ 注入点必须现读，否则每次升版 M6 都 MISS（门禁自伤）。
    ('M6 版本非 SemVer', 'SKILL.md', 'version: ' + _CUR_VER, 'version: 2.0'),
    # 4c 判据断言化是 v2.0.0 真机首跑抓到的假绿（vmcheck 纯报告器 + 只看 rc）。
    # 去掉解析器门禁 ⇒ vmcheck-assert 必须报「未声明 need_py」。
    ('M7 4c 判据退化为看 rc', 'scripts/deploy-4-vm.sh', 'need_py', 'true'),
    # irm|iex 自落盘：把「落到 InstallDir」改成「落到 TEMP」⇒ oneclick 断言必须报未真正落盘。
    ('M17 irm 自落盘写错位置', 'scripts/winvm-sshd-oneclick.ps1',
     '-OutFile $script:SelfPathFinal -TimeoutSec $tmo',
     '-OutFile (Join-Path $env:TEMP \'wb-self.ps1\') -TimeoutSec $tmo'),
    # MSI 缓存被短路：判据恒 false ⇒ 缓存白写，重建仍要下载。
    ('M20 MSI 缓存被短路', 'scripts/winvm-sshd-oneclick.ps1',
     'if (-not $NoMsiCache) { $cacheHit = Restore-MsiCache -Cache $cacheMsi -Dest $MsiFile }',
     'if ($false) { $cacheHit = $false }'),
    # 两仓解耦：把母项目 release 源塞回候选链 ⇒ 必须被 multi-source 抓到。
    ('M19 oneclick 回退到母项目源', 'scripts/_common.sh',
     'for u in "$gitee_raw" "$gh_raw"; do',
     'for u in "$gitee_raw" "https://gitee.com/athronix/workbuddy-virtual-win-plugin/releases/download/V1.4.30/winvm-sshd-oneclick.ps1"; do'),
    # rc=2（等用户粘贴）被标成 FAIL：真机上极易被当成部署失败去排障。
    ('M18 rc=2 误标为 FAIL', 'scripts/deploy.sh',
     'echo "DEPLOY=NEED_USER_ACTION rc=2', 'echo "DEPLOY=FAIL rc=2'),
    # undeploy 1c 假 FAIL 的真因：curl 自带 000 + `|| echo 000` ⇒ "000000"。
    ('M8 health_code 双值回归', 'scripts/_common.sh',
     "*) printf '000' ;;", "*) printf '000'; printf '000' ;;"),
    # 拆通道时 VM 上没脚本 ⇒ 必须下载；退化成就地放弃会打印死命令。
    ('M9 拆通道缺脚本不下载', 'scripts/undeploy-3-ssh.sh',
     'Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $rb',
     "Write-Output 'SKIP_DOWNLOAD'"),
    # 步脚本可单独重跑 ⇒ 公共函数不许依赖调用方的 PY 初始化。
    ('M10 公共函数裸用 $PY', 'scripts/_common.sh', 'for p in "${PY:-}"', 'for p in "$PY"'),
    # -AllowFrom 默认成 VM 自身 IP ⇒ 防火墙白名单把宿主挡死（真机实测超时）。
    ('M11 AllowFrom 默认 VM 自身IP', 'scripts/deploy-1-ssh.sh',
     'ALLOW_FROM="${VM_ALLOW_FROM:-}"', 'ALLOW_FROM="${VM_ALLOW_FROM:-$VM_HOST}"'),
    # -Rollback 卸能力后服务壳残留、sshd.exe 已没了；只看 Get-Service 就"跳过安装"必挂。
    ('M12 僵尸服务壳误判已安装', 'scripts/winvm-sshd-oneclick.ps1',
     'if (Test-Path $sshdExeProbe) {', 'if ($true) {'),
    # 从零部署时 health 必然 000（VM 端服务由第 4 步并行装）；3c 只听端口才是对的口径。
    ('M13 3c 退回只看 health', 'scripts/deploy-3-tunnel.sh',
     'if port_listening "$PORT"; then OK=1; break; fi',
     'HC0="$(health_code "$PORT" 6)"; [ "$HC0" = "200" ] && { OK=1; break; }'),
    # 多源退化成"盲选第一条"：拿不到可达性就发命令 ⇒ VM 侧 404 时用户彻底卡死。
    ('M14 多源退化为盲选首条', 'scripts/_common.sh',
     'url_reachable "$u" && {', ': && {'),
    # 命令内联空数组：foreach 空转，等于没下载。
    # 注入点必须唯一：1c 现在有两条命令（-File 主路径 + irm 备选）都含 $src=@($srcs)，
    # 用更长的串锚定主路径，否则变异因 count=2 而 MISS（门禁自伤）。
    ('M15 命令内联空候选数组', 'scripts/deploy-1-ssh.sh',
     '$src=@($srcs);\$ok=\$false;foreach(\$x in \$src)', '$src=@();\$ok=\$false;foreach(\$x in \$src)'),
    # 后端默认退化成 key：鸿蒙宿主机上每步都误报 NO_CHANNEL（rc=124 相位挂）。
    ('M16 后端默认退化为 key', 'scripts/vm-conn.sh',
     'VM_SSH_BACKEND="${VM_SSH_BACKEND:-auto}"', 'VM_SSH_BACKEND="${VM_SSH_BACKEND:-key}"'),
    # irm 备选命令把 #requires 当首行：scriptblock 上下文不保证支持，真机验证前必须拦住。
    ('M21 首行退回 #requires', 'scripts/winvm-sshd-oneclick.ps1',
     '<#\n  hos-winvm-ssh-tunnel', '#requires -Version 5.1\n<#\n  hos-winvm-ssh-tunnel'),
    # 去掉换行归一化：irm 返回 string[] 时 Create 拼成一行 ⇒ 满屏 ParseException。
    ('M22 irm 备选缺归一化', 'scripts/deploy-1-ssh.sh',
     r'\$s=[string]::Join([char]10,@(\$s));', ''),
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
