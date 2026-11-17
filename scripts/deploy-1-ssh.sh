#!/usr/bin/env bash
# deploy-1-ssh.sh · 建立 host↔VM 免密 SSH 通道（deploy 第 1 步）
#
# 子步骤（用户 2026-11-16 裁定）：
#   1a  判断是否已有免密通道  → READY 则 1b~1d 全 SKIP
#   1b  准备 host 端密钥（与 1a 同脚本；首次生成 + 记录可回滚基线）
#   1c  打印**一条** VM 管理员 PowerShell 命令（脚本由 VM 从远端下载并就地留存）
#   1d  host 端验证；不通过 → 回到 1b 换钥重来（最多 CHANNEL_ROUNDS 轮）
#
# 退出码：0=通道就绪 / 2=需要用户粘贴（NEED_USER_ACTION） / 1=失败
#
# 用法：
#   VM_HOST=172.16.100.2 bash scripts/deploy-1-ssh.sh
#   CHANNEL_WAIT_S=600 bash scripts/deploy-1-ssh.sh    # 打印后原地等用户粘贴（默认 0=不等）
#   ROTATE=1 bash scripts/deploy-1-ssh.sh              # 强制换钥
set -u
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]:-$0}")/_common.sh"

resolve_env; need_node; require_host
PKG_DIR_HINT="$WINVM_HOME"
HOST_STATE_DIR="${WB_TUNNEL_STATE_DIR:-$HOME/.workbuddy/.state/winvm-tunnel}"
HOST_STATE="$HOST_STATE_DIR/host-state.json"
KEY="$WINVM_VM_KEY"
ROUNDS="${CHANNEL_ROUNDS:-3}"
WAIT_S="${CHANNEL_WAIT_S:-0}"

# 远端脚本 URL 与可达性判定来自 _common.sh（deploy 第 1 步与 undeploy 第 3 步共用同一解析）

