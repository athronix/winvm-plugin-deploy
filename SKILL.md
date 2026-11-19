---
name: winvm-plugin-deploy
description: "WinVM Bridge（workbuddy-virtual-win-plugin）鸿蒙宿主 + Windows VM 双端部署/卸载/复验的唯一执行权威。结构 = 5 步部署（①建 ssh 免密通道 ②取包装 host 端 ③起 tunnel 并验证 ④装 VM 端（含全局 npm 上游 agent-browser/agent-desktop）、起 mcp/a2a service、上游工具面判据 ⑤verify（三探针 + 终态矩阵 + 上游工具面））+ 3 步卸载（①停 tunnel 卸 host ②停 VM 服务 + 卸 VM 模块 + 卸上游 CLI ③拆 ssh 通道 --remove-ssh-tunnel yes|no 默认 no）；--purge-all 一键回到裸机（②追加 2e 运行时深清 node/codebuddy/私钥，③的同一 SYSTEM 任务里卸 sshd MSI 与两处 authorized_keys）。每步一个脚本、可单独重跑、失败定点重来；第 1 步失败时只给用户一条可整段粘贴的 VM 管理员 PowerShell 命令（远端脚本只从技能仓取、Gitee/GitHub 双源回退，全程无需 token；-File 执行复制自身，irm|iex 执行则自下载落盘到 VM 固定路径，卸载时同一条 -Rollback）。Use when: 部署/重装/卸载/复验 winvm-plugin；按技能 URL 安装或卸载；VM ssh 连不上、免密通道要建或要拆、发布包或一次性脚本下载失败、插件健康复验、agent-browser / agent-desktop 上游装没装或工具面通不通。"
version: 2.5.4
agent_created: true
---

# WinVM 插件部署（winvm-plugin-deploy）

把「鸿蒙宿主 ⇄ Windows VM 跑 WinVM Bridge」压成**两类任务、每步一个脚本**。没有可选分支、没有中间决策层：
一个命令跑到底，失败就只重跑那一步。

## 部署 = 5 步

| # | 做什么 | 脚本 | 依赖 |
|---|---|---|---|
| **1** | 建 host↔VM 免密 ssh 通道（1a 判 READY 则整步 SKIP → **1p 凭据自动建通道**：只要「用户名+口令」或「用户名+空口令」任一能登录就全自动，**成功即整步结束（1b/1c/1d 一个都不跑）**；否则跳过 → 1b 备钥 → 1c 给用户一条命令 → 1d 验证（**默认不回验**，`AUTOKEY_VERIFY_AFTER_S2=1` 才原地等），失败回 1b 换钥重来） | `deploy-1-ssh.sh` + `deploy-1p-autokey.sh` | — |
| **2** | 取发布包（sha256 + 隔离解压）+ 装 host 端插件与依赖 | `deploy-2-host.sh` | — |
| **3** | 起 `winvm-tunnel` service 并验证隧道（本地端口在监听 + daemon 存活；`/health` 属第 5 步端到端） | `deploy-3-tunnel.sh` | 1 + 2 |
| **4** | 装 VM 端（4a 依次补 `node` → `codebuddy` → `agent-desktop` → `agent-browser` 四个**全局**依赖）+ 起 mcp/a2a service + 4c 七判据（内含两个上游工具面） | `deploy-4-vm.sh` | 1 + 2 |
| **5** | verify：三探针（34 项，`PROBE_DEEP=1` 跑 38）+ 上游工具面（33/25，并入同一步）+ 终态矩阵 | `deploy-5-verify.sh`（别名 `verify.sh`） | 3 + 4 |

**1‖2 并行**（互不依赖），**3‖4 并行**，最后 5。编排与并行在 `deploy.sh` 里，脚本本身都能单独跑。

```bash
VM_HOST=172.16.100.2 bash scripts/deploy.sh                    # 全链（首次会停在第 1 步，见下）
VM_HOST=... bash scripts/deploy.sh --only 4                    # 只重跑第 4 步
VM_HOST=... bash scripts/deploy.sh --from 3                    # 从第 3 步起
VM_HOST=... bash scripts/deploy.sh --serial                    # 关并行（排障）
VM_HOST=... RELEASE_TAG=V1.4.30 bash scripts/deploy.sh         # 锁版本
VM_HOST=... SKIP_UPSTREAMS=1 bash scripts/deploy.sh            # 不装/不验两个上游工具面
```

