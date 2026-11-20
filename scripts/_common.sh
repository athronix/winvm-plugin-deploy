#!/usr/bin/env bash
# winvm-plugin-deploy · 共用地基 (v2.0.0)
#
# 只做六件事，别的层不许再各造一套：
#   1) 路径/日志落点      2) 日志与终局判定      3) 分步计时 steps.tsv
#   4) 参数与状态文件      5) 依赖冒烟            6) 断言与四元组提示
#
# 设计约束（血泪教训，勿回退）：
#   · 计数一律 awk `{n++} END{print n+0}`；禁 `grep -c ... || echo 0`（零匹配会吐两个 0 ⇒ 假红 F-17）
#   · 判定必须可证伪：判据行要带真实计数，"字符串在场"不算通过（F-21 / v1.9.3）
#   · 传输预算 ≠ 载荷预算：载荷走 ps-run.sh 的 _payload（VM_PS_TIMEOUT）
#   · 宿主侧删文件禁 rm，用 node -e 'fs.unlinkSync'
#   · 任何 step 脚本都必须能单独重跑（幂等），不依赖上一个 step 的进程内存
set -u

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILLDIR="$(cd "$SCRIPTDIR/.." && pwd)"
export SCRIPTDIR SKILLDIR

WINVM_HOME="${WINVM_HOME:-$HOME/.workbuddy/winvm}"
STATE_FILE="${VMDEPLOY_STATE_FILE:-$WINVM_HOME/deploy-state.env}"
DEPLOY_ROOT="${DEPLOY_ROOT:-$HOME/winvm-deploy}"
# 临时目录唯一来源。鸿蒙沙箱的 /tmp 是只读 tmpfs（实测 `touch /tmp/x` = Read-only
# file system，`curl -o /tmp/x` = curl 23），任何落 /tmp 的写法都会当场失败。
# 故**全仓禁用 /tmp**，一律走本函数：TMPDIR > $HOME/wbtmp。
vm_tmpdir() {
  local d="${TMPDIR:-$HOME/wbtmp}"
  mkdir -p "$d" 2>/dev/null || true
  printf '%s' "$d"
}
: "${VMDEPLOY_RUN_DIR:=${HOME}/wbtmp/winvm-deploy-$(date +%Y%m%d-%H%M%S)}"
LOGD="${VMDEPLOY_LOG_DIR:-$VMDEPLOY_RUN_DIR}"
export WINVM_HOME STATE_FILE DEPLOY_ROOT VMDEPLOY_RUN_DIR LOGD
mkdir -p "$LOGD" "$WINVM_HOME" 2>/dev/null || true

# ssh2 后端统一（鸿蒙沙箱 OpenSSH 二进制对 VM 相位挂，见 references/troubleshooting.md）
export VM_SSH_BACKEND="${VM_SSH_BACKEND:-ssh2}"

C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
[ -t 1 ] || { C_RED=''; C_GRN=''; C_YEL=''; C_DIM=''; C_OFF=''; }

_T0_ALL=$(date +%s)

