#!/usr/bin/env bash
# winvm-plugin-deploy · 自检门禁 (v1.8.0)
#
# 一个命令跑完本技能的全部可本地验证断言（不需要 VM、不碰通道）：
#   静态面 : bash -n / 控制字符 / frontmatter / V11 断言锚点 / 入包枚举 / 相对链接 / ASCII 载荷
#   行为面 : F-19 零插值 + EncodedCommand 解码 / F-20 有界幂等复跑 / F-21 严格判据 / F-22 密钥择优
#            F-23·F-24·F-25 动作级观测链（log_path 解析 / 空摘录归一 / 噪声白名单）
#   容器面 : git diff --check（非 git 环境自动 SKIP）
#
# 用法：bash scripts/selfcheck.sh             # 常规自检（15 项）
#       bash scripts/selfcheck.sh --mutate    # 变异自证：5 组历史缺陷必须全被抓住
#   退出码 0=全绿；1=有 FAIL；2=前置缺失（无 python3）
#   证据文件默认写到 ${SKILL_SELFCHECK_OUT:-$HOME/wbtmp/winvm-plugin-deploy-selfcheck.txt}
#   工作目录默认 ${TMPDIR:-$HOME/wbtmp}/skill-selfcheck-<pid>（/tmp 在本沙箱只读）
#   跑完保留工作区并把路径打在 WORK_DIR= 上；确需清理才传 SELFCHECK_CLEAN=1
#   （沙箱对批量删除有护栏，删目录会弹用户确认，故默认不删）
#
# 设计约束：本脚本自身也在被检查范围内（bash -n、控制字符、相对链接），
# 任何字面量都不得写成会被自身断言命中的形态。
set -u
SKILLDIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# ---- 渲染器解析（鸿蒙沙箱 / 常规 Linux 双兼容）----
_pick() { for c in "$@"; do [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }; done; return 1; }
PY="${PY:-$(_pick "$(command -v python3 2>/dev/null || true)" /data/service/hnp/bin/python3 /usr/bin/python3)}"
[ -n "$PY" ] || { echo "SELFCHECK=NO_PYTHON（缺 python3，无法自检）" >&2; exit 2; }
NODE="${NODE:-$(_pick "$(command -v node 2>/dev/null || true)" /data/storage/el1/bundle/libs/arm64/node/bin/node /usr/bin/node)}"
BASH_OK="${BASH_OK:-$(_pick /data/storage/el1/bundle/libs/arm64/bash/bin/bash "$(command -v bash 2>/dev/null || true)" /bin/bash)}"
[ -n "$BASH_OK" ] || BASH_OK=/bin/bash

WORK="${SELFCHECK_WORK:-${TMPDIR:-$HOME/wbtmp}/skill-selfcheck-$$}"
mkdir -p "$WORK" || { echo "SELFCHECK=NO_WORKDIR $WORK" >&2; exit 2; }

MODE="${1:-}"
if [ "$MODE" = "--mutate" ]; then
  "$PY" - "$SKILLDIR" "$BASH_OK" "$NODE" "$WORK" <<'MUTEOF'
"""把历史上每个真实缺陷注入技能副本，断言对应断言必须变 FAIL。
绿的实现跑在坏的树上=假绿；本模式证明自检断言确实可被证伪。

设计约束（实测踩过）：只克隆**一次**，每例改完用原位还原，不做「克隆→删→再克隆」。
原因=沙箱对批量删除有护栏（SAFE_DELETE_BULK_CONFIRM_REQUIRED，50 个/回合），
每轮整树克隆再删会累计越线，子进程被拦后异常退出、又没打印 FAIL，
表现为「静默 MISSED」——把环境限制误读成断言失效。"""
import os, shutil, subprocess, sys, time

