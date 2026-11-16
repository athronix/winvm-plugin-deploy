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

st_begin 3b "起隧道服务（幂等：本地已监听则不重启）"
TL="$(sub_log tunnel)"
PORT="${WINVM_TUNNEL_LOCAL_PORT:-18443}"
HC0="$(health_code "$PORT" 5)"
TP0="$(tunnel_pid)"
LISTEN0=0
port_listening "$PORT" && LISTEN0=1
if [ "$LISTEN0" = "1" ] && [ "$TP0" != "0" ] && kill -0 "$TP0" 2>/dev/null; then
  # 幂等短路：隧道已在服务（本地端口有 listener + daemon 存活），就别 restart。
  # 实证代价（2026-11-16）：restart 会重建到 VM 的 ssh 连接，与第 4 步（并行）的新建连接
  # 抢 VM sshd 的握手槽，实测把第 4 步打成 "Connection lost before handshake"。
  # 注意判据是"本地监听"，不是 health —— 从零部署时 VM 端服务还没装，health 必然 000。
  echo "  本地 $PORT 已监听且 daemon(pid=$TP0) 存活（health=$HC0）→ 跳过 restart"
  st_end 0 SKIP "already-listening（避免与第 4 步抢 ssh 握手）"
else
  ( cd "$PKG" && "$NODE" delivery/winvm-plugin.mjs tunnel restart > "$TL" 2>&1 ); TRC=$?
  tail -6 "$TL"
  st_end 0 SKIP "restart rc=$TRC（判据归 3c）"
fi

st_begin 3c "验证隧道（本地端口在监听 + daemon 存活）"
PORT="${WINVM_TUNNEL_LOCAL_PORT:-18443}"
OK=0; tries=0
while [ "$tries" -lt 30 ]; do
  if port_listening "$PORT"; then OK=1; break; fi
  tries=$((tries + 1)); sleep 2
done
# health 只是"端到端是否已通"的信息位：从零部署时 VM 端 winvm service 由第 4 步并行安装，
# 此刻 18443 后面没有人应答，health=000 是**合法中间态**，不能当隧道故障（第 5 步才验端到端）。
HC="$([ "$OK" = "1" ] && health_code "$PORT" 3 || printf '000')"
TP="$(tunnel_pid)"
ALIVE=0; [ "$TP" != "0" ] && kill -0 "$TP" 2>/dev/null && ALIVE=1
echo "  listen=$OK daemon=$ALIVE(pid=$TP) health=$HC (port=$PORT, ${tries} 次等待)"
if [ "$OK" != "1" ] || [ "$ALIVE" != "1" ]; then
  st_end 1 FAIL "listen=$OK daemon=$ALIVE"
  echo "--- tunnel 日志尾部 ---"
  tail -20 "$WINVM_HOME/tunnel.log" 2>/dev/null || echo "(无 tunnel.log)"
  die "隧道未建立" "本地 $PORT 无 listener 或 daemon 已退出（≠ VM 端服务问题）" \
      "listen=$OK daemon=$ALIVE(pid=$TP)" "看 $WINVM_HOME/tunnel.log 与 $TL；不要重启 VM"
fi
if [ "$HC" = "200" ]; then
  st_end 0 PASS "listen=yes daemon=yes health=200（端到端已通）"
else
  st_end 0 PASS "listen=yes daemon=yes health=$HC（VM 端服务未装=从零部署合法中间态，端到端归第 5 步）"
fi
state_set TUNNEL_READY 1
steps_report
