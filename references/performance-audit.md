# 效率审计：23 动作逐个评判与时间去向（v1.9.1）

> 基线：e2e5 真机全链（`~/wbtmp/e2e5-1428`，2026-11-13，`ACTION=full` 从零安装）。
> 数据源 = `actions.tsv` / `steps.tsv` / `logs/*.log`（含 `setup.log` 自带相位计时）。
> 目标（用户 2026-11-16 裁定，不含用户交互与 LLM 决策）：deploy ≤30s / verify ≤30s / undeploy ≤20s。

## 0. 先去掉重复计量

`actions.tsv` 有 23 行，但 **R1–R4 与 R2.5 是编排层包装行**，与内层动作是同一段时间：

- `R2`(81s) ⊃ `U1+U2+U3+U4`(75s)
- `R3`(964s) ⊃ `P0…C6`(920s)
- `R4`(66s) ⊃ `VERIFY/5-*` + `VERIFY/6`(48s)

真实基线：**undeploy 75s / deploy 920s / verify 48s（复用）· 311s（冷跑）**。

## 1. 逐动作评判

### 编排层（5 行，非独立动作）

| 编号 | 动作 | 实测 | 判定 | 说明 |
|---|---|---|---|---|
| R1/1 | download-verify 取包 | 12s | **必须，但与 C2 重复** | R1 与 C2 各跑一次 download-verify（roundtrip 故意不传 PKG_ROOT 让 deploy 自己取最新） |
| R2/2 | undeploy 包装 | 81s | **重复计量** | = U1–U4，非独立成本 |
| R2.5/2.5 | wait-channel 判稳 | 85s | **冗余 75s** | 连击成功之间 **硬 sleep 75s**（为老 ssh 二进制的半开 auth 槽设计）；ssh2 后端每次独立连接，无需此等待 |
| R3/3 | deploy 包装 | 964s | **重复计量** | = P0–C6 |
| R4/4 | verify 包装 | 66s | **重复计量** | = VERIFY/5-* + VERIFY/6 |

### undeploy 任务（4 个原子动作）

| 编号 | 动作 | 实测 | 判定 | 说明 |
|---|---|---|---|---|
| U1/1 | host 拆除 | 7s | **必须** | 已接近地板 |
| U2/2 | VM 拆除 | 41s | **必须** | `Remove-Item -Recurse -Force C:\WinVMBridge` 删数万文件 = 物理下限；可优化见 §4-B |
| U3/3 | 隧道处置 | 1s | **必须** | 已最优（`kept by request` 直接跳过） |
| U4/4.2 | 独立复检 | 26s | **必须但重复探测** | 价值=「不信 U2 自报」；但 U2 的 `.ps1` 已输出同域 6 项 POST STATUS。26s 中 ~25s 是 PS 冷启 + 两个 CIM 慢查询 |

### deploy 任务（10 个原子动作）

| 编号 | 动作 | 实测 | 判定 | 说明 |
|---|---|---|---|---|
| P0/0 | preflight 体检 | 63s | **必须但 60% 重复** | VM 内八项（OS/SSHD/BRIDGE/LISTEN/NODE/CLI/NETCAT/FW）与 C3.0 同域；P0 不可替代的价值只有「取包/安装之前判通道可达」 |
| C1/1.5 | 通道保障 | 4s | **必须** | 已最优（在则不建） |
| C2/2 | 取包三件套 | 13s | **必须但与 R1 重复** | 见 §1 编排层 |
| C3/3.0 | ENV_PRECHECK 硬门禁 | 60s | **必须** | 60s 中 `npm ls -g`（20–35s）与判定无关，纯参考值 |
| C3/3.2 | prepare+setup | 429s | **必须（物理）** | 见 §2 拆解，内含 4 处可回收 |
| C3/3.3 | vmcheck 七判据 | 71s | **必须但与 C4.5/C5 重叠** | `health_http` 与 C4.5 的 health 重复；`Get-ScheduledTask` 全枚举是主成本 |
| C4/4.1 | install-host | 5s | **必须** | 已接近地板 |
| C4/4.5 | fresh + health | 4s | **必须** | 已接近地板 |
| C5/5 | 三探针 38 项 | 269s | **必须（功能面唯一证据）** | 见 §3，**不可并行**（ps-bridge 单实例串行） |
| C6/6.1 | skill 交付判据 | 2s | **必须** | 已最优 |

