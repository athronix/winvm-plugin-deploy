#!/usr/bin/env bash
# deploy-3-tunnel.sh · 起 winvm-tunnel service 并验证（deploy 第 3 步，需 1+2 完成）
#
# 只做两件：把隧道服务拉起来（幂等 restart）+ 用真实 HTTP 判据验证（health=200）。
# 顺带修一个已知脆弱点：vm-conn.json 的 identityFile 是单值，若指向未被授权的钥
# （VM 重建后 authorized_keys 只留本技能的钥），隧道会连续 "All configured
# authentication methods failed"。这里按"文件存在的钥"对齐后再起。
#
# 用法：VM_HOST=... bash scripts/deploy-3-tunnel.sh
set -u
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]:-$0}")/_common.sh"

resolve_env; need_node
state_load
PKG="${PKG_ROOT:-}"
[ -n "$PKG" ] && [ -f "$PKG/delivery/winvm-plugin.mjs" ] \
  || die "找不到包根" "第 2 步未完成或状态丢失" "state=$STATE_FILE" \
         "先跑 bash scripts/deploy-2-host.sh"

st_begin 3a "对齐 vm-conn.json 的 identityFile"
VMC="$WINVM_HOME/vm-conn.json"
if [ -f "$VMC" ]; then
  CUR="$("$NODE" -e 'try{process.stdout.write(require(process.argv[1]).identityFile||"")}catch{}' "$VMC" 2>/dev/null)"
else
  CUR=""
fi
WANT="$WINVM_VM_KEY"
if [ "$CUR" != "$WANT" ]; then
  if [ -f "$WANT" ]; then
    "$NODE" -e '
      const fs=require("fs"),p=process.argv[1],k=process.argv[2];
      let j={}; try{j=JSON.parse(fs.readFileSync(p,"utf8"))}catch{}
      j.identityFile=k; j.vmHost=j.vmHost||process.argv[3]; j.vmUser=j.vmUser||process.argv[4];
      j.vmSshPort=j.vmSshPort||Number(process.argv[5]);
      fs.writeFileSync(p, JSON.stringify(j,null,2)+"\n");
    ' "$VMC" "$WANT" "$VM_HOST" "$VM_USER" "$VM_SSH_PORT" 2>/dev/null \
      && echo "  identityFile: ${CUR:-<空>} → $WANT" \
      || warn "vm-conn.json 写入失败（继续，隧道可能用旧钥）"
  else
    warn "目标密钥不存在：$WANT（跳过对齐）"
  fi
else
  echo "  identityFile 已是 $WANT"
fi
st_end 0 PASS "identityFile=$(basename "$WANT")"

st_begin 3b "起隧道服务（幂等：已就绪则不重启）"
TL="$(sub_log tunnel)"
PORT="${WINVM_TUNNEL_LOCAL_PORT:-18443}"
HC0="$(health_code "$PORT" 5)"
if [ "$HC0" = "200" ]; then
  # 幂等短路：隧道已在服务且 health 通，就别 restart。
  # 实证代价（2026-11-16）：restart 会重建到 VM 的 ssh 连接，与第 4 步（并行）的新建连接
  # 抢 VM sshd 的握手槽，实测把第 4 步打成 "Connection lost before handshake"。
  echo "  health=200（隧道已在跑）→ 跳过 restart"
  st_end 0 SKIP "already-healthy（避免与第 4 步抢 ssh 握手）"
else
  ( cd "$PKG" && "$NODE" delivery/winvm-plugin.mjs tunnel restart > "$TL" 2>&1 ); TRC=$?
  tail -6 "$TL"
  st_end 0 SKIP "restart rc=$TRC（判据归 3c health）"
fi

st_begin 3c "验证隧道（/health = 200）"
PORT="${WINVM_TUNNEL_LOCAL_PORT:-18443}"
HC="000"; tries=0
while [ "$tries" -lt 30 ]; do
  HC="$(health_code "$PORT" 6)"
  [ "$HC" = "200" ] && break
  tries=$((tries + 1)); sleep 2
done
echo "  health=$HC (port=$PORT, ${tries} 次等待)"
if [ "$HC" != "200" ]; then
  st_end 1 FAIL "health=$HC"
  echo "--- tunnel 日志尾部 ---"
  tail -20 "$WINVM_HOME/tunnel.log" 2>/dev/null || echo "(无 tunnel.log)"
  die "隧道未就绪" "daemon 起不来或到 VM 18443 不通" "health=$HC" \
      "看 $WINVM_HOME/tunnel.log 与 $TL；不要重启 VM"
fi
st_end 0 PASS "health=200"
state_set TUNNEL_READY 1
steps_report
