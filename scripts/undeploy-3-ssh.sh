#!/usr/bin/env bash
# undeploy-3-ssh.sh · 拆除 SSH 免密通道（undeploy 第 3 步，需第 2 步完成）
#
# 参数：--remove-ssh-tunnel yes|no   默认 no（保留通道）
#
#   no  ：什么也不做，只打印"通道保留"，并说明下次 deploy 会直接跳过第 1 步。
#   yes ：拆。两条路，automatic 优先：
#           a) 通道在 → 把 VM 上**已经存好的** winvm-sshd-oneclick.ps1 以 SYSTEM 计划任务
#              触发 -Rollback（避免拆 sshd 时自断通道），宿主侧同步清本技能建的私钥/known_hosts
#           b) 通道不在 → 打印用户在 VM 管理员 PowerShell 里执行的那一条命令
#
# 注意：绝不为了拆通道而重建通道；绝不重启 VM。
#
# 用法：bash scripts/undeploy-3-ssh.sh [--remove-ssh-tunnel yes|no] [--purge-sshd]
#
#   --purge-sshd ：在同一个 SYSTEM 任务里，-Rollback 之后再跑 vm-purge-sshd.ps1：
#                  停/删 sshd 服务、卸 OpenSSH MSI（product code 从注册表解析）、
#                  删 C:\Program Files\OpenSSH、C:\ProgramData\ssh（含
#                  administrators_authorized_keys 与用户 authorized_keys）、
#                  System32\OpenSSH、防火墙规则，最后删 C:\ProgramData\WinVMDeploy。
#                  证据留在 C:\ProgramData\winvm-purge-sshd.log（通道已断，只能靠它复盘）。
set -u
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]:-$0}")/_common.sh"

REMOVE="no"; PURGE_SSHD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --remove-ssh-tunnel) REMOVE="${2:-no}"; shift ;;
    --remove-ssh-tunnel=*) REMOVE="${1#*=}" ;;
    --purge-sshd) PURGE_SSHD=1 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac; shift
done
case "$REMOVE" in yes|no) ;; *) echo "--remove-ssh-tunnel 只接受 yes|no（当前:$REMOVE）" >&2; exit 2 ;; esac

resolve_env; need_node
VM_SCRIPT_WIN='C:\ProgramData\WinVMDeploy\winvm-sshd-oneclick.ps1'
# BOM 归一化片段（可重复粘贴）：oneclick 源文件是 UTF-8 **无 BOM**（irm|iex / scriptblock 的硬要求），
# 而 powershell -File 在 PS 5.1 上对无 BOM 文件按系统 ANSI(CP936) 解码 ⇒ 中文注释变乱码
# ⇒ 乱码里的 ? 打断引号配对 ⇒ ParserError「unexpected token」，脚本一行未执行。
# 所以凡是要用 -File 跑它（-Rollback / 重建），先把副本重写成 UTF-8 with BOM。
BOM_FIX="\$b=[IO.File]::ReadAllBytes('$VM_SCRIPT_WIN'); if (-not (\$b.Length -ge 3 -and \$b[0] -eq 0xEF)) { [IO.File]::WriteAllText('$VM_SCRIPT_WIN',[Text.Encoding]::UTF8.GetString(\$b),(New-Object Text.UTF8Encoding(\$true))) }"
USER_CMD="$BOM_FIX; powershell -NoProfile -ExecutionPolicy Bypass -File $VM_SCRIPT_WIN -Rollback"

# ── 保留通道（默认）──
if [ "$REMOVE" = "no" ]; then
  st_begin 3a "SSH 通道处理（--remove-ssh-tunnel no）"
  st_end 0 SKIP "通道保留（下次 deploy 第 1 步会直接判定 READY 并跳过）"
  echo "TUNNEL=KEPT"
  steps_report
  exit 0
fi

# ── 拆通道 ──
st_begin 3a "通道状态（只判不建）"
if channel_ready 6000; then CH=1; st_end 0 PASS "channel=READY → 走 SYSTEM post 动作"; else CH=0; st_end 0 SKIP "channel=DOWN → 走用户命令"; fi

# v2.4.0（用户 2026-11-18 裁定）：原 3c「宿主侧私钥/known_hosts 回滚」已删除。
# 理由：① 私钥是可复用资产，删掉会让下次部署重新备钥（多一轮 1b）；
#       ② 该步只在 no-baseline 时才"保守保留"，价值密度低，却占一个环节；
#       ③ 真正的安全边界是「只删自己建的东西」，由 deploy 第 1 步的 host-state.json
#          基线保证——不再主动删，就不存在误删风险。
# 需要手工清私钥时：node -e 'fs.unlinkSync("<KEY>")'（宿主禁 rm）。