# ─────────────────────────── 1) 日志 ───────────────────────────
log()  { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '%s %s[OK]%s %s\n'   "$(date +%H:%M:%S)" "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s %s[WARN]%s %s\n' "$(date +%H:%M:%S)" "$C_YEL" "$C_OFF" "$*"; }
err()  { printf '%s %s[FAIL]%s %s\n' "$(date +%H:%M:%S)" "$C_RED" "$C_OFF" "$*" >&2; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

# die <现象> [根因] [证据] [处置]
die() {
  err "现象: $1"
  [ $# -gt 1 ] && [ -n "${2:-}" ] && err "根因: $2"
  [ $# -gt 2 ] && [ -n "${3:-}" ] && err "证据: $3"
  [ $# -gt 3 ] && [ -n "${4:-}" ] && err "处置: $4"
  err "日志: $LOGD"
  exit 1
}

# 子步骤日志：`sub_log <name>` 返回路径，调用方自行重定向
sub_log() { printf '%s/%s.log' "$LOGD" "$1"; }

# ─────────────────────────── 2) 参数 ───────────────────────────
state_load() {
  [ -f "$STATE_FILE" ] || return 0
  # 只接受 KEY=VALUE，行内禁执行（防御：状态文件不是脚本）
  while IFS='=' read -r k v; do
    case "$k" in ''|\#*) continue ;; esac
    case "$k" in *[!A-Z0-9_]*) continue ;; esac
    [ -n "${!k:-}" ] && continue      # 显式 env 优先，状态文件只补缺
    export "$k=$v"
  done < "$STATE_FILE"
}

state_set() { # state_set KEY VALUE
  mkdir -p "$WINVM_HOME" 2>/dev/null || true
  local tmp="${STATE_FILE}.tmp.$$"
  if [ -f "$STATE_FILE" ]; then
    awk -F= -v k="$1" '!/^#/ && $1!=k' "$STATE_FILE" > "$tmp" 2>/dev/null || : > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s=%s\n' "$1" "$2" >> "$tmp"
  mv -f "$tmp" "$STATE_FILE" 2>/dev/null || cp -f "$tmp" "$STATE_FILE" 2>/dev/null || true
  export "$1=$2"
}

state_dump() {
  [ -f "$STATE_FILE" ] || { echo "(no state file)"; return 0; }
  grep -vE '^\s*(#|$)' "$STATE_FILE" | sed 's/^/  /'
}

resolve_env() {
  state_load
  # 默认值来自用户口径（2026-11-20）：这台 VM 就是「172.16.100.2 / User / 无密码」。
  # 写成默认值是为了让**新机器上一条命令就能跑通**，不必先知道 IP 才能起步；
  # 换机器仍是 `VM_HOST=<ip> bash scripts/deploy.sh` 覆盖，无需改脚本。
  : "${VM_HOST:=172.16.100.2}"
  : "${VM_USER:=User}"
  : "${VM_SSH_PORT:=22}"
  # 口令文件默认 ~/.winvm-pass（用户自建、脚本只读不写）。只有文件真实存在才生效：
  # 不存在时保持空值 ⇒ 后续按「无口令」处理，不会把「空文件」误判成「空口令意图」。
  if [ -z "${WINVM_PASSWORD_FILE:-}" ] && [ -f "$HOME/.winvm-pass" ]; then
    WINVM_PASSWORD_FILE="$HOME/.winvm-pass"
  fi
  # 密钥三级链：env > vm-conn.json.identityFile > 约定默认（本插件建的通道钥）
  if [ -z "${WINVM_VM_KEY:-}" ] && [ -f "$WINVM_HOME/vm-conn.json" ]; then
    local k=""
    [ -n "${NODE:-}" ] && k="$("$NODE" -e 'try{const j=require(process.argv[1]);process.stdout.write(j.identityFile||"")}catch{}' "$WINVM_HOME/vm-conn.json" 2>/dev/null)"
    [ -n "$k" ] && WINVM_VM_KEY="$k"
  fi
  : "${WINVM_VM_KEY:=$HOME/.ssh/id_ed25519_winvm}"
  export VM_HOST VM_USER VM_SSH_PORT WINVM_VM_KEY
  if [ -n "${WINVM_PASSWORD_FILE:-}" ]; then export WINVM_PASSWORD_FILE; fi
  return 0
}

require_host() {
  [ -n "${VM_HOST:-}" ] || die "VM_HOST 未设置" \
    "缺少目标虚拟机地址" \
    "环境变量 VM_HOST 为空且无状态文件" \
    "VM_HOST=172.16.100.2 bash scripts/$0 ；或用 deploy-1-ssh.sh 记录到 $STATE_FILE"
}

# ─────────────────────────── 3) 依赖 ───────────────────────────
need_node() {
  local n
  for n in "${NODE:-}" /data/storage/el1/bundle/libs/arm64/node/bin/node /data/service/hnp/bin/node "$(command -v node 2>/dev/null)"; do
    [ -n "$n" ] && [ -x "$n" ] || continue
    if "$n" -e 'process.exit(0)' >/dev/null 2>&1; then NODE="$n"; export NODE; return 0; fi
  done
  die "没有可用的 node 解释器" "宿主运行插件/解包需要 node" "候选均冒烟失败" \
      "确认 /data/storage/el1/bundle/libs/arm64/node/bin/node 存在（目录不是二进制）"
}

need_py() {
  local p
  for p in "${PY:-}" /data/service/hnp/bin/python3 "$(command -v python3 2>/dev/null)" python3; do
    [ -n "$p" ] || continue
    if "$p" -c 'import sys;sys.exit(0)' >/dev/null 2>&1; then PY="$p"; export PY; return 0; fi
  done
  die "没有可用的 python3" "探针与包校验需要 python3" "候选均冒烟失败" "确认 PY 环境变量或系统 python3"
}

need_bash() { : "${BASH_OK:=$(command -v bash || echo bash)}"; export BASH_OK; }

# ─────────────────────────── 4) 计时 ───────────────────────────
# steps.tsv 列：step<TAB>phase<TAB>id<TAB>label<TAB>rc<TAB>dur<TAB>judgment<TAB>advice
STEPS_TSV="$LOGD/steps.tsv"
st_begin() { # st_begin <step> <label>
  ST_T0=$(date +%s)
  ST_STEP="$1"; ST_LABEL="$2"
  log "── [$1] $2"
}
st_end() { # st_end <rc> <PASS|FAIL|SKIP|WAIT_USER> <judgment> [advice]
  local rc="$1" verd="$2" judge="$3" adv="${4:-none}"
  local dur=$(( $(date +%s) - ST_T0 ))
  [ -f "$STEPS_TSV" ] || printf 'step\tlabel\trc\tdur_s\tjudgment\tadvice\n' > "$STEPS_TSV"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ST_STEP" "$ST_LABEL" "$rc" "$dur" "$judge" "$adv" >> "$STEPS_TSV"
  case "$verd" in
    PASS) ok "$ST_STEP (${dur}s) $judge" ;;
    SKIP) dim "$ST_STEP (${dur}s) SKIP $judge" ;;
    WAIT_USER) warn "$ST_STEP (${dur}s) WAIT_USER $judge" ;;
    *) err "$ST_STEP (${dur}s) $verd $judge" ;;
  esac
  [ "$verd" = "PASS" ] || [ "$verd" = "SKIP" ] || [ "$verd" = "WAIT_USER" ] || ST_FAILED="$ST_STEP"
  ST_VERDICT="$verd"
}