### 唯一的人工步骤

从零部署时第 1 步会打印**一整行**命令，用户在 VM 的**管理员 PowerShell** 粘贴执行即可（约 1~3 分钟，含装 OpenSSH）：

```powershell
$ErrorActionPreference='Stop';$d=Join-Path $env:ProgramData 'WinVMDeploy';New-Item -ItemType Directory -Force -Path $d|Out-Null;$f="$d\winvm-sshd-oneclick.ps1";iwr -UseBasicParsing -Uri '<远端直链>' -OutFile $f;Unblock-File $f;$t=[IO.File]::ReadAllText($f,[Text.Encoding]::UTF8);[IO.File]::WriteAllText($f,$t,(New-Object Text.UTF8Encoding($true)));powershell -NoProfile -ExecutionPolicy Bypass -File $f -PublicKey '<公钥>' -User 'User' -Port 22
```

- **那句中段 `ReadAllText`→`WriteAllText(...UTF8Encoding($true))` 是必需的一步，别省**：
  `winvm-sshd-oneclick.ps1` 在仓库里必须是 **UTF-8 无 BOM**（`irm|iex` / `[scriptblock]::Create`
  会把 BOM 当首字符，`param` 块脱离参数区直接报「意外的属性 CmdletBinding」）；
  但 `powershell -File` 在 Windows PowerShell 5.1 上**不认 UTF-8 声明**，对无 BOM 文件按系统
  ANSI（中文环境 CP936）解码 ⇒ 中文注释/文案变乱码 ⇒ 乱码里的 `?` 打断引号配对 ⇒ `ParserError`，
  **脚本一行都不会执行**（2026-11-18 真机：`unexpected token '锛?'` 于 oneclick:74）。
  所以「源文件无 BOM，落盘副本转 BOM」是硬契约，两条执行路径各拿自己能解析的字节。

- 命令由 `deploy-1-ssh.sh` 现拼（公钥、端口都已填好），**不需要用户改任何东西**。
- `-AllowFrom` **默认不带**：它在 VM 侧落成防火墙白名单（只放行该来源），默认传错值会直接把宿主挡死（实测症状=连接超时）。要收紧来源才加 `VM_ALLOW_FROM=<宿主源IP>`（如 `172.16.100.1`）。
- 脚本执行时把自己**落盘**到 `C:\ProgramData\WinVMDeploy\winvm-sshd-oneclick.ps1`，所以卸载阶段有确定路径。
  - `-File` 执行 → 直接复制自身；
  - `irm <url> | iex` 执行（`$PSCommandPath` 为空）→ **脚本先把自己下载到该路径**再跑，功能等价；
    下载源 `-SelfUrl`（可多个，缺省 `raw@main`），离线演练可 `-NoSelfFetch` 跳过；
  - 落盘失败会打 `selfstage=none` 警告，并明确「将来没有 -Rollback 可执行文件」。
- 用户粘完 → **重跑同一条 deploy 命令**：1a 判到 READY 就跳过 1b~1d，直接往下走。已完成的步骤全部幂等。
- `CHANNEL_WAIT_S=600` 可让第 1 步原地等用户粘贴（默认 0 = 打印完就退出，让命令露在前台）。

### 远端脚本从哪来（只从技能仓取，双源回退）

`winvm-sshd-oneclick.ps1` **只从技能仓取**，不再从母项目 release 资产取——技能仓 GitHub / Gitee
双端 public，raw 匿名可下，两仓彻底解耦（2026-11-17 用户裁定）。宿主侧逐个 HEAD 探测取首个可达，
VM 侧按同一顺序循环兜底：

