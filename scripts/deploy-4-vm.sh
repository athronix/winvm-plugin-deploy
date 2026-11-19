#!/usr/bin/env bash
# deploy-4-vm.sh · 装 VM 端并起 winvm service（mcp + a2a）（deploy 第 4 步，与第 3 步并行）
#
# 四件：① 补齐 VM 运行时依赖（node，幂等）② 推包 + 装 VM 端（含 npm 上游 agent-browser /
# agent-desktop）+ 起服务 ③ 七判据体检 ④ MCP 上游工具面判据（真实 tools/list）
# 全程只经现役 ssh 通道；不建通道、不重启 VM。
#
# 用法：VM_HOST=... bash scripts/deploy-4-vm.sh [--purge-workspace]
set -u
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]:-$0}")/_common.sh"

resolve_env; need_node; need_bash; require_host
state_load
# 单个脚本也能跑（编排层不在场）：自行把 SKIP_UPSTREAMS 映射到 setup.mjs 认的 env。
: "${SKIP_UPSTREAMS:=0}"; export SKIP_UPSTREAMS
[ "$SKIP_UPSTREAMS" = "1" ] && export WINVM_SKIP_UPSTREAMS=1
PKG="${PKG_ROOT:-}"
[ -n "$PKG" ] && [ -f "$PKG/delivery/setup.mjs" ] \
  || die "找不到包根" "第 2 步未完成" "state=$STATE_FILE" "先跑 bash scripts/deploy-2-host.sh"

# ── 通道门禁：有界等健康窗（不重启 VM，只等新建连接可用）──
st_begin 4.0 "通道门禁（新建连接实测，≤${CHANNEL_GATE_S:-60}s）"
GATE="${CHANNEL_GATE_S:-60}"; waited=0
while :; do
  channel_ready 8000 && break
  [ "$waited" -ge "$GATE" ] && {
    st_end 1 FAIL "通道 ${GATE}s 内不可用（WEDGE：长连活着但新建握手超时）"
    die "通道新建连接不可用" "guest sshd 握手段间歇挂起（WEDGE），非网络层" \
        "ping 通但 ssh2 ready 超时" \
        "按红线不自启/重启 VM；等健康窗后重跑 --only 4（第 1~3 步已 PASS，不必重来）"
  }
  sleep 10; waited=$((waited + 10))
  echo "  … 等健康窗 ${waited}s / ${GATE}s"
done
st_end 0 PASS "channel=READY$([ "$waited" -gt 0 ] && echo "（等了 ${waited}s）")"

# ── 4a 依赖补齐（node，幂等；全 SKIP 也要三次往返，故单独成段便于计时）──
st_begin 4a "prepare-vm --ensure-deps（node + codebuddy + 两上游全局 CLI）"
PL="$(sub_log prepare-vm)"
# v2.4.0：依赖安装整体前移到 4a（DB-7），顺序 = node → codebuddy → agent-desktop → agent-browser。
# 这样 4b 不再承担 npm 全局安装（少一段最不可控的时长），4c 直接对结果下判据。
# SKIP_UPSTREAMS=1 时只装 node/codebuddy，两个上游由用户显式放弃（4c 记 SKIP）。
DEPS_ARGS="--ensure-deps"
[ "${SKIP_UPSTREAMS:-0}" = "1" ] && DEPS_ARGS="--ensure-deps --skip-upstream-deps"
_run_prepare() {
  ( cd "$PKG" && "$NODE" delivery/bootstrap.mjs prepare-vm --apply $DEPS_ARGS \
      --vm-host "$VM_HOST" --vm-user "$VM_USER" --vm-ssh-port "$VM_SSH_PORT" ) > "$PL" 2>&1
}
# 依赖缺口判据（P12）：prepare-vm 的 .ps1 在 DB-3/DB-7 失败时只 Write-Output "[MANUAL] ..."，
# **不返回非零 rc** ⇒ 只看 rc 会把「node 没装上」报成 [OK] 依赖就绪（2026-11-19 真机假绿：
# [DB-7][MANUAL] node missing 后面紧跟 [OK] 4a (59s) 依赖就绪，故障被推迟到 4b 才以
# VM_START_FAILED 的面目出现，归因成本极高）。必须扫日志文本，把「缺件」当失败。
_deps_gap() { grep -qE '\[DB-3\]\[MANUAL\]|\[DB-7\]\[MANUAL\]|zip install FAILED|zip install ran but node still not on PATH' "$1" 2>/dev/null; }

