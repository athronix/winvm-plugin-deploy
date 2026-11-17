# 分步时序账本（deploy 5 步 / undeploy 3 步）

> 数据来源：**2026-11-17 真机全链实测**（技能 v2.0.2，`~/wbtmp/winvm-deploy-2026{1117-114329,1117-115248}/steps.tsv`）。
> 用时为**单次实测墙钟**，不含宿主机排队；标 🔬 的是真机实测，标 ⏳ 的是仍未覆盖的分支。
> ⚠ 数值随 VM 负载浮动 ±15%，勿当 SLA 引用；判据是"同一环境下优化前后可比"，不是绝对值。

## 结论先行

1. **deploy 全链 296s，其中 `4b`（推包+装 VM 端+起服务）124s 占 42%** —— 唯一接近物理下限的环节，不可再压。
2. **undeploy 全链 202s，其中三段系统性等待 159s 占 79%**：`2c` 停服务卸模块 70s、`3b` SYSTEM 派生回滚 70s、`3d` 等通道消失 19s。等的是 VM 侧系统调度，不是脚本开销。
3. **真正的优化空间在"白等"，且已被削掉约 300s/轮**：3c 假 FAIL 123s、1a 二进制相位挂 15s+ 全步失联、4c 假绿 49s、1c 死路重来。
4. **人工步骤从 1065s 降到 31s**：这次用户一次粘对（命令零双引号 + 单行 + 三源回退），脚本内 9 个阶段 31s 全绿。差异全部来自"命令是否一次就对"。

## 一、deploy = 5 大步 / 16 细步骤

### 第 1 步：建 host↔VM 免密通道（`deploy-1-ssh.sh`）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案（已落地） | 完善效果 |
|---|---|---|---|---|
| 1a 判断通道 | 🔬 **1s**（READY）<br>🔬 **15s**（DOWN） | ① WEDGE 时 sshd 握手挂起，判据像"网络不通"；② 长连健康 ≠ 新建连接可用 | 判据统一为**新建连接实测**（`ssh2-conn.mjs ping`）；后端默认 `auto` | 🔬 READY 1s / DOWN 15s；不再依赖 health 长连口径 |
| 1b 备密钥 | 🔬 0s | 密钥被覆盖后无法回滚；「通道本来活着」的机器从不写基线 | 1a READY 与 1b 两条路**都写** `host-state.json` 基线 | 🔬 `baseline` 恒存在，undeploy 可精确删钥 |
| 1c 打印用户命令 | 🔬 3s（三源探测） | ① 单源 404 → 用户卡死；② 经 Git Bash 粘贴双引号被吞；③ 多行被折叠致语法崩 | **三源回退**（gitee release → GitHub raw@main → GitHub release）+ **全单引号 + 单行 `;`** | 🔬 三源 HEAD 全 200；VM 内 3/3 可达；PS 侧 `PARSE_OK` |
| 1d 用户粘贴 | 🔬 **31s**（脚本内 9 阶段）<br>（前值 1065s） | 人工耗时不可控；粘错一次要回 1b 换钥 | 命令零双引号单行化 + 三源回退消除"下不到" | 🔬 一次粘对，31s 内 `[9/9]` + sshd.exe 就位 |

**1d 阶段分解（本轮实测，11:51:20→11:51:51）**：[1/9] 基线 10s → [2/9] MSI 安装 13s（6.6MB / 下载 2.9s，msiexec 7.1s）→ [3/9] 启动 0s → [4/9] sshd_config 2s → [5/9] 公钥+ACL 0s → [6/9] 网络档 0s → [7/9] 防火墙 2s → [8/9] 自检 0s → [9/9] 重启 3s。