SK, BASH, NODE, WORK = sys.argv[1:5]
# 唯一目录、全程零删除：沙箱对批量删除有护栏（>50 个/回合即拦），
# 删副本会连带把自检自己拦死。所以本模式只建不删，路径打在 MUT_DIR 上由使用者自行清理。
BASE = os.path.join(WORK, "mut-%d-%d" % (os.getpid(), int(time.time())))
os.makedirs(BASE, exist_ok=True)

CLONE = os.path.join(BASE, "skill")
shutil.copytree(SK, CLONE, ignore=shutil.ignore_patterns(".git", "dist", "__pycache__"))

TARGETS = ["scripts/ps-run.sh", "scripts/deploy.sh", "scripts/step.sh", "SKILL.md"]
PRISTINE = {t: open(os.path.join(CLONE, t), encoding="utf-8").read() for t in TARGETS}


def reset():
    for t in TARGETS:
        p = os.path.join(CLONE, t)
        cur = open(p, encoding="utf-8").read() if os.path.exists(p) else None
        if cur != PRISTINE[t]:
            open(p, "w", encoding="utf-8").write(PRISTINE[t])


def edit(rel, old, new):
    p = os.path.join(CLONE, rel)
    s = open(p, encoding="utf-8").read()
    assert s.count(old) == 1, "anchor %s count=%d" % (rel, s.count(old))
    open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))


def run(tag):
    r = subprocess.run([BASH, os.path.join(CLONE, "scripts", "selfcheck.sh")],
                       capture_output=True, text=True,
                       env=dict(os.environ,
                                SELFCHECK_WORK=os.path.join(BASE, "_w_" + tag),
                                SKILL_SELFCHECK_OUT=os.path.join(BASE, "_e_" + tag + ".txt")))
    fails = [l.split("  ")[1] for l in r.stdout.splitlines() if l.startswith("FAIL")]
    # 子进程非零退出却一行 FAIL 都没有 = 自检自身崩了（既不是绿，也不是断言命中）。
    # 必须显式暴露，否则会被误报成 MISSED、掩盖真实原因（本模式就是这么被坑过）。
    if r.returncode != 0 and not fails:
        tail = (r.stderr or "").strip().splitlines()
        fails = ["HARNESS_CRASH rc=%d %s" % (r.returncode, tail[-1][:140] if tail else "no stderr")]
    return r.returncode, fails


def m1():  # F-19：JS 串里重新插值 bash 变量
    edit("scripts/ps-run.sh",
         '_enc="$("$NODE" -e \'process.stdout.write(Buffer.from("Remove-Item -LiteralPath \\"" + '
         'process.argv[1] + "\\" -Force -ErrorAction SilentlyContinue","utf16le").toString("base64"))\' "$base")"',
         '_enc="$("$NODE" -e \'process.stdout.write(Buffer.from("Remove-Item -LiteralPath \\"${base}\\" '
         '-Force -ErrorAction SilentlyContinue","utf16le").toString("base64"))\')"')


def m2():  # F-21：判据函数体里放宽 BLOCKERS 闸
    edit("scripts/deploy.sh",
         '    && grep -q "BLOCKERS=none" "$LOGD/env-check.log" 2>/dev/null',
         "    && true")


def m3():  # F-24：空摘录不再归一为 -
    edit("scripts/step.sh",
         "  if [ -n \"$out\" ]; then printf '%s\\n' \"$out\"; else echo \"-\"; fi",
         "  printf '%s\\n' \"$out\"")


def m4():  # F-23：不再写动作日志索引
    edit("scripts/step.sh",
         "    printf '%s\\t%s\\n' \"$(date -u +%s)\" \"$step\" >> \"$RUN_DIR/logs/.index\"",
         "    : # no index")


def m5():  # frontmatter 版本号非 SemVer
    p = os.path.join(CLONE, "SKILL.md")
    s = open(p, encoding="utf-8").read()
    i = s.find("version:")
    j = s.find("\n", i)
    open(p, "w", encoding="utf-8").write(s[:i] + "version: 1.x" + s[j:])


