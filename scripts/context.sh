#!/usr/bin/env bash
# winvm-plugin-deploy · context.sh (v1.7.0)
# Responsibility: collect EVERY dynamic fact ONCE, up front, and freeze it into a
# sourceable env file. All later actions take these as PARAMETERS (user ruling
# 2026-11-13: "dynamic parts are fetched beforehand and injected into script
# parameters"). No LLM/user decision is needed between actions.
#
# Usage:
#   bash scripts/context.sh collect                 # -> $VMDEPLOY_CONTEXT_ENV (default ~/wbtmp/vmdeploy-context.env)
#   bash scripts/context.sh collect --fix-registry # also repair stale duplicate skill registrations
#   bash scripts/context.sh snapshot <label>       # lightweight pre/post state -> $RUN_DIR/state-<label>.txt
#   bash scripts/context.sh snapshot <label> full  # + health/VM terminal (one ssh2 round trip)
#   bash scripts/context.sh show                   # print frozen facts (no secrets)
#
# Collected facts (all injected into driver arguments by run-flow.sh):
#   VM_HOST VM_USER VM_SSH_PORT WINVM_VM_KEY VM_SSH_BACKEND
#   PKG_ROOT DEPLOY_ROOT RELEASE_TAG NODE PY BASH_OK
#   SKILL_ROOT SKILL_VERSION SKILL_REGISTRY_DRIFT
#   VMDEPLOY_RUN_DIR VMDEPLOY_CONTEXT_ENV
set -u
_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL_ROOT="$(dirname "$_here")"
: "${VMDEPLOY_CONTEXT_ENV:=${HOME}/wbtmp/vmdeploy-context.env}"
: "${VMDEPLOY_RUN_DIR:=${HOME}/wbtmp/vmdeploy-run-$(date +%Y%m%d-%H%M)}"
: "${DEPLOY_ROOT:=${HOME}/winvm-deploy}"
: "${VMDEPLOY_ENV_SH:=${HOME}/wbtmp/vmdeploy-env.sh}"
PY="${PY:-$(command -v python3 || true)}"; [ -n "$PY" ] || PY=/data/service/hnp/bin/python3
mkdir -p "$(dirname "$VMDEPLOY_CONTEXT_ENV")" "$VMDEPLOY_RUN_DIR"

# ---- lightweight state: local facts only, <0.1s, safe at every action boundary ----
_light_state() {
  local out="$1"
  {
    echo "SNAPSHOT_AT=$(date -u +%FT%TZ) epoch=$(date +%s)"
    echo "-- vm-conn.json"; [ -f "$HOME/.workbuddy/winvm/vm-conn.json" ] && tr -d '\n' < "$HOME/.workbuddy/winvm/vm-conn.json" || echo ABSENT; echo
    echo "-- vm-conn.json.roundtrip"; [ -f "$HOME/.workbuddy/winvm/vm-conn.json.roundtrip" ] && echo PRESENT || echo ABSENT
    echo "-- probe-stamp"; [ -f "$HOME/wbtmp/vmdeploy-probes-stamp.txt" ] && grep -E '^(epoch|pkg|deploy_ok)=' "$HOME/wbtmp/vmdeploy-probes-stamp.txt" | tr '\n' ' ' || echo ABSENT; echo
    echo "-- pkg-root.txt"; cat "$DEPLOY_ROOT/pkg-root.txt" 2>/dev/null || echo ABSENT
    echo "-- tunnel-pids"; ls -1 "$HOME/.workbuddy/winvm/"*.pid 2>/dev/null | tr '\n' ' ' || true; echo
    echo "-- mcp-winvm-keys"; "$PY" -c '
import json,os
try:
 d=json.load(open(os.path.expanduser("~/.workbuddy/mcp.json")));k=[x for x in d.get("mcpServers",{}) if "winvm" in x.lower()]
 print(len(k)," ".join(k))
except Exception as e: print("ERR",e)' 2>&1
    echo "-- plugin-cache"; ls -1 "$HOME/.workbuddy/plugins/cache/winvm/" 2>/dev/null | tr '\n' ' ' || true; echo
    echo "-- connector-skills"; ls -1 "$HOME/.workbuddy/connectors/skills/connector-winvm/" 2>/dev/null | wc -l
    echo "-- side.json"; [ -f "$HOME/.workbuddy/winvm/side.json" ] && echo PRESENT || echo ABSENT
  } > "$out" 2>&1
}

