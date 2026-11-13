#!/usr/bin/env bash
# winvm-plugin-deploy · SSH channel single action (v1.5.0, user ruling 2026-11-13)
#
#   status  : UNDEPLOY only - FAST single-shot verdict, NEVER rebuild.
#             Exit 0=channel up / 1=channel down. Two NEW connections max
#             (1 ssh2 ping + 1 binary); NEVER vm_channel_probe()'s five-try
#             fallback (>2min on a dead channel = undeploy's normal input).
#   ensure  : DEPLOY only - channel up => do nothing; down => emit the built-in one-click PS
#             for the user's single manual paste, then stop with rc=2.
#   confirm : called by WorkBuddy after the user pasted; built-in four-stage verify +
#             ssh2 ping as the authoritative verdict (binary failure != no channel).
#   post    : UNDEPLOY only - schedule the built-in -Rollback as a VM-side SYSTEM task so the
#             VM executes the tunnel teardown itself AFTER the ssh session dies.
#
# Hard rule: undeploy NEVER calls ensure / host-generate-key / rebuild. A broken
# channel during uninstall is not a defect: the VM side is handled by the merged
# bundle from build-vm-bundle.sh instead.
set -u
_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${VMDEPLOY_ENV_SH:=${HOME}/wbtmp/vmdeploy-env.sh}"; [ -f "$VMDEPLOY_ENV_SH" ] && . "$VMDEPLOY_ENV_SH"
# v1.5.0 F-02: one backend for every caller; vm-conn.sh reads it at source time.
export VM_SSH_BACKEND="${VM_SSH_BACKEND:-ssh2}"
# shellcheck disable=SC1090
. "$_here/vm-conn.sh"
: "${VM_HOST:?VM_HOST unset - protocol P-1: ask the user}"; : "${VM_USER:=User}"; : "${VM_SSH_PORT:=22}"
# ssh2-conn.mjs (ping/exec/put) reads these from process.env - a plain shell
# variable is NOT visible to the node child. Export the whole connection contract
# once, here, so status/ensure/confirm/post and ps-run.sh all agree on one key.
export VM_HOST VM_USER VM_SSH_PORT WINVM_VM_KEY VM_CHANNEL VM_SSH_BACKEND
# v1.6.0: the tunnel lifecycle is INTERNAL (hos-winvm-ssh-tunnel v2.3.0
# merged into this skill). HOS_TUNNEL_SKILL stays a backward-compatible
# override pointing at a standalone skill root; default = THIS skill root,
# so every "$HOS/scripts/..." resolves to our own scripts/ directory.
HOS="${HOS_TUNNEL_SKILL:-$(dirname "$_here")}"
OUTD="${VMDEPLOY_RUN_DIR:-$HOME/wbtmp}"; mkdir -p "$OUTD"
ACT="${1:-status}"

_N="${VMDEPLOY_NODE:-${NODE:-}}"
[ -n "$_N" ] && [ -x "$_N" ] || _N="$(command -v node 2>/dev/null || true)"
[ -n "$_N" ] || _N="/data/storage/el1/bundle/libs/arm64/node/bin/node"

# Fast verdict: one ssh2 ping (authoritative) + one binary single-shot fallback.
# Both are NEW connections (long-lived tunnel health != new connection usable).
# On success export VM_CHANNEL=key so ps-run.sh children skip their own probe.
_channel_fast_probe() {
  if [ -x "$_N" ] && [ -f "$_here/ssh2-conn.mjs" ] && \
     timeout "${CHANNEL_PING_TIMEOUT:-20}" "$_N" "$_here/ssh2-conn.mjs" ping >/dev/null 2>&1; then
    export VM_CHANNEL=key
    return 0
  fi
  if timeout 12 ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no \
       -i "$WINVM_VM_KEY" -o IdentitiesOnly=yes -p "$VM_SSH_PORT" \
       "${VM_USER}@${VM_HOST}" whoami >/dev/null 2>&1; then
    export VM_CHANNEL=key
    return 0
  fi
  return 1
}

