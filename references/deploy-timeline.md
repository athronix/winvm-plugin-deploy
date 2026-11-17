# 分步时序账本（deploy 5 步 / undeploy 3 步）

> 数据来源：2026-11-16 真机 E2E 各轮 `~/wbtmp/winvm-deploy-<ts>/steps.tsv`（技能 v2.0.0→v2.0.1 期间）。
> 用时为**单次实测**，不含宿主机排队与用户离开的时间；"完善效果"列标 🔬 的是本轮已实测，
> 标 ⏳ 的是待 VM 恢复后补测（见 §四）。

## 结论先行

1. **deploy 全链 ≈ 289s，其中 `4b` 占 168s（58%）** —— 这是唯一接近物理下限的环节（推包 + VM 端装 + 起服务）。
2. **undeploy 全链 ≈ 60~82s，其中拆通道 `3d` 等消失 53s 占主导** —— 等的是 VM 侧 SYSTEM 任务执行 sshd 移除，不可压缩。
3. **可优化的从来不是"跑多久"，而是"白等多久"**：本轮修掉的三处假红/空等合计白白浪费 **≈ 190s**（3c 123s + 1c 双值 0s 但导致重跑 + 4c 69s 恢复轮）。
4. 人工步骤（1d 粘贴）实测 **1065s** 才 READY —— 这一段只能靠"命令一次就对"来压缩，不能靠脚本。

## 一、deploy = 5 大步 / 16 细步骤

### 第 1 步：建 host↔VM 免密通道（`deploy-1-ssh.sh`）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案（本轮已落地） | 完善效果 |
|---|---|---|---|---|
| 1a 判断通道 | 1s（READY）<br>15s（DOWN） | ① WEDGE 时 sshd 握手挂起，判据像"网络不通"；② 只判长连会把"已建长连健康"误当通道可用 | 判据统一为 **新建连接实测**（`ssh2-conn.mjs ping`，2s 内出结论） | 🔬 READY 1s / DOWN 15s，不再依赖 health 长连口径 |
| 1b 备密钥 | 1s | 密钥被覆盖后无法回滚；「通道本来活着」的机器从不写基线 | 1a READY 与 1b 两条路**都写** `host-state.json` 基线 | 🔬 `baseline` 恒存在，undeploy 可精确删钥 |
| 1c 打印用户命令 | 1s（含 URL 探测） | ① 单源 404 → 用户卡死；② 经 Git Bash 粘贴双引号被吞；③ 多行被折叠成一行导致语法崩 | **三源回退**（gitee release → GitHub raw@main → GitHub release）+ 命令**全单引号 + 单行 `;` 串联**；宿主侧逐源打印 `[200]/[---]` | 🔬 三源 HEAD 全 200；命令零双引号（PS 侧待 ⏳ 解析验证） |
| 1d 等用户粘贴并验证 | 1065s（超时 2226s） | 人工耗时不可控；粘贴错一次就要回 1b 换钥重来（3 轮上限） | `CHANNEL_WAIT_S` 原地等（默认 0=不阻塞）；失败自动回 1b 换钥 | 🔬 2226s 内 1065s 转 READY；无人工介入的部分为 0 成本 |

### 第 2 步：取包 + 装 host 端（`deploy-2-host.sh`）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案 | 完善效果 |
|---|---|---|---|---|
| 2a 取包 | 0~1s（已缓存） | 首次下载受网络影响；包被篡改/截断 | release 资产 + sha256 + **隔离解压**；母项目仓已转 public，匿名可下 | 🔬 缓存命中 0s；匿名下载 200 |
| 2b MANIFEST 对账 | 1s | 文件缺失/多出被静默放过 | 逐文件比对 + `RESULT: PASS/FAIL` | 🔬 11 项对账 1s |
| 2c 两端结构检查 | 0s | 少件到第 4 步才炸 | host 4 件齐 + `.env` 就位前置检查 | 🔬 0s 前置拦截 |
| 2d install-host | 1s（幂等） | 重复安装污染、disabledTools 漂移 | `--yes --no-tunnel` 幂等；插件缓存逐文件 SHA256 校验 | 🔬 rc=0 1s |
| 2e 交付判据 | 0s | "装完不知道装没装" | connector skills ≥8 硬断言 | 🔬 `skills=8` |

