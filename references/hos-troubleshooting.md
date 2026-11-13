# 排错表

先按现象定位，再决定是否动系统。绝大多数"连不上"都能用一句命令判开：`Get-Service sshd` + `Get-NetTCPConnection -LocalPort 22`。

| 现象 | 根因 | 处理 |
|---|---|---|
| `Bad owner or permissions .../.ssh/config` | hmdfs 属主 ≠ 进程 uid | 删 `~/.ssh/config`，全程用 `-i` + `-F /dev/null` |
| `Add-WindowsCapability` 报 `0x800f0954` | 连不上 Windows Update | 用默认的 MSI 方式，不要碰可选功能 |
| 卡在 `2/9 安装 Add-WindowsCapability` 长时间不动 | WU 排队 / 无外网到微软 | Ctrl+C 后重跑（默认已改 MSI）；或手动下 msi 用 `-MsiPath`；最坏 `-InstallMethod Zip` |
| `msiexec` 报 `1618` | 还有安装操作在跑（多半是上一步 DISM 余波） | 脚本自动等 15s×3 重试；仍失败重启 VM 再跑 |
| `msiexec` 报 `1603` | 权限 / 磁盘 / 包损坏 | 看 `wb-msi-install-<ts>.log`；重下 msi（校验文件头 `D0CF11E0`） |
| 启动即报 `The variable cannot be validated ... InstallMethod` | 内部 `$script:` 变量与 `ValidateSet` 参数同名 | 见 [pitfalls 第 2 条](hos-pitfalls.md)；此类错误**零副作用**，换新脚本重跑即可 |
| 日志出现 `PFRO` / `PendingFileRenameOperations` | **不是故障**：下次启动才执行的文件改名队列，无进程可结束 | 不用管；只有 `CBS`/`WU` 待重启标记才需要重启 VM |
| 按文档去 `%ProgramData%\ssh\Logs\sshd.log` 找不到日志 | MSI 版 10.x 不写文件日志，走 ETW | `Get-WinEvent -LogName OpenSSH/Operational -MaxEvents 50`；`[preauth]`=认证前被拒，`[postauth]`=已认证 |
| `所有下载源都失败` + 日志有 `文件头不匹配（D0CF11E0A1B11AE1 != D0CF11E0）` | **假失败**：魔数校验 bug，包其实是好的 | 见 [pitfalls 第 27 条](hos-pitfalls.md)；或直接拿已下好的包 `-MsiPath $env:TEMP\OpenSSH-Win64.msi` |
| `github.com` 的 HEAD 通但下载卡住 | 直连被限速（实测 GET 20s 无数据） | 用默认源顺序（`gh-proxy.com` 优先），或 `-DownloadUrl`，或 `-ProxyUrl` |
| winget 不可用 | 精简系统无 App Installer | 走 zip 多镜像下载 |
| 所有镜像都下载失败 | 网络 / 代理限制 | 在能上网的机器下 `OpenSSH-Win64.zip`，拷入 VM 后 `-OpenSSHZipPath` 重跑 |
| sshd 改配置后起不来 | 指令写进 `Match` 块 / 重复行 / 拼写错 | `sshd -t` 定位；从 `.bak-<时间戳>` 回滚 |
| 端口改了却连不上 | 防火墙没同步 | 规则 `LocalPort` 改成同端口；`Get-NetTCPConnection -LocalPort <p>` 确认监听 |
| `Permission denied (publickey)` | 公钥放错文件 / ACL 过宽 / 文件带 BOM | 管理员→`%ProgramData%` 那个文件；SID 收紧 ACL；存 ASCII |
| 配了密钥仍要密码 | ACL 过宽或授权文件编码异常 | 重置 ACL；文件 ASCII 无 BOM |
| 能登录但**日志是 `Accepted none`** | `PermitEmptyPasswords yes` ⇒ 匿名登录 | 见 [pitfalls 第 1 条](hos-pitfalls.md)，这是最危险的"绿着错" |
| 服务 `STOPPED` / 开机不自启 | 未设 `Automatic` | `Set-Service sshd -StartupType Automatic; Start-Service sshd` |
| 远端命令只回显不执行 | 默认 shell 是 cmd，`;` 不分命令 | 用 `&`/`&&` 或显式 `powershell -Command` |
| **ping 通、22 端口超时（DROP 非 refuse）**，但 5985 正常 | ① 网络档被改成 **Public**（22/3389/445 规则多为 Domain,Private，切 Public 后全被丢）；② sshd 未运行/未装且无放行规则 | 见下方"22 端口 DROP" |
| `ssh` 直接 `Operation timed out` | 同上（DROP，非服务拒绝） | 同上；**不要**误判为密钥或 ACL 问题 |
| VM 上 `22` 通、宿主机却连不上 | 防火墙 `RemoteAddress` 收了、但宿主机 IP 不在白名单 | `-AllowFrom` 补上宿主机在 VM 内网段的地址 |

## 22 端口 DROP 诊断与修复（VM 本机管理员 PowerShell）

**先取证**（4 条输出贴回来即可判定根因）：

```powershell
Get-NetConnectionProfile | Format-Table Name,InterfaceAlias,NetworkCategory -Auto
Get-Service sshd -ErrorAction SilentlyContinue | Format-List Name,Status,StartType
Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue
Get-NetFirewallRule -DisplayName '*OpenSSH*' | Format-Table DisplayName,Enabled,Profile,Direction,Action -Auto
```

**再修复**（幂等，可整段跑）：

```powershell
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private   # 关键：Public→Private
Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service sshd -ErrorAction SilentlyContinue
Get-NetFirewallRule -DisplayName '*OpenSSH*' | Set-NetFirewallRule -Enabled True -Profile Any -Action Allow
Get-NetTCPConnection -State Listen -LocalPort 22
```

- `Get-Service sshd` **为空** ⇒ sshd 根本没装（常见于回滚快照）→ 跑 `winvm-sshd-oneclick.ps1` 重装。
- **从外部无法区分"服务未运行"和"防火墙 DROP"**：两者都表现为超时。必须在 VM 侧取证。
- 3389 同时不通时 **RDP 也进不去**，只能用虚拟机控制台（Hyper-V/VMware/VirtualBox 窗口）操作。

## 症状 → 该读哪份文件

| 症状 | 读 |
|---|---|
| 能连但不敢确定是不是真公钥 | [verification.md](hos-verification.md) 第三节 |
| destroy 报某条失败 | [rollback-contract.md](hos-rollback-contract.md) undo 类型表 |
| 重跑后 journal 条数爆炸 | [rollback-contract.md](hos-rollback-contract.md) 三道闸门 |
| 不知道现场到底是什么状态 | `-Continue` 或 `scripts/vm-diag.ps1` |
