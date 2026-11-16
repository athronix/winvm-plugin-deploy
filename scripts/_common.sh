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
  : "${VM_HOST:=}"
  : "${VM_USER:=User}"
  : "${VM_SSH_PORT:=22}"
  # 密钥三级链：env > vm-conn.json.identityFile > 约定默认（本插件建的通道钥）
  if [ -z "${WINVM_VM_KEY:-}" ] && [ -f "$WINVM_HOME/vm-conn.json" ]; then
    local k=""
    [ -n "${NODE:-}" ] && k="$("$NODE" -e 'try{const j=require(process.argv[1]);process.stdout.write(j.identityFile||"")}catch{}' "$WINVM_HOME/vm-conn.json" 2>/dev/null)"
    [ -n "$k" ] && WINVM_VM_KEY="$k"
  fi
  : "${WINVM_VM_KEY:=$HOME/.ssh/id_ed25519_winvm}"
  export VM_HOST VM_USER VM_SSH_PORT WINVM_VM_KEY
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
  ( cd "$SCRIPTDIR" && \
    VM_HOST="$VM_HOST" VM_USER="$VM_USER" VM_SSH_PORT="$VM_SSH_PORT" \
    WINVM_VM_KEY="$WINVM_VM_KEY" WINVM_SSH_READY_TIMEOUT_MS="$t" \
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

port_listening() { # port_listening <port> [host] → 本地/远端端口是否有 listener
  # 纯 bash /dev/tcp 探测：连接成功即有人 accept。不依赖 curl（curl 在"连上但无 HTTP
  # 应答"与"连接被拒"两种情况都可能给 000，分不开）。
  local h="${2:-127.0.0.1}"
  ( exec 3<>"/dev/tcp/$h/$1" ) >/dev/null 2>&1
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
# 技能源仓是 private ⇒ raw 匿名 404，只能走母项目 release 资产（第 5 资产）。
# 注意：本函数必须自给自足——步脚本可单独重跑，调用方未必跑过 need_py，
# 所以不许裸用 $PY（set -u 下会 unbound variable，静默把 URL 判成不可达）。
sshd_script_url() {
  [ -n "${SSHD_SCRIPT_URL:-}" ] && { printf '%s' "$SSHD_SCRIPT_URL"; return 0; }
  local tag="${RELEASE_TAG:-}" py="${PY:-}" raw=""
  if [ -z "$tag" ]; then
    [ -n "$py" ] || py="$(command -v python3 2>/dev/null || true)"
    raw="$(curl -fsSL --connect-timeout 10 --max-time 25 \
      "https://gitee.com/api/v5/repos/athronix/workbuddy-virtual-win-plugin/releases/latest" 2>/dev/null)"
    if [ -n "$py" ]; then
      tag="$(printf '%s' "$raw" | "$py" -c 'import sys,json;print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null)"
    fi
    # python 不可用时退回文本解析（同一 JSON 的 tag_name 字段）
    [ -n "$tag" ] || tag="$(printf '%s' "$raw" | sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p' | head -1)"
  fi
  [ -n "$tag" ] || return 1
  printf 'https://gitee.com/athronix/workbuddy-virtual-win-plugin/releases/download/%s/winvm-sshd-oneclick.ps1' "$tag"
}

url_reachable() { # url_reachable <url> → 200 才算可用
  local code
  code="$(curl -sIL --connect-timeout 12 --max-time 30 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null)"
  [ "$code" = "200" ]
}
