#!/usr/bin/env bash
# winvm-plugin-deploy · step timer / ACTION-LEVEL trace (v1.7.0)
# v1.7.0 adds (backward compatible; steps.tsv format UNCHANGED):
#   - actions.tsv : one row per BASIC MAINTENANCE ACTION with pre/post state,
#                   error excerpt, exact command, executor, env, next-branch,
#                   mergeability (metadata from action-catalog.tsv)
#   - states/<phase>-<step>-pre|post.txt : lightweight before/after snapshots
# Usage:
#   step.sh begin <phase> <step-id> "<desc>"
#   step.sh end   <phase> <step-id> <rc> <PASS|FAIL|SKIP> "<judged>" ["<issue>"]
#   step.sh log   <step-id>            # raw output -> logs/<step>.log
#   step.sh report                     # legacy summary + process action table path
set -u
RUN_DIR="${VMDEPLOY_RUN_DIR:-${HOME}/wbtmp/vmdeploy-run-$(date +%Y%m%d)}"
mkdir -p "$RUN_DIR/logs" "$RUN_DIR/stamps" "$RUN_DIR/states"
TSV="$RUN_DIR/steps.tsv"
ATS="$RUN_DIR/actions.tsv"
_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CAT="$_here/action-catalog.tsv"
: "${NODE:=$(command -v node || true)}"
PY="${PY:-$(command -v python3 || true)}"; [ -n "$PY" ] || PY=/data/service/hnp/bin/python3
[ -f "$TSV" ] || printf 'phase\tstep\tdesc\tbegin_utc\tend_utc\tdur_s\trc\tresult\tjudged\tissues_solution\n' > "$TSV"
[ -f "$ATS" ] || printf 'seq\tprocess\tphase\tstep\tdesc\tcmd\tsubject\tenv\tbegin_utc\tend_utc\tdur_s\trc\tresult\tjudged\tissues\tpre_state\tpost_state\tlog_path\terror_excerpt\tnext_ok\tnext_fail\tmergeable\n' > "$ATS"
now_iso() { date -u +%FT%TZ; }
_safe() { printf '%s' "${1:-}" | tr '\t\n\r' '   '; }

# Lightweight local state (<0.1s, no network) - safe at EVERY action boundary.
_mini_state() {
  local out="$1"
  {
    echo "at=$(now_iso) epoch=$(date +%s)"
    printf 'vm-conn='; [ -f "$HOME/.workbuddy/winvm/vm-conn.json" ] && tr -d '\n' < "$HOME/.workbuddy/winvm/vm-conn.json" || printf ABSENT; echo
    printf 'vm-conn-roundtrip='; [ -f "$HOME/.workbuddy/winvm/vm-conn.json.roundtrip" ] && echo PRESENT || echo ABSENT
    printf 'probe-stamp='; [ -f "$HOME/wbtmp/vmdeploy-probes-stamp.txt" ] && grep -E '^(pkg|deploy_ok)=' "$HOME/wbtmp/vmdeploy-probes-stamp.txt" | tr '\n' ' ' || printf ABSENT; echo
    printf 'pkg-root='; cat "${DEPLOY_ROOT:-$HOME/winvm-deploy}/pkg-root.txt" 2>/dev/null || printf ABSENT; echo
    printf 'mcp-winvm-keys='; "$PY" -c '
import json,os
try:
 d=json.load(open(os.path.expanduser("~/.workbuddy/mcp.json")));k=[x for x in d.get("mcpServers",{}) if "winvm" in x.lower()]
 print(len(k)," ".join(k))
except Exception as e: print("ERR",e)' 2>&1
    printf 'plugin-cache='; ls -1 "$HOME/.workbuddy/plugins/cache/winvm/" 2>/dev/null | tr '\n' ' '; echo
    printf 'connector-skills='; ls -1 "$HOME/.workbuddy/connectors/skills/connector-winvm/" 2>/dev/null | wc -l
    printf 'tunnel-pids='; ls -1 "$HOME/.workbuddy/winvm/"*.pid 2>/dev/null | tr '\n' ' '; echo
  } > "$out" 2>&1
}

# catalog lookup: key="phase/step", returns 8 tab-separated fields
_catalog() {
  "$PY" - "$CAT" "$1" <<'PYEOF'
import sys
cat,key=sys.argv[1],sys.argv[2]
fields=["-"]*8
try:
    for line in open(cat,encoding="utf-8"):
        if not line.strip() or line.startswith("#"): continue
        p=line.rstrip("\n").split("\t")
        if p[0]==key:
            fields=(p[1:9]+["-"]*8)[:8]
            break
except Exception: pass
print("\t".join(x.replace("\t"," ").replace("\n"," ") for x in fields))
PYEOF
}

_error_excerpt() {
  local f="$1" out=""
  [ -f "$f" ] || { echo "-"; return; }
  # F-24: capture first, normalise after - a pipeline's status is the last command's,
  # so `... | cut || echo "-"` never produced '-' for a clean log (empty field instead).
  # F-25: the HarmonyOS sandbox prints getcwd/chdir notices on every bash spawn; they
  # match the keywords but are pure noise - deny-list before excerpting.
  out="$(grep -iE 'error|fail|timeout|refused|denied|rc=[1-9]|exception|fatal|traceback' "$f" 2>/dev/null \
    | grep -vE 'getcwd: cannot access parent directories|chdir: error retrieving current directory|shell-init: error retrieving current directory' \
    | tail -3 | tr '\t\n\r' '   ' | cut -c1-220 || true)"
  out="$(printf '%s' "$out" | sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//')"
  if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "-"; fi
}