| 源 | 地址 |
|---|---|
| Gitee 技能仓 raw | `https://gitee.com/athronix/winvm-plugin-deploy/raw/<ref>/scripts/winvm-sshd-oneclick.ps1` |
| GitHub 技能仓 raw | `https://raw.githubusercontent.com/athronix/winvm-plugin-deploy/<ref>/scripts/winvm-sshd-oneclick.ps1` |

- `<ref>` 默认 `main`（永远最新）；要锁脚本版本用 `SSHD_SCRIPT_REF=v2.0.3`（技能仓 tag 命名空间）。
- 换整条链：`SSHD_SCRIPT_URL=<直链>` 永远排第一，其余候选仍作兜底。
- 给用户的**那一行命令内联全部候选**：`foreach` 逐个 `Invoke-WebRequest -TimeoutSec 45`，任一成功即继续，
  全失败才抛 `DOWNLOAD_ALL_FAILED`。VM 的出口网络与宿主不同，单源 404/超时是部署期最常见的卡点。
- 至少一源需宿主侧 HEAD=200，否则第 1 步**直接失败**并逐源打印 `[200]/[---]`——它不会假装通道建好了。
- 全链路**不需要任何 token**：两个仓都是 public，Gitee API 也不再被调用（不再解 `releases/latest`）。

> `RELEASE_TAG` 只影响**第 2 步取发布包**（母项目 release 的 zip），与 oneclick 无关。

## 卸载 = 3 步

| # | 做什么 | 脚本 | 依赖 |
|---|---|---|---|
| **1** | 停 `winvm-tunnel` + 卸 host 端插件（不需通道） | `undeploy-1-host.sh` | — |
| **2** | 停 VM 端 service + 卸 VM 端模块 + **卸全局上游 CLI**（`--keep-upstreams` 保留）；`--purge-all` 时加 **2e 运行时深清**（node 运行时 / codebuddy / VM 侧 `~/.ssh` 私钥 / npm 缓存 / 死 PATH） | `undeploy-2-vm.sh` | — |
| **3** | 拆 ssh 通道（`--remove-ssh-tunnel yes\|no`，**默认 no**）；`--purge-all` 时 `--purge-sshd` 在同一个 SYSTEM 任务里追加「停/删 sshd + 卸 OpenSSH MSI + 删两处 authorized_keys + WinVMDeploy」 | `undeploy-3-ssh.sh` | 2 完成 |

**1‖2 并行**，然后 3。

```bash
VM_HOST=... bash scripts/undeploy.sh                            # 默认保留通道，卸上游 CLI
VM_HOST=... bash scripts/undeploy.sh --remove-ssh-tunnel yes    # 连通道一起拆
VM_HOST=... bash scripts/undeploy.sh --purge-workspace          # 连 C:\WinVMWorkspace 一起删
VM_HOST=... bash scripts/undeploy.sh --keep-upstreams           # 保留 agent-browser / agent-desktop
VM_HOST=... bash scripts/undeploy.sh --purge-all                # 彻底卸载到裸机（隐含拆通道）
VM_HOST=... bash scripts/undeploy.sh --dry-run                  # 只打印计划
```

第 3 步 `yes` 的两条路：
- **通道在** → 把 VM 上已存的 `winvm-sshd-oneclick.ps1` 以 **SYSTEM 计划任务**触发 `-Rollback`（避免拆 sshd 时自断自己），宿主侧同步只删本技能建的私钥/known_hosts。
- **通道不在** → 打印用户在 VM 里执行的那一条：`powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\WinVMDeploy\winvm-sshd-oneclick.ps1 -Rollback`。

## 上游 MCP 工具面（agent-browser / agent-desktop）

除 54 项结构性能力外，VM 端还跑两个**第三方 stdio MCP server**，由 `vm-service` 反向代理成
`POST /mcp/browser`、`POST /mcp/desktop`，宿主侧对应 `connector:winvm-browser`（33 工具）与
`connector:winvm-desktop`（75 工具，默认只暴露 25）。四者**共用同一条隧道**，只差路径。

