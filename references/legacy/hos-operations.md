# 操作全流程（阶段 A→G）

每阶段：做什么 → 命令 → 判据。可逆性设计见 [rollback-contract.md](hos-rollback-contract.md)。

## 阶段 A：宿主机生成密钥

```sh
sh scripts/host-generate-key.sh                          # 默认 ~/.ssh/id_ed25519_winvm / 账户 User / 端口 22
sh scripts/host-generate-key.sh ~/.ssh/k2 User 2222      # 自定义路径 / 账户 / 端口
ROTATE=1 sh scripts/host-generate-key.sh                 # 强制重新生成（旧钥备份 .old-<时间戳>）
NOHARDEN=1 sh scripts/host-generate-key.sh               # 旧写法，等价于不加 -Harden
```

- `ed25519` + **无 passphrase**：自动化免密必须留空；有 passphrase 就要 ssh-agent，沙箱不适用。
- 私钥 `600`，绝不进仓库。hmdfs 上 `chmod` 可能被忽略（见 pitfalls 2），能设就设。
- 脚本打印**公钥 + SHA256 指纹**，并把公钥注入 ps1 整段输出（替换 `__PUBKEY__`），所以产出的 ps1 零编辑即可跑。
- 首次运行写宿主机基线 `$HOME/.workbuddy/.state/hos-winvm-ssh-tunnel/host-state.json`（包外，`WB_TUNNEL_STATE_DIR` 可覆盖）：密钥是否已存在、是否本 skill 拥有（按公钥注释 `workbuddy-hos-winvm-tunnel` 判定）、known_hosts 是否已有该主机。
- 轮换 = `ROTATE=1` 重生成 + VM 侧重跑 ps1（幂等追加），旧钥按"安全收尾"吊销。

## 阶段 B：Windows 安装 OpenSSH Server（联网，不需要 ISO）

默认没有。ps1 按序自动回退：

| 序 | 方式 | 适用 | 要点 |
|---|---|---|---|
| 1 | **官方 MSI（默认首选）** | 有外网 | 下载 `OpenSSH-Win64-v10.4.0.0.msi` → `msiexec /i <msi> /qn /norestart /l*v <log>`；镜像先 HEAD(6s) 探源再下 |
| 2 | 官方 zip + 多镜像 | MSI 被拦 / 想免安装 | 下载 `OpenSSH-Win64.zip` → 解压 → `Install-sshd.ps1` |
| 3 | winget | 精简系统、前两者不行 | `winget install --id Microsoft.OpenSSH.Preview --exact --silent`，失败试 `Microsoft.OpenSSH.Beta` |
| 4 | `Add-WindowsCapability` | **仅 `-InstallMethod Capability`** | 走 Windows Update，实测国内长时间卡在 2/9，默认不自动尝试 |
| 4b | `dism /online /add-capability` | **仅 `-InstallMethod Dism`** | 与 4 同源同慢；仅当 Capability 模块不可用但 `dism.exe` 可用时兜底。退出码 3010 = 成功但需重启 |
| 5 | 全失败 | 无外网 | **抛错并提示**用 `-MsiPath` / `-OpenSSHZipPath` 手动指定，绝不静默失败 |

镜像实测（同网段，前 4 MB 速度），脚本按此排序：

| 源 | HEAD | 下载速度 | 结论 |
|---|---|---|---|
| `gh-proxy.com` | 200 / 1.17s | **5.92 MB/s** | 首选（6.57 MB 约 1-2 秒） |
| `ghfast.top` | 200 / 0.95s | 1.01 MB/s | 次选 |
| `ghproxy.net` | 200 / 6.16s | 0.03 MB/s | 兜底（基本不动） |
| `github.com` 直连 | 200 / 0.85s | **GET 20s 超时** | 最后兜底；HEAD 通 ≠ 能下 |
| `mirror.ghproxy.com` / `hub.gitmirror.com` / `gh.llkk.cc` / `github.moeyy.xyz` / `ghproxy.cc` | 均不通 | — | 已剔除，避免白等 6s×5 |

- **任意自定义源**：`-DownloadUrl <完整URL>`，优先级最高；不显式给 `-InstallMethod` 时按扩展名推断。
- **走代理**：`-ProxyUrl http://127.0.0.1:2080`，HEAD 探测 / 下载 / GitHub API 全部生效。
- `0x800f0954` = 连不上 Windows Update → 用 MSI，不要碰可选功能。
- 下载超时默认 180 s（`-DownloadTimeoutSec`）；文件 <0.5 MB 或**文件头前 N 字节**不匹配 `D0CF11E0`(msi)/`504B0304`(zip) 视为失败并换源。
- 已手动下好包最省时：`-MsiPath %USERPROFILE%\OpenSSH-Win64-v10.4.0.0.msi`（或 `-OpenSSHZipPath ...zip`）→ 跳过下载直接装 + 记 journal，可逆性不丢。
- MSI 装的回滚走 `msiexec /x {ProductCode} /qn`（ProductCode 装完自动从注册表取回写进 journal）。