### verify 任务（4 个原子动作）

| 编号 | 动作 | 实测 | 判定 | 说明 |
|---|---|---|---|---|
| VERIFY/5-mcp-probe | 复用 | 2s | **必须（纯开销）** | 复用判定本身 ~2s，可压到 <0.5s |
| VERIFY/5-a2a-probe | 复用 | 2s | 同上 | 同上 |
| VERIFY/5-example-probe | 复用 | 2s | 同上 | 同上 |
| VERIFY/6 | 终态矩阵 | 42s | **必须** | 42s 中 ~30s 是一次 ps-run（PS 冷启 + `Get-ScheduledTask` + `Get-NetTCPConnection`） |

**结论：23 行里 5 行是包装（不占独立时间），16 个原子动作全部是「必须」——没有一个是纯粹多余的。
多余的是「同一件事被做了两遍」：取包 ×2、VM 内探测 ×2（P0/C3.0）、health ×3（vmcheck/C4.5/C5）、
终态探测 ×2（U2/U4）。**

## 2. C3.2 = 429s 的内部（setup.log 自带计时）

| 相位 | 耗时 | 内容 | 可回收 |
|---|---|---|---|
| HOST | 3.7s | 宿主插件安装 | — |
| VM | **160.1s** | `tar -czf winvm-dist.tgz` + `scp` + 远端 `install-vm.mjs` | 打包与传输可压缩 |
| VM-START | **71.3s** | `schtasks /End` → kill → `/Run` → 轮询端口 ≤420s | 轮询间隔偏保守 |
| TUNNEL | **80.9s** | 黑洞嫌疑探测 → `tunnel ensure`（实测仅 **0.7s**） | **~70s 可回收** |
| TEST | 0.9s | 宿主自检 | — |
| QA-PROBE | **24.3s** | scp 2 个小 ps1 + MANIFEST 写**两遍**（日志 58/59 行同文件） | 并入 tar 可为 0 |
| HEALTH | 1.7s | /health | — |
| （prepare-vm） | ~86s | bootstrap prepare-vm --ensure-node | 全 SKIP 时可快 |

**TUNNEL 80.9s 的成因**：`tunnel ensure` 本身 0.7s，其余在「daemon 自报 healthy 但 /health 未通」的判定链上——
`probeTunnelHttp`（curl `--max-time 5`，失败即 5s）× 若干 + `pluginTunnelStatus`（起一个 node 加载整个
plugin bundle，超时窗 20s）+ 20s 退避窗口（10×2s）。**根因是「探测用宽窗 + 探测次数多」，不是隧道慢。**

## 3. C5 = 269s 的构成与「不可并行」的硬原因

| 探针 | 项数 | 实测 | 说明 |
|---|---|---|---|
| mcp-probe | 20 | ~40s | 逐能力串行 HTTP，单项 1–2s |
| a2a-probe | 5 | ~40s | 含 E4 真实 LLM 委派（一轮完整 agent 回合） |
| example-probe | 13 | **~190s** | `storage.cleanup.analyze` 深扫 + `system.eventlog.query` + `gui.screen.capture` |

**为什么不能并行**：VM 侧 `ps-bridge.ps1` 是**单实例串行执行器**（请求进 pending 队列），三个探针并发
只是把请求排到同一条队里，总时长不变，还会让客户端超时窗更容易被撞穿（假 FAIL 风险）。
**并行化在此架构下无收益。**

