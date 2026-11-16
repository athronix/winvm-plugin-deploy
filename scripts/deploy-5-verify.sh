#!/usr/bin/env bash
# deploy-5-verify.sh · 复验（deploy 第 5 步；也是独立 verify 的唯一入口）
#
# 三探针（按 PROBE_DEEP 分级，34 项 / 38 项）+ 终态矩阵（fresh / mcp / health / skills / VM 三点）。
# 不建通道、不修通道、不重启 VM。通道瞬态窗 → VERIFY=INCOMPLETE rc=2（既不假绿也不误报功能失败）。
#
# 新鲜复用：deploy 刚在本进程跑完探针时，同包根 + 600s 内可只跑矩阵（省 ~100s）。
#   复用必须带真实计数（读不到即 meter-missing → FAIL），否则 deploy 段假绿会被静默继承。
#
# 用法：VM_HOST=... bash scripts/deploy-5-verify.sh
#       VERIFY_FORCE_PROBE=1 ...            # 强制冷跑探针
#       PROBE_DEEP=1 ...                    # 跑全 38 项（含真实 LLM 委派 / 盘扫族）
set -u
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]:-$0}")/_common.sh"

resolve_env; need_node; need_py
state_load
if [ -z "${PKG_ROOT:-}" ] || [ ! -d "${PKG_ROOT:-}/qa/deploy-probes" ]; then
  if resolve_pkg_root; then PKG_ROOT="$PKG_RESOLVED"; else
    die "找不到包根" "deploy-2 未完成" "state=$STATE_FILE 与三级链均空" "先跑 bash scripts/deploy-2-host.sh"
  fi
fi
PKG="$PKG_ROOT"
export PKG_ROOT
export PROBE_DEEP="${PROBE_DEEP:-0}"
STAMP="${VMDEPLOY_PROBE_STAMP:-$HOME/wbtmp/winvm-probes-stamp.txt}"
FRESH="${PROBE_FRESH_BUDGET_S:-600}"
FAILS=""

# ── 新鲜复用判定（四条件全满足才复用）──
REUSE=0; RREASON="no-stamp"
if [ "${VERIFY_FORCE_PROBE:-0}" != "1" ] && [ -f "$STAMP" ]; then
  S_EPOCH="$(sed -n 's/^epoch=//p' "$STAMP" | head -1)"
  S_OK="$(sed -n 's/^deploy_ok=//p' "$STAMP" | head -1)"
  S_PKG="$(sed -n 's/^pkg=//p' "$STAMP" | head -1)"
  NOW="$(date +%s)"
  if [ "${S_OK:-0}" != "1" ]; then RREASON="deploy-not-green"
  elif [ "${S_PKG:-}" != "$PKG" ]; then RREASON="pkg-changed"
  elif [ -z "${S_EPOCH:-}" ] || [ $((NOW - S_EPOCH)) -gt "$FRESH" ]; then RREASON="stale($((NOW - ${S_EPOCH:-0}))s)"
  else REUSE=1; RREASON="fresh($((NOW - S_EPOCH))s<=${FRESH}s, same pkg)"; fi
fi

# ── 5a/5b/5c 三探针 ──
PROBE_TOTAL=0; PROBE_PASS=0; PROBE_SKIP=0; PROBLEMS=""
if [ $REUSE -eq 1 ]; then
  st_begin 5 "三探针（复用 deploy 刚跑的结果）"
  echo "  复用理由: $RREASON（强制冷跑=VERIFY_FORCE_PROBE=1）"
  for pr in mcp-probe a2a-probe example-probe; do
    _L="$(grep -E 'SUMMARY|RESULT' "$LOGD/$pr.log" 2>/dev/null | grep -E '[0-9]+/[0-9]+' | tail -1)"
    PT="$(printf '%s' "$_L" | grep -oE '[0-9]+/[0-9]+' | head -1)"
    if [ -n "$PT" ]; then
      PROBE_PASS=$((PROBE_PASS + ${PT%%/*})); PROBE_TOTAL=$((PROBE_TOTAL + ${PT##*/}))
    else
      PROBLEMS="$PROBLEMS $pr:meter-missing"
    fi
    SK="$(printf '%s' "$_L" | grep -oE '[0-9]+ SKIP deep' | grep -oE '[0-9]+' | head -1)"
    PROBE_SKIP=$((PROBE_SKIP + ${SK:-0}))
    echo "  [$pr REUSED] ${PT:-no-meter} SKIP=${SK:-0}"
  done
  st_end "$([ -z "$PROBLEMS" ] && echo 0 || echo 1)" "$([ -z "$PROBLEMS" ] && echo PASS || echo FAIL)" \
    "REUSED PROBES $PROBE_PASS/$PROBE_TOTAL SKIP=$PROBE_SKIP" "${PROBLEMS:-none}"