### 第 3 步：起隧道并验证（`deploy-3-tunnel.sh`）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案（本轮已落地） | 完善效果 |
|---|---|---|---|---|
| 3a 对齐 identityFile | 0s | `vm-conn.json` 单值指向未授权钥 → 连续 `All configured authentication methods failed` | 按 `WINVM_VM_KEY` 自动对齐（仅当目标钥存在） | 🔬 0s，鉴权失败类故障消失 |
| 3b 起隧道 | 1~2s | **restart 会与并行第 4 步抢 VM sshd 握手槽**，实测把 4 步打成 `Connection lost before handshake` | 幂等短路：本地端口已监听 + daemon 存活 → **跳过 restart** | 🔬 从零/增量都不再触发抢槽 |
| 3c 验证隧道 | 1~2s（旧版 **123s FAIL**） | 旧判据要求 `/health=200`，但该服务由**并行的第 4 步**安装 ⇒ 从零部署必然 000，空等 30 轮后假 FAIL | 判据换成 `port_listening`（bash `/dev/tcp`）+ `tunnel_pid/tunnel_alive`（daemon 存活）；health 降为信息位 | 🔬 **123s 假 FAIL → 2s PASS**，单轮省 121s |

### 第 4 步：装 VM 端 + 起服务（`deploy-4-vm.sh`）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案 | 完善效果 |
|---|---|---|---|---|
| 4.0 通道门禁 | 1~2s | 前面步骤把 sshd 打挂后，本步会连吃 3 次超时 | 60s 健康窗 + 一次有界重试，只跑最短链 | 🔬 2s `channel=READY` |
| 4a prepare-vm | 28~101s（幂等 28~42s） | node 缺失、防火墙规则未建、登录态（DB-4 需 VM 内交互一次） | `--ensure-node` 分项打 `[SKIP]`，已就绪不重做 | 🔬 二次跑 42s 全 `[SKIP]`，省 ≈ 60s |
| **4b setup（推包+装+起服务）** | **89~178s** | 全链最大耗时；VM 端服务装完后 socket 可能假死（网络抖动/挂起），表现为宿主 `curl 52` | `--only-vm --skip-build`（不重建 host 产物）；服务假死时重跑本步即修（`schtasks /End`→`/Run`） | 🔬 二次跑 101s（较首跑 168s 降 40%）；**物理下限，不可再压** |
| 4c vmcheck 七判据 | 20~40s（旧版 69s 且假绿） | `vmcheck.ps1` 是**纯报告器**（无退出码）⇒ 只看 rc 等于"跑完就算过" | 自解析 JSON，逐项断言 `task_state/listen_count/side_json/bridge_dir` + health 双口径（VM 本地 / 宿主隧道） | 🔬 69s 假绿 → 20~40s 真断言 |

### 第 5 步：verify（`deploy-5-verify.sh`）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案 | 完善效果 |
|---|---|---|---|---|
| 5 三探针 | 19~40s（冷）<br>1s（复用） | 项数漂移（38↔34）会让汇总判据失去意义；静默少测=最危险假绿 | 探针分级：默认 34 项（`PROBE_DEEP=1` 跑 38）；SKIP 必须打印并计入 `N SKIP deep`；取不到真实计数即 FAIL | 🔬 冷 19~21s / 复用 1s；`34/34 SKIP=4` |
| 5d 终态矩阵 | 12~17s | 缓存与仓库构建物漂移会让人误以为"装的是新代码" | 逐文件 SHA256 `fresh` 对账 + disabledTools + connector skills + VM 三态 | 🔬 12~17s，一次给齐五个维度 |

**deploy 总账**：全链 **289s**（1a 1 + 2 步 2 + 3 步 2 + 4 步 266 + 5 步 18），重跑型（4+5）**198s**。

## 二、undeploy = 3 大步 / 11 细步骤

### 第 1 步：停隧道 + 卸 host（`undeploy-1-host.sh`，‖ 第 2 步）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案（本轮已落地） | 完善效果 |
|---|---|---|---|---|
| 1a 停隧道 | 1~3s | `curl` 连不上时自己吐 `000`，再 `|| echo 000` ⇒ `000000`，判据恒假 | `health_code` 捕获后 case 归一（恒 3 字符） | 🔬 旧版假 FAIL → 1s PASS |
| 1b 卸 host 插件 | 1~2s | host-only 卸载若漏屏蔽 VM 目标，会连 VM 一起卸 | 三处 VM 目标来源全部屏蔽 + `VM_PHASE=0` 断言 | 🔬 `HOST_PASS=11 HOST_FAIL=0` |
| 1c 清空复核 | 0~1s | 残留 mcp 条目/隧道进程会导致下次部署双开 | 复核 health=000 + `mcp_left=none` | 🔬 0s |