if [ "$CH" = "1" ]; then
  st_begin 3b "VM SYSTEM post 动作（用 VM 上已存的 oneclick -Rollback）"
  PL="$(sub_log tunnel-post)"
  # 首选 VM 上已存的那份（deploy 第 1 步留下的）；缺失时**就地下载**再跑，
  # 因为「让用户手敲一条指向不存在文件的命令」是死路（实测踩到）。
  # 绝不 scp 新模板、绝不为拆通道而重建通道。
  # 多源：VM 出口网络与宿主不同，单源 404 会让「拆通道」直接死路，故内联候选数组逐个试。
  SRCS_PS=""
  URL_FOR_VM="$(sshd_script_url || true)"
  if [ -n "$URL_FOR_VM" ] && url_reachable "$URL_FOR_VM"; then
    SRCS_PS="$(sshd_script_srcs_ps 4)"
    echo "  兜底下载源（首个可达）: $URL_FOR_VM（共 $(printf '%s' "$SRCS_PS" | tr ',' '\n' | awk '{n++} END{print n+0}') 个候选）"
  else
    echo "  [WARN] 远端脚本地址不可达，缺文件时将只能给用户手工命令"
  fi
  cat > "$PL.ps1" <<'PS1'
$rb  = 'C:\ProgramData\WinVMDeploy\winvm-sshd-oneclick.ps1'
$src = @(__SRCS__)
$purgeB64 = '__PURGE_B64__'
if (-not (Test-Path $rb)) {
  if ($src.Count -eq 0) { Write-Output 'NO_LOCAL_SCRIPT_NO_URL'; exit 3 }
  $ok = $false
  foreach ($u in $src) {
    try {
      New-Item -ItemType Directory -Force -Path (Split-Path $rb) | Out-Null
      Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $rb -TimeoutSec 45
      Unblock-File $rb; $ok = $true; break
    } catch { Write-Output ('src-fail: ' + $u) }
  }
  if (-not $ok) { Write-Output 'DOWNLOAD_FAILED: all sources'; exit 4 }
  Write-Output 'DOWNLOADED'
}
# PS 5.1 decodes a BOM-less UTF-8 file with the system ANSI codepage, so any
# non-ASCII comment turns into mojibake and breaks quoting => ParserError before
# a single line runs. The source file must stay BOM-less (irm|iex requirement),
# therefore the staged copy is normalized right before powershell -File sees it.
if (Test-Path $rb) {
  $b = [IO.File]::ReadAllBytes($rb)
  if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) {
    [IO.File]::WriteAllText($rb, [Text.Encoding]::UTF8.GetString($b), (New-Object Text.UTF8Encoding($true)))
    Write-Output 'BOM_NORMALIZED'
  }
}
if ($purgeB64 -ne 'NONE') {
  # --purge-all: the same deferred SYSTEM task must also delete sshd itself.
  # A wrapper is required because the task action takes a single command line.
  $purgePath = 'C:\ProgramData\WinVMDeploy\vm-purge-sshd.ps1'
  New-Item -ItemType Directory -Force -Path (Split-Path $purgePath) | Out-Null
  [IO.File]::WriteAllBytes($purgePath, [Convert]::FromBase64String($purgeB64))
  Unblock-File $purgePath
  $wrap = 'C:\ProgramData\WinVMDeploy\WbPurgeAll.ps1'
  $body = @(
    ('$rb = ' + [char]39 + $rb + [char]39),
    ('& powershell -NoProfile -ExecutionPolicy Bypass -File $rb -Rollback'),
    ('& powershell -NoProfile -ExecutionPolicy Bypass -File ' + [char]39 + $purgePath + [char]39 + ' -Apply')
  ) -join [char]10
  [IO.File]::WriteAllText($wrap, $body, (New-Object Text.UTF8Encoding($false)))
  Unblock-File $wrap
  $tr = 'powershell -NoProfile -ExecutionPolicy Bypass -File ' + $wrap
  Write-Output 'PURGE_WRAPPER_READY'
} else {
  $tr = 'powershell -NoProfile -ExecutionPolicy Bypass -File ' + $rb + ' -Rollback'
}
# /ST must be a FUTURE time: a past value makes schtasks warn and the task would
# never fire on its own (we rely on /Run, but a silent no-fire is unrecoverable).
$st = (Get-Date).AddMinutes(10).ToString('HH:mm')
$a1 = @('/Create','/TN','WbTunnelRollback','/TR',$tr,'/SC','ONCE','/ST',$st,'/RL','HIGHEST','/RU','SYSTEM','/F')
& schtasks.exe $a1 | Out-Null
$a2 = @('/Run','/TN','WbTunnelRollback')
& schtasks.exe $a2 | Out-Null
Write-Output 'POST_ROLLBACK_SCHEDULED'
PS1
  # 占位替换注入 URL 与（purge-all 时的）sshd 清理脚本 base64
  PB64="NONE"
  [ "$PURGE_SSHD" = "1" ] && PB64="$("$NODE" -e 'const fs=require("fs");process.stdout.write(fs.readFileSync(process.argv[1]).toString("base64"))' "$SCRIPTDIR/vm-purge-sshd.ps1")"
  "$NODE" -e 'const fs=require("fs");const p=process.argv[1];let s=fs.readFileSync(p,"utf8");s=s.replace("__SRCS__",process.argv[2]);s=s.replace("__PURGE_B64__",process.argv[3]);fs.writeFileSync(p,s)' "$PL.ps1" "${SRCS_PS:-}" "$PB64"
  bash "$SCRIPTDIR/ps-run.sh" "$PL.ps1" > "$PL" 2>&1; PRC=$?
  tr -d '\r' < "$PL" | tail -5
  if [ $PRC -eq 0 ] && grep -q 'POST_ROLLBACK_SCHEDULED' "$PL" 2>/dev/null; then
    if [ "$PURGE_SSHD" = "1" ]; then
      grep -q 'PURGE_WRAPPER_READY' "$PL" 2>/dev/null || echo "  [WARN] wrapper 未确认（$PL）"
      st_end 0 PASS "SYSTEM 任务已触发：-Rollback → vm-purge-sshd（卸 sshd + 两处 authorized_keys + WinVMDeploy）"
    else
      st_end 0 PASS "SYSTEM 任务已触发（VM 在本会话断开后自行完成 -Rollback）"
    fi
    # v2.4.0：原 3d「等通道消失」已删。理由：拆通道是 SYSTEM 任务的异步结果，
    # 宿主空等 6~27s 只影响"本次是否打印 REMOVED"，不改变任何终态；
    # 真需要确认时重跑 deploy 第 1 步（1a 会实测），比在这里轮询更准。
    TUNNEL=SCHEDULED
    echo "TUNNEL=SCHEDULED（异步；如需确认，重跑 deploy 第 1 步看 1a 判据）"
    state_set CHANNEL_READY 0
    steps_report
    exit 0
  fi
  st_end $PRC SKIP "post 动作未成功（转用户命令）"
  grep -q 'DOWNLOAD_FAILED' "$PL" 2>/dev/null && echo "  VM 侧下载失败：$(tr -d '\r' < "$PL" | grep DOWNLOAD_FAILED | head -1)"
  grep -q 'NO_LOCAL_SCRIPT_NO_URL' "$PL" 2>/dev/null && echo "  VM 上无 $VM_SCRIPT_WIN 且远端地址不可达"
