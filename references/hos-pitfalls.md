# 坑与陷阱（172.16.100.2 实测沉淀）

按"会让人得出错误结论"的程度排序，前 5 条最危险。

## 1. 【头号】`PermitEmptyPasswords yes` = 匿名登录，公钥彻底失效

- **机理**：OpenSSH `auth2-none.c` —— 「账户密码为空 **且** `permit_empty_passwd=yes`」时 **none 认证直接成功**。而 ssh 客户端**总是先发 none**，服务器一接受，后续 `publickey` 根本不会被执行。
- **现象**：`ssh` 能连、能跑命令、`verify` 全绿，**但服务端日志里全是 `Accepted none`**，一次 `Accepted publickey` 都没有 —— 所谓"免密通道"实际是"匿名通道"。
- **为什么极难发现**：三处都"看起来对"——① 能登录 ② 命令能跑 ③ 验证脚本通过。唯一可靠判据是**服务端日志里的认证方法**，或 `verify-tunnel.sh` 第 2 段（none 必须被拒）。
- **实测对照**（同一台 VM，只改这一行）：

  ```
  PermitEmptyPasswords yes → 10:07:46 Accepted none for User from 172.16.100.1
  PermitEmptyPasswords no  → 10:08:22 Accepted publickey for User from 172.16.100.1 ED25519 SHA256:74Ke67fq…
  ```

- **推论**：「允许空密码密码登录」与「禁止匿名登录」是同一个开关，无法只开一半。空密码账户只能走公钥。
- **附带陷阱**：`ssh -i /dev/null` 在"空密码服务器"上**也能登录**（BatchMode 会自动用空密码）。任何"免密测试"都必须显式 `PreferredAuthentications=publickey`。

## 2. `$script:` 变量名不能与带 `Validate*` 特性的参数同名

参数 `[ValidateSet(...)]$InstallMethod` 在脚本作用域内就是 `$InstallMethod`，而 `$script:InstallMethod = ''` 是**同一个变量**（PS 变量名大小写不敏感，`$script:` 指的就是脚本作用域）。`Validate*` 不只校验传参，**对变量的每次赋值也校验** → 初始化那一行赋空串立刻抛 `ValidationMetadataException`，脚本**一行代码都没执行**就退出。内部状态另起名字（`$script:InstallUsed`）；改完必须扫一遍「param 块所有带 `Validate*` 的名字 × 脚本体 `$script:<同名>` 赋值」。

## 3. 在 SSH 会话里再起 `ssh.exe` 子进程 = 可能永久挂住

build 的"none 认证探测"若直接 `& ssh.exe ...`，而 build 本身就跑在 ssh 会话里，子进程默认继承控制台 stdin，**非交互会话**下会卡在等待输入（实测 >4 分钟不退出），或退化成 `Host key verification failed` / `-F NUL` 打不开 → 日志长期是"**无法判定（连接异常）**"。**一个永远黄灯的探测等于没有探测。**

正解："**先看生效配置、再决定要不要联网**"——`sshd -T` 拿到 `PermitEmptyPasswords`（`no` ⇒ none 在协议层就不可能通过，直接判定并跳过网络）；只有算不清时才发起带 `-n`（stdin=NUL）+ `WaitForExit(8000)` 强杀的子进程探测。**推论**：任何脚本内嵌套调 ssh 的地方都要 `-n` + 硬超时，且 `WaitForExit(timeout)` 返回值必须判，否则等于没设超时。

## 4. 占位符绝不能参与字面比较

宿主机用 `s.replace('__PUBKEY__', pub)` 全局注入公钥后，脚本里原有的 `$PublicKey -eq '__PUBKEY__'` 会变成 `-eq '<真实公钥>'` → **恒真** → 正式执行直接 `throw`、DryRun 误报"公钥未填入"。一律改用**格式判断**（`-notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)'`）。

## 5. 防火墙规则枚举：三条管道里只有一条是对的

| 写法 | 结果 |
|---|---|
| `Get-NetFirewallRule -Direction Inbound \| Get-NetFirewallPortFilter` | **静默返回空** → 292 条入站规则里一条 TCP 22 都匹配不到，得出"没开防火墙"的**假阴性** |
| `<portfilter> \| Get-NetFirewallAddressFilter` | `AmbiguousParameterSet` 直接抛错 |
| `<portfilter> \| Get-NetFirewallRule` → `Get-NetFirewallAddressFilter -AssociatedNetFirewallRule <rule>` | ✅ 正确，5 条全部解析出 `remote=172.16.100.1,127.0.0.1` |