## 阶段 C：启动 sshd

**先起服务，再改配置**——否则改完配置没法判断"服务本身是否健康"。

```powershell
Set-Service -Name sshd -StartupType Automatic
if ((Get-Service sshd).Status -ne 'Running') { Start-Service sshd }
```

判据：`sc query sshd` = `RUNNING`；`sc qc sshd` 的 `START_TYPE` = `AUTO_START`。

## 阶段 D：配置 sshd_config（最容易踩坑的一步）

文件：`%ProgramData%\ssh\sshd_config`。四条纪律：

1. **先备份**：`Copy-Item sshd_config "sshd_config.bak-$(Get-Date -f yyyyMMdd-HHmmss)"`；首次另留一份 `.wb-orig` 供 destroy 还原。
2. **只在全局区写指令**：第一个 `Match` 行之后只能写子块指令，把 `Port` 插到 `Match Group administrators` 后面会直接语法错。脚本以"第一个 `Match` 行"为全局区终点。
3. **幂等**：有则改、无则插、重复则注释，绝不无脑 `Add-Content`。
4. **校验再重启**：先 `sshd -t -f <预览副本>`，通过才写真实文件；再 `sshd -t`，失败立刻回滚备份且**不重启**（服务不动 = 通道不断 = 不自锁）。重启统一放阶段 E 之后。

配置项清单：

| 指令 | 值 | 说明 |
|---|---|---|
| `Port` | `22`（可改） | 必须与防火墙放行端口一致 |
| `PubkeyAuthentication` | `yes` | 免密前提 |
| `PermitEmptyPasswords` | **`no`（恒为 no）** | 写 `yes` 会让空密码账户走 none 直通 = 匿名登录，公钥彻底失效 |
| `PasswordAuthentication` | **`yes`（默认）** | 密码认证方法默认保留；要减攻击面显式 `-Harden` |
| `MaxAuthTries` / `LoginGraceTime` | `-Harden` 时才写 `3` / `30` | 默认保持环境原状 |
| `ListenAddress` | `<VM内网IP>` + `127.0.0.1` | `-ListenAddress auto` 自动取；不写 `0.0.0.0` |
| `Match Group administrators` + `AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys` | 必须存在 | 管理员公钥重定向；缺失则管理员密钥"放了也不生效" |

手工等效命令（不想用脚本时）：

```powershell
Copy-Item $env:ProgramData\ssh\sshd_config "$env:ProgramData\ssh\sshd_config.bak-$(Get-Date -f yyyyMMdd-HHmmss)"
& "$env:ProgramFiles\OpenSSH\sshd.exe" -t          # 改完必做
Restart-Service sshd                               # Windows OpenSSH 不吃 HUP，必须重启
```

`LimitBlankPasswordUse`（LSA 层）：只在 `-EmptyPasswordMode yes` 时改成 `0` 并记 journal；判定不放开空密码时，若发现是**本账本**改的那条会自动收回（别处设的 `0` 一律不碰）。

## 阶段 E：部署公钥 + ACL + 防火墙

| 账户类型 | 目标文件 | ACL |
|---|---|---|
| 管理员（Administrators 组） | `%ProgramData%\ssh\administrators_authorized_keys` | 仅 `Administrators` + `SYSTEM`，禁用继承 |
| 标准用户 | `%USERPROFILE%\.ssh\authorized_keys` | 仅该用户 + `SYSTEM`，`.ssh` 目录同步收紧 |

- 用 **SID** 收紧（`*S-1-5-32-544`=Administrators，`*S-1-5-18`=SYSTEM），规避本地化组名问题。
- 文件必须 **ASCII 无 BOM**、一行一把钥；权限过宽 sshd 会**静默忽略**并回退密码（表现为"配了还让输密码"）。
- 防火墙必须与 `Port` 一致，且**必须 `-Profile Any`**：

```powershell
# 系统预置的 OpenSSH-Server-In-TCP 只作用于 Domain,Private；网络档变 Public 就会"服务在跑但外部连不上"
Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled True -Profile Any -Action Allow -Direction Inbound -Protocol TCP -LocalPort 22
New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP-WB' -DisplayName 'OpenSSH Server (sshd) - WorkBuddy' `
  -Enabled True -Profile Any -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