_run_prepare; PRC=$?
# 两类瞬态各给一次有界重试（幂等动作，重试安全）：
#   ① 建连类（握手超时/连接丢失）
#   ② 依赖安装类（镜像下载瞬时失败——2026-11-19 实测：同一条 cdn.npmmirror.com URL
#      第一次报「不能解析远程名称」、第二次 37.6MB 完整下载成功；DNS/代理/443 均正常）
_retry_once() {
  cp -f "$PL" "${PL%.log}.attempt1.log" 2>/dev/null || true
  echo "  [4a] $1 → 等 15s 重试一次（幂等，不改任何东西）"
  sleep 15
  _run_prepare; PRC=$?
}
if [ $PRC -ne 0 ] && grep -qE 'Connection lost before handshake|ready 超时|Timed out while waiting' "$PL" 2>/dev/null; then
  _retry_once "建连瞬态"
elif [ $PRC -eq 0 ] && _deps_gap "$PL"; then
  _retry_once "依赖安装瞬态（镜像下载失败）"
fi
# 重试后仍缺件 ⇒ 兜底直接装 node（绕开 prepare-vm 的 winget 前缀与它那次失败的下载）。
# 兜底只补 node：DB-7 三个 CLI 依赖 npm，node 一到位它们能在下一轮幂等补齐。
# 兜底脚本独立成文件（scripts/node-zip-fallback.ps1）而非 heredoc：① 纯 ASCII 可被
#   ps-run.sh 的载荷纪律检查；② 能单独真机验证；③ 门禁能静态断言它的关键约束。
if [ $PRC -eq 0 ] && _deps_gap "$PL"; then
  echo "  [4a] 依赖仍缺 → 兜底装 node（scripts/node-zip-fallback.ps1）"
  NODE_ZIP_VER="$(sed -n "s/^export const NODE_ZIP_VER = '\([^']*\)'.*/\1/p" "$PKG/delivery/prepare-vm.mjs" 2>/dev/null | head -1)"
  [ -n "${NODE_ZIP_VER:-}" ] || NODE_ZIP_VER=24.21.0
  FB="$VMDEPLOY_RUN_DIR/node-zip-fallback.$NODE_ZIP_VER.ps1"
  sed "s/__NODE_ZIP_VER__/$NODE_ZIP_VER/g" "$SCRIPTDIR/node-zip-fallback.ps1" > "$FB"
  if VM_PS_TIMEOUT="${VM_PS_TIMEOUT:-600}" bash "$SCRIPTDIR/ps-run.sh" "$FB" \
       > "$VMDEPLOY_RUN_DIR/node-zip-fallback.log" 2>&1; then
    grep -E '^\[FB\]' "$VMDEPLOY_RUN_DIR/node-zip-fallback.log" | tail -4
    echo "  [4a] node 兜底成功 → 再跑一次 prepare-vm 让 DB-7 补齐三个 CLI"
    _run_prepare; PRC=$?
  else
    grep -E '^\[FB\]' "$VMDEPLOY_RUN_DIR/node-zip-fallback.log" | tail -8
    tail -4 "$VMDEPLOY_RUN_DIR/node-zip-fallback.log"
  fi
fi
grep -E 'DB-7|SKIP|已就绪|ensure|npm install -g|\[MANUAL\]' "$PL" | tail -8
if [ $PRC -ne 0 ]; then
  tail -10 "$PL"
  st_end $PRC FAIL "prepare-vm rc=$PRC（VM 端可能缺 node）"
  die "VM 依赖补齐失败" "node 安装或路径探测失败" "$PL" \
      "看 $PL；VM 内 node 走 nvm-windows，切换版本会让全局 CLI 消失"