另注：**不要用无参全量 `Get-NetFirewallAddressFilter`**（实测 8 分钟跑不完）；逐规则 pipe 也要几十秒。用 `portfilter → rule` 单向流水约 10 s 拿端口清单，再逐条解析地址约 20 s。`$arr += $cimInstance` 在 PS 5.1 会报 `op_Addition`，别用。

---

## 6-15：环境与编码

6. **hmdfs 不支持 `~/.ssh/config`**：文件属主恒为 `20001006`、进程是 `20020171` → `Bad owner or permissions`，会**拖垮所有 ssh**（含 github/gitee）。不写 config，一律 `-F /dev/null -i <key> -o IdentitiesOnly=yes`；误建立即删。
7. **hmdfs 上 `rm`/`mv` 被 shim 拦截**（`bad interpreter`）：用 `python3 -c "import os; os.remove(...)"` / `os.replace(...)`；`chmod` 也可能被忽略。
8. **Windows 默认 shell = cmd.exe**：`;` 不分命令，用 `&`/`&&` 或显式 `powershell -Command`。
9. **三层引号会吃掉 `$false`**：`Unregister-ScheduledTask -Confirm:$false` 经 `ssh → cmd → powershell` 后 `$false` 变字符串 → 参数绑定失败 → **整段脚本因 ParserError 一行都没执行**。删除计划任务最省事的是 `schtasks /Delete /TN <name> /F`。
10. **编码两坑**：① 复杂远端脚本用 `powershell -EncodedCommand <base64(UTF-16LE)>`，避开 bash→cmd→PS 三层引号；② **`.ps1` 含中文必须 UTF-8 with BOM** —— 无 BOM 时 PS 5.1 按 GBK 解析，中文注释会破坏字符串引号，报"意外的标记/字符串缺少终止符"（实测无 BOM 报 3 处语法错，加 BOM 后通过）。
11. **`#!` 转义**：写 shebang 或路径时 `echo` 会解释反斜杠，用 `printf '%s\n'`。
12. **`\a` 之类转义让字符串变样**：`echo "ssh\administrators"` 会得到 `sshdministrators`。改 `printf`。
13. **脚本头 `$SCRIPT_VERSION` 是判版本的唯一权威**：跑之前先看一眼日志首行 `wb-tunnel vX.Y.Z`。用旧版本去验证新修复，会得出"修复无效"的错误结论。
14. **默认没有 `pwsh`**：Windows 只带 `powershell.exe`（5.1），PowerShell 7 需另装，且 DISM 模块在 7 下常加载失败。
15. **"粘贴执行"与"带参数运行"互斥**：交互式会话里的 `param(...)` 没有命令行绑定，整段粘贴后 `-DryRun`/`-Rollback` 一律无效（等于总跑正式分支）。要预演或回滚必须落成 `.ps1` 文件再用 `-File` 调用。

## 16-24：Windows 服务与配置

