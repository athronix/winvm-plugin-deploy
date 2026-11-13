#!/usr/bin/env bash
# winvm-plugin-deploy · uninstall driver v1.5.0 (user ruling 2026-11-13)
#
# uninstall = exactly THREE parts, in this order:
#   1) HOST  - WorkBuddy removes its own plugin/cache/mcp/tunnel locally.
#   2) VM    - remove WinVMBridge; done by WorkBuddy if a channel exists,
#              otherwise merged into ONE user bundle (no channel rebuild).
#   3) SSH   - teardown the passwordless tunnel via the built-in -Rollback, scheduled as
#              a VM-side SYSTEM POST ACTION when a channel exists (so the VM
#              finishes it after this ssh session dies), merged into the same
#              bundle when the channel is down.
#
# *** NEVER rebuild a channel during uninstall. *** A dead channel is expected
# state here, not a failure. Never reboot the VM.
#
# Usage:
#   VM_HOST=<ip> bash undeploy.sh                    # DRY-RUN: three-part plan
#   VM_HOST=<ip> bash undeploy.sh --apply           # execute all three parts
#   ... --apply --keep-tunnel                       # keep the SSH tunnel (default: tear it down)
#   ... --apply --purge-workspace                   # also delete C:/WinVMWorkspace (destructive)
set -u
_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${VMDEPLOY_ENV_SH:=${HOME}/wbtmp/vmdeploy-env.sh}"; [ -f "$VMDEPLOY_ENV_SH" ] && . "$VMDEPLOY_ENV_SH"
export VM_SSH_BACKEND="${VM_SSH_BACKEND:-ssh2}"          # F-02: one backend for every caller
# shellcheck disable=SC1090
. "$_here/vm-conn.sh"
# shellcheck disable=SC1090
. "$_here/pkg-root.sh"
STEP() { bash "$_here/step.sh" "$@"; }
APPLY=0; KEEP_TUNNEL=0; PURGE_WS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --keep-tunnel) KEEP_TUNNEL=1 ;;
    --purge-workspace) PURGE_WS=1 ;;
    --pkg) PKG="$2"; PKG_ROOT="$2"; shift ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac; shift
done
if resolve_pkg_root; then PKG="$PKG_RESOLVED"; echo "[PKG] root=$PKG (source=$PKG_SOURCE)"; else
  echo "[PKG] no legal package root - HOST removal still possible; VM bundle uses the skill's own ps1" >&2
  PKG=""
fi
: "${VM_HOST:?VM_HOST unset - protocol P-1}"; : "${VM_USER:=User}"; : "${VM_SSH_PORT:=22}"
NODE="${NODE:?run env-detect.sh first}"
LOGD="${VMDEPLOY_LOG_DIR:-${VMDEPLOY_RUN_DIR:-$HOME/wbtmp/vmdeploy-undeploy-$(date +%Y%m%d)}}"; mkdir -p "$LOGD"
VMC="$HOME/.workbuddy/winvm/vm-conn.json"
# v1.6.0: the tunnel lifecycle is INTERNAL (hos-winvm-ssh-tunnel v2.3.0
# merged into this skill). HOS_TUNNEL_SKILL stays a backward-compatible
# override pointing at a standalone skill root; default = THIS skill root,
# so every "$HOS/scripts/..." resolves to our own scripts/ directory.
HOS="${HOS_TUNNEL_SKILL:-$(dirname "$_here")}"

echo "==== undeploy v1.5.0 / three-part plan ===="
echo "  1 HOST  : local, no channel needed"
echo "  2 VM    : channel up => WorkBuddy; channel down => merged user bundle"
echo "  3 SSH   : channel up => VM SYSTEM post action; channel down => same bundle"
echo "  keep-tunnel=$KEEP_TUNNEL purge-workspace=$PURGE_WS backend=$VM_SSH_BACKEND"

# ---- channel probe: STATUS ONLY, never rebuild (P-2 retired) ----
bash "$_here/channel.sh" status > "$LOGD/channel-status.log" 2>&1; CRC=$?
cat "$LOGD/channel-status.log"
if [ $CRC -eq 0 ]; then CH_UP=1; else CH_UP=0; fi
echo "CHANNEL_UP=$CH_UP REBUILD=NO"

# ---- R4: keep a snapshot of the runtime connection fact for a later deploy ----
if [ -f "$VMC" ]; then
  cp -f "$VMC" "$VMC.roundtrip" && echo "[R4] vm-conn.json -> .roundtrip (deploy restores it before P0)"
fi