cmd="${1:-report}"; shift || true
case "$cmd" in
  begin)
    phase="${1:?phase}"; step="${2:?step-id}"; desc="${3:-}"
    date -u +%s > "$RUN_DIR/stamps/$step"
    printf '%s\t%s\t%s\n' "$phase" "$(now_iso)" "$desc" > "$RUN_DIR/stamps/$step.meta"
    _mini_state "$RUN_DIR/states/${phase}-${step}-pre.txt"
    echo "[$(now_iso)] BEGIN ${phase}/${step} ${desc}"
    ;;
  end)
    phase="${1:?}"; step="${2:?}"; rc="${3:-0}"; result="${4:-PASS}"; judged="${5:-}"; issue="${6:-none}"
    st="$RUN_DIR/stamps/$step"; b=$( [ -f "$st" ] && cat "$st" || echo "")
    e=$(date -u +%s)
    dur=$([ -n "$b" ] && echo $((e - b)) || echo "")
    meta="$RUN_DIR/stamps/$step.meta"; b_iso=$( [ -f "$meta" ] && cut -f2 "$meta" || echo ""); desc=$( [ -f "$meta" ] && cut -f3 "$meta" || echo "")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$phase" "$step" "$(_safe "$desc")" "$b_iso" "$(now_iso)" "${dur:-}" \
      "$rc" "$result" "$(_safe "$judged")" "$(_safe "$issue")" >> "$TSV"
    # ---- action-level row ----
    PRE="$RUN_DIR/states/${phase}-${step}-pre.txt"; POST="$RUN_DIR/states/${phase}-${step}-post.txt"
    _mini_state "$POST"
    CATROW="$(_catalog "${phase}/${step}")"
    PROCESS="$(printf '%s' "$CATROW" | cut -f1)"; CMD="$(printf '%s' "$CATROW" | cut -f2)"
    SUBJECT="$(printf '%s' "$CATROW" | cut -f3)"; ENVX="$(printf '%s' "$CATROW" | cut -f4)"
    NEXTOK="$(printf '%s' "$CATROW" | cut -f6)"; NEXTFAIL="$(printf '%s' "$CATROW" | cut -f7)"; MERGE="$(printf '%s' "$CATROW" | cut -f8)"
    LOGP="$RUN_DIR/logs/${step}.log"; [ -f "$LOGP" ] || LOGP="$RUN_DIR/${step}.log"; [ -f "$LOGP" ] || LOGP="-"
    if [ "$LOGP" = "-" ] && [ -f "$RUN_DIR/logs/.index" ]; then
      # F-23: pick the LAST action log written inside this action's [begin,end] window.
      _ln="$(awk -F'\t' -v b="$(( ${b:-0} - 1 ))" -v e="$(( e + 1 ))" \
        '$1>=b && $1<=e {n=$2} END{if(n!="") print n}' "$RUN_DIR/logs/.index" 2>/dev/null)"
      [ -n "$_ln" ] && [ -f "$RUN_DIR/logs/$_ln.log" ] && LOGP="$RUN_DIR/logs/$_ln.log"
    fi
    SEQ=$(( $(wc -l < "$ATS") ))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$SEQ" "$PROCESS" "$phase" "$step" "$(_safe "$desc")" "$(_safe "$CMD")" "$(_safe "$SUBJECT")" "$(_safe "$ENVX")" \
      "$b_iso" "$(now_iso)" "${dur:-}" "$rc" "$result" "$(_safe "$judged")" "$(_safe "$issue")" \
      "$(_safe "$(basename "$PRE")")" "$(_safe "$(basename "$POST")")" "$(_safe "$LOGP")" \
      "$(_safe "$(_error_excerpt "$LOGP")")" "$(_safe "$NEXTOK")" "$(_safe "$NEXTFAIL")" "$(_safe "$MERGE")" >> "$ATS"
    echo "[$(now_iso)] END ${phase}/${step} rc=${rc} ${result} dur=${dur}s"
    ;;
  log)
    step="${1:?step-id}"; cat > "$RUN_DIR/logs/$step.log"
    # F-23 (E2E3): driver logs are named by ACTION (env-check/prepare-vm/...), while
    # `end` receives a step NUMBER (3.0/3.2/...). Record epoch->name so `end` can
    # resolve log_path + error_excerpt deterministically inside its own time window.
    printf '%s\t%s\n' "$(date -u +%s)" "$step" >> "$RUN_DIR/logs/.index"
    echo "LOG_SAVED=$RUN_DIR/logs/$step.log"
    ;;
  report)
    awk -F'\t' 'NR>1{n++; if($6!=""){s+=$6; if($6>max){max=$6;mrow=$1"/"$2" "$6"s"}} if($10!="none"&&$10!="")iss++}
      END{printf "steps=%d sum_dur=%ds slowest=[%s] issue_rows=%d\n", n+0, s+0, mrow, iss+0}' "$TSV"
    echo "--- Top5 by dur ---"
    awk -F'\t' 'NR>1 && $6!=""{print $6"\t"$1"/"$2"\t"$3}' "$TSV" | sort -rn | head -5
    echo "--- 问题行 ---"
    awk -F'\t' 'NR>1 && $10!="none" && $10!=""{print "· "$1"/"$2": "$10}' "$TSV"
    echo "--- 失败/跳过 ---"
    awk -F'\t' 'NR>1 && ($7!="0" || $8!="PASS"){print "· "$1"/"$2" rc="$7" "$8" "$10}' "$TSV"
    cp "$TSV" "$RUN_DIR/summary.txt" 2>/dev/null
    echo "TSV=$TSV"; echo "ACTIONS=$ATS"; echo "LOGS=$RUN_DIR/logs"
    ;;
  *) echo "用法：step.sh begin|end|log|report …" >&2; exit 2 ;;
esac