MUT = [("M1 F-19 插值回归", m1, "F-19 ps-run zero-interpolation (code lines)"),
       ("M2 F-21 判据放宽", m2, "F-21 strict verdict"),
       ("M3 F-24 空摘录不归一", m3, "F-23/24/25 action-trace guard"),
       ("M4 F-23 无日志索引", m4, "F-23/24/25 action-trace guard"),
       ("M5 版本号非 SemVer", m5, "frontmatter name/version")]

print("=== baseline（未变异，必须 ALL_GREEN）===")
reset()
rc, fails = run("baseline")
print("  rc=%s fails=%s" % (rc, fails))
ok_all = (rc == 0 and not fails)

for name, fn, expect in MUT:
    print("=== %s ===" % name)
    reset()
    fn()
    rc, fails = run(name.split()[0])
    hit = expect in fails
    ok_all &= (rc != 0 and hit)
    print("  rc=%s fails=%s  expect=%r  %s" % (rc, fails, expect, "CAUGHT" if hit else "MISSED"))
    reset()

print("MUT_DIR=%s（取证副本保留在原地；确认结果后可自行删除整个目录）" % BASE)
print("MUTATION_RESULT=" + ("ALL_CAUGHT" if ok_all else "FAILED"))
sys.exit(0 if ok_all else 1)
MUTEOF
  rc=$?
  # 不清理 WORK：整树删除会撞沙箱批量删除护栏（且 rm shim 在鸿蒙沙箱可能是坏的）。
  # 取证副本路径由上面的 MUT_DIR 行给出。
  exit $rc
fi



"$PY" - "$SKILLDIR" "$BASH_OK" "$NODE" "$WORK" "${1:-}" <<'PYEOF'
import os, sys, glob, re, subprocess, shutil, datetime

SK, BASH, NODE, WORK, MODE = sys.argv[1:6]
PY = sys.executable
lines, fails = [], []


def chk(name, ok, detail=""):
    lines.append(("PASS" if ok else "FAIL") + "  " + name + (("  " + str(detail)) if detail else ""))
    if not ok:
        fails.append(name)


def skip(name, why):
    lines.append("SKIP  " + name + "  (" + why + ")")


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def rd(p):
    return open(p, encoding="utf-8", errors="replace").read()


sh = sorted(glob.glob(os.path.join(SK, "scripts", "*.sh")))

# ---------- 1 static: bash -n ----------
bad = []
for p in sh:
    r = run([BASH, "-n", p])
    if r.returncode:
        bad.append((os.path.basename(p), (r.stderr or r.stdout).strip()[:80]))
chk("bash -n all scripts", not bad, "total=%d fail=%s" % (len(sh), bad))

# ---------- 2 static: control chars (text files only; dist/*.zip is binary) ----------
TEXT_EXT = (".sh", ".mjs", ".js", ".md", ".tsv", ".ps1", ".json", ".txt", ".yaml", ".yml", ".example")
allf = [p for p in glob.glob(os.path.join(SK, "**", "*"), recursive=True)
        if os.path.isfile(p) and p.endswith(TEXT_EXT)]
bad = []
for p in allf:
    b = open(p, "rb").read()
    if any(x < 32 and x not in (9, 10, 13) for x in b):
        bad.append(os.path.relpath(p, SK))
chk("control chars zero", not bad, "files=%d bad=%s" % (len(allf), bad[:5]))

# ---------- 3 static: frontmatter ----------
fm = rd(os.path.join(SK, "SKILL.md"))[:2000]
name = re.search(r"^name:\s*(\S+)", fm, re.M)
ver = re.search(r"^version:\s*(\S+)", fm, re.M)
chk("frontmatter name/version",
    bool(name and ver and name.group(1) == "winvm-plugin-deploy" and re.match(r"^\d+\.\d+\.\d+$", ver.group(1))),
    "name=%s version=%s" % (name.group(1) if name else "?", ver.group(1) if ver else "?"))