snapshot() {
  local label="${1:?snapshot needs a label}" mode="${2:-light}" out="$VMDEPLOY_RUN_DIR/state-${1}.txt"
  _light_state "$out"
  if [ "$mode" = full ]; then
    {
      echo "-- health"; curl -sS --noproxy 127.0.0.1 --max-time 8 -o /dev/null -w 'http=%{http_code} t=%{time_total}s\n' "http://127.0.0.1:${WINVM_TUNNEL_LOCAL_PORT:-18443}/health" 2>&1 || echo UNREACHABLE
      echo "-- vm-terminal"; if [ -n "${VM_HOST:-}" ] && [ -x "${BASH_OK:-}" ]; then
        "${BASH_OK}" "$_here/ps-run.sh" -c '$t=(Get-ScheduledTask -TaskName WinVMBridge.Service -EA SilentlyContinue).State; $l=@(Get-NetTCPConnection -LocalPort 18443 -State Listen -EA SilentlyContinue).Count; $s=(Get-Service sshd).Status; Write-Output ("VM: task=" + $t + " listen=" + $l + " sshd=" + $s)' 2>&1 | tr -d '\r' | tail -2
      else echo "(VM_HOST/BASH_OK not frozen; skipped)"; fi
    } >> "$out" 2>&1
  fi
  echo "STATE_SAVED=$out"
}