steps_report() {
  [ -f "$STEPS_TSV" ] || return 0
  # 编排层（deploy.sh/undeploy.sh）会在最后统一打印；步脚本也会调一次（单独重跑时有用），
  # 两者同时生效 ⇒ 同一张表打印 2~3 遍（2026-11-17 实测）。编排期由它置 1 静音子进程。
  [ "${VMDEPLOY_STEPS_QUIET:-0}" = "1" ] && return 0
  echo
  echo "== 分步计时 =="
  awk -F'\t' 'NR>1{printf "  %-10s %-42s %4ss  %s\n",$1,substr($2,1,42),$4,$3}' "$STEPS_TSV"
  local total=$(( $(date +%s) - _T0_ALL ))
  echo "  WALL_S=$total"
}

# ─────────────────────────── 5) 包根 ───────────────────────────
# shellcheck disable=SC1091
. "$SCRIPTDIR/pkg-root.sh"

# ─────────────────────────── 6) 通道判定 ───────────────────────────
# 唯一判据 = 新建连接实测（长连健康 ≠ 新建可用）。ssh2 ping 权威，二进制只作兜底。
# ssh2-conn.mjs 只认环境变量（无 --flags），故此处显式注入。
channel_ready() { # channel_ready [ready_timeout_ms]
  local t="${1:-6000}"
  # WINVM_SSH_AUTH 透传：1p（密码建通道）阶段 export WINVM_SSH_AUTH=password 后，
  # 本判据改按密码认证探测；其余阶段为空 ⇒ ssh2-conn 走原 key 分支（零行为变化）。
  ( cd "$SCRIPTDIR" && \
    VM_HOST="$VM_HOST" VM_USER="$VM_USER" VM_SSH_PORT="$VM_SSH_PORT" \
    WINVM_VM_KEY="$WINVM_VM_KEY" WINVM_SSH_READY_TIMEOUT_MS="$t" \
    WINVM_SSH_AUTH="${WINVM_SSH_AUTH:-}" WINVM_SSH_PASSWORD="${WINVM_SSH_PASSWORD:-}" \
    WINVM_SSH_PASSWORD_EMPTY="${WINVM_SSH_PASSWORD_EMPTY:-}" \
    "$NODE" ssh2-conn.mjs ping ) >/dev/null 2>&1
}

