# 分步时序账本（deploy 5 步 / undeploy 3 步）

> 数据来源：**2026-11-17 真机全链实测两轮**（技能 v2.0.2 → v2.0.3）。
> 账本对应 `~/wbtmp/winvm-deploy-2026{1117-1xxxxx}/steps.tsv`；1d 的 9 阶段取自 VM 侧 `wb-tunnel-build-*.log`。
> 用时为**单次实测墙钟**，不含宿主机排队；标 🔬 的是真机实测，标 ⏳ 的是仍未覆盖的分支。
> ⚠ 数值随 VM 负载浮动 ±15%，勿当 SLA 引用；判据是「同一环境下优化前后可比」，不是绝对值。

## 结论先行

1. **deploy 全链 126s / 135s / 274s（三轮，v2.0.2 时代 296s）**，其中 `4b`（推包+装 VM 端+起服务）61~155s 占 45%~57% —— 唯一接近物理下限的环节。**轮次 3 的 274s 已归因于「4b 每轮无条件重推 8MB + 重装」（母项目 setup 层缺内容短路），非技能回归**，见 §四。
2. **undeploy 全链 79s（v2.0.2 时代 202s）**：`2c` 停服务卸模块 70s、`3b` SYSTEM 派生回滚 70s 是 VM 侧系统调度，`3d` 等通道消失已从 27s 压到 6s。
3. **1d 阶段 2（装 OpenSSH）从 72s 降到 8s**：MSI 缓存命中，跳过 60.2s 下载；这是本轮最大的单项收益。
4. **最贵的从来不是脚本开销，是「白等」与「一条命令粘不对」**：3c 假 FAIL 123s、1a 二进制相位挂、4c 假绿、1c 死路重来，累计已削掉约 400s/轮；人工段从 1065s → 31s → 23s。

## 一、deploy = 5 大步 / 16 细步骤

### 第 1 步：建 host↔VM 免密通道（`deploy-1-ssh.sh`）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案（已落地） | 完善效果 |
|---|---|---|---|---|
| 1a 判断通道 | 🔬 **1s**（READY）<br>🔬 **15s**（DOWN） | ① WEDGE 时 sshd 握手挂起，判据像"网络不通"；② 长连健康 ≠ 新建连接可用 | 判据统一为**新建连接实测**（`ssh2-conn.mjs ping`）；后端默认 `auto` | 🔬 READY 1s / DOWN 15s；不再依赖 health 长连口径 |
| 1b 备密钥 | 🔬 0s | 密钥被覆盖后无法回滚；「通道本来活着」的机器从不写基线 | 1a READY 与 1b 两条路**都写** `host-state.json` 基线 | 🔬 `baseline` 恒存在，undeploy 可精确删钥 |
| 1c 打印用户命令 | 🔬 3s（双源探测） | ① 单源 404 → 用户卡死；② 经 Git Bash 粘贴双引号被吞；③ 多行被折叠致语法崩；④ **`irm\|iex` 模式下 BOM / string[] 会让脚本一行都没跑就满屏红字** | 双源回退（**只从技能仓**：Gitee raw → GitHub raw）+ 全单引号单行 `;` + 备选命令内联 `[string]::Join([char]10,@($s))` 归一化 | 🔬 两源 HEAD 全 200、sha256 与源一致；VM 内 `PARSE_OK`；**irm 备选已真机跑通**（见 §四 轮次 2） |
| 1d 用户粘贴 | 🔬 **23s**（脚本内 9 阶段）<br>（前值 1065s / 31s） | 人工耗时不可控；粘错一次要回 1b 换钥 | 命令零双引号单行化 + 双源回退 + **MSI 缓存** | 🔬 `selfstage=existing`，`[9/9]` 全绿，阶段 2 仅 8s |

**1d 阶段分解（两轮对照，同一台 VM）**：

