#!/usr/bin/env bash
# winvm-plugin-deploy · 验证 driver v1.5.0（Step 5+6：三探针 38 项 + 终态矩阵 + 计时报告）
# 职责定界（用户 2026-11-13 裁定）：verify 只在 deploy ready 之后跑，是 WorkBuddy
# 自己调用的健康/功能性监测；它【不建通道、不修通道、不重启 VM】。通道相位窗
# 记 ENV_WINDOW=1 → VERIFY=INCOMPLETE rc=2，绝不假绿也不误报功能失败。
# 用法：[PKG_ROOT=<dir>] bash verify.sh   # deploy ready 后由 WorkBuddy 自调；也用作独立复核
set -u
_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${VMDEPLOY_ENV_SH:=${HOME}/wbtmp/vmdeploy-env.sh}"; [ -f "$VMDEPLOY_ENV_SH" ] && . "$VMDEPLOY_ENV_SH"
# v1.5.0 F-07：verify 自己不建/不修通道，但读 VM 终态行必须走与 deploy/undeploy
# 同一后端（ssh2），否则同一瞬态窗里二进制挂起会被误判成「功能失败」。
export VM_SSH_BACKEND="${VM_SSH_BACKEND:-ssh2}"
NODE="${NODE:-$(command -v node || true)}"; PY="${PY:-$(command -v python3 || true)}"
# run19 R-1：选根三级默认（env PKG_ROOT > pkg-root.txt 状态 > 现探 > 保底旧默认），
# 与 deploy/undeploy 共享 pkg-root.sh 事实源——旧硬指外层在隔离重解现场=空壳（run19 VER=2 实锤）。
# shellcheck disable=SC1090
. "$_here/pkg-root.sh"
if resolve_pkg_root; then
  PKG="$PKG_RESOLVED"; echo "[PKG] root=$PKG（来源=$PKG_SOURCE）"
else
  PKG="$HOME/winvm-deploy/overall-root"
  echo "⚠ [PKG] env/状态文件/现探三皆空，保底旧默认 $PKG" >&2
fi
# v1.5.0 F-05：与 deploy/undeploy/step.sh 共用 VMDEPLOY_RUN_DIR，杜绝日志双落点
# 各写一份、R2 单点扫描落空（11-12 e2e2 实锤）。
LOGD="${VMDEPLOY_LOG_DIR:-${VMDEPLOY_RUN_DIR:-$HOME/wbtmp/vmdeploy-verify-$(date +%Y%m%d-%H%M)}}"; mkdir -p "$LOGD"
STEP() { bash "$_here/step.sh" "$@"; }
[ -d "$PKG/qa/deploy-probes" ] || { echo "包根缺 qa/deploy-probes：$PKG（PKG_ROOT=<dir> bash verify.sh 显式指定，或先跑 deploy/download-verify 落 pkg-root.txt）" >&2; pkg_root_usage_error; exit 2; }

# ── v1.3.0 探针新鲜复用（run22 账本：deploy C5 刚过再冷跑=+240s）──
# 判定=probe-fresh.sh 单一事实源（与单测共用；四防线=deploy 全绿门/时效窗/同包根/强制冷跑，缺 stamp 或旧格式保守不复用）。
# 矩阵段不受复用影响恒跑（便宜且是独立复核面）。
PROBE_STAMP="${VMDEPLOY_PROBE_STAMP:-$HOME/wbtmp/vmdeploy-probes-stamp.txt}"
FRESH="${PROBE_FRESH_BUDGET_S:-600}"
_PF_OUT="$(VMDEPLOY_PROBE_STAMP="$PROBE_STAMP" PROBE_PKG="$PKG" PROBE_FRESH_BUDGET_S="$FRESH" "${BASH_OK:-bash}" "$_here/probe-fresh.sh" 2>/dev/null)"
REUSE=0; REASON=""
case "$_PF_OUT" in *"REUSE=1"*) REUSE=1;; esac
REASON="$(printf '%s\n' "$_PF_OUT" | sed -n 's/^REASON=//p' | head -1)"
[ $REUSE -eq 1 ] && echo "[probe-fresh] $REASON"

echo "== 探针（X-5 带宽：全链 97~250s 属正常带；判据=零超时零复跑） =="
FAILS=""
for pr in mcp-probe a2a-probe example-probe; do
  STEP begin VERIFY "5-$pr" "$pr 20/5/13"
  if [ $REUSE -eq 1 ]; then
    echo "[$pr REUSED] 新鲜窗 ${FRESH}s 内复用 deploy C5 结果（stamp=$PROBE_STAMP；强制冷跑=VERIFY_FORCE_PROBE=1）"
    # v1.9.1 观测修复（e2e5 实锤）：旧版 `step.sh log "$pr" < /dev/null` 会把 deploy C5
    # 已落盘的探针明细覆盖成 0 字节（logs/{mcp,a2a,example}-probe.log 全空 = 269s 观测黑洞）。
    # 现改为写入复用标记，保留原始明细供事后追查。
    printf '[REUSED] 复用 deploy C5 结果：stamp=%s 新鲜窗=%ss pkg=%s\n原始明细见同一 run 的 deploy 段 %s.log\n' \
      "$PROBE_STAMP" "$FRESH" "$PKG" "$pr" | "$_here/step.sh" log "$pr" >/dev/null 2>&1 || true
    STEP end VERIFY "5-$pr" 0 PASS "REUSED(deploy C5 fresh)" "none"
    continue
  fi
  ( cd "$PKG" && "$PY" "qa/deploy-probes/$pr.py" > "$LOGD/$pr.log" 2>&1 ); RC=$?
  LINE="$(grep -E 'SUMMARY|RESULT' "$LOGD/$pr.log" | tail -1)"
  echo "[$pr rc=$RC] $LINE"; "$_here/step.sh" log "$pr" < "$LOGD/$pr.log" >/dev/null || true
  if [ $RC -ne 0 ]; then FAILS="$FAILS $pr"; STEP end VERIFY "5-$pr" $RC FAIL "$pr" "$LINE"; else STEP end VERIFY "5-$pr" 0 PASS "${LINE:-ok}" "none"; fi