### 第 2 步：取包 + 装 host 端（`deploy-2-host.sh`）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案 | 完善效果 |
|---|---|---|---|---|
| 2a 取包 | 🔬 1s（已缓存） | 首次下载受网络影响；包被篡改/截断 | release 资产 + sha256 + 隔离解压；两仓已转 public | 🔬 缓存命中 1s |
| 2b MANIFEST 对账 | 🔬 0s | 文件缺失/多出被静默放过 | 逐文件比对 + `RESULT: PASS/FAIL` | 🔬 11 项对账 0s |
| 2c 两端结构检查 | 🔬 0s | 少件到第 4 步才炸 | host 4 件齐 + `.env` 就位前置检查 | 🔬 0s 前置拦截 |
| 2d install-host | 🔬 1s（幂等） | 重复安装污染、disabledTools 漂移 | `--yes --no-tunnel` 幂等 + 缓存逐文件 SHA256 | 🔬 rc=0 1s |
| 2e 交付判据 | 🔬 0s | "装完不知道装没装" | connector skills ≥8 硬断言 | 🔬 `skills=8`（**本轮它救了一次**：宿主重启擦空了 `connectors/skills/`，2e 判 0 后重跑本步恢复 8） |

### 第 3 步：起隧道并验证（`deploy-3-tunnel.sh`）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案（已落地） | 完善效果 |
|---|---|---|---|---|
| 3a 对齐 identityFile | 🔬 0s | `vm-conn.json` 指向未授权钥 → 连续 `All configured authentication methods failed` | 按 `WINVM_VM_KEY` 自动对齐（仅当目标钥存在） | 🔬 0s |
| 3b 起隧道 | 🔬 1s（幂等短路） | **restart 会与并行第 4 步抢 sshd 握手槽**，实测把 4 步打成 `Connection lost before handshake` | 本地端口已监听 + daemon 存活 → **跳过 restart** | 🔬 从零/增量都不再抢槽 |
| 3c 验证隧道 | 🔬 **0s**（旧版 **123s FAIL**） | 旧判据要 `/health=200`，但服务由**并行第 4 步**装 ⇒ 从零必 000，空等 30 轮假 FAIL | 判据改 `port_listening` + `tunnel_pid/tunnel_alive`；health 降为信息位 | 🔬 `listen=yes daemon=yes health=200`，**123s→0s** |

### 第 4 步：装 VM 端 + 起服务（`deploy-4-vm.sh`）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案 | 完善效果 |
|---|---|---|---|---|
| 4.0 通道门禁 | 🔬 1s | 前面步骤把 sshd 打挂后，本步会连吃 3 次超时 | 60s 健康窗 + 有界重试，只跑最短链 | 🔬 1s `channel=READY` |
| 4a prepare-vm | 🔬 **45s** | node 缺失、防火墙未建、登录态（DB-4 需 VM 内交互一次） | `--ensure-node` 分项打 `[SKIP]` | 🔬 45s（全 `[SKIP]` 时 42s） |
| **4b setup（推包+装+起服务）** | 🔬 **124s** | 全链最大项；服务装完后 socket 可能假死（网络抖动/挂起），表现为宿主 `curl 52` | `--only-vm --skip-build`；假死时重跑本步即修 | 🔬 124s；**物理下限**（首跑曾 168s） |
| 4c vmcheck 七判据 | 🔬 **54s**（旧版 69s 且假绿） | `vmcheck.ps1` 是纯报告器（无退出码）⇒ 只看 rc 等于"跑完就算过" | 自解析 JSON 逐项断言 + health 双口径 | 🔬 54s 真断言（**比旧版快 15s 且不再是假绿**） |

### 第 5 步：verify（`deploy-5-verify.sh`）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案 | 完善效果 |
|---|---|---|---|---|
| 5 三探针 | 🔬 **38s**（冷跑 34 项）<br>1s（stamp 复用） | 项数漂移（38↔34）让汇总判据失去意义；静默少测=最危险假绿 | 探针分级：默认 34（`PROBE_DEEP=1` 跑 38）；SKIP 必须打印并计入；取不到真实计数即 FAIL | 🔬 `34/34 SKIP=4`，38s |
| 5d 终态矩阵 | 🔬 **26s** | 缓存与仓库构建物漂移会让人误以为"装的是新代码" | 逐文件 SHA256 `fresh` 对账 + disabledTools + connector skills + VM 三态 | 🔬 26s 一次给齐五维 |