health_code() { # health_code [port] [max_time] → 恒为 3 字符（不通=000）
  local out
  out="$(curl -sS --noproxy 127.0.0.1 -o /dev/null -w '%{http_code}' --max-time "${2:-8}" \
    "http://127.0.0.1:${1:-${WINVM_TUNNEL_LOCAL_PORT:-18443}}/health" 2>/dev/null)"
  # 连不上时 curl 自己就吐 "000" 且 rc!=0；若再 `|| echo 000` 会拼成 "000000"
  # （同 grep -c 双值坑）。这里统一归一到 3 字符，调用方才能用 = "000" 判不通。
  case "$out" in
    [1-5][0-9][0-9]) printf '%s' "$out" ;;
    *) printf '000' ;;
  esac
}

# ── oneclick 之后的「宿主侧免密回验」开关（默认关闭，v2.4.0）──
# 口径（用户 2026-11-18）：oneclick 自己已做 [9/9] 回环复验；宿主再空等一轮 90s，
# 常态下纯属浪费。所以 1p.7（S2 后）与 1d（用户粘完 oneclick 后）**默认 SKIP**，
# 仅测试/查验时 `AUTOKEY_VERIFY_AFTER_S2=1` 启用。
# 注意：关闭时**不落 CHANNEL_READY=1**（没验过就不许写"已就绪"），
# 后续 deploy-4 的 4.0 通道门禁（≤60s 健康窗）会实测——那里才是这条路的真判据。
oneclick_verify_enabled() { # → 0=启用 / 1=跳过
  [ "${AUTOKEY_VERIFY_AFTER_S2:-0}" = "1" ]
}

wait_channel_ready() { # wait_channel_ready <window_s> → 0=就绪 / 1=超时
  # 纯轮询，不做任何状态写入；步骤表（st_begin/st_end）由调用方负责。
  local win="${1:-90}" waited=0
  while [ "$waited" -lt "$win" ]; do
    channel_ready 6000 && { echo "$waited"; return 0; }
    sleep 5; waited=$((waited + 5))
    [ $((waited % 15)) -eq 0 ] && echo "  … 等通道恢复 ${waited}s / ${win}s" >&2
  done
  return 1
}

port_listening() { # port_listening <port> [host] → 本地/远端端口是否有 listener
  # 纯 bash /dev/tcp 探测：连接成功即有人 accept。不依赖 curl（curl 在"连上但无 HTTP
  # 应答"与"连接被拒"两种情况都可能给 000，分不开）。
  local h="${2:-127.0.0.1}"
  ( exec 3<>"/dev/tcp/$h/$1" ) >/dev/null 2>&1
}