16. **`sshd -t -f <副本>` 可零风险预演**：先把目标配置写到 `%TEMP%` 再校验，能验证生成逻辑而不碰真实文件、不重启服务（DryRun 就是这么做的）。
17. **改 sshd_config 后必须 `Restart-Service sshd`**：Windows OpenSSH 不吃 `HUP`；重启会瞬断现有 SSH 连接（远程操作时属正常，重连即可）。
18. **重启必须放全流程最后**：安装 → 启动 → 写配置 → 放公钥 → 防火墙全部完成**之后**才重启。否则远程执行时重启会让后续步骤丢失。
19. **ACL 用 SID，别用本地化组名**（`*S-1-5-32-544` / `*S-1-5-18`）。
20. **管理员公钥落点**：属 Administrators 就必须进 `%ProgramData%\ssh\administrators_authorized_keys`；写用户 profile 等于没写。
21. **MSI 版（10.x）的 sshd 日志不在文件里，走 ETW**：`%ProgramData%\ssh\Logs\` 目录存在但**是空的**，`sshd.log` 根本不生成。排查用 `Get-WinEvent -LogName OpenSSH/Operational -MaxEvents 50`；`[preauth]` = 认证前断开 = 被拒，`[postauth]` = 已认证成功、正常退出。
22. **`PendingFileRenameOperations`（PFRO）不是"挂起操作"**：它是"下次启动早期再改名/删除这些文件"的队列，**没有进程、当前会话内永远不执行**，既 kill 不了也不需要 kill。真正会阻塞安装的是 **CBS `RebootPending`** 和 **WU `RebootRequired`** —— 判定只该看这两个。手删 PFRO 值等于把队列永久丢弃，可能留下半删的 SxS 残件 → 反而更容易 1603。
23. **`msiexec.exe` 常驻是正常的**（MSI 服务宿主）：判"真有安装占用"要看 `Global\_MSIExecute` 互斥体是否被持有，不是看进程在不在。
24. **未装 sshd 与防火墙 DROP 从外部无法区分**：两者都只表现为 TCP 超时（Windows 防火墙默认 drop，不回 RST）。必须在 VM 侧看 `Get-Service sshd` + `Get-NetTCPConnection -LocalPort 22`。

## 25-32：安装、下载与幂等设计

25. **无 ISO 时的安装主力是「MSI 优先」**：官方 `OpenSSH-Win64-v*.msi` + `msiexec /i /qn`（10-40 秒）；zip + `Install-sshd.ps1`；`winget`；`Add-WindowsCapability` **只在显式要求时用**——它走 Windows Update，实测国内长时间卡在 "2/9 安装"不动（`dism /online /add-capability` 同源同慢）。不要要求用户提供 ISO。
26. **下载源要轮询且能明确失败**：单源失败换下一个；全失败要抛错并给手动兜底指令（`-OpenSSHZipPath`），绝不能"看起来装完了其实没装"。
27. **文件头校验要把十六进制串换成字节数**：`'D0CF11E0'.Length` 是 **8**，而它表示 **4 个字节**。旧实现读 8 字节得到 `D0CF11E0A1B11AE1`，再和 `'D0CF11E0'` 比 → 恒不相等 → **把下载成功的正常包全部判成"错误页"**，然后徒劳换完 20 个源，用户只看到"所有源都失败"。正确写法：`$nbyte = $Magic.Length / 2`，取前 `$nbyte` 字节转 hex 用 `StartsWith`。**校验逻辑写错比不校验更糟**——它把成功伪装成失败，还把排查引到"网络"上。
28. **防火墙必须显式 `-Profile Any`**：系统预置 `OpenSSH-Server-In-TCP` 默认只作用于 `Domain,Private`；网络档一旦变 `Public`（重启/换网/未识别网络），SSH 就表现为"服务 RUNNING 但外部 TCP 超时"（实测：ping 1ms、5985 通、22/3389/445 全 DROP）。修法：`-Profile Any` + 网络档改 Private，并加一条独立规则防组策略重置。
29. **幂等要落在"闸门 + upsert"两处**：`Set-NetFirewallRule` 重复调用确实不报错，但每跑一次 journal 就多一条，destroy 会撤十几次（结果对，但审计被噪声淹没、`.bak-*` 堆积）。三道闸门见 [rollback-contract.md](hos-rollback-contract.md)。
30. **幂等不能削弱回滚**：重跑时若把 `before` 也刷新成当前值，destroy 只会恢复到最后一次运行前，而不是最初 —— 这正是"过度/不足还原"的根源。`before` 只写一次，是这条链上最不能动的一环。
31. **审计日志不要跟着回滚一起删**：删了就没法解释"上一步为什么失败"。正确做法是 `status=rolledback` 保留，下次 build 归档成 `history-<ts>.json` 再重开。
32. **慢不等于坏，但要能证明"没卡死"**：长操作必须给 ① 明确预估时间 ② 前置心跳日志 ③ 可中断且中断后能续跑（journal 保证）。用户 Ctrl+C 后重跑应从断点继续，而不是从头再赌一次。

## 33-34：暴露面与验证

33. **"只听内网 + 防火墙收窄"只是配置层结论**，不足以断言"外部进不来"。要四层同时成立：拓扑（邻居表里没有第三台）、监听（不绑 `0.0.0.0`/Tailscale）、防火墙（来源白名单 + 三 profile 默认阻止）、无 portproxy 旁路。判据见 [verification.md](hos-verification.md)。
34. **`AllowTcpForwarding yes` + `GatewayPorts no` 是安全组合**：前者允许已登录用户开 `-R`，后者把远程转发限制在 `127.0.0.1`，不会在 VM 上开 `0.0.0.0` 端口。**不要**把 `GatewayPorts` 改成 `yes` —— 那会让任何持钥会话把 VM 变成对外跳板，直接击穿"只对宿主机开放"。
