---
name: winvm-plugin-deploy
description: "WinVM Bridge（workbuddy-virtual-win-plugin）鸿蒙宿主 + Windows VM 双端部署/卸载/复验的唯一执行权威。结构 = 5 步部署（①建 ssh 免密通道 ②取包装 host 端 ③起 tunnel 并验证 ④装 VM 端（含全局 npm 上游 agent-browser/agent-desktop）、起 mcp/a2a service、上游工具面判据 ⑤verify（三探针 + 终态矩阵 + 上游工具面））+ 3 步卸载（①停 tunnel 卸 host ②停 VM 服务 + 卸 VM 模块 + 卸上游 CLI ③拆 ssh 通道 --remove-ssh-tunnel yes|no 默认 no）。每步一个脚本、可单独重跑、失败定点重来；第 1 步失败时只给用户一条可整段粘贴的 VM 管理员 PowerShell 命令（远端脚本只从技能仓取、Gitee/GitHub 双源回退，全程无需 token；-File 执行复制自身，irm|iex 执行则自下载落盘到 VM 固定路径，卸载时同一条 -Rollback）。Use when: 部署/重装/卸载/复验 winvm-plugin；按技能 URL 安装或卸载；VM ssh 连不上、免密通道要建或要拆、发布包或一次性脚本下载失败、插件健康复验、agent-browser / agent-desktop 上游装没装或工具面通不通。"
version: 2.1.0
agent_created: true
---

# WinVM 插件部署（winvm-plugin-deploy）

把「鸿蒙宿主 ⇄ Windows VM 跑 WinVM Bridge」压成**两类任务、每步一个脚本**。没有可选分支、没有中间决策层：
一个命令跑到底，失败就只重跑那一步。

## 部署 = 5 步