done
[ $REUSE -eq 1 ] && echo "[probe-reuse] 3/3 REUSED（deploy 完 600s 内同包根=同一事实，矩阵段仍独立复核）"

echo "== 终态矩阵 =="
STEP begin VERIFY 6 "终态矩阵"
# run17 D-3：矩阵各行 rc 入 VRC 聚合（旧=&& 短路吞 ps-run 失败后恒 0 PASS，VM 行空转假绿）
VRC=0
"$NODE" "$PKG/delivery/install-host.mjs" --check-fresh 2>&1 | tail -1 > "$LOGD/fresh.txt"; cat "$LOGD/fresh.txt"
"$NODE" -e "const j=require(process.env.HOME+'/.workbuddy/mcp.json');for(const k of Object.keys(j.mcpServers||{}))if(/winvm/i.test(k))console.log(k,'disabledTools='+(j.mcpServers[k].disabledTools||[]).length)" | tee "$LOGD/disabled.txt" | head -2
curl -sS --noproxy 127.0.0.1 -o /dev/null -w 'health=%{http_code}\n' --max-time 15 "http://127.0.0.1:18443/health" | tee "$LOGD/health.txt"
# 管道末级 tee 恒 0，判据取内容：装完态 health=200（非 200=如实计失败）
grep -q "health=200" "$LOGD/health.txt" 2>/dev/null || VRC=1
echo "connector skills=$(ls "$HOME/.workbuddy/connectors/skills/connector-winvm/" 2>/dev/null | wc -l)" | tee -a "$LOGD/health.txt"
ENV_WINDOW=0
if [ -n "${VM_HOST:-}" ]; then
  # v1.5.0：不再先跑 vm_channel_probe（灭窗时五试全探 >2min，且随后 ps-run 又新建
  # 一次连接 = 重复探测）。ps-run.sh 自身走 ssh2 三试，其 rc 即通道权威判据。
  # 预置 VM_CHANNEL=key 让 ps-run 子进程跳过它自己的五试 probe（ssh2 后端不依赖该值）。
  # shellcheck disable=SC1090
  . "$_here/vm-conn.sh" 2>/dev/null
  export VM_CHANNEL=key
  # run18 P-3：PIPESTATUS 取 ps-run 真 rc（管道末级 tr 恒 0 会吞）+ 内容判据（VM: task= 行必须在场）。
  # v1.9.1 效率：Get-NetTCPConnection（CIM，秒级）换 .NET GetActiveTcpListeners()（毫秒级，
  # 语义等价：同为「本地 18443 上处于 Listen 的套接字计数」）。task/sshd 保持原语以便保留
  # State 语义（Running vs Ready 是有用的区分，且此处只跑一次）。
  "${BASH_OK:-bash}" "$_here/ps-run.sh" -c '$t=(Get-ScheduledTask -TaskName WinVMBridge.Service -EA SilentlyContinue).State; $l=@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -eq 18443 }).Count; $s=(Get-Service sshd).Status; Write-Output ("VM: task=" + $t + " listen=" + $l + " sshd=" + $s)' | tr -d '\r' > "$LOGD/vm-terminal.txt"; VTRC=${PIPESTATUS[0]}
  cat "$LOGD/vm-terminal.txt"
  if [ $VTRC -ne 0 ] || ! grep -q "VM: task=" "$LOGD/vm-terminal.txt" 2>/dev/null; then
    # 通道相位窗是【环境问题】不是【功能失败】，但也不能吞掉当 PASS。
    echo "⚠ VM 终态行取不到 rc=$VTRC（环境瞬态窗，非功能失败；不宣称 PASS）" >&2
    ENV_WINDOW=1
  fi
fi
STEP end VERIFY 6 $VRC "$([ $VRC -eq 0 ] && echo PASS || echo FAIL)" "矩阵见 $LOGD$([ $ENV_WINDOW -eq 1 ] && echo '；ENV_WINDOW=1 VM 终态行缺失')" "$([ $VRC -eq 0 ] && echo none || echo '终态矩阵有行失败，对照 '$LOGD)"

STEP report
[ $VRC -ne 0 ] && FAILS="$FAILS matrix"
if [ -n "$FAILS" ]; then echo "VERIFY=FAIL:$FAILS（对照 troubleshooting.md 处置后只重跑失败探针即可）"; exit 1; fi
if [ "$ENV_WINDOW" = "1" ]; then
  echo "VERIFY=INCOMPLETE ENV_WINDOW=1（VM 终态行缺失：环境瞬态窗，不计功能失败，也不宣称 PASS；等健康窗后只重跑 verify.sh，绝不重启 VM）"
  exit 2
fi
echo "VERIFY=PASS"