else
  st_begin 5 "三探针 ${PROBE_DEEP:+(deep=$PROBE_DEEP)}"
  echo "  ($RREASON)"
  for pr in mcp-probe a2a-probe example-probe; do
    ( cd "$PKG" && "$PY" "qa/deploy-probes/$pr.py" > "$LOGD/$pr.log" 2>&1 ); RC=$?
    LINE="$(grep -E 'SUMMARY|RESULT' "$LOGD/$pr.log" 2>/dev/null | grep -E '[0-9]+/[0-9]+' | tail -1)"
    echo "  [$pr rc=$RC] ${LINE:-no-meter}"
    PT="$(printf '%s' "$LINE" | grep -oE '[0-9]+/[0-9]+' | head -1)"
    if [ -n "$PT" ]; then
      PROBE_PASS=$((PROBE_PASS + ${PT%%/*})); PROBE_TOTAL=$((PROBE_TOTAL + ${PT##*/}))
    else
      PROBLEMS="$PROBLEMS $pr:no-count"
    fi
    SK="$(printf '%s' "$LINE" | grep -oE '[0-9]+ SKIP deep' | grep -oE '[0-9]+' | head -1)"
    PROBE_SKIP=$((PROBE_SKIP + ${SK:-0}))
    [ $RC -ne 0 ] && PROBLEMS="$PROBLEMS $pr:rc=$RC"
  done
  # 项数即断言：探针增删 case 必须同步此处，否则本段 FAIL（刻意的同步面告警）
  EXP_TOTAL=34; EXP_SKIP=4
  [ "$PROBE_DEEP" = "1" ] && { EXP_TOTAL=38; EXP_SKIP=0; }
  [ "$PROBE_TOTAL" != "$EXP_TOTAL" ] && PROBLEMS="$PROBLEMS total-$PROBE_TOTAL!=$EXP_TOTAL"
  [ "$PROBE_SKIP" != "$EXP_SKIP" ] && PROBLEMS="$PROBLEMS skip-$PROBE_SKIP!=$EXP_SKIP"
  st_end "$([ -z "$PROBLEMS" ] && echo 0 || echo 1)" "$([ -z "$PROBLEMS" ] && echo PASS || echo FAIL)" \
    "PROBES $PROBE_PASS/$PROBE_TOTAL SKIP=$PROBE_SKIP deep=$PROBE_DEEP" "${PROBLEMS:-none}"
fi
[ -z "$PROBLEMS" ] || FAILS="$FAILS probes"

# 探针刚全绿 → 落候选 stamp（deploy_ok=0，只有 deploy.sh 全链零 FAIL 才升 1）
if [ -z "$PROBLEMS" ] && [ $REUSE -eq 0 ]; then
  mkdir -p "$(dirname "$STAMP")" 2>/dev/null || true
  printf 'epoch=%s\npkg=%s\ndeploy_ok=0\n' "$(date +%s)" "$PKG" > "$STAMP" 2>/dev/null || true
fi

# ── 5d 终态矩阵 ──
st_begin 5d "终态矩阵（fresh / mcp / health / skills / VM）"
VRC=0
"$NODE" "$PKG/delivery/install-host.mjs" --check-fresh > "$LOGD/fresh.txt" 2>&1; FRC=$?
tail -1 "$LOGD/fresh.txt"
[ $FRC -ne 0 ] && VRC=1
"$NODE" -e 'const j=require(process.env.HOME+"/.workbuddy/mcp.json");for(const k of Object.keys(j.mcpServers||{}))if(/winvm/i.test(k))console.log(k,"disabledTools="+(j.mcpServers[k].disabledTools||[]).length)' 2>/dev/null | tee "$LOGD/disabled.txt" | head -2
HC="$(health_code "${WINVM_TUNNEL_LOCAL_PORT:-18443}" 15)"; echo "health=$HC" | tee "$LOGD/health.txt"
[ "$HC" = "200" ] || VRC=1
SKCNT="$(ls "$HOME/.workbuddy/connectors/skills/connector-winvm/" 2>/dev/null | awk 'END{print NR+0}')"
echo "connector skills=$SKCNT" | tee -a "$LOGD/health.txt"
[ "${SKCNT:-0}" -ge 8 ] || VRC=1

ENV_WINDOW=0
if [ -n "${VM_HOST:-}" ]; then
  # 原生原语（CIM 全枚举 20-35s 是旧版元凶）：schtasks /fo CSV + .NET GetActiveTcpListeners
  bash "$SCRIPTDIR/ps-run.sh" -c '$r=@(schtasks /query /tn WinVMBridge.Service /fo CSV /nh 2>$null | ConvertFrom-Csv -Header n,next,status); $t=if ($r.Count -gt 0) { [string]$r[0].status } else { "absent" }; $l=@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -eq 18443 }).Count; $s=(Get-Service sshd).Status; Write-Output ("VM: task=" + $t + " listen=" + $l + " sshd=" + $s)' \
    2>/dev/null | tr -d '\r' > "$LOGD/vm-terminal.txt"; VTRC=${PIPESTATUS[0]}
  cat "$LOGD/vm-terminal.txt" 2>/dev/null
  if [ $VTRC -ne 0 ] || ! grep -q "VM: task=" "$LOGD/vm-terminal.txt" 2>/dev/null; then
    echo "⚠ VM 终态行取不到（rc=$VTRC）= 通道瞬态窗，环境问题非功能失败" >&2
    ENV_WINDOW=1
  fi
else
  warn "VM_HOST 未设：跳过 VM 终态行（只做 host 侧矩阵）"
  ENV_WINDOW=1
fi
st_end $VRC "$([ $VRC -eq 0 ] && echo PASS || echo FAIL)" \
  "matrix$( [ "$ENV_WINDOW" = "1" ] && echo ' +ENV_WINDOW')" \
  "$([ $VRC -eq 0 ] && echo none || echo "看 $LOGD")"
[ $VRC -ne 0 ] && FAILS="$FAILS matrix"

steps_report
if [ -n "$FAILS" ]; then
  echo "VERIFY=FAIL:$FAILS（只重跑失败探针或矩阵，别重跑整链）"
  exit 1
fi
if [ "$ENV_WINDOW" = "1" ]; then
  echo "VERIFY=INCOMPLETE ENV_WINDOW=1（等健康窗只重跑本脚本；绝不重启 VM）"
  exit 2
fi
echo "VERIFY=PASS"
state_set VERIFY_OK 1