# ---------- 4/5 V11 assertion anchors (release-time surface) ----------
skill_md = rd(os.path.join(SK, "SKILL.md"))
NEED_STR = ["URL 单指令入口", "winvm-plugin-deploy-skill.zip", "roundtrip.sh", "ROUNDTRIP_RESULT",
            "SSH 免密通道生命周期", "hos-winvm-ssh-tunnel", "INSTALL_PROMPT.md"]
missing = [s for s in NEED_STR if s not in skill_md]
chk("V11 SKILL.md string anchors", not missing, "missing=%s" % missing)

rel = lambda p: os.path.relpath(p, SK).replace(os.sep, "/")
entries = ["winvm-plugin-deploy/SKILL.md", "winvm-plugin-deploy/RELEASE-VERSION.txt"]
for sub in ("scripts", "references", "assets"):
    d = os.path.join(SK, sub)
    if os.path.isdir(d):
        for dp, _, fs in os.walk(d):
            for f in fs:
                entries.append("winvm-plugin-deploy/" + rel(os.path.join(dp, f)))
NEED_FILE = ["SKILL.md", "scripts/ssh2-conn.mjs", "scripts/undeploy.sh", "references/troubleshooting.md",
             "RELEASE-VERSION.txt", "scripts/roundtrip.sh", "scripts/probe-fresh.sh"]
missing = [x for x in NEED_FILE if "winvm-plugin-deploy/" + x not in entries]
chk("V11 package file anchors", not missing, "missing=%s" % missing)

# ---------- 6 packaging whitelist enumeration ----------
NEW = ["scripts/run-flow.sh", "scripts/context.sh", "scripts/action-report.sh", "scripts/action-catalog.tsv",
       "scripts/selfcheck.sh"]
missing = [x for x in NEW if "winvm-plugin-deploy/" + x not in entries]
badroot = [e for e in entries if not e.startswith("winvm-plugin-deploy/")]
chk("packaging whitelist captures new files", not missing and not badroot,
    "entries=%d missing=%s badroot=%d" % (len(entries), missing, len(badroot)))

# ---------- 7/8/9/10 code-level guards on driver scripts ----------
ps = rd(os.path.join(SK, "scripts", "ps-run.sh"))
code_ps = "\n".join(l for l in ps.splitlines() if not l.lstrip().startswith("#"))
# F-19 的要害是「清理串经 process.argv 传参 + EncodedCommand 生效」。注意 ${base} 本身在
# vmscp / -File 里是合法远端路径变量，不能 blanket 禁——只禁「JS 串里插值 ${base}」这一缺陷形态。
FORBID = ['LiteralPath "${base}"', 'LiteralPath \\"${base}']
chk("F-19 ps-run zero-interpolation (code lines)",
    "process.argv[1]" in code_ps and "-EncodedCommand ${_enc}" in code_ps
    and "Remove-Item -LiteralPath" in code_ps and not any(f in code_ps for f in FORBID),
    "argv=%s enc=%s" % ("process.argv[1]" in code_ps, "-EncodedCommand ${_enc}" in code_ps))

dp = rd(os.path.join(SK, "scripts", "deploy.sh"))
chk("F-20 bounded idempotent retry", "TRANSIENT_TRUNCATION" in dp and "RETRY" in dp,
    "TRANSIENT_TRUNCATION=%s RETRY=%s" % ("TRANSIENT_TRUNCATION" in dp, "RETRY" in dp))