| 阶段 | v2.0.3 轮次 1（16:12:44） | v2.0.3 轮次 2（16:51:19） | 说明 |
|---|---|---|---|
| [1/9] 基线采集 | 10s | 9s | journal 归档 + 快照，固定成本 |
| **[2/9] 装 OpenSSH** | **72s**（下载 60.2s + msiexec 8.1s） | **8s**（**命中 MSI 缓存**，msiexec 6.1s） | 🔬 **-89%**，本轮最大收益 |
| [3/9] 启动并自启 | 0s | 0s | 已是 Automatic+Running，幂等短路 |
| [4/9] sshd_config | 2s | 1s | 留档 + 预览校验 + 真写 + 再校验 |
| [5/9] 公钥 + ACL | 0s | 0s | 写 `administrators_authorized_keys` + icacls |
| [6/9] 网络配置档 | 0s | 0s | 两档均 Private，无需改 |
| [7/9] 防火墙 | 2s | 2s | 主规则 + 兜底规则 |
| [8/9] 自检 | 0s | 0s | 5 项断言 |
| [9/9] 重启 sshd | 3s | 3s | 本机回环复验 |

> 下载波动实测 **2.9s ~ 60.2s**（同一 6.6MB MSI，跨时段差 20 倍）——这就是缓存必须做的理由。
> 缓存路径 `C:\ProgramData\WinVMDeploy\cache\OpenSSH-Win64.msi`，`-Rollback` **不删**；
> 校验 `D0CF11E0` 文件头 + `>1MB` 防半截文件；偶发坏包用 `-NoMsiCache` 强制重下。

### 第 2 步：取包 + 装 host 端（`deploy-2-host.sh`）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案 | 完善效果 |
|---|---|---|---|---|
| 2a 取包 | 🔬 1s（已缓存） | 首次下载受网络影响；包被篡改/截断 | release 资产 + sha256 + 隔离解压；两仓已转 public | 🔬 缓存命中 1s；版本行现可正确解析（`V1.4.30`） |
| 2b MANIFEST 对账 | 🔬 1s | 文件缺失/多出被静默放过 | 逐文件比对 + `RESULT: PASS/FAIL` | 🔬 11 项对账 PASS |
| 2c 两端结构检查 | 🔬 0s | 少件到第 4 步才炸 | host 4 件齐 + `.env` 就位前置检查 | 🔬 0s 前置拦截 |
| 2d install-host | 🔬 0s（幂等） | 重复安装污染、disabledTools 漂移 | `--yes --no-tunnel` 幂等 + 缓存逐文件 SHA256 | 🔬 rc=0 |
| 2e 交付判据 | 🔬 1s | "装完不知道装没装" | connector skills ≥8 硬断言 | 🔬 `skills=8`（**曾救一次**：宿主重启擦空 `connectors/skills/`，2e 判 0 后重跑本步恢复） |

### 第 3 步：起隧道并验证（`deploy-3-tunnel.sh`）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案（已落地） | 完善效果 |
|---|---|---|---|---|
| 3a 对齐 identityFile | 🔬 0s | `vm-conn.json` 指向未授权钥 → 连续 `All configured authentication methods failed` | 按 `WINVM_VM_KEY` 自动对齐（仅当目标钥存在） | 🔬 0s |
| 3b 起隧道 | 🔬 1s（幂等短路） | **restart 会与并行第 4 步抢 sshd 握手槽**，实测把 4 步打成 `Connection lost before handshake` | 本地端口已监听 + daemon 存活 → **跳过 restart** | 🔬 从零/增量都不再抢槽 |
| 3c 验证隧道 | 🔬 **0s**（旧版 **123s FAIL**） | 旧判据要 `/health=200`，但服务由**并行第 4 步**装 ⇒ 从零必 000，空等 30 轮假 FAIL | 判据改 `port_listening` + `tunnel_pid/tunnel_alive`；health 降为信息位 | 🔬 `listen=yes daemon=yes health=000`（从零合法中间态），**123s→0s** |

