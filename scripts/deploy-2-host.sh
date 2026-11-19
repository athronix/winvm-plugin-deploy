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
DVRC=0
bash "$SCRIPTDIR/download-verify.sh" ${RELEASE_TAG:+--tag "$RELEASE_TAG"} > "$DV" 2>&1 || DVRC=$?
if [ "$DVRC" -ne 0 ]; then
  tail -12 "$DV"
  # P18（2026-11-19 真机暴露）：旧写法是 `if ! bash ...; then` + `rc=$?`，而 `!` 取反后
  # `$?` 恒为 0 ⇒ 无论失败原因是什么，日志都打 `download-verify rc=0`。
  # 这条恰恰是「最该看清的一行」：rc=0 会让人以为「脚本本身没问题、是别的原因」，
  # 而真凶可能是 rc=1（下载/打包不可达）或 rc=2（sha 不一致，属事故）。
  # 判据纪律：**失败路径上的诊断信息必须本身可信**，否则等于没有证据。
  st_end 1 FAIL "download-verify rc=$DVRC"
  die "取包失败" "下载/校验/解压三者之一（rc=1 网络或 tag 不存在；rc=2 sha256 不一致属事故）" \
      "$DV 末行：$(tail -1 "$DV")" \
      "看 $DV；离线时用 SKIP_DOWNLOAD=1 复用本地包"
fi
PKG="$(grep -E '^PKG_ROOT=' "$DV" | tail -1 | cut -d= -f2-)"
[ -n "$PKG" ] && [ -f "$PKG/MANIFEST.txt" ] || {
  tail -12 "$DV"; st_end 1 FAIL "无 PKG_ROOT 输出"
  die "包根未确定" "download-verify 未输出合法包根" "$DV" "检查 DEPLOY_ROOT=$DEPLOY_ROOT 与缓存"
}
# MANIFEST.txt 的版本行是 `version: V1.4.30`（**冒号**分隔，母项目 pack-release.mjs 产出），
# 旧代码按 `^version=`（等号）解析 ⇒ 恒取不到 ⇒ 日志与 state 里版本永远是 unknown
# （2026-11-17 真机实测：包其实是 V1.4.30）。冒号/等号都吃，兼容历史包。
VER="$(sed -n 's/^version[[:space:]]*[:=][[:space:]]*//p' "$PKG/MANIFEST.txt" 2>/dev/null | head -1 | tr -d '\r')"
echo "  包根 = $PKG"
echo "  版本 = ${VER:-unknown}"
# P17（2026-11-19 真机）：指定了版本却装到另一版，是本报告里唯一「rc=0 跑错基准」的缺陷。
# download-verify 侧已保证「选中层声明==TAG」，这里再对账一次并**硬失败**——
# 两道锁不是冗余：download-verify 可能被 SKIP_DOWNLOAD / 手工摆包绕过，
# 而 2a 是「包根进入 state」的唯一入口，错在这一步，后面 4b/4c/5d 全都在错基准上判 PASS。
if [ -n "${RELEASE_TAG:-}" ] && [ "$VER" != "$RELEASE_TAG" ]; then
  st_end 1 FAIL "tag=$RELEASE_TAG 实得 ver=${VER:-unknown}"
  die "包版本与指定 TAG 不符" "显式 RELEASE_TAG 必须严格命中（P17：状态文件/旧层不得覆盖显式参数）" \
      "RELEASE_TAG=$RELEASE_TAG  包根=$PKG  MANIFEST version=${VER:-unknown}" \
      "先 RELEASE_TAG=$RELEASE_TAG bash scripts/download-verify.sh，或改用盘上已有版本"
fi
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
