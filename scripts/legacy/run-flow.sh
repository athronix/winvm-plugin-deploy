#!/usr/bin/env bash
# winvm-plugin-deploy · 统一维护入口 (v1.7.0) — ONE CALL for undeploy -> deploy -> verify
#
# User ruling 2026-11-13:
#  - Merge consecutive actions into ONE script, executed once, same environment,
#    same executor, with NO user/LLM decision in between.
#  - Every dynamic value is fetched BEFOREHAND by context.sh collect, frozen into
#    vmdeploy-context.env, and injected as PARAMETERS into every downstream action.
#  - Front stage prints ONLY the final process action table; all intermediate
#    detail (before/after state, per-action logs, durations, rc, errors) is saved
#    to the run dir. VERBOSE=1 streams intermediate detail (for testing).
#
# Usage (one command, no mid-chain decisions):
#   VM_HOST=172.16.100.2 bash scripts/run-flow.sh                  # default ACTION=full
#   VM_HOST=... ACTION=deploy  bash scripts/run-flow.sh            # targeted re-run
#   VM_HOST=... ACTION=verify VERBOSE=1 bash scripts/run-flow.sh  # test with detail
#   VM_HOST=... REGISTRY_FIX=1 bash scripts/run-flow.sh            # also fix skill registry drift
# All other parameters (VM_USER/VM_SSH_PORT/WINVM_VM_KEY/PKG_ROOT/NODE/PY/
# BASH_OK/RELEASE_TAG/PROBE_FRESH_BUDGET_S) come from the frozen context.
set -u
_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${ACTION:=full}"
: "${VERBOSE:=0}"
: "${REGISTRY_FIX:=0}"
: "${VMDEPLOY_RUN_DIR:=${HOME}/wbtmp/flow-$(date +%Y%m%d-%H%M%S)}"
: "${VMDEPLOY_CONTEXT_ENV:=${HOME}/wbtmp/vmdeploy-context.env}"
export VMDEPLOY_RUN_DIR VMDEPLOY_CONTEXT_ENV ACTION VERBOSE
mkdir -p "$VMDEPLOY_RUN_DIR"
T0=$(date +%s)
say(){ echo "[$(date +%H:%M:%S)] $*"; }
vlog(){ [ "$VERBOSE" = "1" ] && echo "[detail] $*" || true; }

# ── Phase A: freeze every dynamic fact ONCE (no LLM decision afterwards) ──
if [ "$REGISTRY_FIX" = "1" ]; then
  bash "$_here/context.sh" collect --fix-registry > "$VMDEPLOY_RUN_DIR/context.log" 2>&1
else
  bash "$_here/context.sh" collect > "$VMDEPLOY_RUN_DIR/context.log" 2>&1
fi
CRC=$?
if [ $CRC -ne 0 ]; then
  cat "$VMDEPLOY_RUN_DIR/context.log" >&2
  echo "RUN_FLOW=ABORT reason=context-collect-failed rc=$CRC (P-1: VM_HOST/VM_USER 由用户提供)" >&2
  exit 2
fi
# shellcheck disable=SC1090
. "$VMDEPLOY_CONTEXT_ENV"
# PKG_ROOT is deliberately NOT exported: roundtrip R1 resolves the LATEST
# release and writes pkg-root.txt; exporting a frozen (possibly stale) value
# would make deploy.sh set PKG_EXPLICIT=1 and skip that resolution.
export VM_HOST VM_USER VM_SSH_PORT WINVM_VM_KEY VM_SSH_BACKEND DEPLOY_ROOT \
       RELEASE_TAG NODE PY BASH_OK PROBE_FRESH_BUDGET_S SKILL_VERSION
vlog "context frozen: host=$VM_HOST user=$VM_USER key=$WINVM_VM_KEY skill=$SKILL_VERSION"
[ "$VERBOSE" = "1" ] && cat "$VMDEPLOY_CONTEXT_ENV" | grep -v '^#' || true

# ── Phase B: full state snapshot BEFORE (health + VM terminal) ──
bash "$_here/context.sh" snapshot pre-flow full > "$VMDEPLOY_RUN_DIR/snapshot-before.log" 2>&1 || true
vlog "pre-flow full snapshot saved"