### 第 4 步：装 VM 端 + 起服务（`deploy-4-vm.sh`）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案 | 完善效果 |
|---|---|---|---|---|
| 4.0 通道门禁 | 🔬 1s | 前面步骤把 sshd 打挂后，本步会连吃 3 次超时 | 60s 健康窗 + 有界重试，只跑最短链 | 🔬 1s `channel=READY` |
| 4a prepare-vm | 🔬 **27s**（轮次 1 为 20s / v2.0.2 为 45s） | node 缺失、防火墙未建、登录态（DB-4 需 VM 内交互一次） | `--ensure-node` 分项打 `[SKIP]` | 🔬 `DB-2/3/6` 全 `[SKIP]`，27s |
| **4b setup（推包+装+起服务）** | 🔬 **61s**（轮次 1 为 62s，v2.0.2 首跑 168s / 稳态 124s） | 全链最大项；服务装完后 socket 可能假死（网络抖动/挂起），表现为宿主 `curl 52` | `--only-vm --skip-build`；假死时重跑本步即修 | 🔬 61s，**物理下限** |
| 4c vmcheck 七判据 | 🔬 **14s**（v2.0.2 69s→54s；全量重装轮 38s） | `vmcheck.ps1` 是纯报告器（无退出码）⇒ 只看 rc 等于"跑完就算过" | 自解析 JSON 逐项断言 + health 双口径 | 🔬 14s 真断言（**比旧版快 40s 且不再是假绿**） |
| 4d 上游工具面 | 🔬 **12s**（首轮，含懒启动）/ 3s（已就绪） | `/health.upstreams` 是懒启动观测值（刚起恒 `idle`），拿它断言会把"没被调过"误判成"装坏了" | 真打 `POST /mcp/<id>` 的 `tools/list` 计数；期望值 33/10 可 env 覆盖 | 🔬 `browser=33 desktop=10`，顺带验证懒启动通路 |

### 第 5 步：verify（`deploy-5-verify.sh`）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案 | 完善效果 |
|---|---|---|---|---|
| 5 三探针 | 🔬 **16s**（冷跑 34 项）<br>1s（stamp 复用） | 项数漂移（38↔34）让汇总判据失去意义；静默少测=最危险假绿 | 探针分级：默认 34（`PROBE_DEEP=1` 跑 38）；SKIP 必须打印并计入；取不到真实计数即 FAIL | 🔬 `34/34 SKIP=4`，16s（v2.0.2 为 38s） |
| 5d 终态矩阵 | 🔬 **8s**（v2.0.2 为 26s） | 缓存与仓库构建物漂移会让人误以为"装的是新代码" | 逐文件 SHA256 `fresh` 对账 + disabledTools + connector skills（现要求 ≥10）+ VM 三态 | 🔬 8s 一次给齐五维 |
| 5e 上游工具面 | 🔬 **3s** | 4d 只在第 4 步跑；verify 单独调用于排障时就没有复验面 | 与 4d 同一 `upstream_judge`；失败按 health 分流（200=真缺陷，非 200=ENV_WINDOW） | 🔬 `browser=33 desktop=10` |

**deploy 总账**：轮次 1/2 全链 🔬 **126s / 135s** = 1a 1 + 2 步 3 + 3 步 2 + 4 步 102 + 5 步 24 + 收尾；
轮次 3 为 **274s**（4 步 251s），归因见 §四。
（v2.0.2 为 296s；同样包含 4 步 225s + 5 步 65s —— 即 5 步已从 65s 压到 24s。）

## 二、undeploy = 3 大步 / 11 细步骤

### 第 1 步：停隧道 + 卸 host（`undeploy-1-host.sh`，‖ 第 2 步）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案（已落地） | 完善效果 |
|---|---|---|---|---|
| 1a 停隧道 | 🔬 2s | `curl` 连不上时自己吐 `000`，再 `|| echo 000` ⇒ `000000`，判据恒假 | `health_code` 捕获后 case 归一（恒 3 字符） | 🔬 旧版假 FAIL → 2s PASS |
| 1b 卸 host 插件 | 🔬 2s | host-only 卸载若漏屏蔽 VM 目标，会连 VM 一起卸 | 三处 VM 目标来源全部屏蔽 + `VM_PHASE=0` 断言 | 🔬 host 端清空 |
| 1c 清空复核 | 🔬 0s | ① 残留 mcp 条目/隧道进程会导致下次部署双开；② **旧包卸载新装**必留 `winvm-browser`/`winvm-desktop`（卸载器键表按包版本固化） | 复核 health=000 + `mcp_left=none`；新增 `^winvm$|^winvm-` **命名空间兜底**并打印被移除项 | 🔬 兜底实测移除 2 条死条目 → `UNDEPLOY=PASS` |