# ---- skill self-attestation: the loaded skill version must match canonical ----
# Drift found 2026-11-13: ~/.workbuddy/.skill-list-cache.json registered FOUR
# same-name skills; the tool loaded the OLDEST backup (v1.2.2) instead of v1.6.0.
_registry_check() {
  local cache="$HOME/.workbuddy/.skill-list-cache.json" drift=0 count=0
  [ -f "$cache" ] || { echo "SKILL_REGISTRY_DRIFT=UNKNOWN(cache-absent)"; return; }
  count=$("$PY" -c '
import json,os
p=os.path.expanduser("~/.workbuddy/.skill-list-cache.json")
try:
 d=json.load(open(p,encoding="utf-8"));r=d.get("results",[])
 hits=[x for x in r if isinstance(x,dict) and x.get("name")=="winvm-plugin-deploy"]
 print(len(hits))
except Exception: print(0)' 2>/dev/null || echo 0)
  if [ "$count" -gt 1 ] 2>/dev/null; then
    drift=1
    echo "SKILL_REGISTRY_DRIFT=DUP($count)" >&2
    echo "  [context] WARN: $count same-name winvm-plugin-deploy registrations." >&2
    echo "  [context] Deterministic fix: bash scripts/context.sh collect --fix-registry" >&2
  fi
  echo "SKILL_REGISTRY_DRIFT=$drift"
}

_fix_registry() {
  local store="$HOME/.workbuddy/skills" pyout
  # Move (never delete) duplicate backup entries out of the skill scan root.
  # Symlink backups and stale unzip backups are pure registry pollution.
  for d in "$store"/winvm-plugin-deploy.backup-symlink-* "$store"/.backup-winvm-plugin-deploy-unzip-*; do
    [ -e "$d" ] || [ -L "$d" ] || continue
    local dest="$HOME/wbtmp/skill-registry-quarantine/$(basename "$d")"
    mkdir -p "$(dirname "$dest")"
    "$PY" -c 'import os,sys;os.rename(sys.argv[1],sys.argv[2]);print("QUARANTINED="+os.path.basename(sys.argv[1]))' "$d" "$dest" 2>/dev/null \
      || echo "  [context] WARN: could not quarantine $(basename "$d")" >&2
  done
  # Rebuild the cache signature so the host re-scans on next session.
  local cache="$HOME/.workbuddy/.skill-list-cache.json"
  if [ -f "$cache" ]; then
    "$PY" - "$cache" <<'PYEOF'
import json,os,sys
p=sys.argv[1]
try:
    d=json.load(open(p,encoding="utf-8"))
    seen=set(); out=[]
    for x in d.get("results",[]):
        if isinstance(x,dict) and x.get("name")=="winvm-plugin-deploy":
            fp=x.get("filePath","")
            if fp in seen: continue
            seen.add(fp)
        out.append(x)
    d["results"]=out; d["signature"]="invalidated-by-winvm-plugin-deploy-context-v1.7.0"
    json.dump(d,open(p,"w",encoding="utf-8"),ensure_ascii=False)
    print("  [context] cache de-duplicated, signature invalidated")
except Exception as e:
    print("  [context] cache rewrite skipped:",e)
PYEOF
  fi
  echo "  [context] NOTE: restart the session/IDE to force a fresh skill scan."
}

# F-22 (E2E3 round-2 实证): vm-conn.json.identityFile 会被部署端默认探测写成
# ~/.ssh/id_ed25519，而 VM 实际授权的可能是 id_ed25519_winvm。旧 collect 无验证
# 直接采信 ⇒ 卸载误判「通道坏」→ VM 合并包 → 判稳 4 轮 DOWN → GATE 停链，
# 把确定性密钥漂移误报成「环境灭窗」。同秒双钥实测：默认钥 rc=111
# (All configured authentication methods failed) / 专用钥 rc=0 pong ready。
# 修法：候选钥逐一用 **新建连接** ssh2 ping 单发实测，冻结第一个 READY；
# 全败才保留首选并标记 ALL_FAILED（由下游 GATE 判读，绝不在此重建通道/重启 VM）。
_pick_vm_key() {
  local preferred="$1" k rc seen=" " out=""
  local _n="${NODE:-$(command -v node || echo /data/storage/el1/bundle/libs/arm64/node/bin/node)}"
  [ -x "$_n" ] || _n=/data/service/hnp/bin/node
  for k in "$preferred" "$HOME/.ssh/id_ed25519_winvm" "$HOME/.ssh/id_ed25519"; do
    [ -n "$k" ] && [ -f "$k" ] || continue
    case "$seen" in *" $k "*) continue;; esac
    seen="$seen$k "
    timeout 15 env VM_HOST="$VM_HOST" VM_USER="$VM_USER" VM_SSH_PORT="$VM_SSH_PORT" \
      WINVM_VM_KEY="$k" "$_n" "$_here/ssh2-conn.mjs" ping >/dev/null 2>&1
    rc=$?
    echo "  [context] key-probe rc=$rc key=$k" >&2
    if [ $rc -eq 0 ]; then out="$k"; break; fi
  done
  if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
  echo "  [context] KEY_PROBE_ALL_FAILED: keep preferred key; downstream GATE decides (NEVER reboot VM)" >&2
  printf '%s' "$preferred"; return 1
}