```

- 同时把既有覆盖该端口的 Allow 规则 `RemoteAddress` 收窄到 `-AllowFrom`（默认宿主机 IP），每条记 journal。
- **网络配置档必须不是 Public**：`Get-NetConnectionProfile` 若为 `Public`，`Set-NetConnectionProfile -InterfaceAlias <alias> -NetworkCategory Private`；否则 22/3389/445 全被丢包（脚本自动处理并记录）。

## 阶段 F：验证 → 收紧 → 验收

**验证**（宿主机）：

```sh
sh scripts/verify-tunnel.sh 172.16.100.2 User ~/.ssh/id_ed25519_winvm 22
```

四段式，顺序按"能不能被冒名登录"排：

1. TCP 可达。
2. **`none` 必须被拒** —— 命门。若返回被接受，说明无需凭据即可登录，第 3 段的成功是假象。
3. **认证方式通告** —— 顺带打印 `Permission denied (publickey,password,...)` 里的方法列表，不输密码就能证明"密码认证是否开着"。
4. **纯公钥登录** —— 必须 `IdentitiesOnly=yes` + `PreferredAuthentications=publickey` 同时带。

**收紧**（默认不做）：`-Harden` 才写 `PasswordAuthentication no` / `MaxAuthTries 3` / `LoginGraceTime 30`；去掉开关重跑即恢复（幂等）。

**验收**（三条同时成立才算真免密通道）：

- `none` 被拒 + 公钥成功 + 服务端 ETW 出现 `Accepted publickey`。
- 密码通道符合预期：方法列表含 `password` 即"方法仍开放"；上了 `-Harden` 则应消失。
- 吊销测试：临时移除公钥行 → 应无法登录 → 恢复。
- 授权文件里应只有本通道的钥，无历史残留（`baseline.authFiles.hasTunnelKey` 用于区分"构建前遗留"与"本次未清干净"）。

## 阶段 G：destroy

```sh
DRYRUN=1 sh scripts/destroy-tunnel.sh     # 预演：打印将撤销哪些变更
        sh scripts/destroy-tunnel.sh      # 真销毁：VM 侧回滚 + 宿主机侧回滚
KEEP=1  sh scripts/destroy-tunnel.sh      # 只撤配置/公钥/防火墙，保留 sshd 程序与服务
```

**判定标准是「免密登录不再可用」，不是「22 端口关了」。** 构建前 sshd 就存在的机器，destroy 后 22 依然开着 —— 那是正确还原。

| 现场 | 行为 |
|---|---|
| 22 不可达 | 已无通道可撤；打印 VM 本地补跑命令 |
| 22 可达但免密不通 | 无法远程回滚；① 先重建再 destroy ② VM 管理员 PowerShell 直接 `-File ... -Rollback`（该分支不校验公钥，模板可直接用） |
| 22 可达且免密可用 | scp 回滚脚本 → `schtasks` 以 SYSTEM 触发（SSH 断开不影响它）→ 轮询"免密失效"为成功 |

**验收四项**：

1. **无遗留**：密钥、known_hosts 条目、基线 json、`.wb-orig`/`.bak-*`、自建防火墙规则、网络档改动、本次装的 sshd —— 全部消失（VM 侧回滚结束打印只读残留自检逐项核对）。
2. **无过度还原**：构建前就有的密钥、别人的授权文件行、系统原规则、原有服务 —— 一个都不能动。
3. **可重建**：紧接着再跑 build 仍然成功。
4. **密码通道保留**：destroy 后 `verify-tunnel.sh` 第 3 段仍应列出 `password` —— 那是保留项，不是残留。

顺序：**先 VM 后宿主机**（否则通道一断进不去）。VM 侧回滚用一次性计划任务以 SYSTEM 运行，这样"卸载 sshd"不会把执行会话自己干掉；任务在回滚末尾删除。

## ps1 参数总表

| 参数 | 作用 |
|---|---|
| `-DryRun` | 零副作用预演（日志落 `%TEMP%`） |
| `-Continue` | 只读体检：15 项 + 一句结论，报告落 `wb-tunnel-diag-<ts>.log` |
| `-Rollback` | 按 journal 逆序精确还原；可与 `-DryRun` / `-Continue` 组合 |
| `-KeepService` | 回滚时保留 sshd 程序与服务（记 `kept`，后续不带该开关可补撤） |
| `-Port <n>` | 自定义端口，自动同步防火墙 |
| `-InstallMethod Auto\|Msi\|Zip\|Dism\|Winget\|Capability` | 安装方式；`Auto` 走 MSI→Zip→Winget |
| `-MsiPath` / `-OpenSSHZipPath` | 用本地包，跳过下载 |
| `-DownloadUrl` / `-ProxyUrl` / `-DownloadTimeoutSec` | 自定义源 / 代理 / 超时 |
| `-SkipInstall` | 不安装，只做配置（sshd 已在时用） |
| `-ListenAddress auto\|<IP>\|all` | 监听地址；`auto` 取本机内网 IP + 回环 |
| `-AllowFrom <IP[,IP]>` | 防火墙来源白名单（默认宿主机 IP） |
| `-Harden` | 关密码认证 + 收紧 `MaxAuthTries`/`LoginGraceTime` |
| `-EmptyPasswordMode auto\|yes\|no` | `auto` 只探测不放开；`yes` 放开空密码密码登录**并开启 none 匿名**（会报红，build 自检 FAIL） |
| `-NoHarden` / `-AllowEmptyPassword` | 旧写法，等价于默认 / 等价于 `-EmptyPasswordMode yes` |
