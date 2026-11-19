#!/usr/bin/env bash
# winvm-plugin-deploy · 包根选根共享探测（run19 R-1 传导缺口——deploy/undeploy/verify 三 driver 统一事实源）
# 背景：run18 P-1 隔离重解后，overall-root 外层可能只剩「.env+overall/」空壳（真包根=内层 zip
# 原始布局）；旧 undeploy.sh/verify.sh 的 PKG 默认值硬指外层 ⇒ Cannot find module/缺 qa 假阻。
# 本文件 source 即用（零副作用），提供：
#   _pkg_layer_valid  $1=层路径         → MANIFEST.txt+delivery 双在=合法层
#   _pkg_layer_version $1=层路径         → echo 声明版本（CRLF 容错；空=无 MANIFEST）
#   _pick_pkg_root    [TAG] [strict]    → echo 选中层路径 rc=0 / rc=1 无合法层
#       优先版本匹配层（内层优先）；非 strict 回退任一层（内层优先）；strict=仅认版本匹配。
#   resolve_pkg_root  [TAG]             → 三级默认：env PKG_ROOT > $PKG_ROOT_STATE 状态文件 >
#       _pick_pkg_root 现探；产物写 PKG_RESOLVED/PKG_SOURCE，全落空 rc=1（调用方报错含人工处置提示）。
#       保底兼容：旧单平面布局（仅外层合法）经「现探」自然命中；「旧默认」本体不再被静默使用。
#
# ⚠ P17 契约（2026-11-19 真机，指定 V1.4.34 实得 V1.4.32 且 rc=0）：
#   **显式给了 TAG 时，TAG 必须高于状态文件记忆。** 具体：
#     给了 TAG  → 只认「MANIFEST 声明 == TAG」的层；匹配不到一律 rc=1，**不许回退状态文件**。
#     没给 TAG  → 才允许走状态文件（此时状态文件就是唯一意图，属性能优化而非错配）。
#   理由：状态文件是「上次的偶然」，一旦它能覆盖用户显式参数，就把「用户意图」降级成
#   「上次的偶然」，而失败形态是 **rc=0 + 一路绿灯跑在错误基准上**（比报错危险一个量级）。
#   ⚠ 同源陷阱：download-verify.sh 的缓存快路径也调本函数，**必须传 strict**（否则
#   「zip 在、sha 对、但解出来的层还是旧版」会命中缓存并原样返回旧层）。
: "${DEPLOY_ROOT:=${HOME}/winvm-deploy}"
PKG_ROOT_STATE="${PKG_ROOT_STATE_FILE:-$DEPLOY_ROOT/pkg-root.txt}"

_pkg_layer_valid() { [ -f "${1:-}/MANIFEST.txt" ] && [ -d "${1:-}/delivery" ]; }

_pkg_layer_version() {
  [ -f "${1:-}/MANIFEST.txt" ] || { echo ""; return 0; }
  tr -d '\r' < "$1/MANIFEST.txt" | sed -n 's/^version:[[:space:]]*//p' | head -1
}

_pick_pkg_root() {
  local tag="${1:-}" strict="${2:-}" r
  local _inner="$DEPLOY_ROOT/overall-root/overall" _outer="$DEPLOY_ROOT/overall-root"
  if [ -n "$tag" ]; then
    for r in "$_inner" "$_outer"; do
      _pkg_layer_valid "$r" && [ "$(_pkg_layer_version "$r")" = "$tag" ] && { echo "$r"; return 0; }
    done
  fi
  [ "$strict" = "strict" ] && return 1
  for r in "$_inner" "$_outer"; do
    _pkg_layer_valid "$r" && { echo "$r"; return 0; }
  done
  return 1
}