fi
if _deps_gap "$PL"; then
  tail -14 "$PL"
  st_end 1 FAIL "依赖缺件（rc=0 但日志报 MANUAL）"
  die "VM 依赖未补齐（rc=0 的假绿）" \
      "prepare-vm 的 DB-3/DB-7 失败只打印 [MANUAL]，ps1 不返非零" \
      "$PL 中的 [MANUAL] 行" \
      "按 [MANUAL] 提示手工装 node >= 18 后重跑 --only 4；镜像瞬时失败可重跑（已内建一次重试+兜底）"
fi
st_end 0 PASS "依赖就绪"

# ── 4b VM 端安装 + 服务启动（BUILD 打 tar → scp → install-vm → VM-START）──
st_begin 4b "setup --only-vm --skip-build（推包+装 VM 端+起服务）"
SL="$(sub_log setup)"
# WINVM_UPSTREAMS_HANDLED=1：上游 CLI 已由 4a 的 DB-7 装好，install-vm 的 [4b/6] 不再重复装
# （setup 会把它透传成 --skip-upstreams；两条来源语义相同，见 setup.mjs 注释）。
( cd "$PKG" && WINVM_UPSTREAMS_HANDLED=1 "$NODE" delivery/setup.mjs --apply --skip-build --only-vm > "$SL" 2>&1 ); SRC=$?
# 上游安装行（[4b/6] / 已安装 / ⚠ ... 安装失败）必须露出来：它是「可选依赖」，
# 失败不阻断部署，但 4c 会立刻把它变成硬判据——日志里得能看见它在哪一步掉的。
grep -E '部署全部完成|个步骤失败|降级 SKIP|VM_START|TUNNEL|QA-PROBE|\[4b/6\]|npm install -g|已安装：|安装失败' "$SL" | tail -10
if [ $SRC -ne 0 ]; then
  tail -14 "$SL"
  st_end $SRC FAIL "setup rc=$SRC"
  die "VM 端安装失败" "相位名见日志（VM / VM-START / QA-PROBE）" "$SL" \
      "看 $SL 的失败相位；420s 未监听=僵尸 start，先行 schtasks /End + /Run"
fi
# ── dry-run 假绿闸（2026-11-18 真机踩到）──
# 现象：包根只有 .env.example 时，它里面的 WINVM_DRY_RUN=1 是「兜底保险」，setup 会
# **即便传了 --apply 也只规划**，rc=0 且耗时 0s ⇒ 本步报 PASS，实际一个字节都没推。
# 后果：VM 上仍是上一版服务，4c 的 desktop_tools 读到旧白名单（实测 25→10），
# 看起来像「上游白名单退化了」，真正原因是 4b 根本没执行。
# 判据：setup 头部打印 [DRY-RUN 只规划] 而非 [APPLY 真执行]。
if grep -q 'DRY-RUN 只规划' "$SL" 2>/dev/null; then
  st_end 1 FAIL "setup 走了 dry-run（rc=0 但零动作）"
  die "4b 未真正执行（dry-run 假绿）" "包根只有 .env.example 且其中 WINVM_DRY_RUN=1 兜底生效" "$SL" \
      "把 $PKG/.env.example 复制成 .env 并把 WINVM_DRY_RUN 设为 0（该兜底刻意优先于 --apply，本步不越权覆盖）"
fi
st_end 0 PASS "setup rc=0"

# ── 4c 七判据（服务在跑 + 端口在听 + 旁证两项 + health 通 + 两上游工具面）──
# v2.4.0：原 4d 的 MCP 上游判据并入本步 —— 都跑在 VM 内一次载荷里，省一次宿主往返，
# 也避免"4d 只在第 4 步跑、verify 单跑时没有复验面"的缺口（第 5 步同样内置这项）。
# 铁律：vmcheck.ps1 是**纯报告器**（无退出码逻辑），rc=0 只说明「脚本跑完了」。
# 判据必须由本步自己解析 JSON 并逐项断言，否则「拿不到判据也 PASS」＝假绿。
st_begin 4c "vmcheck 七判据（逐项断言）"
need_py
VL="$(sub_log vmcheck)"
( cd "$PKG" && bash "$SCRIPTDIR/ps-run.sh" "$PKG/qa/deploy-probes/vmcheck.ps1" > "$VL" 2>&1 ); VRC=$?
grep -E 'task_state|listen_count|health_http|ok' "$VL" | tail -4
if [ $VRC -ne 0 ]; then
  tail -12 "$VL"
  st_end $VRC FAIL "vmcheck 通道/载荷出错 rc=$VRC（未取到判据）"
  die "VM 端体检未跑通" "ps-run 失败（通道坏或载荷超预算）" "$VL" \
      "rc=124 且零输出=载荷超预算（VM_PS_TIMEOUT），不是通道坏"
