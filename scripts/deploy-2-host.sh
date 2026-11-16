#!/usr/bin/env bash
# deploy-2-host.sh · 取发布包 + host 端插件安装（deploy 第 2 步，与第 1 步并行）
#
# 一件事：把 workbuddy-virtual-win-plugin 发布包落到宿主机，装好 host 端插件与依赖。
# VM 端不在这里装（第 4 步装，第 3 步起隧道）；本步只需通道不在场也能跑 ⇒ 与 1 并行安全。
#
# 用法：VM_HOST=... [RELEASE_TAG=V1.4.30] bash scripts/deploy-2-host.sh
set -u
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]:-$0}")/_common.sh"

resolve_env; need_node; need_py

# ── 2a 取包（缓存命中即跳过下载）──
st_begin 2a "取发布包（sha256 校验 + 隔离解压）"
DV="$(sub_log download-verify)"
if ! bash "$SCRIPTDIR/download-verify.sh" ${RELEASE_TAG:+--tag "$RELEASE_TAG"} > "$DV" 2>&1; then
  tail -12 "$DV"
  st_end 1 FAIL "download-verify rc=$?"
  die "取包失败" "下载/校验/解压三者之一" "$DV 末行：$(tail -1 "$DV")" \
      "看 $DV；离线时用 SKIP_DOWNLOAD=1 复用本地包"
fi
PKG="$(grep -E '^PKG_ROOT=' "$DV" | tail -1 | cut -d= -f2-)"
[ -n "$PKG" ] && [ -f "$PKG/MANIFEST.txt" ] || {
  tail -12 "$DV"; st_end 1 FAIL "无 PKG_ROOT 输出"
  die "包根未确定" "download-verify 未输出合法包根" "$DV" "检查 DEPLOY_ROOT=$DEPLOY_ROOT 与缓存"
}
VER="$(awk -F= '/^version=/{print $2;exit}' "$PKG/MANIFEST.txt" 2>/dev/null)"
echo "  包根 = $PKG"
echo "  版本 = ${VER:-unknown}"
state_set PKG_ROOT "$PKG"
[ -n "${VER:-}" ] && state_set PKG_VERSION "$VER"
st_end 0 PASS "pkg=$PKG ver=${VER:-unknown}"

# ── 2b 清单完整性（undeclared=陈旧层/发布漂移，硬失败）──
st_begin 2b "MANIFEST 对账"
ML="$(sub_log manifest)"
( cd "$PKG" && "$PY" qa/deploy-probes/verify-manifest.py . > "$ML" 2>&1 ); MRC=$?
if [ $MRC -ne 0 ]; then
  tail -8 "$ML"
  st_end $MRC FAIL "manifest rc=$MRC"
  die "包清单对账失败" "包内文件与 MANIFEST 不一致（陈旧层或发布漂移）" "$ML" \
      "重新取包（不要 SKIP_DOWNLOAD）；若持续，查母项目 pack 白名单"
fi
st_end 0 PASS "$(tail -1 "$ML")"

# ── 2c 解压两端结构自检 ──
# host 端 = delivery/*.mjs（已随包解出）；VM 端 tar 由第 4 步 setup 的 BUILD 相位生成。
st_begin 2c "两端结构就位检查"
MISS=""
for f in delivery/install-host.mjs delivery/setup.mjs delivery/uninstall.mjs delivery/winvm-plugin.mjs; do
  [ -f "$PKG/$f" ] || MISS="$MISS $f"
done
[ -f "$PKG/.env" ] || cp "$PKG/delivery/env.example" "$PKG/.env" 2>/dev/null || true
if [ -n "$MISS" ]; then
  st_end 1 FAIL "缺件:$MISS"
  die "包结构不完整" "发布包缺关键交付脚本" "缺:$MISS" "重新取包并核对 MANIFEST"
fi
st_end 0 PASS "host 端 4 件齐；.env $( [ -f "$PKG/.env" ] && echo 就位 || echo 缺失)"

# ── 2d 装 host 端插件（--no-tunnel：隧道归第 3 步）──
st_begin 2d "install-host --yes --no-tunnel（插件+连接器+skills）"
HL="$(sub_log install-host)"
( cd "$PKG" && "$NODE" delivery/install-host.mjs --yes --no-tunnel \
    --vm-host "$VM_HOST" --vm-user "$VM_USER" --vm-ssh-port "$VM_SSH_PORT" > "$HL" 2>&1 ); HRC=$?
tail -6 "$HL"
if [ $HRC -ne 0 ]; then
  st_end $HRC FAIL "install-host rc=$HRC"
  die "host 端插件安装失败" "插件缓存分发或连接器注册失败" "$HL" \
      "看 $HL；connector-states ⚠ 属平台账户噪声可忽略，errno=12 是内存压力"
fi
st_end 0 PASS "install-host rc=0"

# ── 2e 交付判据：connector skills 数量 ──
st_begin 2e "host 端交付判据（connector skills ≥8）"
SKCNT="$(ls "$HOME/.workbuddy/connectors/skills/connector-winvm/" 2>/dev/null | awk 'END{print NR+0}')"
if [ "${SKCNT:-0}" -lt 8 ]; then
  st_end 1 FAIL "skills=$SKCNT < 8"
  die "connector skills 交付不全" "插件 skills 未落到 connectors 目录" "计数=$SKCNT" \
      "重跑 node delivery/deploy-shared-skills.mjs（在 $PKG 下）"
fi
st_end 0 PASS "skills=$SKCNT"
state_set HOST_INSTALLED 1
steps_report