if [ $APPLY -eq 0 ]; then
  echo "DRY-RUN: no changes. Review the three parts above, then add --apply."
  echo "  CH_UP=1  => WorkBuddy removes VM side + schedules the built-in -Rollback as a VM SYSTEM post action."
  echo "  CH_UP=0  => WorkBuddy removes HOST only; build-vm-bundle.sh emits ONE directory for the user"
  echo "              (vm-remove-local.ps1 + wb-rollback.ps1 + RUN-ME.ps1). No channel is rebuilt."
  STEP report; exit 0
fi

FAILED=""; note(){ FAILED="$FAILED $1"; }
STEP begin U1 1 "PART 1/3 - host removal"

# uninstall.mjs is two-end. With no VM target resolvable it SKIPS the VM phase
# (counting 1 expected failure) while still executing every host cleanup step.
# Hide vm-conn.json temporarily and unset the env chain so resolveVmTarget()=null.
if [ -f "$VMC" ]; then
  "$NODE" -e 'require("fs").renameSync(process.argv[1],process.argv[2])' "$VMC" "$VMC.host-phase-hidden" 2>/dev/null \
    || mv -f "$VMC" "$VMC.host-phase-hidden" || true
fi
if [ -n "$PKG" ]; then
  ( cd "$PKG" && unset WINVM_VM_HOST WINVM_VM_USER && "$NODE" delivery/uninstall.mjs --apply > "$LOGD/apply-host.log" 2>&1 ); HRC=$?
else
  HRC=1; echo "[HOST] no package root: skipping uninstall.mjs (nothing installed locally?)" | tee "$LOGD/apply-host.log"
fi
HOST_PASS="$(grep -c '\[PASS\] HOST' "$LOGD/apply-host.log" 2>/dev/null || echo 0)"
HOST_FAIL="$(grep -c '\[FAIL\] HOST' "$LOGD/apply-host.log" 2>/dev/null || echo 0)"
echo "HOST_PASS=$HOST_PASS HOST_FAIL=$HOST_FAIL uninstall_rc=$HRC (rc=1 expected: VM phase skipped on purpose)"
grep -E '\[FAIL\] HOST|APPLY' "$LOGD/apply-host.log" | head -6 || true
STEP log apply-host < "$LOGD/apply-host.log" >/dev/null
[ -f "$VMC.host-phase-hidden" ] && "$NODE" -e 'require("fs").unlinkSync(process.argv[1])' "$VMC.host-phase-hidden" 2>/dev/null || true
if [ "$HOST_FAIL" != "0" ] || [ "$HOST_PASS" -lt 11 ]; then
  STEP end U1 1 1 FAIL "HOST_PASS=$HOST_PASS HOST_FAIL=$HOST_FAIL" "check $LOGD/apply-host.log"; note "U1/host"
else
  STEP end U1 1 0 PASS "HOST_PASS=$HOST_PASS (VM phase intentionally skipped)" "none"
fi

STEP begin U2 2 "PART 2/3 - VM removal"
if [ "$CH_UP" = "1" ]; then
  vmscp "$_here/vm-remove-local.ps1" "${VM_USER}@${VM_HOST}:vm-remove-local.ps1" >/dev/null 2>&1 \
    || { echo "VMSCP_FAILED (dead window) -> falling back to the merged user bundle; NO rebuild" >&2; CH_UP=0; }
fi
if [ "$CH_UP" = "1" ]; then
  # PART 2 owns VM Bridge removal ONLY. PART 3 (channel.sh post) owns the tunnel
  # teardown. Passing -ScheduleTunnelRollback here is both a no-op (wb-rollback.ps1
  # is not beside the scp'd script) and a double registration of the same SYSTEM
  # task. In the channel-down path RUN-ME.ps1 DOES pass it (bundle has both files).
  PARGS="-Apply"
  [ "$PURGE_WS" = "1" ] && PARGS="$PARGS -PurgeWorkspace"
  bash "$_here/ps-run.sh" -c "& .\vm-remove-local.ps1 $PARGS" > "$LOGD/vm-remove.log" 2>&1; VRC=$?
  grep -E 'MODE=|VM_CLEANUP_DONE|BRIDGE_DIR=|TASK_EXISTS=|PORT_LISTEN=|BRIDGE_NODE_LEFT=|POST_ROLLBACK|\[WARN\]' "$LOGD/vm-remove.log" | tail -14 || true
  STEP log vm-remove < "$LOGD/vm-remove.log" >/dev/null
  if [ $VRC -ne 0 ] || ! grep -q 'VM_CLEANUP_DONE' "$LOGD/vm-remove.log" 2>/dev/null; then
    STEP end U2 2 $VRC FAIL "VM removal rc=$VRC" "check $LOGD/vm-remove.log"; note "U2/vm"
  else
    STEP end U2 2 0 PASS "VM_CLEANUP_DONE + POST STATUS" "none"
  fi
  VM_MODE="workbuddy"