# ───────── MCP 上游工具面（agent-browser / agent-desktop）─────────
# 这两个 stdio MCP server 装在 VM 上、由 vm-service 反代成 `/mcp/<id>`，宿主侧只是
# 多两个 connector 条目。**判据只能取真实 tools/list 计数**：
#   · `/health.upstreams[]` 是懒启动的观测值，服务刚起来时恒 `idle`，
#     拿它断言会把「还没被调用」误判成「装坏了」（假红）；
#   · 反过来「路由存在」也不等于「上游可用」——未安装时路由返回 502。
# 函数自给自足解析解释器（不裸用 $PY：步脚本可单独重跑，M10 变异锁过这条）。
upstream_tools() { # upstream_tools <browser|desktop> [port] → 打印工具数；失败打印 ERR:<reason>
  local id="${1:?upstream id}" port="${2:-${WINVM_TUNNEL_LOCAL_PORT:-18443}}"
  local py="${PY:-}" c
  if [ -z "$py" ]; then
    for c in /data/service/hnp/bin/python3 "$(command -v python3 2>/dev/null)" python3; do
      [ -n "$c" ] && "$c" -c 'import sys;sys.exit(0)' >/dev/null 2>&1 && { py="$c"; break; }
    done
  fi
  [ -n "$py" ] || { printf 'ERR:no-python'; return 0; }
  "$py" - "$id" "$port" <<'PYEOF'
import json, sys, urllib.request, urllib.error
up, port = sys.argv[1], sys.argv[2]
payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}).encode()
req = urllib.request.Request(
    "http://127.0.0.1:%s/mcp/%s" % (port, up), data=payload,
    headers={"Content-Type": "application/json", "Accept": "application/json, text/event-stream"})
# 显式空 ProxyHandler：鸿蒙宿主可能带 http_proxy，会把 127.0.0.1 也送进代理
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
try:
    with opener.open(req, timeout=60) as r:
        raw = r.read().decode("utf-8", "replace")
except urllib.error.HTTPError as e:
    print("ERR:http-%d" % e.code); raise SystemExit(0)
except Exception as e:
    print("ERR:%s" % type(e).__name__); raise SystemExit(0)
body = raw.strip()
if body.startswith(("event:", "data:")):          # 兼容 SSE 帧
    parts = [l[5:].strip() for l in body.splitlines() if l.startswith("data:")]
    body = parts[-1] if parts else ""
try:
    d = json.loads(body)
except Exception:
    print("ERR:bad-json"); raise SystemExit(0)
if isinstance(d.get("error"), dict):
    print("ERR:rpc-%s" % d["error"].get("code")); raise SystemExit(0)
tools = ((d.get("result") or {}).get("tools")) or []
print(len(tools))
PYEOF
}

# 上游工具面判据（deploy 第 5 步与独立 verify 共用同一口径，避免两处漂移）。
# v2.4.0：原 4d / 5e 已并入 4c / 第 5 步 —— 第 4 步在 VM 内一次载荷里连带取 tools/list
# （vmcheck.ps1 报 browser_tools/desktop_tools），第 5 步走本函数从宿主侧直打，
# 两个观测面独立；期望值仍只在这里定义，不许在步脚本里各自硬写。
# 期望值是**精确断言**并可用 env 覆盖：上游升级或白名单调整后计数会变，此时刻意报警，
# 由运维显式改 EXP_* 或 env（同 EXP_TOTAL 的「项数即断言」风格）。
UPSTREAM_EXP_BROWSER="${EXP_BROWSER_TOOLS:-33}"   # 33 个工具全量暴露
UPSTREAM_EXP_DESKTOP="${EXP_DESKTOP_TOOLS:-25}"   # 服务端白名单默认 25（v2.2.0 由 10 调宽）
upstream_judge() { # → 打印 "OK <browser=N desktop=M>" 或 "FAIL <原因>"
  local b d bad=""
  b="$(upstream_tools browser)"; d="$(upstream_tools desktop)"
  case "$b" in ''|ERR:*) bad="browser=$b" ;; esac
  case "$d" in ''|ERR:*) bad="${bad:+$bad; }desktop=$d" ;; esac
  if [ -z "$bad" ]; then
    [ "$b" = "$UPSTREAM_EXP_BROWSER" ] || bad="browser=$b!=${UPSTREAM_EXP_BROWSER}"
    [ "$d" = "$UPSTREAM_EXP_DESKTOP" ] || bad="${bad:+$bad; }desktop=$d!=${UPSTREAM_EXP_DESKTOP}"
  fi
  if [ -n "$bad" ]; then echo "FAIL $bad（browser=$b desktop=$d）"; else echo "OK browser=$b desktop=$d"; fi
}