# ── Phase C: the whole maintenance chain, ONE background-safe call ──
# roundtrip.sh is the single source of truth for the action sequence; driver
# scripts remain re-runnable individually for targeted repair.
say "RUN_FLOW START action=$ACTION skill=$SKILL_VERSION run_dir=$VMDEPLOY_RUN_DIR"
if [ "$VERBOSE" = "1" ]; then
  bash "$_here/roundtrip.sh" 2>&1 | tee "$VMDEPLOY_RUN_DIR/console.log"
  RC=${PIPESTATUS[0]}
else
  bash "$_here/roundtrip.sh" > "$VMDEPLOY_RUN_DIR/console.log" 2>&1
  RC=$?
fi
WALL=$(( $(date +%s) - T0 ))

# ── Phase D: full state snapshot AFTER + machine-readable result ──
bash "$_here/context.sh" snapshot post-flow full > "$VMDEPLOY_RUN_DIR/snapshot-after.log" 2>&1 || true
RESULT="$(grep -A8 '== ROUNDTRIP_RESULT ==' "$VMDEPLOY_RUN_DIR/console.log" 2>/dev/null | tail -8)"
{
  echo "== RUN_FLOW_RESULT =="
  echo "ACTION=$ACTION RC=$RC WALL_S=$WALL SKILL_VERSION=$SKILL_VERSION"
  echo "VERDICT_LINE=$(grep '^VERDICT=' "$VMDEPLOY_RUN_DIR/console.log" 2>/dev/null | tail -1)"
  echo "RUN_DIR=$VMDEPLOY_RUN_DIR"
  echo "LOGS=console.log,steps.tsv,actions.tsv,logs/,states/,state-*.txt,snapshot-*.log"
  printf '%s\n' "$RESULT"
} > "$VMDEPLOY_RUN_DIR/run-flow-result.txt"

# ── Phase E: deterministic branch resolution (NO free-form agent decisions) ──
if grep -q 'NEED_USER_ACTION=1' "$VMDEPLOY_RUN_DIR/console.log" 2>/dev/null; then
  echo "NEXT_ACTION=USER_VM_PASTE_ONCE -> bash scripts/channel.sh confirm -> ACTION=deploy bash scripts/run-flow.sh" >> "$VMDEPLOY_RUN_DIR/run-flow-result.txt"
fi
if grep -q 'ENV_WINDOW=1' "$VMDEPLOY_RUN_DIR/console.log" 2>/dev/null; then
  echo "NEXT_ACTION=WAIT_HEALTHY_WINDOW -> ACTION=verify bash scripts/run-flow.sh (NEVER reboot VM)" >> "$VMDEPLOY_RUN_DIR/run-flow-result.txt"
fi
if grep -q 'channel-unstable' "$VMDEPLOY_RUN_DIR/console.log" 2>/dev/null; then
  echo "NEXT_ACTION=GATE_CHANNEL_UNSTABLE -> bash scripts/channel.sh confirm; if READY then ACTION=deploy bash scripts/run-flow.sh" >> "$VMDEPLOY_RUN_DIR/run-flow-result.txt"
fi
if [ $RC -ne 0 ]; then
  FAILED="$(grep '^VERDICT=' "$VMDEPLOY_RUN_DIR/console.log" 2>/dev/null | tail -1)"
  echo "NEXT_ACTION=TARGETED_RERUN -> 查 references/troubleshooting.md 对应现象行, 用 ACTION=<失败过程> bash scripts/run-flow.sh 定点重跑" >> "$VMDEPLOY_RUN_DIR/run-flow-result.txt"
  vlog "chain failed: $FAILED"
fi

# ── Phase F: generate + print the FINAL process action table ONLY ──
if [ "$VERBOSE" = "1" ]; then
  echo "=== [VERBOSE] 中间执行结果 ==="
  cat "$VMDEPLOY_RUN_DIR/run-flow-result.txt"
  echo "=== [VERBOSE] console.log 关键行 ==="
  grep -E 'RT-STEP|^R[0-9]|FAIL|PASS|VERDICT|NEED_USER_ACTION|ENV_WINDOW' "$VMDEPLOY_RUN_DIR/console.log" 2>/dev/null | tail -30
fi
bash "$_here/action-report.sh" > "$VMDEPLOY_RUN_DIR/process-table.stdout" 2>&1
# front stage: result block + final table (nothing else)
cat "$VMDEPLOY_RUN_DIR/run-flow-result.txt"
echo ""
cat "$VMDEPLOY_RUN_DIR/process-table.stdout"
exit $RC
