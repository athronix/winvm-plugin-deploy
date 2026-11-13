# 实测证据与验收基线（172.16.100.2）

本文是"什么算建成"的判据来源。数值取自真实 VM（`User` 空密码、OpenSSH for Windows 10.4、Hyper-V Internal 网络）。

## 一、一次性从零重建的完整证据链

前提：VM 侧先卸载 sshd 制造干净环境，再由 `winvm-sshd-oneclick.ps1` 一次性装好并配置。

| 环节 | 证据 |
|---|---|
| 网络 | `ping` 2/2 收包 `1ms`；TCP 22 `OPEN`，banner `SSH-2.0-OpenSSH_for_Windows_10.4 Win32-OpenSSH-GitHub` |
| 安装 | journal `#1 install-sshd` → `method=msi`，`msiProduct={C3DFF1A5-DB4C-4B49-9FC7-346BAA182D99}`，`msiFile=%TEMP%\OpenSSH-Win64.msi`（6.57 MB，源 `gh-proxy.com`） |
| 服务 | `STATE: 4 RUNNING` / `START_TYPE: 2 AUTO_START` / `BINARY_PATH_NAME: "C:\Program Files\OpenSSH\sshd.exe"` |
| 配置 | `Port 22` / `PubkeyAuthentication yes` / `PasswordAuthentication yes` / `PermitEmptyPasswords no` / `Match Group administrators` → `administrators_authorized_keys` |
| 授权文件 | 1 行，blob 与宿主机公钥一致；ACL = 本账户 `(F)` + `Administrators:(F)` + `SYSTEM:(F)` |
| 免密登录 | `verify-tunnel.sh` → `win-hos-ywang-s\user` / `win-hos-ywang-sanway`，退出码 0 |
| 纯公钥（关键） | 服务端只声明 `Permission denied (publickey,keyboard-interactive)`；强制 `PreferredAuthentications=password` 送空密码 → 拒绝；强制 `keyboard-interactive` 送 3 个空回车 → 拒绝。**证明通道不是靠空密码进去的** |
| 事件日志铁证 | `OpenSSH/Operational`：`Accepted publickey for User from 172.16.100.1 ... ED25519 SHA256:74Ke67fq…`；同段有 `Disconnected ... [preauth]`（空密码尝试被拒的记录） |
| 账户未改密 | `Get-LocalUser User` → `Enabled=True`、`PasswordRequired=False`、`PasswordLastSet` 为历史值，本轮未变 |
| 空密码策略未动 | `HKLM\SYSTEM\CurrentControlSet\Control\Lsa\LimitBlankPasswordUse = 1` |
| 幂等 | `buildCount=4` 而 `ops` 仍只有 8 条（upsert 生效）；连续 3 次登录 `ok` |
| 时延 | 单次登录 **1.4–1.7 s**（含 TCP + AES 握手 + cmd 启动） |
| scp | 上传退出码 0，下载回读内容**完全一致**（双向） |
| 退出码透传 | 远端 `exit 42` → 本地 `$? = 42` |
| journal 完整性 | 8 条 ops 全 `pending`，每条 undo 齐全（含 `uninstall_openssh.msi` ProductCode） |

## 二、暴露面四层核验（回答"是不是只有宿主机能连"）

配置层结论不足以断言"外部真的进不来"。补齐另两层 + 反向实测后，四层同时成立：

| 层 | 实测 | 挡住的路径 |
|---|---|---|
| **① 拓扑** | `Get-NetNeighbor` 里 `172.16.100.0/24` 只有 `172.16.100.1`（MAC `56-DC-F4-6A-E2-DA`）和广播地址 | 该网段是 Hyper-V **点对点内部网络**，物理上不存在第三台机器 |
| **② 监听** | `Get-NetTCPConnection -LocalPort 22 -State Listen` → 只有 `172.16.100.2:22`、`127.0.0.1:22`，同一个 pid，`Get-Process sshd` 单实例 | 不绑 `0.0.0.0`、不绑 Tailscale 地址 |
| **③ 防火墙** | 覆盖 TCP 22 的 5 条 Allow，`Remote` 全 = `172.16.100.1,127.0.0.1`；三个 profile `InboundDefault=NotConfigured`（= 默认阻止入站） | 即便同网段加机器、或网络改桥接，也进不来 |
| **④ 无转发旁路** | `netsh interface portproxy show all` → 无 22 相关条目 | 没有"把 22 转出去/转进来"的旁路 |