# F-21: 断言必须落在**判据函数体**上。只查全文出现会被注释/echo 里的同名字面蒙混过去
# （变异测试 M2 实证：把函数体内的 BLOCKERS=none 改成 BLOCKERS=ok，全文断言仍绿）。
_m = re.search(r"_envcheck_ok\s*\(\)\s*\{(.*?)\n\}", dp, re.S)
_body = "\n".join(l for l in (_m.group(1) if _m else "").splitlines() if not l.lstrip().startswith("#"))
chk("F-21 strict verdict",
    bool(_m) and 'grep -q "ENV_PRECHECK=PASS"' in _body and 'grep -q "BLOCKERS=none"' in _body
    and "&&" in _body and dp.count("! _envcheck_ok") >= 1,
    "fn=%s pass=%s blockers=%s and=%s guard=%d"
    % (bool(_m), 'grep -q "ENV_PRECHECK=PASS"' in _body, 'grep -q "BLOCKERS=none"' in _body,
       "&&" in _body, dp.count("! _envcheck_ok")))
cx = rd(os.path.join(SK, "scripts", "context.sh"))
chk("F-22 key probe", "VM_KEY_PROBE" in cx and "READY" in cx)

# ---------- 11 F-19 EncodedCommand roundtrip (needs node) ----------
JS = ('process.stdout.write(Buffer.from("Remove-Item -LiteralPath \\"" + process.argv[1] + '
      '"\\" -Force -ErrorAction SilentlyContinue","utf16le").toString("base64"))')
if NODE and os.path.isfile(NODE):
    enc = run([NODE, "-e", JS, "vm-env-check.ps1"]).stdout.strip()
    dec = run([NODE, "-e", 'console.log(Buffer.from(process.argv[1],"base64").toString("utf16le"))',
               enc]).stdout.strip()
    chk("F-19 EncodedCommand decode",
        dec == 'Remove-Item -LiteralPath "vm-env-check.ps1" -Force -ErrorAction SilentlyContinue', dec)
else:
    skip("F-19 EncodedCommand decode", "no node")

# ---------- 12 C3.0 behavioural guard (4 falsifiable cases) ----------
G = os.path.join(WORK, "c30")
os.makedirs(G, exist_ok=True)
# 一例一目录、零删除：沙箱对批量删除有护栏（>50 个/回合即拦，见 C 表），
# 删文件既慢又会把自检自己拦死；unique 目录天然隔离，不需要清理。

src = rd(os.path.join(SK, "scripts", "deploy.sh"))
MARK = "STEP begin C3 3.0"
if src.count(MARK) != 1:
    chk("C3.0 four-case behavioural guard", False, "C3.0 anchor not unique")
