#!/usr/bin/env bash
# winvm-plugin-deploy · 铁律通道执行器（R8/X-3/D-2 教训产品化）
# 用法：
#   ps-run.sh <local.ps1> [输出文件]        # 推送并执行 .ps1，stdout 落文件+回显
#   ps-run.sh -c '<powershell 单行>'        # 短片段走 EncodedCommand（base64 UTF-16LE，零引号/零本地展开面）
# 为什么必须这样：VM sshd 默认壳=cmd.exe（Windows OpenSSH 出厂默认），Git-Bash 拓扑亦常见；
#   含 $_ / $p / 引号 / 反斜杠的内联命令串会被某一边壳吞改（R8：安装链 183 次失败根因）。
#   复合逻辑 → 文件推送 -File；短片段 → EncodedCommand（单 token，cmd/bash/pwsh 通吃）。
set -u
: "${VMDEPLOY_ENV_SH:=${HOME}/wbtmp/vmdeploy-env.sh}"; [ -f "$VMDEPLOY_ENV_SH" ] && . "$VMDEPLOY_ENV_SH"
NODE="${NODE:-$(command -v node || true)}"
_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# run17 D-1 修复：无条件 source vm-conn.sh——deploy/undeploy 以 `bash ps-run.sh` 子进程调用时
# 继承 VM_CHANNEL 变量但不继承 vmssh/vmscp 函数；旧条件 source（VM_CHANNEL 已置=不 source）
# → line15 vmssh command not found（127）。函数必须在场；probe 只在通道未定时执行（已置=复用）。
. "$_here/vm-conn.sh"
if [ -z "${VM_CHANNEL:-}" ]; then vm_channel_probe || exit 1; fi

_ps_cmd() { vmssh "$1"; }   # $1=已确保零本地展开的命令串

# ── E2E4 定谳（11-13）：载荷执行走独立预算，不与 25s 传输窗混用 ──
# 现象：vmcheck 153s rc=124、日志仅「VM_CHANNEL/传输层失败」两行、零载荷输出 → 被误判通道坏。
# 实测：同一通道 ping 2.6s 通，而 vmcheck.ps1 自身耗时 47~56s（连测 47/53/56s 三次）——
#   Get-ScheduledTask 全枚举 + Get-NetTCPConnection + /health HTTP + PS 冷启。
# 每次尝试窗 = VM_SSH_TIMEOUT+5 = 30s < 载荷耗时 ⇒ 每次都被外层 timeout 杀，确定性假红。
# 处置：载荷执行 VM_PS_TIMEOUT（默认 180s≈3x 余量）+ VM_SSH_TRIES=2（重载荷超时非瞬态，
#   3 试会让真失败路径拖到 8min+）。scp/连接探测仍用 VM_SSH_TIMEOUT(25s)，语义不被污染。
# 注意：`-File` 型载荷是「跑完才吐输出」，超时=零输出；故 workload 侧判据行必须前置
#   （见 qa/deploy-probes/vm-env-check.ps1 verdict-first 改动），预算与前置是双保险。
VM_PS_TIMEOUT="${VM_PS_TIMEOUT:-180}"
_payload() { VM_SSH_EXEC_TIMEOUT="$VM_PS_TIMEOUT" VM_SSH_TRIES=2 "$@"; }

if [ "${1:-}" = "-c" ]; then
  PS_LINE="${2:?-c 需要 PowerShell 语句}"
  ENC="$("$NODE" -e 'process.stdout.write(Buffer.from(process.argv[1],"utf16le").toString("base64"))' "$PS_LINE")"
  _payload _ps_cmd "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ${ENC}"; exit $?
fi

PS_LOCAL="${1:?用法：ps-run.sh <file.ps1> [out] 或 ps-run.sh -c '<line>'}"
OUT="${2:-}"
[ -f "$PS_LOCAL" ] || { echo "PS 文件不存在：$PS_LOCAL" >&2; exit 2; }
base="$(basename "$PS_LOCAL")"
# ASCII 载荷纪律：非 ASCII → 远端 GBK 码页乱码（判据字段虽 ASCII，日志不可读仍拖慢诊断）
"$NODE" -e 'for(const x of require("fs").readFileSync(process.argv[1])) if(x>127){console.error("NON_ASCII_PAYLOAD：改英文/ASCII 标记");process.exit(3)}' "$PS_LOCAL" || exit 3

vmscp "$PS_LOCAL" "${VM_USER}@${VM_HOST}:${base}" >/dev/null 2>&1 || { echo "VMS scp 失败（先查 VM_CHANNEL）" >&2; exit 1; }
_tmp="$(mktemp)"
_payload _ps_cmd "powershell -NoProfile -ExecutionPolicy Bypass -File ${base}" > "$_tmp" 2>&1; rc=$?
# 清理远端临时件走 EncodedCommand（Remove-Item 含 -LiteralPath，避免壳吞参）
# F-19 (E2E3): the old JS template literal referenced an undefined `base`
# (it is a BASH var, never a JS var) -> ReferenceError on EVERY remote PS call,
# an empty EncodedCommand, a leaked temp .ps1 and one wasted ssh2 round trip.
# Pass the filename via process.argv: zero shell/JS interpolation surface.
_enc="$("$NODE" -e 'process.stdout.write(Buffer.from("Remove-Item -LiteralPath \"" + process.argv[1] + "\" -Force -ErrorAction SilentlyContinue","utf16le").toString("base64"))' "$base")"
_ps_cmd "powershell -NoProfile -NonInteractive -EncodedCommand ${_enc}" >/dev/null 2>&1 || true
[ -n "$OUT" ] && cat "$_tmp" > "$OUT"
cat "$_tmp"; rm -f "$_tmp" 2>/dev/null || "$NODE" -e 'require("fs").unlinkSync(process.argv[1])' "$_tmp" 2>/dev/null
exit $rc