**deploy 总账**：全链 🔬 **296s** = 1a 1 + 2 步 3 + 3 步 2 + 4 步 225 + 5 步 65。

## 二、undeploy = 3 大步 / 11 细步骤

### 第 1 步：停隧道 + 卸 host（`undeploy-1-host.sh`，‖ 第 2 步）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案（已落地） | 完善效果 |
|---|---|---|---|---|
| 1a 停隧道 | 🔬 2s | `curl` 连不上时自己吐 `000`，再 `|| echo 000` ⇒ `000000`，判据恒假 | `health_code` 捕获后 case 归一（恒 3 字符） | 🔬 旧版假 FAIL → 2s PASS |
| 1b 卸 host 插件 | 🔬 2s | host-only 卸载若漏屏蔽 VM 目标，会连 VM 一起卸 | 三处 VM 目标来源全部屏蔽 + `VM_PHASE=0` 断言 | 🔬 host 端清空 |
| 1c 清空复核 | 🔬 0s | 残留 mcp 条目/隧道进程会导致下次部署双开 | 复核 health=000 + `mcp_left=none` | 🔬 0s |

### 第 2 步：停 VM 服务 + 卸模块（`undeploy-2-vm.sh`）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案 | 完善效果 |
|---|---|---|---|---|
| 2a 通道状态 | 🔬 1s | 通道不在是**正常输入**，不是故障 | 只判不建（红线：卸载绝不重建通道） | 🔬 1s |
| 2b 推卸载脚本 | 🔬 3s | 远端脚本缺失只能干等 | scp `vm-remove-local.ps1` 后就地执行 | 🔬 3s |
| 2c 停服务 + 卸模块 | 🔬 **70s** | 僵尸 node 进程（不绑端口、taskkill 免疫） | 服务停止 + 端口复查 + 目录清理三段断言 | 🔬 70s `VM_CLEANUP_DONE` |
| 2d VM 终态五点 | 🔬 **35s** | "删了但没删干净" | 任务/端口/进程/目录/服务五点复核 | 🔬 35s |

### 第 3 步：拆 ssh 通道（`undeploy-3-ssh.sh`）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案（已落地） | 完善效果 |
|---|---|---|---|---|
| 3a 通道状态 | 🔬 1s | 在/不在走两条完全不同的路 | 在 → SYSTEM 任务；不在 → 打印用户命令 | 🔬 1s |
| 3b SYSTEM post 动作 | 🔬 **70s** | ① 拆 sshd 会**自断正在执行的会话**（必须派生 SYSTEM 任务）；② VM 上没存 oneclick 时旧版打印**指向不存在文件**的命令 | 派生 SYSTEM 计划任务执行 `-Rollback`；缺脚本时**先多源下载再执行** | 🔬 70s `POST_ROLLBACK_SCHEDULED`；**兜底下载实测生效**（首选 gitee release） |
| 3c 宿主侧回滚 | 🔬 1s | 无基线时盲删用户私钥 | 只删本技能创建的钥；`unknown` 保守保留并显式告知 | 🔬 1s「私钥非本技能创建，保留」 |
| 3d 等通道消失 | 🔬 **19s** | 要等 VM 侧 sshd 真正停掉，等的是系统调度 | 每 5s 用**新建连接**实测，最长 120s | 🔬 19s（前值 53s，随 VM 负载浮动） |

**undeploy 总账**：全链 🔬 **202s**（第 1‖2 步 113s，拆通道 91s）。

## 三、优化项与效果汇总（v2.0.1 + v2.0.2）