fi
VJ="$(tr -d '\r' < "$VL" | grep -o '{.*}' | tail -1)"
if [ -z "$VJ" ]; then
  tail -10 "$VL"
  st_end 1 FAIL "vmcheck 未输出判据 JSON（无从断言）"
  die "VM 端体检无判据" "载荷输出被截断/格式异常" "$VL" "看 $VL"
fi
PYV="$(printf '%s' "$VJ" | SKIP_UPSTREAMS="${SKIP_UPSTREAMS:-0}" \
  EXP_BROWSER_TOOLS="$UPSTREAM_EXP_BROWSER" EXP_DESKTOP_TOOLS="$UPSTREAM_EXP_DESKTOP" "$PY" -c '
import json,sys,os
d=json.load(sys.stdin)
st=str(d.get("task_state","")).strip()
cnt=int(d.get("listen_count") or 0)
side=d.get("side_json") is True
bdir=d.get("bridge_dir") is True
hh=d.get("health_http")
# v2.4.0：两个上游工具面的判据并入本步（原 4d），计数取自 vmcheck 在 VM 内真打的 tools/list
skip=os.environ.get("SKIP_UPSTREAMS","0")=="1"
eb=os.environ.get("EXP_BROWSER_TOOLS") or "33"
ed=os.environ.get("EXP_DESKTOP_TOOLS") or "25"
bt=str(d.get("browser_tools",""))
dt=str(d.get("desktop_tools",""))
bad=[]
if st not in ("Running","正在运行"): bad.append("task_state=%s" % st)
if cnt < 1: bad.append("listen_count=%d" % cnt)
if not side: bad.append("side_json=false")
if not bdir: bad.append("bridge_dir=false")
if not skip:
    if bt != eb: bad.append("browser_tools=%s!=%s" % (bt,eb))
    if dt != ed: bad.append("desktop_tools=%s!=%s" % (dt,ed))
line="task_state=%s listen_count=%d side_json=%s bridge_dir=%s health_http=%s browser=%s desktop=%s" % (
    st,cnt,str(side).lower(),str(bdir).lower(),hh,bt,dt)
print(("FAIL|" + "; ".join(bad)) if bad else ("OK|" + line))
')"
case "$PYV" in
  OK\|*) VCORE="$(printf '%s' "$PYV" | sed 's/^OK|//')" ;;
  *)      st_end 1 FAIL "$(printf '%s' "$PYV" | sed 's/^FAIL|//')"
          die "VM 端服务未达判据" "$(printf '%s' "$PYV" | sed 's/^FAIL|//')" "$VL" \
              "Ready 但未监听=scheduled task 僵死：schtasks /End /tn WinVMBridge.Service 后 /Run" ;;
esac
# health 双口径：VM 自检走 in-guest HTTP（5s 窗，ps-bridge 正忙会被取消）；
# 宿主侧经隧道 health 才代表「外部可服务」。VM 自检 ERR + 宿主 200 = 服务正常。
VHH="$(printf '%s' "$VJ" | "$PY" -c 'import json,sys;print(json.load(sys.stdin).get("health_http"))')"
if [ "$VHH" = "200" ]; then
  st_end 0 PASS "$VCORE"
else
  HC="$(health_code)"
  if [ "$HC" = "200" ]; then
    echo "  VM 自检 health=$VHH（in-guest 5s 窗被自身载荷挤占），宿主侧 health=200 → 服务确实可服务"
    st_end 0 PASS "$VCORE（VM自检=$VHH，宿主侧=200）"
  else
    st_end 1 FAIL "$VCORE 且宿主侧 health=$HC"
    die "VM 服务 health 不通" "VM 自检=$VHH、宿主侧=$HC" "$VL" \
        "两者皆非 200=服务真坏；仅 VM 自检非 200=判据窗太紧"
  fi
fi

state_set VM_INSTALLED 1
steps_report