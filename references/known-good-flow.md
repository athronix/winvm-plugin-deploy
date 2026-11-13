# 已知良好流程（判据摘录与耗时带宽）

用途：判断「慢是不是异常」「这步本来该输出什么」。数据源=run8/11/12 真机实测（V1.4.16/17 代际）。
**判据权威 = 本技能 `SKILL.md` + `references/troubleshooting.md`**（迭代28 起 `deploy.prompt`/`undeploy.prompt` 已降级退役，仅存档、不入发布包、不再回改）；本文只摘数值与形态。
v1.7.0：默认入口改 `run-flow.sh`（一次调用完成三段，前台只打最终环节表）；中间详细信息全部落 `VMDEPLOY_RUN_DIR`，动作级日志=`actions.tsv` + `states/*-pre/post.txt` + `logs/*.log`；动态参数由 `context.sh collect` 一次冻结。E2E3 baseline 实证：U1 假判据会在 162s 掐断整链（真实卸载其实成功），故 U1 判据只看 HOST verification 行；U1 必须屏蔽包根 `.env`，否则 VM 卸载重复执行、耗时翻倍。E2E3 修复轮：C3.0 判据收紧 + 通道瞬态有界幂等复跑（F-20/F-21）、`ps-run.sh` 清理串零插值（F-19），解决「其余 C3.2~C6 全 PASS 却因单段假红导致 R3 FAIL、R4 SKIP」。E2E3 第二轮：R2.5 四轮 DOWN 的判读先做**双钥 rc 对照**（默认钥 111 / 专用钥 0 = 密钥漂移 F-22，非环境窗），`context.sh` 已改为按实测冻结密钥；只有双钥全败且 health 仍 200 才按 WEDGE 灭窗处置（绝不重启 VM）。
v1.5.0：卸载改为三段式（host / vm / ssh 通道），下表 U0~U4 旧编号仅作耗时带对照，实际判据见「五、v1.5.0 三段式卸载判据」。v1.6.0：SSH 免密通道脚本与参考文档内置（并入 hos-winvm-ssh-tunnel v2.3.0），**判据与耗时带不变**；部署不再需要安装第二个 skill。

## 一、各环节预期耗时带（干净场景，宿主→VM 全链）

| 环节 | 预期带 | 异常信号 |
|---|---|---|
| U0 基线（find+VM 五点） | 15~30s | >1min=通道拥塞（查 timeout 挂起） |
| U1 DRY-RUN | 12~18s | — |
| U2 apply（真拆） | 13~27s | rc≠0 或 FAIL>0=按 troubleshooting B 表 |
| U4 独立复核 | 8~12s | 任何一项与期望不符=假拆嫌疑，立即停 |
| 3.0 ENV_PRECHECK | 20~35s（瞬态截断复跑 1 次 ≤2×） | 判据=`ENV_PRECHECK=PASS` ∧ `BLOCKERS=none`；BLOCKERS≠none=按 P-2 审批补齐；rc=124 且 NODE_OK/CLI_OK 在场=自动有界幂等复跑（勿重跑整链、勿重启 VM） |
| 3.2 deploy/setup apply | **125~140s**（热）；冷机首次可达 ~6min（420s 监听窗内即正常） | 超 420s 未监听=僵尸行处置 |
| 3.3 vmcheck | 15~20s | 七判据任一不符 |
| 4.1 install-host | 2~5s | errno=12=脆弱 node 行 |
| 5.1/5.2/5.3 探针 | 20~25 / 34~40 / 60~180s（链合计**热 ~97 / 冷 ~145 / 深冷 ≤250**） | 判据=零超时零复跑；单项 >300s 查服务端闸/网络 |
| 全程往返参考 | run8=8m35s · run11=408s 步时 · run12=551s（含深冷 +94s） | 显著超带且无新现象=先查 sshd 占满 |

## 二、拆除侧关键判据原文（形态）

- U1 首行必见 `mode : DRY-RUN`；KEEP 项至少含 workspace/authorized_keys；无意外 `[DO]` 越界项。
- U2 POST-CLEANUP 条数动态（宿主 9~11 + VM 8，历轮 19 条）=全 `[PASS]` 零 `[FAIL]`；`APPLY complete`。
- U4：`health=000`（拒连）/ cache absent / `GLOBAL_MCP_CLEAN` / VM 五点=`False False 0 Running True`（注意第 4 位 sshd 是 must-survive=Running）。

## 三、安装侧关键判据原文（形态）