case "$ACT" in
  status)
    if _channel_fast_probe; then
      echo "CHANNEL=${VM_CHANNEL:-key} REBUILD=NO backend=$VM_SSH_BACKEND key=$WINVM_VM_KEY"
      exit 0
    fi
    echo "CHANNEL=NONE REBUILD=NO (fast verdict; uninstall path: VM side goes to the merged user bundle)"
    exit 1
    ;;

  ensure)
    if _channel_fast_probe; then
      echo "CHANNEL_EXISTS=1 backend=$VM_SSH_BACKEND key=$WINVM_VM_KEY (no rebuild, deploy proceeds)"
      exit 0
    fi
    [ -f "$HOS/scripts/host-generate-key.sh" ] || {
      echo "NO_TUNNEL_SCRIPTS: $HOS/scripts/host-generate-key.sh missing from this skill package - reinstall winvm-plugin-deploy v1.6.0+." >&2
      exit 3
    }
    # host-generate-key.sh arg1 = key path. Reuse WINVM_VM_KEY so the three-level
    # chain (env > vm-conn.json > default) and the built-in key never diverge.
    sh "$HOS/scripts/host-generate-key.sh" "$WINVM_VM_KEY" "$VM_USER" "$VM_SSH_PORT" "$VM_HOST" \
      > "$OUTD/host-generate-key.txt" 2>&1
    echo "NEED_USER_ACTION=1"
    echo "---- paste ALL of the following into VM [Administrator] PowerShell once ----"
    cat "$OUTD/host-generate-key.txt"
    echo "---- end of paste. After the user confirms: bash scripts/channel.sh confirm ----"
    exit 2
    ;;

  confirm)
    if [ -f "$HOS/scripts/verify-tunnel.sh" ]; then
      sh "$HOS/scripts/verify-tunnel.sh" "$VM_HOST" "$VM_USER" "$WINVM_VM_KEY" "$VM_SSH_PORT" 2>&1 | tail -20 || true
    fi
    if [ -x "$_N" ] && timeout "${CHANNEL_PING_TIMEOUT:-20}" "$_N" "$_here/ssh2-conn.mjs" ping >/dev/null 2>&1; then
      export VM_CHANNEL=key
      echo "CHANNEL_READY=1 (ssh2 ping authoritative; binary four-stage failure != channel missing)"
      exit 0
    fi
    echo "CHANNEL_READY=0 (ssh2 ping failed: wait for a healthy window and confirm again; NEVER reboot the VM)" >&2
    exit 1
    ;;

  post)
    TPL="$HOS/scripts/winvm-setup-sshd-and-key.ps1"
    RB="$OUTD/wb-rollback.ps1"
    [ -f "$TPL" ] || {
      echo "NO_ROLLBACK_TEMPLATE: $TPL missing from this skill; fall back to build-vm-bundle.sh (VM-side merged bundle)" >&2
      exit 3
    }
    cp -f "$TPL" "$RB"
    # Relative remote name lands in the VM user's home (same contract as hos
    # destroy-tunnel.sh); SYSTEM task keeps running after this ssh session dies.
    vmscp "$RB" "${VM_USER}@${VM_HOST}:wb-rollback.ps1" >/dev/null 2>&1 || {
      echo "POST_SCP_FAILED (dead window? use build-vm-bundle.sh instead; do NOT rebuild)" >&2
      exit 4
    }
    PS="$OUTD/wb-post-rollback.ps1"
    cat > "$PS" <<'PS1'
$rb = Join-Path $env:USERPROFILE 'wb-rollback.ps1'
$tr = 'powershell -NoProfile -ExecutionPolicy Bypass -File ' + $rb + ' -Rollback'
$a1 = @('/Create','/TN','WbTunnelRollback','/TR',$tr,'/SC','ONCE','/ST','00:00','/RL','HIGHEST','/RU','SYSTEM','/F')
& schtasks.exe $a1
$a2 = @('/Run','/TN','WbTunnelRollback')
& schtasks.exe $a2
Write-Output 'POST_ROLLBACK_SCHEDULED'
PS1
    bash "$_here/ps-run.sh" "$PS" 2>&1 | tail -8
    if [ "${TUNNEL_HOST_ROLLBACK:-1}" = "1" ] && [ -f "$HOS/scripts/host-rollback.sh" ]; then
      sh "$HOS/scripts/host-rollback.sh" "$WINVM_VM_KEY" "$VM_HOST" 2>&1 | tail -8 || true
    fi
    echo "TUNNEL_POST_DONE (VM SYSTEM task WbTunnelRollback runs -Rollback; success = passwordless login no longer works)"
    exit 0
    ;;

  *) echo "usage: channel.sh status|ensure|confirm|post" >&2; exit 2 ;;
esac