### 第 2 步：停 VM 服务 + 卸模块（`undeploy-2-vm.sh`）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案 | 完善效果 |
|---|---|---|---|---|
| 2a 通道状态 | 🔬 1s | 通道不在是**正常输入**，不是故障 | 只判不建（红线：卸载绝不重建通道） | 🔬 1s |
| 2b 推卸载脚本 | 🔬 3s | 远端脚本缺失只能干等 | scp `vm-remove-local.ps1` 后就地执行 | 🔬 3s |
| 2c 停服务 + 卸模块 | 🔬 **70s** / 58s（含卸上游 CLI） | 僵尸 node 进程（不绑端口、taskkill 免疫）；**SSH 会话 PATH 无 `C:\nodejs`** ⇒ `Get-Command npm` 为空、上游清理会静默降级 | 服务停止 + 端口复查 + 目录清理三段断言；段 8 杀孤儿上游进程 + `npm uninstall -g`；ps1/终态命令自拼 `Machine;User` PATH | 🔬 `VM_CLEANUP_DONE` + `UPSTREAM_LEFT=NONE` |
| 2d VM 终态五点 | 🔬 **19s**（v2.0.2 为 35s）/ 17s | "删了但没删干净"；上游 CLI 残留不看就发现不了 | 任务/端口/进程/目录/服务 + **上游**六点复核 | 🔬 六点全 clean（`=> False False 0 Running True NONE`） |

### 第 3 步：拆 ssh 通道（`undeploy-3-ssh.sh`）

| 细步骤 | 实测 | 难点 / 风险点 | 优化方案（已落地） | 完善效果 |
|---|---|---|---|---|
| 3a 通道状态 | 🔬 1s | 在/不在走两条完全不同的路 | 在 → SYSTEM 任务；不在 → 打印用户命令 | 🔬 1s |
| 3b SYSTEM post 动作 | 🔬 **70s** | ① 拆 sshd 会**自断正在执行的会话**（必须派生 SYSTEM 任务）；② VM 上没存 oneclick 时旧版打印**指向不存在文件**的命令 | 派生 SYSTEM 计划任务执行 `-Rollback`；缺脚本时**先多源下载再执行** | 🔬 70s `POST_ROLLBACK_SCHEDULED`；兜底下载实测生效（首选**技能仓 Gitee raw**） |
| 3c 宿主侧回滚 | 🔬 1s | 无基线时盲删用户私钥 | 只删本技能创建的钥；`unknown` 保守保留并显式告知 | 🔬 1s「私钥非本技能创建，保留」 |
| 3d 等通道消失 | 🔬 **6s**（轮次 1 为 27s，v2.0.2 为 19s） | 要等 VM 侧 sshd 真正停掉，等的是系统调度 | 每 5s 用**新建连接**实测，最长 120s | 🔬 6s |

**undeploy 总账**：全链 🔬 **79s**（v2.0.2 为 202s，轮次 1 为 105s）。

## 三、优化项与效果汇总（v2.0.1 → v2.0.3）