else:
    tail = src[src.find(MARK):].splitlines()
    pass_i = next((i for i, l in enumerate(tail) if "STEP end C3 3.0 0 PASS" in l), None)
    end_i = next((i for i, l in enumerate(tail) if l == "fi" and pass_i is not None and i > pass_i), None)
    if pass_i is None or end_i is None:
        chk("C3.0 four-case behavioural guard", False, "C3.0 block not delimited")
    else:
        block = "\n".join(tail[:end_i + 1])
        SKEL = ('#!/usr/bin/env bash\nset -u\n_here="__G"\nPKG="__G"\nLOGD="__G"\nBASH_OK="__B"\n'
                'STEP() {\n  if [ "${1:-}" = "end" ]; then\n'
                '    echo "STEP_END rc=$4 result=$5 judged=$6" > "__G/step-result.txt"\n'
                '    echo "$6" > "__G/step-judged.txt"\n  fi\n}\n'
                '_step_log() { :; }\n_fail_note() { echo "$1" >> "__G/fail-notes.txt"; }\n'
                'export LOGD\n. "__G/block.sh"\necho "RETRY=$RETRY ERC=$ERC" > "__G/vars.txt"\n')
        FAKE = ('#!/usr/bin/env bash\nn=0; [ -f "__G/count" ] && n=$(cat "__G/count"); n=$((n+1)); '
                'echo "$n" > "__G/count"\ncase "$CASE_ID:$n" in\n'
                '  A:1) printf \'NODE_OK=true\\nCLI_OK=true\\nvmssh: ssh2 传输层失败\\n\' > "$LOGD/env-check.log"; exit 124;;\n'
                '  A:2) printf \'NODE_OK=true\\nCLI_OK=true\\nENV_PRECHECK=PASS\\nBLOCKERS=none\\n\' > "$LOGD/env-check.log"; exit 0;;\n'
                '  B:*) printf \'NODE_OK=true\\nCLI_OK=true\\nENV_PRECHECK=FAIL\\nBLOCKERS=none\\n\' > "$LOGD/env-check.log"; exit 0;;\n'
                '  C:*) printf \'NODE_OK=true\\nCLI_OK=true\\nENV_PRECHECK=PASS\\nBLOCKERS=codebuddy-login\\n\' > "$LOGD/env-check.log"; exit 0;;\n'
                '  D:*) printf \'NODE_OK=false\\nCLI_OK=true\\n\' > "$LOGD/env-check.log"; exit 124;;\n'
                '  *) echo "unexpected CASE_ID/call $CASE_ID:$n" >&2; exit 99;;\nesac\n')
        CASES = [("A", "1", "PASS"), ("B", "0", "FAIL"), ("C", "0", "FAIL"), ("D", "0", "FAIL")]
        allok = True
        for cid, retry, result in CASES:
            Gc = os.path.join(G, cid)
            os.makedirs(Gc, exist_ok=True)
            open(os.path.join(Gc, "block.sh"), "w", encoding="utf-8").write(block + "\n")
            open(os.path.join(Gc, "skeleton.sh"), "w", encoding="utf-8").write(
                SKEL.replace("__G", Gc).replace("__B", BASH))
            open(os.path.join(Gc, "ps-run.sh"), "w", encoding="utf-8").write(FAKE.replace("__G", Gc))
            os.chmod(os.path.join(Gc, "ps-run.sh"), 0o755)
            e = dict(os.environ, CASE_ID=cid, G=Gc, LOGD=Gc, SELFCHECK_GUARD="1")
            p = run([BASH, os.path.join(Gc, "skeleton.sh")], env=e)
            verdict = open(os.path.join(Gc, "step-result.txt"), encoding="utf-8").read() if os.path.exists(
                os.path.join(Gc, "step-result.txt")) else ""
            v = open(os.path.join(Gc, "vars.txt"), encoding="utf-8").read() if os.path.exists(
                os.path.join(Gc, "vars.txt")) else ""
            got_retry = v.split("RETRY=")[1].split()[0] if "RETRY=" in v else "?"
            got_result = verdict.split("result=")[1].split()[0] if "result=" in verdict else "?"
            ok = (got_retry == retry and got_result == result)
            allok &= ok
            if not ok:
                lines.append("      · CASE %s FAIL retry=%s(exp %s) result=%s(exp %s) rc=%s"
                             % (cid, got_retry, retry, got_result, result, p.returncode))
        chk("C3.0 four-case behavioural guard", allok, "cases=4")

# ---------- 13 F-23/F-24/F-25 action-trace guard (4 cases) ----------
H = os.path.join(WORK, "trace")
shutil.rmtree(H, ignore_errors=True)
os.makedirs(H, exist_ok=True)
STEP = os.path.join(SK, "scripts", "step.sh")
env = dict(os.environ, VMDEPLOY_RUN_DIR=H, PY=PY, NODE=NODE or "")


def step(*a, stdin=None):
    return run([BASH, STEP, *a], env=env, input=stdin)


def lastrow():
    rows = rd(os.path.join(H, "actions.tsv")).splitlines()
    return dict(zip(rows[0].split("\t"), rows[-1].split("\t")))