| # | 做什么 | 脚本 | 依赖 |
|---|---|---|---|
| **1** | 建 host↔VM 免密 ssh 通道（1a 判 → 1b 备钥 → 1c 给用户一条命令 → 1d 验证，失败回 1b 换钥重来） | `deploy-1-ssh.sh` | — |
| **2** | 取发布包（sha256 + 隔离解压）+ 装 host 端插件与依赖 | `deploy-2-host.sh` | — |
| **3** | 起 `winvm-tunnel` service 并验证隧道（本地端口在监听 + daemon 存活；`/health` 属第 5 步端到端） | `deploy-3-tunnel.sh` | 1 + 2 |
| **4** | 装 VM 端（含 node 依赖 + 全局 npm 上游 `agent-browser`/`agent-desktop`）+ 起 mcp/a2a service + 七判据 + 4d 上游工具面 | `deploy-4-vm.sh` | 1 + 2 |
| **5** | verify：三探针（34 项，`PROBE_DEEP=1` 跑 38）+ 终态矩阵 + 5e 上游工具面 | `deploy-5-verify.sh`（别名 `verify.sh`） | 3 + 4 |

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
$ErrorActionPreference='Stop';$d=Join-Path $env:ProgramData 'WinVMDeploy';New-Item -ItemType Directory -Force -Path $d|Out-Null;iwr -UseBasicParsing -Uri '<远端直链>' -OutFile "$d\winvm-sshd-oneclick.ps1";Unblock-File "$d\winvm-sshd-oneclick.ps1";powershell -NoProfile -ExecutionPolicy Bypass -File "$d\winvm-sshd-oneclick.ps1" -PublicKey '<公钥>' -User 'User' -Port 22
```

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
| **2** | 停 VM 端 service + 卸 VM 端模块 + **卸全局上游 CLI**（`--keep-upstreams` 保留） | `undeploy-2-vm.sh` | — |
| **3** | 拆 ssh 通道（`--remove-ssh-tunnel yes\|no`，**默认 no**） | `undeploy-3-ssh.sh` | 2 完成 |

**1‖2 并行**，然后 3。

```bash
VM_HOST=... bash scripts/undeploy.sh                            # 默认保留通道，卸上游 CLI
VM_HOST=... bash scripts/undeploy.sh --remove-ssh-tunnel yes    # 连通道一起拆
VM_HOST=... bash scripts/undeploy.sh --purge-workspace          # 连 C:\WinVMWorkspace 一起删
VM_HOST=... bash scripts/undeploy.sh --keep-upstreams           # 保留 agent-browser / agent-desktop
VM_HOST=... bash scripts/undeploy.sh --dry-run                  # 只打印计划
```

第 3 步 `yes` 的两条路：
- **通道在** → 把 VM 上已存的 `winvm-sshd-oneclick.ps1` 以 **SYSTEM 计划任务**触发 `-Rollback`（避免拆 sshd 时自断自己），宿主侧同步只删本技能建的私钥/known_hosts。
- **通道不在** → 打印用户在 VM 里执行的那一条：`powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\WinVMDeploy\winvm-sshd-oneclick.ps1 -Rollback`。

## 上游 MCP 工具面（agent-browser / agent-desktop）

除 54 项结构性能力外，VM 端还跑两个**第三方 stdio MCP server**，由 `vm-service` 反向代理成
`POST /mcp/browser`、`POST /mcp/desktop`，宿主侧对应 `connector:winvm-browser`（33 工具）与
`connector:winvm-desktop`（75 工具，默认只暴露 10）。四者**共用同一条隧道**，只差路径。

| 环节 | 在哪 | 判据 |
|---|---|---|
| **装** | `deploy-4` 的 4b → 母项目 `delivery/install-vm` 的 `[4b/6]`：`npm i -g agent-browser agent-desktop`（**幂等**：`Get-Command` 已存在即跳过） | 装不上**不阻断**安装（可选依赖），立刻由 4d 变硬判据 |
| **验** | `deploy-4` 的 **4d** + `deploy-5` 的 **5e**，共用 `_common.sh` 的 `upstream_judge` | **真实 `tools/list` 计数**：browser=`33`、desktop=`10`（白名单数）。可用 `EXP_BROWSER_TOOLS` / `EXP_DESKTOP_TOOLS` 覆盖 |
| **卸** | `undeploy-2` 的 2c → `vm-remove-local.ps1` 段 8：杀孤儿上游进程 → `npm uninstall -g` | `UPSTREAM_LEFT=NONE`；`--keep-upstreams` 保留 |

**为什么判据不看 `/health.upstreams[]`**：那是**懒启动**的观测值——服务刚起来时上游还没被调用过，
恒为 `idle`，拿它断言会把「还没被调」误判成「装坏了」。反过来「路由存在」也不等于「上游可用」：
未安装时路由返回 502。所以只有真打一次 `tools/list` 才算数（同时顺带验证懒启动通路）。

**逃生阀**：`SKIP_UPSTREAMS=1`（`deploy.sh` 与单步脚本都认）。一条 env 同时管**不装**（经
`WINVM_SKIP_UPSTREAMS` 透传给母项目 `delivery/setup` → `install-vm --skip-upstreams`）与**不验**（4d/5e 记 SKIP），
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
| `deploy-2-host.sh` | 取包 + MANIFEST 对账 + host 端插件与 skills |
| `deploy-3-tunnel.sh` | 对齐 `vm-conn.json` 的 identityFile + 起隧道 + 隧道判据（端口监听 + daemon 存活） |
| `deploy-4-vm.sh` | VM 依赖 + 推包装服务（含 npm 上游）+ 七判据 + 4d 上游工具面（真实 tools/list） |
| `deploy-5-verify.sh`（`verify.sh`） | 三探针 + 终态矩阵 + 5e 上游工具面；唯一 verify 实现 |
| `undeploy-1-host.sh` | 停隧道 + host-only 卸载（把 VM 目标三处屏蔽干净，防重复/挂死） |
| `undeploy-2-vm.sh` | VM 端停服务 + 删模块 + 卸上游 CLI + 五点终态（含 `UPSTREAM_LEFT`） |
| `undeploy-3-ssh.sh` | 拆通道（SYSTEM post 动作 / 用户命令）+ 宿主侧精确回滚 |
| `winvm-sshd-oneclick.ps1` | **VM 侧单脚本**：建通道 / `-Rollback` 逆序还原 / `-Continue` 只读体检；自留存量到 `C:\ProgramData\WinVMDeploy`（`-File` 复制自身，`irm\|iex` 自下载落盘）；OpenSSH MSI 缓存在 `WinVMDeploy\cache\`，重建通道直接复用（`-NoMsiCache` 强制重下） |
| `_common.sh` | 地基：日志、`st_begin/st_end` 计时、状态文件、参数解析、依赖冒烟、`channel_ready`/`health_code` |
| `vm-conn.sh` / `ssh2-conn.mjs` / `ps-run.sh` | 双后端（默认 ssh2）、ssh2 实体、远端 PS 执行器 |
| `pkg-root.sh` / `download-verify.sh` / `env-detect.sh` | 包根单一事实源、取包三件套、运行时探测 |
| `vm-remove-local.ps1` | VM 端本地卸载（`undeploy-2` 推过去执行）：服务/目录/任务/挂载点/PATH/side.json + **段 8 上游 CLI 清理**（杀孤儿进程 + `npm uninstall -g`；`-KeepUpstreams` 保留） |
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
| 第 1 步报「全部候选源宿主侧不可达」 | 该 tag 的 release 没带 `winvm-sshd-oneclick.ps1`，且 GitHub raw 也拉不到 → 看逐源 `[200]/[---]` 输出；发新版，或 `SSHD_SCRIPT_URL` 指定直链 |
| 通道 READY 但隧道报 `All configured authentication methods failed` | `vm-conn.json` 的 `identityFile` 指向了未被授权的钥。`deploy-3` 会自动对齐；症状仍在就看第 3 步 3a 输出 |
| 第 3 步 health ≠ 200 | 看 `~/.workbuddy/winvm/tunnel.log`；确认 VM 端 18443 在听（第 4 步 4c 会查）。**不要重启 VM** |
| 第 4 步 setup 超 420s 未监听 | 服务僵死：`schtasks /End /tn WinVMBridge.Service` 后 `/Run` |
| 4d / 5e 报 `browser=ERR:http-502` | VM 上没装 `agent-browser`（4b 的 npm 失败被降级）：重跑第 4 步；或 `SKIP_UPSTREAMS=1` 明确跳过 |
| 4d / 5e 报 `browser=ERR:http-404` | vm-service 是旧版（没有 `/mcp/<id>` 路由）：换规范包重装（`--only 4` 可能推旧 dist，见 `references/troubleshooting.md`） |
| 4d / 5e 报 `desktop=N!=10` 但上游正常 | 白名单被改过（`DEFAULT_DESKTOP_TOOL_ALLOWLIST`）：按新值设 `EXP_DESKTOP_TOOLS`，别放宽断言 |
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