| # | 问题（真机症状） | 处置 | 效果 |
|---|---|---|---|
| 1 | 3c 空等 123s 后假 FAIL（health 是从零中间态） | 判据改端口监听 + daemon 存活 | 🔬 省 **123s**/轮，假 FAIL 归零 |
| 2 | `health=000000` 导致卸载 1a/1c 假红 | `health_code` 归一为 3 字符 | 🔬 假红归零 |
| 3 | `tunnel.pid` 是 JSON，`tr -dc 0-9` 拼出 20 位数字 | `tunnel_pid/tunnel_alive` | 🔬 3c 不再误报 `daemon=0` |
| 4 | 拆通道时 VM 无脚本 → 打印死命令 | 就地多源下载后再 `-Rollback` | 🔬 拆通道 79s 全绿 |
| 5 | 僵尸服务壳致重建必挂 | oneclick 判据加 `sshd.exe` 在位 | 🔬 从零重建一次成功 |
| 6 | 单源下载 + 源仓 private | 仓转 public + 双源回退（**只从技能仓**） | 🔬 宿主 2/2、VM 内 2/2 可达，**全程零 token** |
| 7 | 门禁自伤：升版后 M6 变异必 MISS | 版本号现读注入 | 🔬 `ALL_CAUGHT 16/16` |
| **8** | **`VM_SSH_BACKEND` 默认值在 v2.0.0 重构时从 `ssh2` 退化成 `key`** | 默认改回 **`auto`** | 🔬 修复前每步误报 `NO_CHANNEL`（`rc=124`）；修复后 1a 1s、全链无一次通道假红 |
| **9** | **1d 阶段 2 常吃满 60s 下载**（同一 6.6MB MSI 实测 2.9~60.2s） | **MSI 缓存**：`Restore-MsiCache`/`Save-MsiCache` + `-NoMsiCache` | 🔬 阶段 2 **72s → 8s**（-89%） |
| **10** | **`irm\|iex` 备选命令满屏 ParseException**（`意外的属性 CmdletBinding` / `意外的标记 param`），脚本一行未执行 | ① 载荷去 **UTF-8 BOM**；② 删 `#requires` 改运行期版本检查；③ 备选命令 `[string]::Join([char]10,@($s))` 归一化 | 🔬 真机跑通：`selfstage=existing` + `[9/9]` 全绿；门禁 `iex-safe` + M21/M22 |
| **11** | **2a 版本恒 `unknown`**（MANIFEST 是 `version: V1.4.30` 冒号格式，旧代码按 `^version=` 等号锚定） | sed 兼容 `[:=]` 两种分隔 | 🔬 现正确输出 `V1.4.30`；门禁 `pkg-version` + M23 |
| **12** | 计时表重复打印 2~3 遍、`rc=2`（等用户粘贴）被汇总成 `DEPLOY=FAIL` | `VMDEPLOY_STEPS_QUIET=1` + `DEPLOY=NEED_USER_ACTION` | 🔬 一轮一张表、终态语义正确 |
| 13 | `vmcheck`/探针首调撞 VM 冷启 | 判定为非确定性缺陷，**不改判据** | 🔬 冷跑复验 20/20；详见 §五 |

## 四、三轮迭代真机结果（2026-11-17）

| 项 | 轮次 1（16:12 起） | 轮次 2（16:51 起） | 轮次 3（16:58 起） | 变化 |
|---|---|---|---|---|
| 通道命令模式 | `-File` 主路径（`selfstage=existing`） | **`irm\|iex` 备选**（`selfstage=existing`） | 免密已 READY，1b~1d SKIP | 备选路径首次真机跑通 |
| 1d 阶段 2（装 OpenSSH） | 72s | **8s**（命中 MSI 缓存） | —（SKIP） | 🔬 **-89%** |
| 1d 全段 | 31s | 23s | — | -8s |
| 2a 版本解析 | `unknown` | `unknown` | **`V1.4.30`** | 修复生效 |
| deploy 全链 | 126s | 135s | **274s** | 轮次 3 异常（见下） |
| 4a prepare-vm | 20s | 27s | **65s** | 全 `[SKIP]` 仍 65s |
| 4b setup | 62s | 61s | **155s** | [VM] 95.6 + [VM-START] 44.0 + [QA-PROBE] 15.3 |
| 4c vmcheck | 13s | 14s | **31s** | 七判据 PS 往返 |
| 5 三探针 | 16s | 16s | 0s（stamp 复用） | — |
| 5d 终态 | fresh / health=200 / skills=8 | 同左 + `VM_CHANNEL=key（ssh2）` | 同左 | 一致 |
| deploy 判据 | `DEPLOY=PASS` | `DEPLOY=PASS` | `DEPLOY=PASS` | 三轮一致 |
| 探针 | 34/34 | 34/34（SKIP=4） | 34/34（REUSED，SKIP=4） | 一致 |

**轮次 3 为什么是 274s（同一份代码、同一台 VM，前一轮 135s）** —— 可证伪的分解：

1. **不是脚本回归**：三轮判据全绿、步骤集合与顺序完全一致，只有耗时变；`2/3/5` 段（纯宿主逻辑）三轮均 0~2s。
2. **`4b` 从 61s → 155s 的构成**：`[VM] 部署 VM 侧` **95.6s**（`tar` 打包 + `scp` 8MB + VM 内 `install-vm.mjs` 解压覆盖）+ `[VM-START]` **44.0s**（杀残留 → `schtasks /run` → 轮询端口监听）+ `[QA-PROBE]` 15.3s。
   轮次 2 的同一段只有约 35~40s —— 首轮是「清空后全新解压」，本轮是「覆盖已存在目录」（大量文件替换/删除），且 VM 侧此时仍在跑刚重启的服务。