### 第 2 步：停 VM 服务 + 卸模块（`undeploy-2-vm.sh`）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案 | 完善效果 |
|---|---|---|---|---|
| 2a 通道状态 | 1s | 通道不在是**正常输入**，不是故障 | 只判不建（红线：卸载绝不重建通道） | 🔬 1s |
| 2b 推卸载脚本 | 2s | 远端脚本缺失只能干等 | scp `vm-remove-local.ps1` 后就地执行 | 🔬 2s |
| 2c 停服务 + 卸模块 | 13~16s | 僵尸 node 进程（不绑端口、taskkill 免疫） | 服务停止 + 端口复查 + 目录清理三段断言 | 🔬 13~16s `VM_CLEANUP_DONE` |
| 2d VM 终态五点 | 5~6s | "删了但没删干净" | 任务/端口/进程/目录/服务五点复核 | 🔬 5~6s |

### 第 3 步：拆 ssh 通道（`undeploy-3-ssh.sh`）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案（本轮已落地） | 完善效果 |
|---|---|---|---|---|
| 3a 通道状态 | 1~2s | 通道在/不在走两条完全不同的路 | 在 → SYSTEM 任务；不在 → 打印用户命令 | 🔬 2s |
| 3b SYSTEM post 动作 | 13~27s | ① 拆 sshd 会**自断正在执行的会话**（必须派生 SYSTEM 任务）；② VM 上没存 oneclick 时旧版打印一条**指向不存在文件**的命令 | 派生 SYSTEM 计划任务执行 `-Rollback`；缺脚本时**先多源下载再执行** | 🔬 27s `POST_ROLLBACK_SCHEDULED`；旧版 rc=3 死路消失 |
| 3c 宿主侧回滚 | 0s | 无基线时盲删用户私钥 | 只删本技能创建的钥；`unknown` 保守保留并显式告知 | 🔬 0s |
| 3d 等通道消失 | 53s | 判定"消失"要等 VM 侧 sshd 真正停掉，等的是系统调度 | 每 5s 用**新建连接**实测，最长 120s | 🔬 53s（物理等待，不可压） |

**undeploy 总账**：全链 **60~82s**（第 1‖2 步 ≈ 21s，拆通道 ≈ 82s）。

## 三、本轮优化项与效果汇总（v2.0.1）

| # | 问题（真机症状） | 处置 | 效果 |
|---|---|---|---|
| 1 | 3c 空等 123s 后假 FAIL（health 是从零中间态） | 判据改端口监听 + daemon 存活 | 省 **121s**/轮，假 FAIL 归零 |
| 2 | `health=000000` 导致卸载 1a/1c 假红 | `health_code` 归一为 3 字符 | 假红归零 |
| 3 | `tunnel.pid` 是 JSON，`tr -dc 0-9` 拼出 20 位数字 | `tunnel_pid/tunnel_alive` | 3c 不再误报 `daemon=0` |
| 4 | 拆通道时 VM 无脚本 → 打印死命令 | 就地多源下载后再 `-Rollback` | 拆通道从"必失败"到 82s 完成 |
| 5 | 僵尸服务壳致重建必挂 | oneclick 判据加 `sshd.exe` 在位 | 从零重建 23/23 成功 |
| 6 | 单源下载 + 源仓 private | 仓转 public + 三源回退（宿主探测/VM 循环） | 三源 HEAD 全 200；VM 侧待 ⏳ |
| 7 | 门禁自伤：升版后 M6 变异必 MISS | 版本号现读注入 | `MUTATION_RESULT=ALL_CAUGHT 15/15` |

## 四、待实测（VM 恢复后按序补）

1. `bash scripts/selfcheck.sh --mutate` → 期望 `checks=19 fails=0` + `ALL_CAUGHT 15/15`（本轮已离线通过 ✅）
2. **PowerShell 命令语法**：把 1c 打印的那一行在 VM 上只解析不执行（`[scriptblock]::Create`），确认 `PARSE_OK`
3. **VM 侧多源下载**：在同一会话内把三个 URL 各拉一次，确认至少 2 个在 VM 内可达
4. `deploy.sh --only 1`（通道已 READY 时应 1a 短路）→ `--only 3` → `--only 5`
5. 全链 `deploy.sh`（并行）与 `undeploy.sh --remove-ssh-tunnel yes` 各一轮，把本文件"实测"列刷新为 v2.0.1 数字