## 4. 优化清单

### A. 已直接实施（v1.9.1，零真机依赖，自检 16/16 绿）

| # | 改动 | 文件 | 节省 |
|---|---|---|---|
| A1 | wait-channel 轮间隔自适应（ssh2=2s / key=75s，可 `WAIT_GAP` 覆写） | `wait-channel.sh` | R2.5 **85s → ~10s** |
| A2 | P0 链内跳过 VM 内八项（`VMDEPLOY_IN_CHAIN=1`；独立跑/`PREFLIGHT_DEEP=1` 行为不变） | `preflight.sh` + `deploy.sh` | P0 **63s → ~8s** |
| A3 | U4 慢查询替换：`Get-ScheduledTask`→`schtasks /query` 退出码、`Get-NetTCPConnection`→`.NET GetActiveTcpListeners()` | `undeploy.sh` | U4 **26s → ~12s** |
| A4 | VERIFY/6 同上（NetTCP → .NET） | `verify.sh` | VERIFY/6 **42s → ~28s** |
| A5 | 修观测黑洞：verify 复用分支不再用 `< /dev/null` 把 deploy 探针明细覆盖成 0 字节（e2e5 里 `logs/*-probe.log` 全空即此因） | `verify.sh` | —（诊断价值） |

### B. 需决策后实施

| # | 方案 | 节省 | 代价 / 风险 |
|---|---|---|---|
| B1 | **C5 探针分级**：核心 8 项（health/能力数/会话/tools-list/抽样 3 能力/A2A health）+ 深度 30 项按需 | deploy **-230s**，verify 冷跑 **-270s** | 判定口径变更：默认不再覆盖 GUI/存储重能力 |
| B2 | **U2 改名+异步删**：`Rename-Item C:\WinVMBridge → .del-<ts>` 立即返回，后台删 | U2 **41s → ~15s** | 「删除未完成」残留；需 U4 兼容 `.del-*` 判据 |
| B3 | **deploy 30s 口径**：仅「幂等重跑全 SKIP」模式可达 | 冷装 ~600s → 稳态 ~30s | 全 SKIP 等于没验证任何东西，需明确适用场景 |
| B4 | **TUNNEL 探测短路**（母项目 `setup.mjs`）：VM-START 刚确认监听时，跳过「黑洞嫌疑」探测直接 ensure；`pluginTunnelStatus` 失败不重试 | C3.2 **-70s** | 削弱「本地活 ≠ 后端活」的防护，需保留一次 /health 硬判据 |
| B5 | **QA-PROBE 并入 tar**（母项目 `setup.mjs`）：两个 ps1 打进 `winvm-dist.tgz`，省一次 scp + 修 MANIFEST 写两遍 | C3.2 **-24s** | 改动小，但需重打 V1.4.29 验证 |
| B6 | **C3.0 砍 `npm ls -g` / `npm config get prefix`**（母项目探针）：两者只在报告里出现，不参与 BLOCKERS | C3.0 **-25s** | 失去 GLOBAL_PKG 参考值 |
| B7 | **vmcheck 去 health 重复**（母项目探针）：health 交给 C4.5 | C3.3 **-15s** | 判据分布变化，需同步改断言 |

### C. 目标可达性判定（诚实口径）

| 任务 | 目标 | 当前 | A 全实施后 | + B 全实施后 | 判定 |
|---|---|---|---|---|---|
| undeploy | 20s | 75s | 61s | **~20s**（含 B2） | ✅ 需 B2 |
| verify（复用） | 30s | 48s | **34s** | ~20s | ✅ 接近 |
| verify（冷跑） | 30s | 311s | 311s | **~50s**（含 B1） | ⚠ 仅分级后可行 |
| deploy（冷装） | 30s | 920s | 865s | ~600s | ❌ **物理不可行** |
| deploy（幂等全 SKIP） | 30s | — | — | **~30s**（需 B3 短路） | ⚠ 需明确定义 |