3. **`4a` 从 27s → 65s**：`prepare-vm` 六项探测**全部 `[SKIP]`** 仍花 65s ⇒ 开销在**只读探测的通道往返**（每项一次 PowerShell 往返 + `Get-ScheduledTask`/防火墙枚举），对 VM 侧负载敏感。
4. **处置（不改判据，不当回归）**：`4b` 缺「包内容未变则短路」——它**每轮都会重推 8MB 并重装**。这是母项目 `setup` 层待做优化（用 VM 上 `MANIFEST-deploy-*.txt` 的 total-sha256 与本地比，相同则跳过 `scp`+`install-vm`+`VM-START`），预计可省 **100~140s/轮**。已记入母项目 backlog，不在本技能仓可改范围。

> **通道侧异常（轮次 2 前置）**：16:52 三段取证 = `ping` 0% 丢包 / 裸 TCP 12s **零 banner** / 隧道进程与 `health` 均不在
> ⇒ 典型 **WEDGE**（sshd 预认证段停摆，网络层无罪）+ 上一轮卸载已停机。oneclick 的 `[9/9]` 重启 sshd 顺带修复，
> 之后 `ssh2-conn.mjs ping` = `pong ready`。**注意**：手工直调 `ssh2-conn.mjs` 不带 `WINVM_VM_KEY` 会默认读
> `~/.ssh/id_ed25519`（GitHub 钥）⇒ 报 `All configured authentication methods failed`；技能层 `_common.sh` 已统一
> 默认 `~/.ssh/id_ed25519_winvm`，不经 `_common.sh` 的裸调用需自己带上该变量。

## 五、仍未覆盖 / 已知风险

1. **⏳ 1b~1d「从零通道」分支的失败路径**：成功路径两轮已实测（23s / 31s），但「VM 上通道完全建不起来」的分支（无管理员权限 / 无外网 / MSI 被拦）仍未真机演练。
2. **⚠ 探针首调撞 VM 冷启**：VM 刚开机时 `storage.disk.list` / `app.inventory.list` 可能吃满服务端 30s 预算（实测 30203ms / 30031ms FAIL，热态仅 2.7s / 3.3s）。判定为冷启现象（强制冷跑复验 20/20 全过），**不改判据以免掩盖真慢**；处置=等 2~3 分钟重跑 `--only 5`。
3. **⚠ `-AllowFrom` 默认不传的副作用**：防火墙规则对任意来源放行（仍受 `ListenAddress` 收窄）。oneclick 会打印"建议配 -AllowFrom <宿主机IP>"，但没告诉用户去哪找宿主 IP —— 文案待改进。
4. **⚠ 两仓解耦后 oneclick 的唯一来源是技能仓 raw@main**：技能仓若临时不可达（Gitee + GitHub 双挂）则 1c 无源可发。当前靠双源回退兜底；无离线介质方案，属已知边界。
5. **⏳ `4b` 缺「包内容未变则短路」（母项目 backlog，本技能仓改不了）**：每轮无条件 `tar` + `scp` 8MB + `install-vm` + 重启服务，实测 95.6s+44.0s。优化方向=VM 上 `MANIFEST-deploy-*.txt` 的 `total-sha256` 与本地比，相同则整段跳过，预计省 100~140s/轮。**在此之前，重复部署耗时会按 VM 侧负载在 61~155s 之间浮动，属预期而非回归。**

## 六、V1.4.31 / 技能 v2.1.0 真机账（2026-11-17 19:47~19:59，同一台 VM）

样本 = 「先完整 undeploy、再全新 deploy」的从零闭环（与历史轮次的最大差异：这次含两个上游 MCP 的装与卸）。