反向实测（从宿主机发起，验证"不该通的确实不通"）：

| 目标 | 结果 | 含义 |
|---|---|---|
| `172.16.100.2:22` | **OPEN** + banner `SSH-2.0-OpenSSH_for_Windows_10.4` | 正道 |
| VM 的 Tailscale 地址:22 | **TIMEOUT**（同地址 3389 也 TIMEOUT） | 整条 tailnet 路径都不通，不是单靠 sshd 挡 |
| 宿主机物理网卡 IP:22 | **REFUSED** | 家用局域网侧无监听 |
| 宿主机 `127.0.0.1:22` | **REFUSED** | 未误绑到宿主机 |

`sshd -T` 佐证：`listenaddress <VM内网IP>:22` / `listenaddress 127.0.0.1:22` / `GatewayPorts no` / `PermitTunnel no` / `AllowTcpForwarding yes`。

**一条命令看四层**（VM 侧）：

```powershell
Get-NetTCPConnection -LocalPort 22 -State Listen | Select LocalAddress,LocalPort,OwningProcess
netsh interface portproxy show all
Get-NetNeighbor -AddressFamily IPv4 | Where-Object IPAddress -like '172.16.100.*' | Select IPAddress,State,LinkLayerAddress
Get-NetFirewallPortFilter | Where-Object { ([string]$_.LocalPort) -match '\b22\b' } |
  ForEach-Object { $r = Get-NetFirewallRule -Name $_.InstanceID; "$($r.DisplayName)  Remote=$((($r|Get-NetFirewallAddressFilter).RemoteAddress) -join ',')" }
```

**三个仍需注意的边界**：

- **LSA 层要跟着一起收**：`PermitEmptyPasswords`（sshd 层）与 `LimitBlankPasswordUse`（LSA 层）是两道独立闸门。只放开前者是死配置，只留后者为 `0` 则少挡一层（一旦有人把 `PermitEmptyPasswords` 改回 `yes` 就退化成匿名登录）。
- **`GatewayPorts` 不要改成 `yes`**：见 [pitfalls 第 34 条](hos-pitfalls.md)。
- **VM 网卡从 Internal 改成 External/桥接时**，① 层保护消失，只剩 ②③④；此时须确认 `-AllowFrom` 仍是唯一来源。

## 三、"假免密"取证链（照这个顺序怀疑）

一次 build 报告"完成 + 自检通过 + verify 全绿"，但通道其实靠 up 的是 none 认证。取证顺序：

| 步骤 | 观察 | 结论 |
|---|---|---|
| 1. `-i /dev/null` 不给任何 key 登录 | 成功，rc=0 | 没 key 也能进 —— 可疑 |
| 2. `ssh -vvv` 看实际认证方法 | `Authenticated to <ip> using "none"` | **走的是 none 认证** |
| 3. 读服务端 ETW 近 13 条 Accepted | 全部 `Accepted none` | **公钥一次都没用上** |
| 4. 只改 `PermitEmptyPasswords yes → no` 并重启 sshd | `sshd -t` OK，监听不变 | 变更面极小 |
| 5. 复测 none | `Permission denied (publickey,password,keyboard-interactive)` | **none 已被拒** |
| 6. 复测 ETW | `Accepted publickey ... ED25519 SHA256:74Ke67fq…` | **这才是真公钥登录** |
| 7. 四段式 verify | 全绿 | 且为真 |
| 8. 端到端 | `exit 42` → `$?=42`；scp 双向 `diff` 一致 | 通道可用 |