**deploy 30s 的物理下限**（不含任何跳步）：
`tar` 打包（delivery+skills+dist，数十 MB）≈ 20–40s + `scp` 局域网传输 ≈ 30–60s + 远端解包/落地 ≈ 30s +
`Remove-Item`（仅卸载时）≈ 30s + 每次 ps-run 的 PS 冷启 ≈ 5s × N。
**从零安装的硬地板约 180–250s；30s 只能来自「什么都不用做」的短路。**

## 5. 一句话结论

23 个动作里没有多余的**动作**，只有多余的**重复探测**与**固定等待**；时间集中在 4 处——
`C3.2 429s`（其中 94s 是探测/冗余可回收）、`C5 269s`（受单实例串行约束，只能分级）、
`P0+C3.0+C3.3 194s`（同域探测做了三遍）、`R2.5 85s`（75s 是 sleep）。

## 6. 落地进度（2026-11-16 用户裁定后）

| 项 | 状态 | 说明 |
|---|---|---|
| A1 wait-channel 轮间隔 | ✅ v1.9.1 | 85s → ~10s |
| A2 P0 链内去重 | ✅ v1.9.1 | 63s → ~8s |
| A3/A4 U4·VERIFY6 原语替换 | ✅ v1.9.1 | 26s→~12s / 42s→~12s（VERIFY6 的 `Get-ScheduledTask` 在 v1.9.2 一并换掉） |
| A5 复用日志不再被清空 | ✅ v1.9.1 | 观测修复 |
| B1 探针分级 | ✅ v1.9.2（用户裁定：砍 25/33/34/35） | 默认 34 项 ~100s；`PROBE_DEEP=1` 全 38 项。SKIP 显式打印并计入 `RESULT: … N SKIP deep` |
| B2 U2 改名+异步删 | ❌ 用户否决 | 保持同步删 41s → undeploy 实际可达 ~61s，**20s 目标不可达** |
| B3 deploy 口径 | ✅ 用户裁定：拆两个指标 | 冷装 ≤250s / 幂等重跑 ≤30s |
| B4 TUNNEL 探测短路 | ✅ V1.4.29（待真机验） | 读 `tunnel.state.json`/`tunnel.pid` 替代 `pluginTunnelStatus`；退避 20s→6.5s；探测 max-time 5→3。80.9s → ~8s |
| B5 QA-PROBE 并入 tar | ⏸ 暂缓 | 24s = 3 次必需往返（mkdir/probes/manifest）；并行与目录创建竞态，改 tar 结构影响 install-vm 解包路径，需真机验后单独做 |
| B6 砍 npm ls -g | ✅ V1.4.29（待真机验） | `VM_ENVCHECK_NPM=1` 可恢复 |
| B7 vmcheck 换原生 | ✅ V1.4.29（待真机验） | 71s → ~45s（含 health body 截断） |

### 优化后预估（未真机复验）

| 任务 | 基线 | 现在 | 目标 | 差距 |
|---|---|---|---|---|
| undeploy | 75s | ~61s | 20s | ❌ 用户否决 U2 异步删，差 41s |
| verify（复用） | 48s | ~20s | 30s | ✅ |
| verify（冷跑） | 311s | ~115s | 30s | ⚠ 差 85s（探针仍留 34 项） |
| deploy（冷装） | 920s | ~740s | 250s | ⚠ 差 490s（C3.2 的 VM 相位 160s + VM-START 71s 未动） |
| deploy（幂等） | — | 未实现 | 30s | 需新增短路模式 |

**下一步的物理大头**：C3.2 内部 `VM 160.1s`（tar 打包 + scp 传输 + 远端 install-vm）与 `VM-START 71.3s`
（schtasks 重启 + 端口轮询）。这两项是「冷装 ≤250s」的唯一拦路石，需单独一轮改造（tar 增量/压缩、
轮询间隔自适应、install-vm 相位并行）。