collect() {
  local fix=0; [ "${1:-}" = "--fix-registry" ] && fix=1
  [ $fix -eq 1 ] && _fix_registry
  # --- VM connection facts: vm-conn.json, else the .roundtrip snapshot ---
  local V="$HOME/.workbuddy/winvm/vm-conn.json"
  if [ ! -f "$V" ] && [ -f "$V.roundtrip" ]; then
    cp -f "$V.roundtrip" "$V" && echo "  [context] vm-conn.json restored from .roundtrip (uninstalled-state bootstrap)" >&2
  fi
  local HOST="" USER="" PORT="22" KEY=""
  if [ -f "$V" ]; then
    HOST=$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("host",""))' "$V" 2>/dev/null)
    USER=$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("user","User"))' "$V" 2>/dev/null)
    PORT=$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("sshPort",22))' "$V" 2>/dev/null)
    KEY=$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("identityFile",""))' "$V" 2>/dev/null)
  fi
  : "${VM_HOST:=$HOST}"; : "${VM_USER:=$USER}"; : "${VM_SSH_PORT:=$PORT}"
  : "${WINVM_VM_KEY:=${KEY:-$HOME/.ssh/id_ed25519}}"
  local KEY_PROBE=ALL_FAILED
  if WINVM_VM_KEY="$(_pick_vm_key "$WINVM_VM_KEY")"; then KEY_PROBE=READY; fi
  [ -n "$VM_HOST" ] || { echo "FATAL: VM_HOST unresolved (P-1: ask the user for host/user)" >&2; exit 2; }
  # --- runtime (env-detect output is a product, not a decision) ---
  [ -f "$VMDEPLOY_ENV_SH" ] && . "$VMDEPLOY_ENV_SH" 2>/dev/null || true
  : "${NODE:=$(command -v node || echo /data/service/hnp/bin/node)}"
  : "${PY:=$(command -v python3 || echo /data/service/hnp/bin/python3)}"
  : "${BASH_OK:=$(command -v bash || echo /data/storage/el1/bundle/libs/arm64/bash/bin/bash)}"
  : "${VM_SSH_BACKEND:=ssh2}"
  : "${PKG_ROOT:=$(cat "$DEPLOY_ROOT/pkg-root.txt" 2>/dev/null)}"
  : "${RELEASE_TAG:=}"
  : "${PROBE_FRESH_BUDGET_S:=600}"
  local VER; VER="$(grep -m1 '^version:' "$SKILL_ROOT/SKILL.md" 2>/dev/null | tr -d ' \r')"; VER="${VER#version:}"
  local DRIFT; DRIFT="$(_registry_check 2>/dev/null | tail -1)"; DRIFT="${DRIFT#SKILL_REGISTRY_DRIFT=}"
  {
    echo "# frozen by context.sh collect at $(date -u +%FT%TZ)"
    printf 'VM_HOST=%q\n' "$VM_HOST"
    printf 'VM_USER=%q\n' "$VM_USER"
    printf 'VM_SSH_PORT=%q\n' "$VM_SSH_PORT"
    printf 'WINVM_VM_KEY=%q\n' "$WINVM_VM_KEY"
    printf 'VM_KEY_PROBE=%q\n' "$KEY_PROBE"
    printf 'VM_SSH_BACKEND=%q\n' "$VM_SSH_BACKEND"
    printf 'PKG_ROOT=%q\n' "$PKG_ROOT"
    printf 'DEPLOY_ROOT=%q\n' "$DEPLOY_ROOT"
    printf 'RELEASE_TAG=%q\n' "$RELEASE_TAG"
    printf 'NODE=%q\n' "$NODE"
    printf 'PY=%q\n' "$PY"
    printf 'BASH_OK=%q\n' "$BASH_OK"
    printf 'PROBE_FRESH_BUDGET_S=%q\n' "$PROBE_FRESH_BUDGET_S"
    printf 'VMDEPLOY_RUN_DIR=%q\n' "$VMDEPLOY_RUN_DIR"
    printf 'VMDEPLOY_CONTEXT_ENV=%q\n' "$VMDEPLOY_CONTEXT_ENV"
    printf 'SKILL_ROOT=%q\n' "$SKILL_ROOT"
    printf 'SKILL_VERSION=%q\n' "$VER"
    printf 'SKILL_REGISTRY_DRIFT=%q\n' "$DRIFT"
  } > "$VMDEPLOY_CONTEXT_ENV"
  echo "CONTEXT_SAVED=$VMDEPLOY_CONTEXT_ENV"
  echo "  VM_HOST=$VM_HOST VM_USER=$VM_USER port=$VM_SSH_PORT backend=$VM_SSH_BACKEND"
  echo "  WINVM_VM_KEY=$WINVM_VM_KEY VM_KEY_PROBE=$KEY_PROBE"
  echo "  PKG_ROOT=${PKG_ROOT:-(resolved by download-verify)}"
  echo "  SKILL_VERSION=$VER SKILL_REGISTRY_DRIFT=$DRIFT"
  snapshot pre-flow light >/dev/null
}

case "${1:-collect}" in
  collect) shift || true; collect "$@" ;;
  snapshot) shift || true; snapshot "$@" ;;
  show) [ -f "$VMDEPLOY_CONTEXT_ENV" ] && grep -vE '^#|KEY' "$VMDEPLOY_CONTEXT_ENV" || echo "(no frozen context)" ;;
  *) echo "usage: context.sh collect [--fix-registry] | snapshot <label> [full] | show" >&2; exit 2 ;;
esac
