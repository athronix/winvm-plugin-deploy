#!/usr/bin/env bash
# winvm-plugin-deploy · 一键往返模板 driver（v1.3.0 时间预算战役产物，run22 账本驱动）
#
# 设计=用户裁定 11-09：「相连固定的操作提取动态参数连成一脚本；LLM 只在取必要信息、
# 探环境、做必要决策处介入，其余全交给模板脚本」。本脚本把 取包→拆→装→验 固定链一次跑完：
#   - 动态参数（仅这四个）：VM_HOST(必填) / VM_USER(默认 User) / ACTION / RELEASE_TAG(默认现解 latest)
#   - 固定操作=下方序列，全部复用既有 driver（deploy.sh/undeploy.sh/verify.sh，单一事实源不复制逻辑）
#   - 探针新鲜复用：deploy C5 通过后落 stamp，verify 在同包根 600s 内跳过重跑（省 ~240s）
#   - 全程 ssh2 后端（灭相位免疫）；steps.tsv 子步计时统一进 RUN_DIR；机器可读末块供 LLM 一次解析
#   - 失败即停+定点报障（对照 troubleshooting.md），不做无谓续跑
# v1.5.0：full 卸载默认 --keep-tunnel（拆后要重装，通道不能拆，否则重装要人工建通道）；
#   R2.5 UNSTABLE 先做 ssh2 新建连接权威复核，复核也失败才 GATE 停链（e2e2 805s 假 FAIL 实锤）。
#
# 用法：
#   VM_HOST=172.16.100.2 bash roundtrip.sh                    # 默认 ACTION=full（取包+拆+装+验）
#   VM_HOST=... ACTION=deploy bash roundtrip.sh               # 只装+验（现役不动）
#   VM_HOST=... ACTION=undeploy bash roundtrip.sh            # 只拆
#   VM_HOST=... ACTION=verify bash roundtrip.sh              # 只验（探针新鲜则复用，VERIFY_FORCE_PROBE=1 强制重跑）
#   RELEASE_TAG=V1.4.99 SKIP_DOWNLOAD=1 ... 等微调见下参数表。
# 建议后台跑（Bash run_in_background）：完成后读末块 ROUNDTRIP_RESULT 即可，勿轮询中间态。
set -u
_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${VMDEPLOY_ENV_SH:=${HOME}/wbtmp/vmdeploy-env.sh}"; [ -f "$VMDEPLOY_ENV_SH" ] && . "$VMDEPLOY_ENV_SH"

# ── 动态参数（唯一需要 LLM/用户提供的面） ─────────────────────────────
: "${ACTION:=full}"                       # full|deploy|undeploy|verify|cycle(=full 别名)
: "${VM_USER:=User}"
: "${RELEASE_TAG:=}"                       # 空=download-verify 现解 gitee latest
: "${SKIP_DOWNLOAD:=0}"                    # 1=用当前 pkg-root.txt 包根（不重取包）
: "${DEPLOY_ROOT:=${HOME}/winvm-deploy}"
: "${PROBE_FRESH_BUDGET_S:=600}"           # 探针复用新鲜窗
export VM_SSH_BACKEND="${VM_SSH_BACKEND:-ssh2}"
export DEPLOY_ROOT PROBE_FRESH_BUDGET_S
: "${VM_HOST:?VM_HOST 未设（P-1：这是本脚本唯一必问参数）}"

RUN_DIR="${VMDEPLOY_RUN_DIR:-$HOME/wbtmp/rt-$(date +%Y%m%d-%H%M)}"
mkdir -p "$RUN_DIR"
export VMDEPLOY_RUN_DIR="$RUN_DIR"   # 关键接缝：子 driver（deploy/undeploy/verify）的 LOGD/steps.tsv 全认这个变量
# stamp 走全局共享位（=deploy.sh/verify.sh 的默认路径）：roundtrip 只统一 RUN_DIR，
# 让「本轮 deploy 写→本轮 verify 读」与「手动 deploy→稍后手动 verify」两场景同径。
STAMP="${VMDEPLOY_PROBE_STAMP:-$HOME/wbtmp/vmdeploy-probes-stamp.txt}"
export VMDEPLOY_PROBE_STAMP="$STAMP"
T0=$(date +%s)
say(){ echo "[$(date +%H:%M:%S)] $*"; }
_step(){ say "RT-STEP $*"; }

case "$ACTION" in cycle) ACTION=full;; esac
case "$ACTION" in full|deploy|undeploy|verify) ;; *) echo "ACTION 非法：$ACTION（full|deploy|undeploy|verify）" >&2; exit 2;; esac