**安全阀做法（推荐复用）**：改 sshd_config 前先 `Copy-Item` 备份，并 `Register-ScheduledTask -Once -At (Get-Date).AddMinutes(3)` 建"3 分钟后自动恢复 + 重启 sshd + 删任务"的计划任务；验证通过后立即 `schtasks /Delete /TN <name> /F` 拆除。这样即使改错导致断连，VM 会自己恢复，不需要人守现场。

## 四、destroy 实测与失败语义

| 项 | 结果 |
|---|---|
| 回滚总量 | 17 条 ops 逆序处理，`failed=0` 时 `status=rolledback` |
| `#1 install-sshd` | `msi-uninstall:0,verified-absent` → 真卸载；宿主机侧随后实测 `22 CLOSED` |
| 规则已不存在 | **不算失败**。MSI 卸载会连带删掉它自己塞进来的防火墙规则；"来源限制没什么可还的、也没有残留"本来就是**已完成**。这类 false-failure 会让人误以为 destroy 不可靠，比真失败更有害 |
| `-Enabled $false` 抛枚举错 | `NetSecurity.Enabled` 是枚举，splatting 传 `[bool]` 会 `Invalid cast`，必须传字符串 `'True'`/`'False'`；且只在**有记录**时才改（否则会把规则禁用 = 过度还原） |
| 通道结果 | 公钥删掉后 `Permission denied (publickey,password,keyboard-interactive)` —— 免密确实被销毁；`password` 仍在候选里属**故意保留** |
| 残留自检 | 回滚结束自动打印：服务是否存在 / 端口是否释放 / 本通道防火墙规则条数 / 授权文件是否还有本通道公钥 / `LimitBlankPasswordUse` / journal pending 条数 / 临时文件 |

> 断连后无法远程验证剩余项，这是 destroy 的**正常现象**，也说明"先 VM 后宿主机"的顺序是对的。

## 五、当前基线快照（`vm-diag.ps1` 一次看全，约 50 s）

| 维度 | 基线值 |
|---|---|
| 服务 | `Running / Automatic / LocalSystem`，binary `%ProgramFiles%\OpenSSH\sshd.exe` |
| 监听 | 仅 `172.16.100.2:22`、`127.0.0.1:22`（同一 pid） |
| `sshd -T` | `PasswordAuthentication yes`、`PermitEmptyPasswords no`、`GatewayPorts no`、`PermitTunnel no`、`AllowTcpForwarding yes` |
| 防火墙 | 5 条覆盖 TCP 22 的 Allow，`remote` 全 = `172.16.100.1,127.0.0.1` |
| 拓扑 | `172.16.100.0/24` 邻居只有 `.1` + 广播 |
| 授权文件 | `administrators_authorized_keys` 1 行，`ssh-ed25519` + 注释 `workbuddy-hos-winvm-tunnel` |
| ETW | 近 12 条全是 `Accepted publickey ... ED25519 SHA256:74Ke67fq…`，无一条 `Accepted none` |

两个非阻塞事实：① 若 VM 上有代理软件（如 `0.0.0.0:2080 → 127.0.0.1:2080` 的 portproxy），它与 22 无关，但确实"对 Internal 网段开放"，VM 网卡改桥接时要一起复核。② journal 里的 `version` 字段记的是**账本创建时**的脚本版本，不是当前版本；看当前版本读脚本头 `$SCRIPT_VERSION` 或日志首行。

## 六、未闭环项（诚实标注）

- **非初始环境的逐场景实测**：`账户有密码` / `已有免密通道` / `sshd 已装并运行` 三种变体有对应代码路径与 undo，但未逐一跑过全流程。
- **`-EmptyPasswordMode yes`** 路径未实测；它等价于允许匿名登录，仅作为取舍选项存在，正常不应使用。
- **`vm-diag.ps1` 的防火墙段**依赖 `<portfilter> | Get-NetFirewallRule` 这条唯一正确管道（见 pitfalls 第 5 条）；换成别的写法会静默给出"没有规则"的假阴性。
