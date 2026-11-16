#!/usr/bin/env bash
# winvm-plugin-deploy · 过程执行环节信息列表生成器 (v1.7.0)
# Reads actions.tsv + steps.tsv + states/*, emits a Markdown process table.
# DEFAULT: table + full intermediate detail are written to files; only the
# FINAL table is echoed to stdout (user ruling 2026-11-13: front stage prints
# just the final process table; all intermediate logs land in the run dir).
# VERBOSE=1 additionally streams intermediate detail to stdout.
set -u
RUN_DIR="${VMDEPLOY_RUN_DIR:-${HOME}/wbtmp/vmdeploy-run-$(date +%Y%m%d)}"
PY="${PY:-$(command -v python3 || true)}"; [ -n "$PY" ] || PY=/data/service/hnp/bin/python3
VERBOSE="${VERBOSE:-0}"
OUT="$RUN_DIR/process-actions.md"
"$PY" - "$RUN_DIR" "$OUT" <<'PYEOF'
import os,sys,datetime
rd,out=sys.argv[1],sys.argv[2]
def read(fn):
    p=os.path.join(rd,fn)
    return open(p,encoding="utf-8",errors="replace").read().splitlines() if os.path.isfile(p) else []
acts=[l.split("\t") for l in read("actions.tsv")[1:] if l.strip()]
hdr=["seq","process","phase","step","desc","cmd","subject","env","begin_utc","end_utc","dur_s",
     "rc","result","judged","issues","pre_state","post_state","log_path","error_excerpt",
     "next_ok","next_fail","mergeable"]
rows=[dict(zip(hdr,(r+[""]*len(hdr))[:len(hdr)])) for r in acts]
# state diffs (pre vs post) - only changed lines
def diff(pre,post):
    a=read(os.path.join("states",pre)); b=read(os.path.join("states",post))
    sa=[x for x in a if not x.startswith("at=")]; sb=[x for x in b if not x.startswith("at=")]
    ch=[f"{x} -> {y}" for x,y in zip(sa,sb) if x!=y]
    return ("; ".join(ch)[:180] if ch else "no local-state change")
L=[]
L.append("# 过程执行环节信息列表（winvm-plugin-deploy v1.7.0）")
L.append("")
L.append(f"- 生成时刻：{datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')}")
L.append(f"- 运行目录：`{rd}`（中间详细日志、前后状态、错误日志全在此）")
L.append(f"- 动作数：{len(rows)}；通过：{sum(1 for r in rows if r['result']=='PASS')}；"
         f"失败：{sum(1 for r in rows if r['result']=='FAIL')}；"
         f"其它：{sum(1 for r in rows if r['result'] not in ('PASS','FAIL'))}")
tot=sum(int(r["dur_s"]) for r in rows if r["dur_s"].isdigit())
L.append(f"- 动作计时合计：{tot}s；最慢 3：")
for r in sorted([r for r in rows if r["dur_s"].isdigit()],key=lambda x:-int(x["dur_s"]))[:3]:
    L.append(f"  - {r['phase']}/{r['step']} {r['dur_s']}s {r['desc'][:48]}")
L.append("")
L.append("| # | 过程 | 环节/动作 | 命令（脚本/系统命令） | 主体 | 环境 | 前置状态→后置状态（差异） | 时长 | rc | 结果 | 判据 | 错误摘录 | 下一步(成功/失败) | 可合并 |")
L.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for r in rows:
    d=diff(r["pre_state"],r["post_state"]) if r["pre_state"] and r["post_state"] else "-"
    nxt=(r["next_ok"] or "-")+" / "+(r["next_fail"] or "-")
    cells=[r["seq"],r["process"],f"{r['phase']}/{r['step']} {r['desc']}",r["cmd"],r["subject"],r["env"],
           d,(r["dur_s"] or "-")+"s",r["rc"],r["result"],r["judged"],r["error_excerpt"],nxt,r["mergeable"]]
    L.append("| "+" | ".join(str(c).replace("|","/").replace("\n"," ")[:230] for c in cells)+" |")
L.append("")
L.append("## 失败/异常动作（四元组：现象 / 根因 / 证据 / 处置）")
L.append("")
bad=[r for r in rows if r["result"]!="PASS" or r["rc"] not in ("0","")]
if not bad: L.append("（无）")
for r in bad:
    L.append(f"- **{r['phase']}/{r['step']} {r['desc']}**")
    L.append(f"  - 现象：rc={r['rc']} result={r['result']} judged={r['judged']}")
    L.append(f"  - 证据：`{r['log_path']}`；错误摘录={r['error_excerpt'] or '-'}")
    L.append(f"  - 处置（确定性命令）：`{r['next_fail']}`")
    L.append(f"  - 前后状态：`{r['pre_state']}` → `{r['post_state']}`")
L.append("")
L.append("## 合并与效率分析")
L.append("")
mergeable=sum(1 for r in rows if r["mergeable"]=="Y")
L.append(f"- 标记可与上一步合并的动作：{mergeable}/{len(rows)}；已由 `run-flow.sh` 合并为一次后台调用。")
L.append("- 动态参数由 `context.sh collect` 一次性冻结并植入各动作参数，链内无需用户/LLM 决策。")
L.append("- 中间详细信息：`console.log` / `steps.tsv` / `actions.tsv` / `logs/*.log` / `states/*` / `state-*.txt`。")
open(out,"w",encoding="utf-8").write("\n".join(L)+"\n")
# stdout stays CLEAN: run-flow.sh prints only the final table.
PYEOF
if [ "$VERBOSE" = "1" ]; then
  echo "=== [VERBOSE] 中间详细信息索引 ==="
  echo "RUN_DIR=$RUN_DIR"; ls -1 "$RUN_DIR" | head -40
  echo "--- steps.tsv ---"; cat "$RUN_DIR/steps.tsv" 2>/dev/null
  echo "--- actions.tsv ---"; cat "$RUN_DIR/actions.tsv" 2>/dev/null
fi
# FRONT STAGE: final table only
cat "$OUT"