- Step 0.2：`vmssh whoami` 出 `域\用户`；0.4：`NetworkCategory` 与规则 `Profile` 匹配即过（Private/Private OK）。
- 2.3 `RESULT: PASS`（files 881；已装态包根=883 on-disk 属运行期豁免，I-6.4 白名单）。
- 3.3 vmcheck 七判据：`task_state=Running`（或 N1 兜底态）、`listen_addr=127.0.0.1`、`listen_count=1`、`side_json=true`、`bridge_dir=true`、`health_http=200`、`health_body.ok=true`；V1.4.15+ 日志可含 `VM_START_SWEEP PID=…` 清扫显形。
- Step 4：隧道四判据全符（RUNNING/healthy/ownerMatch/!stale）+`FRESH`+`200`+`disabledTools=8`；`connector-states ⚠×2`=平台账户噪声放行。
- Step 5：`RESULT: PASS` ×3（20/20+5/5+13/13）；E7 记录耗时对 X-5 带。
- Step 6：连接器目录=8（含 hos-win-skill、winvm-orchestrator）。

## 四、拆除⇄安装回环验收基线

一轮干净往返的"完全合格"= 上述环节**零重试、零人工纠正、每步 rc=0**（run10/12 达成态）；任何一次脚本面 RETRY 都要在报告 issues 列写明「现象/根因/方案」——driver 的 steps.tsv 即为该报告数据源（`step.sh report` 直出 Top5/问题行）。

## 五、v1.5.0 三段式卸载判据（权威）

| 段 | 输出锚点 | 判据 |
|---|---|---|
| 0 通道状态（只判不建） | `CHANNEL_UP=0|1 REBUILD=NO` | `REBUILD=NO` 必须在场；出现 `ensure` / `host-generate-key` /「重建通道」=违规 |
| 1 host | `HOST_PASS=n HOST_FAIL=0` | `[PASS] HOST` ≥11 且零 `[FAIL] HOST`；`uninstall.mjs` rc=1 属预期（VM 相位按设计跳过） |
| 2 vm（通道在） | `VM_CLEANUP_DONE` + POST STATUS | `BRIDGE_DIR=False / TASK_EXISTS=False / PORT_LISTEN=False / BRIDGE_NODE_LEFT=False`；SSHD 不作判据 |
| 2 vm（通道不在） | `VM_BUNDLE=<dir>` + `NEED_USER_ACTION=1` | 目录四件齐全：`vm-remove-local.ps1` / `wb-rollback.ps1` / `RUN-ME.ps1` / `PASTE-THIS.txt`；VM 终态=`PENDING_USER`（不算失败） |
| 3 ssh 通道 | `TUNNEL_POST_DONE` 或 `TUNNEL_POST_MERGED=1` | 成功判据=**免密登录不再可用**（不是 22 端口关闭）；VM 侧 SYSTEM 任务 `WbTunnelRollback` 在场 |
| 收口 | `UNDEPLOY_DONE parts=host+vm+tunnel vm_mode=...` | `vm_mode=workbuddy|user-bundle`；`--keep-tunnel` 时该段显式跳过 |

耗时带（v1.5.0 宿主侧预期）：通道状态判定 ≤20s（ssh2 ping 单发）；host 段 15~40s；VM 段通道在 ~30~60s、通道不在=合并包生成 <2s + 用户执行；通道 post 段 ~20~40s。显著超带先查 sshd 灭窗相位（ssh2 后端已免疫二进制挂起）。

## 六、v1.7.0 一次执行基线（E2E3 真机实测，2026-11-13）

| 段 | 实测 | 判据锚点 |
|---|---|---|
| R1 download-verify | 1s | `PKG_ROOT=` 非空 |
| U1/U2/U3 host→vm→通道 | 3s / 71s / 1s | `HOST_PASS=11 HOST_FAIL=0`、`VM_CLEANUP_DONE`、`kept by request` |
| R2.5 拆后判稳 | 83s | `STABILITY=STABLE`（**必用新建连接实测**；该窗内 124/111/255 均属瞬态，勿据此查钥） |
| C3.0 ENV_PRECHECK | 116s | `ENV_PRECHECK=PASS` ∧ `BLOCKERS=none` ∧ `retry≤1` |
| C3.2 prepare+setup | 329s | 两段 rc=0 |
| C3.3 vmcheck | 47s | 七判据全符 |
| C5 三探针 38 项 | 169s | 20/20+5/5+13/13；冷启动 ~145s、深冷 ≤250s |
| C6 skill 交付 | 1s | 计数=8 |
| R3 deploy 合计 | 740s | `DEPLOY_APPLY_DONE` |
| R4 verify | 44s | 探针复用 4/3（不重复跑，`deploy_ok=1` 第四防线） |

**全轮：`ACTION=full UNDEPLOY=PASS DEPLOY=PASS VERIFY=PASS WALL_S=994 VERDICT=YES`，23 动作 0 失败。**
台前只打最终「过程执行环节信息表」；中间细节（`console.log`/`steps.tsv`/`actions.tsv`/`logs/*`/`states/*`）全落 `VMDEPLOY_RUN_DIR`。
读表口径：`error_excerpt` = 日志中命中错误关键字的**尾部 3 行**（已滤沙箱 getcwd 噪声）；PASS 行出现摘录仅表示日志含该关键字，例如 U1/R2 的 `uninstall_rc=1` 是 host-only 相位按设计跳过 VM 段的预期记录，不代表失败。