ok = True
step("begin", "C3", "3.0", "ENV_PRECHECK")
step("log", "env-check", stdin="NODE_OK=true\nCLI_OK=true\nvmssh: ssh2 传输层失败 rc=124（3 试尽）\n")
step("end", "C3", "3.0", "124", "FAIL", "env-check rc=124", "照 P-2 处置")
d = lastrow()
c1 = d["log_path"].endswith("logs/env-check.log") and "ssh2" in d["error_excerpt"] and os.path.isfile(d["log_path"])
ok &= c1
step("begin", "C4", "4.1", "install-host")
step("log", "install-host", stdin="install-host rc=0\nFRESH OK\n")
step("end", "C4", "4.1", "0", "PASS", "install-host rc=0", "none")
d2 = lastrow()
c2 = d2["log_path"].endswith("logs/install-host.log") and d2["error_excerpt"] == "-"
ok &= c2
step("begin", "R1", "1", "download-verify")
step("log", "1", stdin="download rc=0\n")
step("end", "R1", "1", "0", "PASS", "PKG_ROOT=x", "none")
c3 = lastrow()["log_path"].endswith("logs/1.log")
ok &= c3
step("begin", "R1", "1.9", "noise-only")
step("log", "noise-only",
     stdin="shell-init: error retrieving current directory: getcwd: cannot access parent directories: Not supported\n"
           "chdir: error retrieving current directory: getcwd: cannot access parent directories: Invalid argument\n"
           "FRESH OK\n")
step("end", "R1", "1.9", "0", "PASS", "noise only", "none")
c4 = lastrow()["error_excerpt"] == "-"
ok &= c4
if not ok:
    lines.append("      · F-23/24/25 cases: logpath=%s excerpt2=%r excerpt4=%r"
                 % (c1, d2["error_excerpt"], lastrow()["error_excerpt"]))
chk("F-23/24/25 action-trace guard", ok, "cases=4")

# ---------- 14 markdown relative links ----------
links, broken = [], []
for p in glob.glob(os.path.join(SK, "**", "*.md"), recursive=True):
    for t in re.findall(r"\]\(([^)#]+)", rd(p)):
        if t.startswith(("http://", "https://", "mailto:")):
            continue
        links.append((p, t))
        if not os.path.exists(os.path.normpath(os.path.join(os.path.dirname(p), t))):
            broken.append((rel(p), t))
chk("markdown relative links", not broken, "links=%d broken=%s" % (len(links), broken[:5]))

# ---------- 15 git diff --check (container surface) ----------
if os.path.isdir(os.path.join(SK, ".git")):
    GIT = shutil.which("git") or next((c for c in (
        os.path.expanduser("~/.harmonybrew/opt/git/bin/git"), "/usr/bin/git") if os.path.isfile(c)), None)
    if GIT:
        r = run([GIT, "-C", SK, "diff", "--check"])
        chk("git diff --check", r.returncode == 0, (r.stdout + r.stderr).strip()[:160])
    else:
        skip("git diff --check", "no git binary")
else:
    skip("git diff --check", "not a git checkout")

out = "\n".join(lines) + ("\n\nSELFCHECK=%s checks=%d fails=%d\n"
                          % ("ALL_GREEN" if not fails else "FAILED", len(lines), len(fails)))
print(out)
dest = os.environ.get("SKILL_SELFCHECK_OUT") or os.path.join(os.path.expanduser("~"), "wbtmp",
                                                             "winvm-plugin-deploy-selfcheck.txt")
try:
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    open(dest, "w", encoding="utf-8").write(
        "# winvm-plugin-deploy selfcheck · %s\n# skill=%s mode=%s\n\n%s\n"
        % (datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"), SK, MODE, out))
    print("EVIDENCE=" + dest)
except Exception as e:
    print("EVIDENCE_WRITE_FAIL " + str(e)[:80])

# 默认**不清理**工作区：鸿蒙沙箱对批量删除有护栏（>50 个/回合），
# 删临时目录会变成用户确认弹窗——自检不该为清理打扰使用者。
# 需要清理时显式传 SELFCHECK_CLEAN=1；工作区路径总是打在 WORK_DIR= 上。
if os.environ.get("SELFCHECK_CLEAN"):
    shutil.rmtree(WORK, ignore_errors=True)
print("WORK_DIR=" + WORK)
sys.exit(0 if not fails else 1)
PYEOF
rc=$?
exit $rc