# 前置：env-detect 缺位则自跑（探测=脚本活，不问 LLM）
if [ -z "${NODE:-}" ] || [ ! -x "${NODE:-/nonexistent}" ]; then
  _step "P-ENV 环境探测（env-detect.sh 自举）"
  bash "$_here/env-detect.sh" > "$RUN_DIR/env-detect.log" 2>&1 || { say "FATAL env-detect rc=$?"; exit 3; }
  . "$VMDEPLOY_ENV_SH"
fi

FAILED=""
RES_U="SKIP"; RES_D="SKIP"; RES_V="SKIP"; PKG_NOTE="(当前包根)"

# ── 序列一：取发布包（RELEASE_TAG 现解+隔离重解+校验，全固定） ──────
if [ "$ACTION" = full ] || { [ "$ACTION" = deploy ] && [ "$SKIP_DOWNLOAD" != 1 ]; }; then
  _step "R1 download-verify（tag=${RELEASE_TAG:-latest 现解}）"
  RT=0
  if [ -n "$RELEASE_TAG" ]; then RELEASE_TAG="$RELEASE_TAG" bash "$_here/download-verify.sh" > "$RUN_DIR/download-verify.log" 2>&1 || RT=$?
  else bash "$_here/download-verify.sh" > "$RUN_DIR/download-verify.log" 2>&1 || RT=$?; fi
  if [ $RT -ne 0 ]; then say "FAIL R1 download-verify rc=$RT → 查 $RUN_DIR/download-verify.log（troubleshooting A/D 族）"; exit 4; fi
  PKG_NOTE="$(grep -E '^PKG_ROOT=' "$RUN_DIR/download-verify.log" | tail -1)"
  say "OK R1 $PKG_NOTE（$(grep -E '^\[download\] tag=' "$RUN_DIR/download-verify.log" | tail -1)）"
fi

# ── 序列二：拆除 ──────────────────────────────────────────────────────
if [ "$ACTION" = full ] || [ "$ACTION" = undeploy ]; then
  # v1.5.0：full = 拆了要立刻装回去，通道必须留着（undeploy 三段式里第 3 段显式跳过）。
  # 否则拆完通道坏 → undeploy 会发 VM 合并包要求人工执行 → 一键链被人工步骤卡死。
  UARGS="--apply"
  if [ "$ACTION" = full ] && [ "${ROUNDTRIP_KEEP_TUNNEL:-1}" = "1" ]; then
    UARGS="$UARGS --keep-tunnel"
    say "R2 full 默认 --keep-tunnel（保留通道供 R3 自动部署；ROUNDTRIP_KEEP_TUNNEL=0 可关）"
  fi
  _step "R2 undeploy $UARGS"
  bash "$_here/undeploy.sh" $UARGS > "$RUN_DIR/undeploy.log" 2>&1; RC=$?
  RES_U=$([ $RC -eq 0 ] && echo PASS || echo "FAIL(rc=$RC)")
  [ $RC -ne 0 ] && { FAILED="$FAILED undeploy"; say "FAIL R2 → 查 $RUN_DIR/undeploy.log（troubleshooting kept/僵尸行）"; }
  say "R2 $RES_U"
  [ -n "$FAILED" ] && { echo "== ROUNDTRIP_RESULT =="; echo "ACTION=$ACTION UNDEPLOY=$RES_U DEPLOY=SKIP VERIFY=SKIP WALL_S=$(( $(date +%s) - T0 ))"; echo "RUN_DIR=$RUN_DIR"; echo "VERDICT=NO FAILED:$FAILED"; exit 5; }
fi