| 环节 | 在哪 | 判据 |
|---|---|---|
| **装** | `deploy-4` 的 **4a** → 母项目 `delivery/prepare-vm --ensure-deps` 的 **DB-7**：`node` → `codebuddy`（`@tencent-ai/codebuddy-code`）→ `agent-desktop` → `agent-browser`，四个一律**全局**装（**幂等**：`Get-Command <命令名>` 已存在即跳过） | 装不上**不阻断**安装（可选依赖），但 4c 立刻变硬判据；4b 传 `WINVM_UPSTREAMS_HANDLED=1` ⇒ `install-vm` 不再重复装 |
| **验** | `deploy-4` 的 **4c**（VM 内 `vmcheck.ps1` 直打 `tools/list`）+ `deploy-5` 三探针段（宿主侧 `_common.sh` 的 `upstream_judge`），两个**独立观测面** | **真实 `tools/list` 计数**：browser=`33`、desktop=`25`（白名单数）。可用 `EXP_BROWSER_TOOLS` / `EXP_DESKTOP_TOOLS` 覆盖 |
| **卸** | `undeploy-2` 的 2c → `vm-remove-local.ps1` 段 8：杀孤儿上游进程 → `npm uninstall -g` | `UPSTREAM_LEFT=NONE`；`--keep-upstreams` 保留 |

**为什么判据不看 `/health.upstreams[]`**：那是**懒启动**的观测值——服务刚起来时上游还没被调用过，
恒为 `idle`，拿它断言会把「还没被调」误判成「装坏了」。反过来「路由存在」也不等于「上游可用」：
未安装时路由返回 502。所以只有真打一次 `tools/list` 才算数（同时顺带验证懒启动通路）。

**逃生阀**：`SKIP_UPSTREAMS=1`（`deploy.sh` 与单步脚本都认）。一条 env 同时管**不装**（经
`WINVM_SKIP_UPSTREAMS` 透传给母项目 `delivery/setup` → `install-vm --skip-upstreams`）与**不验**（4c 的 `browser_tools`/`desktop_tools` 与第 5 步的 `browser=·desktop=·` 都记 SKIP），
避免出现「装了不验」或「验了没装」的错配。

**两个实测坑（排障先看这两条）**：
1. **SSH 会话拿不到 `C:\nodejs`**：Windows OpenSSH 进的是 cmd.exe/powershell，PATH 只有 Machine 段；
   而 node/npm 在 User 段。任何经通道跑的 `Get-Command npm` 都会为空 ⇒ 卸载会静默降级成警告。
   `vm-remove-local.ps1` 与 `undeploy-2` 的终态命令都已显式拼 `Machine;User`。
2. **Session 0 空桌面**：SSH 直启 `agent-desktop` 的 `list_apps` 恒为 `[]`，因为 SSH 落 Session 0。
   上游必须由 vm-service（InteractiveToken 计划任务，Session 1）spawn 才继承真实桌面。

## 红线

1. **绝不主动重启 VM / guest**。通道坏 = 探测并利用健康窗跑最短链，无窗则止损上报。
2. **卸载绝不重建通道**。通道不在是卸载的正常输入，不是故障。
3. **远端 PowerShell**：复合逻辑写 `.ps1` → scp → `powershell -File`；短片段 `-EncodedCommand`（base64 UTF-16LE）。VM 侧脚本全 ASCII。一律经 `ps-run.sh`。
4. **两个超时预算不可混用**：连接/握手/短命令 `VM_SSH_TIMEOUT`(25s)；PowerShell **载荷** `VM_PS_TIMEOUT`(180s，由 `ps-run.sh` 的 `_payload` 注入)。载荷自身实测 47~56s，用 25s 窗会把"跑完才输出"的 `-File` 杀成零输出 rc=124（看起来像通道坏）。
5. **计数判据禁 `grep -c ... || echo 0`**（零匹配吐两个 0 ⇒ 恒真 ⇒ 假红）。一律 `awk '{n++} END{print n+0}'`。
6. **判据必须可证伪**：写真实计数，不写"某某字样在场"。探针项数（34/4 或 38/0）是硬断言——改了探针必须同步改这里。
7. **宿主删文件禁 `rm`** → `node -e 'fs.unlinkSync(...)'`。

## 状态与日志