# 写回滚基线（只在缺失时写；1a 判 READY 与 1b 备钥两条路都要写，
# 否则「通道本来就活着」的机器永远没有基线，undeploy 只能保守不删钥）
write_baseline_if_absent() { # <existed 0|1> <ours 0|1> <known_before 0|1> [force_created]
  [ -f "$HOST_STATE" ] && return 0
  mkdir -p "$HOST_STATE_DIR" 2>/dev/null || true
  "$PY" - "$HOST_STATE" "$KEY" "$1" "$2" "$3" "$VM_HOST" "$VM_USER" "$VM_SSH_PORT" "${4:-}" <<'PY'
import json, os, sys, datetime
p, key, existed, ours, known, ip, user, port = sys.argv[1:9]
force = (sys.argv[9] if len(sys.argv) > 9 else '').strip()
created = True if force == 'true' else ((existed == '0') or (ours == '1'))
st = {'ts': datetime.datetime.now().isoformat(timespec='seconds'), 'keyPath': key,
      'keyExistedBefore': existed == '1', 'keyCreatedBySkill': created,
      'knownHostsEntryExistedBefore': known == '1',
      'vmIp': ip, 'vmUser': user, 'port': port, 'createdBy': 'winvm-plugin-deploy'}
os.makedirs(os.path.dirname(p), exist_ok=True)
json.dump(st, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print('[baseline] 已记录 -> %s (keyCreatedBySkill=%s knownHostsExistedBefore=%s)'
      % (p, created, known == '1'))
PY
}

key_facts() { # 输出 "<existed> <ours> <known_before>"
  local existed=0 ours=0 known_before=0
  [ -f "$KEY" ] && existed=1
  [ -f "$KEY.pub" ] && grep -q 'workbuddy-winvm' "$KEY.pub" 2>/dev/null && ours=1
  [ -f "$HOME/.ssh/known_hosts" ] && grep -q -- "$VM_HOST" "$HOME/.ssh/known_hosts" 2>/dev/null && known_before=1
  printf '%s %s %s' "$existed" "$ours" "$known_before"
}

# ── 1b：准备 host 端密钥 + 记录可回滚基线 ──
prepare_key() {
  local rotate="${1:-0}"
  mkdir -p "$(dirname "$KEY")" "$HOST_STATE_DIR" 2>/dev/null || true
  local existed=0 ours=0
  [ -f "$KEY" ] && existed=1
  [ -f "$KEY.pub" ] && grep -q 'workbuddy-winvm' "$KEY.pub" 2>/dev/null && ours=1

  if [ "$rotate" = "1" ] && [ -f "$KEY" ]; then
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    "$NODE" -e 'const fs=require("fs");for(const s of ["","\.pub"]){try{fs.renameSync(process.argv[1]+s,process.argv[1]+s+".old-"+process.argv[2])}catch{}}' "$KEY" "$ts" 2>/dev/null \
      || true
    echo "[1b] 旧钥已备份为 $KEY.old-$ts"
  fi
  if [ ! -f "$KEY" ]; then
    if ! command -v ssh-keygen >/dev/null 2>&1; then
      die "缺少 ssh-keygen" "host 端无法生成密钥" "$(command -v ssh-keygen || echo not-found)" \
          "确认 PATH 含 openssh-client；或手工放置 $KEY 后重跑"
    fi
    ssh-keygen -t ed25519 -N '' -C 'workbuddy-winvm' -f "$KEY" >/dev/null 2>&1 \
      || die "ssh-keygen 失败" "无法写入 $KEY" "见上一条命令输出" "检查目录可写性：$(dirname "$KEY")"
    echo "[1b] 已生成新密钥：$KEY"
  else
    echo "[1b] 复用已有密钥：$KEY"
  fi

  # 基线只写一次（供 undeploy-3 精确回滚：删本技能建的钥 / 恢复 known_hosts）
  local known_before=0
  [ -f "$HOME/.ssh/known_hosts" ] && grep -q -- "$VM_HOST" "$HOME/.ssh/known_hosts" 2>/dev/null && known_before=1
  write_baseline_if_absent "$existed" "$ours" "$known_before" "$([ "$rotate" = "1" ] && echo true)"
  PUB="$(cat "$KEY.pub" 2>/dev/null)"
  [ -n "$PUB" ] || die "公钥不可读" "$KEY.pub 为空" "cat 失败" "重跑并加 ROTATE=1 换钥"
}

# ── 1c：打印用户命令 ──
print_user_command() {
  local url="$1" pub="$2"
  # -AllowFrom 在 VM 侧落成**防火墙白名单**（只放行该来源 IP）。默认绝不能给
  # $VM_HOST——那是 VM 自己的地址，会把宿主直接挡在门外（实测症状=连接超时）。
  # 只有用户显式给 VM_ALLOW_FROM=<宿主源IP> 时才带。
  local allow_arg=""
  [ -n "${ALLOW_FROM:-}" ] && allow_arg=" -AllowFrom '$ALLOW_FROM'"
  # 多源：VM 的出口网络与宿主不同，单源 404/超时会把用户直接卡死。
  # 命令内联候选数组逐个 try，失败才抛错；全程只用单引号（经 Git Bash 粘贴不会被吞引号）。
  local srcs; srcs="$(sshd_script_srcs_ps 4)"
  [ -n "$srcs" ] || srcs="'$url'"
  # irm 备选命令与 -File 路径共用同一候选数组：VM 出口网络与宿主不同，单源失败率高。
  local raw_main="https://raw.githubusercontent.com/athronix/winvm-plugin-deploy/main/scripts/winvm-sshd-oneclick.ps1"
  cat <<EOF

════════════════════ user 只需要做这一件事 ════════════════════
把下面【一整行】复制到 VM 的【管理员 PowerShell】里回车（约 1~3 分钟，含装 OpenSSH）

\$ErrorActionPreference='Stop';\$d=Join-Path \$env:ProgramData 'WinVMDeploy';New-Item -ItemType Directory -Force -Path \$d|Out-Null;\$f=Join-Path \$d 'winvm-sshd-oneclick.ps1';\$src=@($srcs);\$ok=\$false;foreach(\$x in \$src){try{Invoke-WebRequest -UseBasicParsing -Uri \$x -OutFile \$f -TimeoutSec 45;\$ok=\$true;break}catch{Write-Host ('src-fail: '+\$x)}};if(-not \$ok){throw 'DOWNLOAD_ALL_FAILED'};Unblock-File \$f;powershell -NoProfile -ExecutionPolicy Bypass -File \$f -PublicKey '$pub' -User '$VM_USER' -Port $VM_SSH_PORT$allow_arg

脚本会自己存到 VM 的 C:\\ProgramData\\WinVMDeploy\\winvm-sshd-oneclick.ps1
（卸载通道时直接：powershell -NoProfile -ExecutionPolicy Bypass -File C:\\ProgramData\\WinVMDeploy\\winvm-sshd-oneclick.ps1 -Rollback）

【备选：不想先落盘时用 irm|iex 直跑】脚本会把自己再下载落盘到同一路径，功能等价：
\$ErrorActionPreference='Stop';\$src=@($srcs);\$s=\$null;foreach(\$x in \$src){try{\$s=Invoke-RestMethod -UseBasicParsing -Uri \$x -TimeoutSec 45;if(\$s){break}}catch{}};if(-not \$s){throw 'DOWNLOAD_ALL_FAILED'};&([scriptblock]::Create(\$s)) -PublicKey '$pub' -User '$VM_USER' -Port $VM_SSH_PORT -SelfUrl \$src$allow_arg
══════════════════════════════════════════════════════════════
EOF
  local nsrc; nsrc="$(printf '%s' "$srcs" | awk -F',' '{print NF}')"
  echo "脚本来源（按序尝试，共 $nsrc 个）:"
  printf '%s\n' "$srcs" | tr ',' '\n' | sed "s/^/  /;s/'//g"
  echo "公钥指纹: $(ssh-keygen -lf "$KEY.pub" 2>/dev/null || echo '(不可用)')"
  echo "NEED_USER_ACTION=1"
}

# ═══════════════════════════ 1a ═══════════════════════════
st_begin 1a "判断 host↔VM 免密通道"
if channel_ready 5000; then
  # 通道可用还需确认"是本技能这把钥"，否则后续 scp 会用错钥
  # 同时补写回滚基线：READY 路径此前从不写基线，会让 undeploy 无从判断钥的归属
  read -r _ex _ours _kh <<<"$(key_facts)"
  write_baseline_if_absent "$_ex" "$_ours" "$_kh"
  st_end 0 PASS "channel=READY key=$(basename "$KEY") → 1b~1d SKIP"
  state_set CHANNEL_READY 1
  state_set WINVM_VM_KEY "$KEY"
  steps_report
  exit 0
fi
st_end 0 SKIP "channel=DOWN → 进入 1b 备钥"
CH_ROUND=0
# ═══════════════ 1b/1c/1d 迭代（验证失败回 1b 换钥） ═══════════════
while [ "$CH_ROUND" -lt "$ROUNDS" ]; do
  CH_ROUND=$((CH_ROUND + 1))
  ROT=0; [ "$CH_ROUND" -gt 1 ] && ROT=1
  [ "${ROTATE:-0}" = "1" ] && [ "$CH_ROUND" -eq 1 ] && ROT=1

  st_begin "1b.$CH_ROUND" "准备 host 端密钥（round $CH_ROUND/$ROUNDS rotate=$ROT）"
  prepare_key "$ROT" || die "备钥失败" "1b 未产出可用密钥" "见上" "修好后重跑本脚本"
  st_end 0 PASS "key=$KEY pub=sha256:$(ssh-keygen -lf "$KEY.pub" 2>/dev/null | awk '{print $2}')"

  st_begin "1c.$CH_ROUND" "打印 VM 侧一键命令（远端下载）"
  if ! URL="$(sshd_script_url)"; then
    st_end 1 FAIL "无法解析远端脚本 URL"
    die "拿不到 winvm-sshd-oneclick.ps1 的远端地址" \
        "多源候选全空（tag 解析失败且无 SSHD_SCRIPT_URL）" \
        "sshd_script_urls() 输出为空" \
        "显式指定：SSHD_SCRIPT_URL=<直链> bash scripts/deploy-1-ssh.sh"
  fi
  if ! url_reachable "$URL"; then
    st_end 1 FAIL "全部候选源宿主侧不可达（首个 $URL）"
    echo "  候选源（宿主侧探测结果）："
    while IFS= read -r _u; do
      [ -n "$_u" ] || continue
      if url_reachable "$_u"; then echo "    [200] $_u"; else echo "    [---] $_u"; fi
    done <<UEOF
$(sshd_script_urls)
UEOF
    die "远端脚本地址全部不可达" "该 tag 的 release 未含 ps1，且 GitHub raw 也拉不到" \
        "见上方逐源探测结果" \
        "先发布新版（资产含该 ps1），或 SSHD_SCRIPT_URL 指向可用直链"
  fi
  # -AllowFrom = VM 侧防火墙白名单（只放行该来源）。默认留空=不限定来源，
  # 仍受 ListenAddress 收窄保护；要收紧就显式 VM_ALLOW_FROM=<宿主源IP>。
  ALLOW_FROM="${VM_ALLOW_FROM:-}"
  st_end 0 WAIT_USER "url=$URL"
  print_user_command "$URL" "$PUB"

  # 可选原地等待（默认不等待：编排层把命令显形给用户后退出，用户粘完重跑即越过本步）
  if [ "$WAIT_S" -gt 0 ]; then
    st_begin "1d.$CH_ROUND" "等待用户粘贴并验证通道（≤${WAIT_S}s）"
    waited=0; ready=0
    while [ "$waited" -lt "$WAIT_S" ]; do
      sleep 5; waited=$((waited + 5))
      if channel_ready 5000; then ready=1; break; fi
      [ $((waited % 60)) -eq 0 ] && echo "  … 已等 ${waited}s / ${WAIT_S}s（在 VM 里粘贴执行后会自动继续）"
    done
    if [ "$ready" = "1" ]; then
      st_end 0 PASS "channel=READY after ${waited}s"
      state_set CHANNEL_READY 1
      state_set WINVM_VM_KEY "$KEY"
      steps_report; exit 0
    fi
    st_end 2 WAIT_USER "等待超时 ${WAIT_S}s，通道仍未就绪"
    echo "NEED_USER_ACTION=1（命令已打印；粘贴执行后重跑本脚本即继续）"
    exit 2
  fi

  # 不等待模式：给用户命令后即退出，由用户粘完重跑
  state_set CHANNEL_READY 0
  state_set WINVM_VM_KEY "$KEY"
  echo "DEPLOY_NEED_USER_ACTION=1（下一步：粘贴上面那一行 → 重跑 bash scripts/deploy.sh）"
  steps_report
  exit 2
done

die "通道三轮仍未建立" "密钥/网络/权限三者之一" "见 1b/1c 各轮日志" \
    "在 VM 里跑 -Continue 只读体检：powershell -File C:\\ProgramData\\WinVMDeploy\\winvm-sshd-oneclick.ps1 -Continue"