# ── 序列三：安装（C5 通过会写探针 stamp 供 R4 复用） ─────────────────
# e2e2R6（11-12 e2e2 三例实锤 S8/S9/S10）：拆机重启 sshd 后存在认证段瞬态窗
# （光谱=124 挂起/111 瞬拒/255 拒——124 文案只写"VM 开机期"覆盖不全），背靠背装
# 必撞 RED 早退。full 模式在拆与装之间插入判稳（wait-channel 连击 2×4，预算 ~10min）。
# v1.5.0 F-09：旧 `|| true` 把 UNSTABLE 吞掉仍进 R3 = 805s 假 FAIL；现改 GATE，
# 但先用 ssh2 新建连接实测复核，避免二进制判稳自身错钥/相位挂造成误停。
if [ "$ACTION" = full ]; then
  _step "R2.5 wait-channel 判稳（拆后瞬态窗）"
  timeout 600 bash "$_here/wait-channel.sh" 2 4 > "$RUN_DIR/wait-channel.log" 2>&1; WRC=$?
  STAB="$(grep -oE 'STABLE|UNSTABLE' "$RUN_DIR/wait-channel.log" | tail -1)"
  say "R2.5 STABILITY=${STAB:-UNKNOWN} rc=$WRC"
  if [ "$WRC" -ne 0 ]; then
    # F-09：连击判稳失败 != 通道不存在（旧裸 ssh 错钥/相位挂）。用 ssh2 新建连接
    # 单发 ping 作权威复核；仍失败才是真环境窗，必须 GATE，撞窗硬跑=805s 假 FAIL。
    if bash "$_here/channel.sh" confirm > "$RUN_DIR/channel-confirm.log" 2>&1; then
      say "R2.5 OVERRIDE=SSH2_READY（ssh2 新建连接实测通过；连击 UNSTABLE 不作 gate）"
    else
      FAILED="$FAILED channel-unstable"
      say "R2.5 GATE：连击判稳与 ssh2 权威复核均败 → 不进 R3（等健康窗；绝不重启 VM）"
      tail -4 "$RUN_DIR/channel-confirm.log" 2>/dev/null || true
      echo "== ROUNDTRIP_RESULT =="
      echo "ACTION=$ACTION UNDEPLOY=$RES_U DEPLOY=SKIP VERIFY=SKIP WALL_S=$(( $(date +%s) - T0 ))"
      echo "RUN_DIR=$RUN_DIR PKG=$PKG_NOTE"
      echo "VERDICT=NO FAILED:$FAILED"
      exit 6
    fi
  fi
fi
if [ "$ACTION" = full ] || [ "$ACTION" = deploy ]; then
  _step "R3 deploy --apply"
  VMDEPLOY_PROBE_STAMP="$STAMP" bash "$_here/deploy.sh" --apply > "$RUN_DIR/deploy.log" 2>&1; RC=$?
  RES_D=$([ $RC -eq 0 ] && echo PASS || echo "FAIL(rc=$RC)")
  [ $RC -ne 0 ] && { FAILED="$FAILED deploy"; say "FAIL R3 → 查 $RUN_DIR/deploy.log + steps.tsv（ENV_PRECHECK/P-2 口径）"; }
  say "R3 $RES_D"
fi

# ── 序列四：验证（新鲜窗内且刚装过 ⇒ 探针复用只跑矩阵） ───────────────
if [ "$ACTION" = full ] || [ "$ACTION" = verify ] || [ "$ACTION" = deploy ]; then
  if [ -n "$FAILED" ]; then
    say "R4 SKIP（前序已败，不浪费探针带宽）"
    RES_V=SKIP
  else
    _step "R4 verify"
    bash "$_here/verify.sh" > "$RUN_DIR/verify.log" 2>&1; RC=$?
    RES_V=$([ $RC -eq 0 ] && echo PASS || echo "FAIL(rc=$RC)")
    [ $RC -ne 0 ] && FAILED="$FAILED verify"
    say "R4 $RES_V（探针复用=$(grep -c 'REUSED' "$RUN_DIR/verify.log" 2>/dev/null || echo 0)/3）"
  fi
fi

WALL=$(( $(date +%s) - T0 ))
# 末块=机器可读，LLM 一次解析定全局（勿再分段问）
echo ""
echo "== ROUNDTRIP_RESULT =="
echo "ACTION=$ACTION UNDEPLOY=$RES_U DEPLOY=$RES_D VERIFY=$RES_V WALL_S=$WALL"
echo "RUN_DIR=$RUN_DIR PKG=$PKG_NOTE"
echo "TIMINGS_TOP5:"; "${NODE:-node}" -e "
const fs=require('fs');const p='$RUN_DIR/steps.tsv';
try{const rows=fs.readFileSync(p,'utf8').trim().split('\n').slice(1).map(l=>l.split('\t'));
rows.sort((a,b)=>(+b[5]||0)-(+a[5]||0));
for(const r of rows.slice(0,5))console.log('  '+r[5]+'s '+r[0]+'/'+r[1]+' '+r[2].slice(0,28)+' '+r[7]);}catch(e){console.log('  (steps.tsv 缺)')}" 2>/dev/null || true
[ -z "$FAILED" ] && { echo "VERDICT=YES"; exit 0; } || { echo "VERDICT=NO FAILED:$FAILED"; exit 1; }