- 运行状态：`~/.workbuddy/winvm/deploy-state.env`（VM_HOST/USER/PORT、密钥、PKG_ROOT、各步完成标记）。
  每步 `state_load` 后再做，所以单跑任一步都不会缺上下文。
- 每轮日志：`~/wbtmp/winvm-deploy-<时间戳>/`，含 `steps.tsv`（分步 rc/耗时/判据）、各步 `.log`。
- 探针新鲜 stamp：`~/wbtmp/winvm-probes-stamp.txt`。deploy 全链零失败才升 `deploy_ok=1`，verify 在同包根 + 600s 内可只跑矩阵（省 ~100s）；`VERIFY_FORCE_PROBE=1` 强制冷跑。

## 脚本清单

| 脚本 | 职责 |
|---|---|
| `deploy.sh` / `undeploy.sh` | 两个任务的总入口（编排 + 并行 + 汇总） |
| `deploy-1-ssh.sh` | 免密通道：判 / 备钥 / 给命令 / 验证（1a~1d，失败回 1b，最多 3 轮） |
| `deploy-1p-autokey.sh` | 凭据自动建通道（1p.1~1p.7）：ssh2「口令 / 空口令」登录 → `net session` 判身份 → **S1 直写授权文件**（管理员→`ProgramData\ssh\administrators_authorized_keys`，否则→用户级 `.ssh\authorized_keys`；ACL 用 SID，**不重启 sshd**）→ 立即回验 key → 不通才 **S2** 跑 oneclick（修配置+重启 sshd）→ 仍不通 **S3** 退 2 回人工 1c |
| `deploy-2-host.sh` | 取包 + MANIFEST 对账 + host 端插件与 skills |
| `deploy-3-tunnel.sh` | 对齐 `vm-conn.json` 的 identityFile + 起隧道 + 隧道判据（端口监听 + daemon 存活） |
| `deploy-4-vm.sh` | VM 依赖（node/codebuddy/agent-desktop/agent-browser）+ 推包装服务 + 4c 七判据（含两上游工具面，真实 tools/list） |
| `deploy-5-verify.sh`（`verify.sh`） | 三探针 + 上游工具面 + 终态矩阵；唯一 verify 实现 |
| `undeploy-1-host.sh` | 停隧道 + host-only 卸载（把 VM 目标三处屏蔽干净，防重复/挂死） |
| `undeploy-2-vm.sh` | VM 端停服务 + 删模块 + 卸上游 CLI + 五点终态（含 `UPSTREAM_LEFT`）；`--purge-all` 追加 2e 运行时深清 |
| `undeploy-3-ssh.sh` | 拆通道：3a 派生 `WbTunnelRollback` SYSTEM 任务 + 3b 判据（VM 自行 `-Rollback`）；`--purge-sshd` 时任务改挂临时 wrapper `WbPurgeAll`（VM 侧运行时生成，不随包分发）（`-Rollback` → `vm-purge-sshd.ps1`）；**不再做宿主侧回滚**（私钥是可复用资产，基线由 `host-state.json` 保证） |
| `winvm-sshd-oneclick.ps1` | **VM 侧单脚本**：建通道 / `-Rollback` 逆序还原 / `-Continue` 只读体检；自留存量到 `C:\ProgramData\WinVMDeploy`（`-File` 复制自身，`irm\|iex` 自下载落盘）；OpenSSH MSI 缓存在 `WinVMDeploy\cache\`，重建通道直接复用（`-NoMsiCache` 强制重下） |
| `_common.sh` | 地基：日志、`st_begin/st_end` 计时、状态文件、参数解析、依赖冒烟、`channel_ready`/`health_code` |
| `vm-conn.sh` / `ssh2-conn.mjs` / `ps-run.sh` | 双后端（默认 ssh2）、ssh2 实体、远端 PS 执行器 |
| `pkg-root.sh` / `download-verify.sh` / `env-detect.sh` | 包根单一事实源、取包三件套、运行时探测 |
| `vm-remove-local.ps1` | VM 端本地卸载（`undeploy-2` 推过去执行）：服务/目录/任务/挂载点/PATH/side.json + **段 8 上游 CLI 清理**（杀孤儿进程 + `npm uninstall -g`；`-KeepUpstreams` 保留） |
| `vm-purge-runtime.ps1` | 2e 运行时深清（`--purge-all`）：`C:\nodejs` + nvm、codebuddy 包与 shim、VM 侧 `~/.ssh` 六个文件、npm 缓存、死 PATH、残留任务与防火墙；`-KeepWinVMDeploy` 留给 3b |
| `vm-purge-sshd.ps1` | 3b 的 sshd 清理（SYSTEM 延迟执行）：停/删服务、卸 MSI（product code 从注册表解析）、删三个程序/配置目录、防火墙、最后删 WinVMDeploy；日志落 `C:\ProgramData\winvm-purge-sshd.log` |
| `selfcheck.sh` | 离线自检门禁（不需要 VM）：语法/控制字符/frontmatter/结构断言/变异自证 |
| `scripts/legacy/`、`references/legacy/` | v1.x 编排层与旧通道文档，**仅留档，不入发布包、不作判据** |

## 自检门禁

改完任何脚本/文档先跑它（不需要 VM，是唯一的离线判据）：

```bash
bash scripts/selfcheck.sh                 # 末行 SELFCHECK=ALL_GREEN checks=N fails=0
bash scripts/selfcheck.sh --mutate        # 变异自证：往副本注缺陷，必须被断言抓到
```

## 卡住时

| 现象 | 处置 |
|---|---|
| 第 1 步打印命令后退出 2 | 正常：去 VM 粘那条命令，回来重跑 deploy |
| VM 上粘完命令满屏红字 `Unexpected token` / `Missing expression after ','`，且报错行内容是乱码（如 `妯″紡`、`锛?`） | **编码问题，不是下载损坏**：`powershell -File` 在 PS 5.1 上按系统 ANSI(CP936) 解码无 BOM 的 UTF-8 文件 ⇒ 中文注释变乱码 ⇒ 打断引号配对 ⇒ ParserError，脚本一行未执行。粘之前必须先转 BOM：`$t=[IO.File]::ReadAllText($f,[Text.Encoding]::UTF8);[IO.File]::WriteAllText($f,$t,(New-Object Text.UTF8Encoding($true)))`。v2.5.1 起命令内已含这一步 |
| 第 1 步报「全部候选源宿主侧不可达」 | 该 tag 的 release 没带 `winvm-sshd-oneclick.ps1`，且 GitHub raw 也拉不到 → 看逐源 `[200]/[---]` 输出；发新版，或 `SSHD_SCRIPT_URL` 指定直链 |
| 通道 READY 但隧道报 `All configured authentication methods failed` | `vm-conn.json` 的 `identityFile` 指向了未被授权的钥。`deploy-3` 会自动对齐；症状仍在就看第 3 步 3a 输出 |
| 第 3 步 health ≠ 200 | 看 `~/.workbuddy/winvm/tunnel.log`；确认 VM 端 18443 在听（第 4 步 4c 会查）。**不要重启 VM** |
| 第 4 步 setup 超 420s 未监听 | 服务僵死：`schtasks /End /tn WinVMBridge.Service` 后 `/Run` |
| 4c / 第 5 步报 `browser=ERR:http-502` | VM 上没装 `agent-browser`（4b 的 npm 失败被降级）：重跑第 4 步；或 `SKIP_UPSTREAMS=1` 明确跳过 |
| 4c / 第 5 步报 `browser=ERR:http-404` | vm-service 是旧版（没有 `/mcp/<id>` 路由）：换规范包重装（`--only 4` 可能推旧 dist，见 `references/troubleshooting.md`） |
| 4c / 第 5 步报 `desktop=N!=25` 但上游正常 | 白名单被改过（`DEFAULT_DESKTOP_TOOL_ALLOWLIST`）：按新值设 `EXP_DESKTOP_TOOLS`，别放宽断言 |
| 4a 日志里出现 `[DB-3][MANUAL]` / `[DB-7][MANUAL]` 但步骤报 `[OK] 依赖就绪` | **假绿，v2.5.3 起已被拦**：`prepare-vm` 的 ps1 在依赖失败时只打印 `[MANUAL]` 不 `exit 1` ⇒ 只看 rc 会误判。v2.5.3 的 4a 会扫这两行判失败，并自动重试一次 + 调 `scripts/node-zip-fallback.ps1` 兜底装 node。若仍失败，按 `[MANUAL]` 提示手工装 node ≥ 18 后重跑 `--only 4` |
| `[DB-3] zip install FAILED: 不能解析远程名称` | **多半是镜像瞬时抖动，不是 DNS**：先在同一台 VM 上手工 `Invoke-WebRequest` 同一条 URL 验证（实测同 URL 第二次 37.6MB 完整下载）。v2.5.3 起 4a 内建一次重试 + 独立兜底，直接重跑 `--only 4` 即可；别去改 DNS/代理 |
| 4a 兜底报 `RESCUE_NEEDS_IDLE` | `node.exe` 正被进程映射（实测就是 WinVM 服务自己），映射中的镜像**既不能删也不能覆盖**。动作：`schtasks /end /tn WinVMBridge.Service` + 杀掉占用的 node pid，再重跑 4a；**不要为清一个文件重启 VM** |
| `npm warn install-scripts ... not yet covered by allowScripts` | **无害，postinstall 实际已执行**（实测 `agent-browser/skill-data` 27 文件在位）。npm 11 把提示提级成 warn。要消音：`npm config set allow-scripts=agent-browser,agent-desktop --location=user` |
| 4a 日志先打「`.ps1` 已推送 …」，紧接着 `-File 方式参数实际参数 winvm-setup-….ps1 不存在`（rc=4294770688） | **母项目 V1.4.34 之前的老包才会遇到**：旧 `runRemotePs1` 用**裸文件名**推送，靠「sftp 落盘目录 == ssh 登录 cwd」这条假前提；put 与 exec 是两次独立建连、各自选后端，链路抖过一次就分裂（实测同一台机 11:53 成功、12:04 失败）。V1.4.34 起统一改为 `${VM_DEPLOY_DIR}/<name>` **绝对路径**，日志会打印完整路径。若仍见裸名 ⇒ 包是旧的，换规范包重装 |
| DB-7 显示 `desktop:MISSING browser:MISSING`，但 4c/第 5 步明明读到 `browser=33 desktop=25` | **母项目 V1.4.34 之前的老包假红**：`state` 漏映射 `cliDesktop`/`cliBrowser`（探测端叫 `browserCli`/`desktopCli`），日志与计划表恒读 `undefined`。**安装行为本来是对的**（DB-7 的 ps1 自己 `Get-Command` 重探），所以别去手工装 CLI。V1.4.34 起修好，正常会显示 `desktop:OK browser:OK` 且计划表 `[SKIP] all present` |
| 卸载后 `UPSTREAM_LEFT=agent-desktop` | `npm uninstall -g` 失败（npm 不在 PATH / 文件占用）：看 `vm-remove.log` 的 `[WARN]` 行；手工 `npm uninstall -g`。不需要卸就加 `--keep-upstreams` |
| verify 报 `ENV_WINDOW=1` | 通道瞬态窗，环境问题非功能失败。等健康窗只重跑 `verify.sh` |
| 探针报 `total-33!=34` / `skip-N!=4` | 探针项数被改动 → 同步改 `deploy-5-verify.sh` 的 `EXP_TOTAL/EXP_SKIP`（刻意告警，别放宽） |

## 参考文档（渐进披露）

| 文件 | 何时读 |
|---|---|
| `references/deploy-timeline.md` | 想知道每一步**该花多久**、难在哪、怎么再快一点（含实测效果列） |
| `references/known-good-flow.md` | 想知道"正常长什么样"：各步预期输出与判据 |
| `references/troubleshooting.md` | 任何一步报错，按病征查根因与处置 |
| `references/performance-audit.md` | 优化耗时的历史账本与取舍理由 |
| `references/legacy/` | v1.x 旧编排与旧通道文档，**仅留档，不作判据** |