tunnel_pid() { # → 隧道 daemon pid（读不到/无文件输出 0）
  # tunnel.pid 是 JSON（{"pid":57857,...}），不是纯数字文本。
  # 早期用 `tr -dc '0-9'` 会把 11 行 JSON 里所有数字拼成一串，kill -0 必然失败（2026-11-16 实测）。
  local f="${WINVM_HOME}/tunnel.pid" p
  [ -f "$f" ] || { printf '0'; return 0; }
  p="$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$f" 2>/dev/null | head -1)"
  printf '%s' "${p:-0}"
}

tunnel_alive() { # → 0=daemon 存活 1=不在
  local p; p="$(tunnel_pid)"
  [ "$p" != "0" ] && kill -0 "$p" 2>/dev/null
}

user_home_file() { printf '%s/%s' "$HOME" "$1"; }

# ── 远端 oneclick 脚本地址（deploy 第 1 步与 undeploy 第 3 步共用，单一事实源）──
# 2026-11-17 用户裁定：**only from 技能仓**。技能仓 GitHub / Gitee 双端 public，raw 匿名可下，
# 所以 oneclick 不再从母项目 release 资产取——那既是跨仓耦合，也是「资产滞后于脚本」的陷阱。
# 「资源难以下载」仍是部署链最典型的止血点：VM 的出口网络与宿主不同，故保留两源循环。
# 本组函数必须自给自足——步脚本可单独重跑，调用方未必跑过 need_py，
# 所以不许裸用 $PY（set -u 下会 unbound variable，静默把 URL 判成不可达）。
# 锁版本：SSHD_SCRIPT_REF=<技能仓 tag/分支>（默认 main）；整链替换：SSHD_SCRIPT_URL=<直链>。
sshd_script_urls() { # 候选源，每行一个（显式 SSHD_SCRIPT_URL 永远排第一）
  [ -n "${SSHD_SCRIPT_URL:-}" ] && printf '%s\n' "$SSHD_SCRIPT_URL"
  local ref="${SSHD_SCRIPT_REF:-main}" u
  # 顺序：Gitee（国内链路稳、匿名 200 实测）→ GitHub（同仓同 ref，跨网兜底）。
  local gitee_raw="https://gitee.com/athronix/winvm-plugin-deploy/raw/$ref/scripts/winvm-sshd-oneclick.ps1"
  local gh_raw="https://raw.githubusercontent.com/athronix/winvm-plugin-deploy/$ref/scripts/winvm-sshd-oneclick.ps1"
  for u in "$gitee_raw" "$gh_raw"; do
    [ -n "$u" ] && printf '%s\n' "$u"
  done
}

sshd_script_srcs_ps() { # 前 N 个候选拼成 PowerShell 数组元素（'u1','u2'），供 VM 侧多源循环
  local n="${1:-3}" u out="" i=0
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    i=$((i + 1)); [ "$i" -gt "$n" ] && break
    out="$out${out:+,}'$u'"
  done <<EOF
$(sshd_script_urls)
EOF
  printf '%s' "$out"
}

sshd_script_url() { # 首个宿主侧可达的候选；全不可达时退回首个候选（调用方自行判 FAIL）
  local u first=""
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    [ -n "$first" ] || first="$u"
    url_reachable "$u" && { printf '%s' "$u"; return 0; }
  done <<EOF
$(sshd_script_urls)
EOF
  [ -n "$first" ] || return 1
  printf '%s' "$first"
}

url_reachable() { # url_reachable <url> → 200 才算可用（探测窗短，多源串行不拖时间）
  local t="${VM_URL_PROBE_T:-8}" code
  code="$(curl -sIL --connect-timeout "$t" --max-time "$((t * 2))" -o /dev/null -w '%{http_code}' "$1" 2>/dev/null)"
  [ "$code" = "200" ]
}