fi

# 通道不在 / post 失败 → 给用户那一条命令
st_begin 3b "输出用户命令（通道不可用时唯一安全路径）"
if [ "$PURGE_SSHD" = "1" ]; then
  # 通道已断时，「彻底」必须也包含 sshd —— 否则用户跑完 -Rollback 通道照旧
  # 不回来（sshd 服务还在但钥已删），而技能这边再也没有入口补那一段。
  # 命令做成自包含：内联 base64 写出 vm-purge-sshd.ps1 → -Rollback → -Apply。
  PB64U="$("$NODE" -e 'const fs=require("fs");process.stdout.write(fs.readFileSync(process.argv[1]).toString("base64"))' "$SCRIPTDIR/vm-purge-sshd.ps1")"
  cat <<EOF

════════════════ 彻底卸载：在 VM 管理员 PowerShell 里执行这一整条 ════════════════
\$ErrorActionPreference='Continue'; \$d='C:\\ProgramData\\WinVMDeploy'; New-Item -ItemType Directory -Force -Path \$d|Out-Null; \$p=Join-Path \$d 'vm-purge-sshd.ps1'; [IO.File]::WriteAllBytes(\$p,[Convert]::FromBase64String('$PB64U')); Unblock-File \$p; \$rb=Join-Path \$d 'winvm-sshd-oneclick.ps1'; if (Test-Path \$rb) { \$b=[IO.File]::ReadAllBytes(\$rb); if (-not (\$b.Length -ge 3 -and \$b[0] -eq 0xEF)) { [IO.File]::WriteAllText(\$rb,[Text.Encoding]::UTF8.GetString(\$b),(New-Object Text.UTF8Encoding(\$true))) }; powershell -NoProfile -ExecutionPolicy Bypass -File \$rb -Rollback }; powershell -NoProfile -ExecutionPolicy Bypass -File \$p -Apply
══════════════════════════════════════════════════════════════════════════════════
（一条命令三段：写出 sshd 清理脚本 → 若 oneclick 脚本仍在则 -Rollback → 停/删 sshd、
  卸 OpenSSH MSI、删 C:\\ProgramData\\ssh 的两处 authorized_keys、删 WinVMDeploy。
  过程中 SSH 会断，属预期；证据留在 C:\\ProgramData\\winvm-purge-sshd.log）
EOF
else
  cat <<EOF

════════════════════ 卸载通道：在 VM 管理员 PowerShell 里执行这一条 ════════════════════
$USER_CMD
══════════════════════════════════════════════════════════════════════════════════════
（该脚本是 deploy 第 1 步下载并留在 VM 上的；它按 journal 逆序精确还原，可重复执行）
EOF
fi
st_end 0 WAIT_USER "TUNNEL_REMOVE_PENDING_USER"
echo "TUNNEL=PENDING_USER"
echo "NEED_USER_ACTION=1"
state_set CHANNEL_READY 0
steps_report
exit 2