| # | 问题（真机症状） | 处置 | 效果 |
|---|---|---|---|
| 1 | 3c 空等 123s 后假 FAIL（health 是从零中间态） | 判据改端口监听 + daemon 存活 | 🔬 省 **123s**/轮，假 FAIL 归零 |
| 2 | `health=000000` 导致卸载 1a/1c 假红 | `health_code` 归一为 3 字符 | 🔬 假红归零 |
| 3 | `tunnel.pid` 是 JSON，`tr -dc 0-9` 拼出 20 位数字 | `tunnel_pid/tunnel_alive` | 🔬 3c 不再误报 `daemon=0` |
| 4 | 拆通道时 VM 无脚本 → 打印死命令 | 就地多源下载后再 `-Rollback` | 🔬 拆通道 202s 全绿 |
| 5 | 僵尸服务壳致重建必挂 | oneclick 判据加 `sshd.exe` 在位 | 🔬 从零重建一次成功 |
| 6 | 单源下载 + 源仓 private | 仓转 public + 三源回退 | 🔬 宿主 3/3、**VM 内 3/3** 可达 |
| 7 | 门禁自伤：升版后 M6 变异必 MISS | 版本号现读注入 | 🔬 `ALL_CAUGHT 15/15` |
| **8** | **`VM_SSH_BACKEND` 默认值在 v2.0.0 重构时从 `ssh2` 退化成 `key`**（legacy 层三个脚本都是 `:-ssh2`） | 默认改回 **`auto`**（ssh2 优先、无 node 自动降级二进制） | 🔬 修复前每步误报 `NO_CHANNEL`（`rc=124`）；修复后 1a 2s、全链无一次通道假红 |
| **9** | `vmcheck`/探针首调撞 VM 冷启（WMI/注册表冷启 > 服务端 30s 预算） | 判定为非确定性缺陷，记录处置；**不改判据** | 🔬 冷跑复验 20/20；详见 §五 |

## 四、本轮补测结果（原"待实测"清单，已全部闭环）

| # | 待测项 | 结果 |
|---|---|---|
| 1 | `selfcheck.sh` 门禁 | ✅ `SELFCHECK=ALL_GREEN checks=19 fails=0` |
| 2 | 1c 命令 PS 侧只解析不执行 | ✅ `PARSE_OK`、`AST_COMMANDS=8`（Join-Path/New-Item/Invoke-WebRequest/Unblock-File/powershell）、`DOWNLOAD_ALL_FAILED` 守卫在、3 源齐、零双引号 |
| 3 | VM 内三源下载 | ✅ **3/3**：gitee release 148036B/7.9s、raw@main 148753B/2.4s、gh release 148036B/3.1s |
| 4 | 定点复跑 1 / 3 / 5 | ✅ 1 步 2s（READY 短路）、3 步 7s（3c 零等待）、5 步 66s（34/34） |
| 5 | 全链 deploy + `undeploy --remove-ssh-tunnel yes` | ✅ deploy 296s `DEPLOY=PASS`；undeploy 202s `host=clean vm=clean tunnel=yes` |

## 五、仍未覆盖 / 已知风险

1. **⏳ 1b~1d「从零通道」分支的失败路径**：本轮成功路径已实测（31s），但「VM 上通道完全建不起来」的分支（无管理员权限 / 无外网 / MSI 被拦）仍未真机演练。
2. **⚠ 探针首调撞 VM 冷启**：VM 刚开机时 `storage.disk.list` / `app.inventory.list` 可能吃满服务端 30s 预算（实测 30203ms / 30031ms FAIL，热态仅 2.7s / 3.3s）。判定为冷启现象（强制冷跑复验 20/20 全过），**不改判据以免掩盖真慢**；处置=等 2~3 分钟重跑 `--only 5`。
3. **⚠ gitee release 第 5 资产版本滞后**：`V1.4.30` 的 `winvm-sshd-oneclick.ps1` 是 148036B（不含僵尸壳修复），而 raw@main 是 148753B（含）。候选链首选 gitee release ⇒ 会下到旧脚本。**必须发 V1.4.31 刷新第 5 资产**才能消除。
4. **⚠ `-AllowFrom` 默认不传的副作用**：防火墙规则对任意来源放行（仍受 `ListenAddress` 收窄）。oneclick 会打印"建议配 -AllowFrom <宿主机IP>"，但没告诉用户去哪找宿主 IP —— 文案待改进。