resolve_pkg_root() {
  local tag="${1:-}" s p
  if [ -n "${PKG_ROOT:-}" ]; then PKG_RESOLVED="$PKG_ROOT"; PKG_SOURCE="env PKG_ROOT"; return 0; fi
  # P17：显式给了 TAG ⇒ 只按 TAG 真匹配（strict），匹配不到就失败，**不许退回状态文件**。
  # 旧实现把状态文件排在 tag 探测之前，导致 `RELEASE_TAG=V1.4.34` 静默拿到 V1.4.32 的旧层。
  if [ -n "$tag" ]; then
    if p="$(_pick_pkg_root "$tag" strict)"; then PKG_RESOLVED="$p"; PKG_SOURCE="tag($tag)"; return 0; fi
    PKG_RESOLVED=""; PKG_SOURCE=""
    PKG_ROOT_MISMATCH="tag=$tag（无该版本的合法层；状态文件已被忽略，见 P17 契约）"
    return 1
  fi
  if [ -f "$PKG_ROOT_STATE" ]; then
    s="$(head -1 "$PKG_ROOT_STATE" | tr -d '\r\n')"
    if [ -n "$s" ] && _pkg_layer_valid "$s"; then PKG_RESOLVED="$s"; PKG_SOURCE="state($PKG_ROOT_STATE)"; return 0; fi
  fi
  if p="$(_pick_pkg_root)"; then PKG_RESOLVED="$p"; PKG_SOURCE="probe"; return 0; fi
  PKG_RESOLVED=""; PKG_SOURCE=""
  return 1
}

# pkg_root_tag_mismatch_error：显式 TAG 匹配不到时的报错（P17）。
# 与 pkg_root_usage_error 分开是因为处置完全不同：这里**盘上是有合法层**的，只是版本不对，
# 用户最需要知道的是「你要的那版不在，盘上声明的是哪些版本」——而不是被引导去「找包根」。
pkg_root_tag_mismatch_error() {
  local want="${1:-}" found=""
  for r in "$DEPLOY_ROOT/overall-root/overall" "$DEPLOY_ROOT/overall-root"; do
    _pkg_layer_valid "$r" && found="$found $(_pkg_layer_version "$r")@$r"
  done
  echo "PKG_TAG_MISMATCH：要求 $want，但 $DEPLOY_ROOT 下没有任何声明该版本的合法层。" >&2
  echo "  盘上现有层（声明版本@路径）：${found:- 无}" >&2
  echo "  ⚠ 状态文件 $PKG_ROOT_STATE 已被**忽略**（显式 tag 优先于记忆，见 P17）。处置三选一：" >&2
  echo "  ① 取该版本：RELEASE_TAG=$want bash download-verify.sh（会隔离旧层后重解）" >&2
  echo "  ② 改用盘上已有的版本：RELEASE_TAG=<上面列出的版本> 重跑" >&2
  echo "  ③ 确实是旧层残留：核对 MANIFEST.txt 的 version 行与 release 实际产物" >&2
}

# pkg_root_usage_error：三 driver 共用的「找不到合法包根」报错文案（含人工处置，勿静默空壳）
pkg_root_usage_error() {
  echo "PKG_ROOT_NOT_FOUND：$DEPLOY_ROOT/overall-root 下无合法包根（层=MANIFEST.txt+delivery 双在；可能被隔离/半解/空壳）。处置三选一：" >&2
  echo "  ① 显式覆盖：PKG_ROOT=<包根> bash <driver>.sh 或 --pkg <包根>（undeploy 拆除场景包根或已被移走=指回 stale-quarantine/ 内恢复的完整层）" >&2
  echo "  ② 重取包：bash download-verify.sh（隔离重解后自动写 pkg-root.txt）" >&2
  echo "  ③ P-4 类人工处置：检查 $DEPLOY_ROOT/stale-quarantine/ 与 overall-root 现状，必要时手工摆放后再跑" >&2
}

# 非 source 直跑=自测模式（三场景快速自检）
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  _pick_pkg_root "${1:-}" || echo "NO_ROOT"
fi