else
  bash "$_here/build-vm-bundle.sh" > "$LOGD/vm-bundle.log" 2>&1; BRC=$?
  cat "$LOGD/vm-bundle.log"
  echo "NEED_USER_ACTION=1 (HOST removal is already done; copy VM_BUNDLE to the VM and run RUN-ME.ps1)"
  STEP end U2 2 $BRC "$([ $BRC -eq 0 ] && echo PASS || echo FAIL)" "VM side merged into user bundle; no channel rebuild" "none"
  VM_MODE="user-bundle"
fi

STEP begin U3 3 "PART 3/3 - SSH tunnel removal"
if [ "$KEEP_TUNNEL" = "1" ]; then
  echo "KEEP_TUNNEL=1: tunnel left in place (explicit opt-out of part 3)"
  STEP end U3 3 0 PASS "kept by request" "none"
elif [ "$VM_MODE" = "user-bundle" ]; then
  # parts 2+3 already merged into RUN-ME.ps1 (-ScheduleTunnelRollback).
  if [ -f "$HOS/scripts/host-rollback.sh" ]; then
    sh "$HOS/scripts/host-rollback.sh" "$WINVM_VM_KEY" "$VM_HOST" 2>&1 | tail -8 || true
    echo "HOST_KEY_ROLLBACK=done (only this skill's key / known_hosts / baseline)"
  fi
  echo "TUNNEL_POST_MERGED=1 (VM SYSTEM task WbTunnelRollback inside RUN-ME.ps1)"
  STEP end U3 3 0 PASS "merged into VM bundle" "none"
else
  bash "$_here/channel.sh" post > "$LOGD/tunnel-post.log" 2>&1; TRC=$?
  tail -12 "$LOGD/tunnel-post.log"
  STEP log tunnel-post < "$LOGD/tunnel-post.log" >/dev/null
  if [ $TRC -ne 0 ]; then
    echo "POST_ROLLBACK_FAILED: fall back to build-vm-bundle.sh (do NOT rebuild the channel)" >&2
    bash "$_here/build-vm-bundle.sh" | tee -a "$LOGD/tunnel-post.log"
    STEP end U3 3 $TRC FAIL "post scheduling failed -> user bundle" "VM bundle emitted instead"; note "U3/tunnel"
  else
    STEP end U3 3 0 PASS "VM SYSTEM post action scheduled" "none"
  fi
fi

STEP begin U4 4.2 "independent re-check"
U4_RC=0
HCODE="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 4 "http://127.0.0.1:${WINVM_TUNNEL_LOCAL_PORT:-18443}/health" 2>/dev/null)"
echo "health=${HCODE} (expect 000 = host side cleaned)"
[ "$HCODE" = "000" ] || { U4_RC=1; note "U4/health"; }
"$NODE" -e "const j=require(process.env.HOME+'/.workbuddy/mcp.json');const k=Object.keys(j.mcpServers||{}).filter(x=>/winvm/i.test(x));console.log(k.length?'LEFT:'+k:'GLOBAL_MCP_CLEAN')" || { U4_RC=1; note "U4/mcp"; }
if [ "$VM_MODE" = "user-bundle" ]; then
  echo "VM terminal state = PENDING_USER (bundle handed over; not a failure)"
else
  bash "$_here/ps-run.sh" -c '$a=Test-Path C:\WinVMBridge; $b=[bool](Get-ScheduledTask -TaskName WinVMBridge.Service -EA SilentlyContinue); $c=@(Get-NetTCPConnection -LocalPort 18443 -State Listen -EA SilentlyContinue).Count; $d=(Get-Service sshd).Status; $e=Test-Path C:\WinVMWorkspace; Write-Output ("expect False False 0 * True => " + $a + " " + $b + " " + $c + " " + $d + " " + $e)' || { U4_RC=1; note "U4/vm"; }
fi
STEP end U4 4.2 $U4_RC "$([ $U4_RC -eq 0 ] && echo PASS || echo FAIL)" "host clean / VM $VM_MODE" "none"

STEP report
[ "$VM_MODE" = "user-bundle" ] && echo "NEED_USER_ACTION=1"
echo "UNDEPLOY_DONE parts=host+vm+tunnel vm_mode=$VM_MODE keep_tunnel=$KEEP_TUNNEL"
[ -n "$FAILED" ] && { echo "UNDEPLOY_WITH_FAILURES:$FAILED" >&2; exit 1; }
exit 0