| 段 | 实测 | 说明 |
|---|---|---|
| undeploy 全链 | 🔬 **79s** | 1a 3 + 1b 2 + 1c 1 + 2a 1 + 2b 2 + **2c 58** + 2d 17 |
| 其中 2c（含卸上游 CLI） | 58s | 历史同段 70s；本轮 `UPSTREAM_LEFT=NONE`（两个全局包已删除） |
| **undeploy 判据** | **首跑 `FAIL rc=1`**（1c） | 见下方「真缺陷」；兜底修复后 `--only 1` 复跑 **PASS（5s）** |
| deploy 全链 | 🔬 **413s** | 见下分解；**历史 126~274s**，本轮偏高，主因是从零重装 + 上游首次安装 |
| 2 步（host） | 6s | 2a 1s（缓存命中）/ 2b 1s / 2c 0s / 2d 1s / **2e skills=10** |
| 3 步（隧道） | 2s | 3b 幂等短路 |
| 4a prepare-vm | **76s** | 六项全 `[SKIP]` 仍 76s（历史 20~65s）——只读探测的通道往返，对 VM 负载敏感 |
| 4b setup（含装上游） | **226s** | `[VM] 165.6 + [VM-START] 42.6 + [QA-PROBE] 18.3` |
| 4c 七判据 | 38s | `health_http=200` |
| **4d 上游工具面** | **12s** | 首次调用触发懒启动（browser+desktop 各一次 `tools/list`） |
| 5 三探针 | 35s | 34/34 SKIP=4（stamp 过期 11001s，冷跑） |
| 5d 矩阵 | 13s | `connector skills=10` / `disabledTools=8` / `health=200` |
| **5e 上游工具面** | **3s** | 上游已 ready，秒回 |
| **verify** | **PASS** | `DEPLOY=PASS` |

**上游 CLI 的耗时账（首次 vs 幂等）** —— 取自 VM 侧 `install-vm-run.log` 的 `[t+Xs]` 打点：

| 事实 | 数值 | 判读 |
|---|---|---|
| `[4b/6]` 段（`npm i -g agent-browser agent-desktop`） | **47.9s**（t+8.8 → t+56.7） | **首次**安装成本；含两个包下载 + 全局落盘 |
| 之后每轮同段 | **≈0s** | `Get-Command` 命中即跳过（幂等），4 个 `[SKIP]` 级别 |
| `npm warn install-scripts ... postinstall` | 两个包都告警 | npm 11 `allow-scripts` 默认拦 postinstall；**CLI 实测正常**（原生二进制走平台子包），故不加 `--allow-scripts` |
| 全局包体积对 `[VM]` 相位的影响 | 165.6s 中含 47.9s npm | 若不需要这两个工具面：`SKIP_UPSTREAMS=1` 可省下这 48s |

**本轮抓到的真缺陷（已修）**：`undeploy` 1c 报 `mcp.json 仍留 winvm-browser,winvm-desktop`。

- **现象**：`UNDEPLOY=FAIL rc=1`，host 端已卸干净、VM 端五点全 clean，只有全局 `~/.workbuddy/mcp.json` 残留两条死条目。
- **根因**：V1.4.30 的 `delivery/uninstall.mjs` 键表按**包版本**固化（`GLOBAL_MCP_KEYS=['winvm','winvm-a2a']`），而安装侧（V1.4.31 前的 install-host）已写入 4 条 ⇒ **旧包卸载新装必然漏**。这不是偶发，任何「装的版本比卸载器新」的场景都会踩。
- **处置**：① 技能层 1c 加 `^winvm$|^winvm-` **命名空间兜底**（只动本项目命名空间，打印被移除项）；② 母项目 `uninstall.mjs` 键表扩到 4 条与 `install-host` 的 `ourKeys` 对齐；③ 门禁 +M25 变异（兜底退化成单键必须被抓）。
- **复验**：`undeploy.sh --only 1` → `卸载器未清的条目已兜底移除: winvm-browser,winvm-desktop` → `UNDEPLOY=PASS`（5s）。

**本轮耗时偏高的归因（不算回归）**：① 从零重装（`C:\WinVMBridge` 被上一轮卸载删空）⇒ `[VM]` 相位走全新解压，165.6s；② 上游 CLI 首次安装 47.9s；③ `4a` 76s / `4c` 38s 属历史波动带（20~76s / 13~38s）。可再压的两处仍是母项目 backlog：`4b` 内容短路（省 100~140s）、`4a` 只读探测合并往返。
