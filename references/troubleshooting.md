# 问题百科（现象 → 根因 → 处置）

按「哪一步出的问题」查。每行都能落到一个具体判据或一条命令。
旧版 127 行历史 run 记录已归档到 `references/legacy/`；本文件只留**可复用的判据与解药**。

## 第 1 步：建 SSH 通道

| 现象 | 根因 | 处置 |
|---|---|---|
| 打印命令后 `exit 2` | **正常**：首次部署必须用户粘贴一次 | 去 VM 管理员 PowerShell 粘那一行，回来重跑 `deploy.sh`；1a 会判 READY 直接跳过 1b~1d |
| `拿不到 winvm-sshd-oneclick.ps1 的远端地址` | 该 tag 的 release 没带这个资产 / gitee API 不可达 | 发新版（资产含 ps1）；或 `SSHD_SCRIPT_URL=<直链>` 显式指定 |
| `远端脚本地址不可达（HEAD ≠ 200）` | 同上，或代理/网络 | 同上；先在宿主 `curl -sIL <url>` 自证 |
| 用户执行时报 `PublicKey 未提供或格式不对` | 粘贴时公钥被换行截断/引号丢失 | 重新复制**整行**；公钥在单引号内 |
| 用户执行后仍连不上 | sshd 装了但监听/防火墙/网络档不对 | VM 里跑只读体检：`powershell -File C:\ProgramData\WinVMDeploy\winvm-sshd-oneclick.ps1 -Continue` |
| 重建时报 `Cannot start service sshd`，且 [1/9] 显示 `OpenSSH.Server 能力状态：NotPresent`、[2/9] 显示 `sshd 服务已存在，跳过安装` | **僵尸服务壳**：`-Rollback` 卸掉 capability（连 `System32\OpenSSH\sshd.exe` 一起没了），但保留了 sshd 服务注册项。旧版 [2/9] 只看 `Get-Service sshd` 就跳过安装，[3/9] 拿着无二进制的服务去 Start ⇒ 必失败 | v2.0.0 起 [2/9] 判据改为「服务在 **且** `sshd.exe` 在位」，否则 `sc.exe delete sshd` 清壳后走正常安装。**旧包上 VM 时**手动清壳：`sc.exe stop sshd; sc.exe delete sshd`，再重跑脚本 |
| 长命令粘贴后 PowerShell 报 `Unexpected token '\System32\...'` / `exe_exi` 之类被截断 | 命令经 **Git Bash / MSYS** 传递时双引号被吃掉，`"$env:WINDIR\..."` 变成裸 token | 给用户的命令**在 PowerShell 里粘**；必须经 bash 时全用单引号且路径写死（`C:\Windows\...`），或改用 `-PublicKeyFile` 避开含空格的长公钥 |
| 多行命令粘进去后 PowerShell 报 `行:1 字符:NN`，多条语句挤在同一条报错里 | 终端把多行粘贴**折叠成单行**（换行丢失），`if { }` 块被压平后语法崩 | **给用户的命令一律写成单行 `;` 串联**（块体压成 `{ a; b }` 也可），永不依赖换行 |
| 三轮都没建起来 | 密钥 / 网络 / 权限三者之一 | 看 `1b.*`/`1c.*` 各轮日志；VM 侧 build 段应有 `[+]` 行而无 `[x]` |
| `ping` 100% 丢包 | VM 整机离线（关机/暂停/断网） | 用户在 VM 管理端开机/恢复。脚本救不了，别循环重试 |
| **每步都报 `NO_CHANNEL`，但 `ping` 通、`health=200`** | 通道后端默认值退化成 `key`（**v2.0.0 重构引入的回归**，v2.0.2 已修）。鸿蒙宿主机上 OpenSSH 二进制会相位性挂在**认证段**（`rc=124`、stderr 为空），而 `ssh2-conn.mjs ping` 同一秒仍是 `pong ready` | 先看 `vm-conn.sh` 的 `VM_SSH_BACKEND` 默认值须为 **`auto`**；临时绕过：`VM_SSH_BACKEND=ssh2 bash scripts/deploy.sh`。注意 `All configured authentication methods failed` 是**钥配错**，与本条不同 |
| 粘 `irm\|iex` 备选命令后满屏 `意外的属性 CmdletBinding` / `表达式或语句中包含意外的标记 param` / `赋值表达式无效`（`Create` 阶段就抛） | ① 载荷文件带 **UTF-8 BOM** 或首行是 `#requires` ⇒ `[scriptblock]::Create` 的解析器不把 `param` 当参数区；② `Invoke-RestMethod` 对 text/plain 返回 `string[]`，`Create` 按 `$OFS`（空格）**拼成一行** | **脚本一行都没执行**，别去查密钥/网络。v2.0.3 起：载荷保持 UTF-8 无 BOM、版本门槛改运行期检查、1c 备选命令内联 `[string]::Join([char]10,@($s))` 归一化；门禁 `iex-safe` + M21/M22 双锁。旧包临时绕过：改用 `-File` 主路径（`Invoke-WebRequest -OutFile` + `powershell -File`，不走 scriptblock） |

**通道判定只用新建连接实测**（`ssh2-conn.mjs ping`）。`health=200` 是**长连**健康，不等于新建可用——
两者分叉正是 WEDGE 的指纹。

| **1p 提示 `PASSWORD_AUTH_UNAVAILABLE`（`auth=empty-password`）** | 该账户**无密码**，但 Windows 出厂两道策略挡住了空口令网络登录：sshd `PermitEmptyPasswords no` + 本地策略 `LimitBlankPasswordUse=1` | 这是确定性的策略拒绝，不是脚本缺陷。要放开（需管理员、且降低安全性）：① `Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' LimitBlankPasswordUse 0`；② sshd_config 设 `PermitEmptyPasswords yes` 后 `Restart-Service sshd`。**否则走 1c**：VM 内以管理员跑一次 oneclick 即可，之后免密 READY 就不再走本路径 |
| **1p 提示 `ADMIN_NO` 但仍 PASS** | 登录账户不在 Administrators 组 | 这不是失败：`Match Group administrators` 不命中时 sshd 读的是**用户级** `~\.ssh\authorized_keys`，而它本来就不需要管理员权限 ⇒ **免密登录照样能建成**。但后续需要管理员能力的步骤（防火墙/服务/Defender）仍会要人工提权 |
| **1p 的 S1 明明写了公钥、key 回验仍不通** | sshd_config 把 `AuthorizedKeysFile` 指到了别处，或 `PubkeyAuthentication no`，或 ACL 策略拦 | 脚本会自动降级 S2（在口令会话里跑 oneclick 修配置 + 重启 sshd）再回验一次；S2 也不通才退 2。手工排查：VM 内 `Get-Content C:\ProgramData\ssh\sshd_config | Select-String 'AuthorizedKeysFile|Pubkey'` |
| **1p 报 `timeout: exec _askpass_env: No such file or directory`** | 老版 `vm-conn.sh` 把 `timeout` 包在 shell 函数外层（`_ssh_t _askpass_env ssh`）| v2.2.0 已修为 `_askpass_env _ssh_t ssh`；若在旧技能包上遇到，直接手工 `ssh` 建通道后重跑（免密 READY 就不再走口令路径） |
| **`prepare-vm` 报 `fwSsh:MISSING` 但规则确实在** | v1.4.31 及更早：① 探测脚本把 `WinVM-SSH-<undefined>` 当规则名（`cfg.vmSshPort` vs `sshPort` 字段错位）；② 降级路径用 `netsh ... name=`，而规则的 **Name 是 GUID**、`WinVM-SSH-22` 只是 DisplayName | v1.4.32 已修（`normalizePorts` + 注册表直读 `Name=` 字段）。判据现在是三态 `OK/INACTIVE/MISSING`，`INACTIVE` 表示规则存在但被禁用/方向反/阻断 |
| **直调 `node delivery/bootstrap.mjs ...` 报 `All configured authentication methods failed`** | 绕过技能层 `_common.sh` ⇒ 没注入 `WINVM_VM_KEY`，默认候选链拿到了另一把钥（如 GitHub 钥） | v1.4.32 已把 `id_ed25519_winvm` 排到候选链首位；临时绕法：`WINVM_VM_KEY=$HOME/.ssh/id_ed25519_winvm node delivery/bootstrap.mjs ...` |
| **1p 报 `timeout: exec _askpass_env: No such file or directory`** | 老版 `vm-conn.sh` 把 `timeout` 包在 shell 函数外层（`_ssh_t _askpass_env ssh`）| v2.2.0 已修为 `_askpass_env _ssh_t ssh`；若在旧技能包上遇到，直接手工 `ssh` 建通道后重跑（免密 READY 就不再走口令路径） |

## 第 2 步：取包 + 装 host 端

| 现象 | 根因 | 处置 |
|---|---|---|
| `SHA256_MISMATCH` | 源内容与旁挂不一致（事故级） | **别重试硬跑**。核对 release 资产与本地 pack 是否同一份 |
| `MANIFEST 对账失败` / undeclared | 陈旧包层，或发布白名单漂移 | 重新取包（不要 `SKIP_DOWNLOAD=1`）；持续则查母项目 `pack-release.mjs` 白名单 |
| gitee 下载中断 | gitee 302→foruda 一次性签名，断点续传必坏 | 脚本已内建「整文件重试」，别加 `-C -` |
| `install-host` rc≠0 且日志有 `errno=12` | 宿主内存压力下 node 崩（脆弱 node） | 重跑本步；排障时用 `node -e` 冒烟确认解释器 |
| `connector-states ⚠` | 平台账户态噪声 | 忽略，不参与判据 |
| `connector skills < 8` | skills 没落到 connectors 目录 | 在包根跑 `node delivery/deploy-shared-skills.mjs` |

## 第 3 步：起 tunnel 并验证

| 现象 | 根因 | 处置 |
|---|---|---|
| tunnel 日志连续 `All configured authentication methods failed` | `vm-conn.json` 的 `identityFile` 指向未被授权的钥（**单值、无回退链**） | 3a 已自动对齐到 `WINVM_VM_KEY`；仍失败就看 3a 输出里 `→` 的目标文件是否存在 |
| 手测 `ssh2-conn.mjs ping` 报 `All configured authentication methods failed`，但 `ssh -i` 手连成功 | 手测**漏了 `WINVM_VM_KEY`**，ssh2 回落到默认 `~/.ssh/id_ed25519`（不存在/不对）。这是**假红**，通道其实健康 | 手测必须带 `WINVM_VM_KEY=$HOME/.ssh/id_ed25519_winvm`；看错误是「握手超时」还是「认证失败」：前者=WEDGE，后者=钥配错 |
| `health` 反复 000 | daemon 没起，或到 VM 18443 不通 | 看 `~/.workbuddy/winvm/tunnel.log`；VM 端服务在不在听由第 4 步 4c 判。**不要重启 VM** |
| `curl: (52) Empty reply from server` + `health=000`，但 `ping` 0% 丢包、`ssh2-conn ping` 通、tunnel daemon 存活 | **VM 端 winvm 服务假死**：VM 网络抖动/挂起恢复后进程还在，但 socket 已死（ssh 转发接上就被对端 close）。实测 **restart 隧道无效**（2026-11-16） | 重跑 `deploy.sh --only 4`（4b 会重装并重启 `WinVMBridge.Service`）；赶时间可在 VM 里 `schtasks /End /TN WinVMBridge.Service & schtasks /Run /TN WinVMBridge.Service`。**不要重启 VM** |
| restart 后第 4 步立刻握手失败 | restart 重建到 VM 的 ssh 连接，与第 4 步抢握手槽（2026-11-16 实证） | 3b 已改「health 已 200 就跳过 restart」；第 4 步另有 60s 健康窗门禁 + 一次有界重试 |

## 第 4 步：装 VM 端 + 起服务

| 现象 | 根因 | 处置 |
|---|---|---|
| `ssh2 连接错误: Timed out while waiting for handshake` | **WEDGE**：guest sshd 握手段挂起（TCP 通、长连活、新建死）。不是网络层 | 按红线**不重启 VM**。先做三段取证（见下），确认是 sshd 停摆后可**经隧道重启 sshd**（不重启 VM），再 `--only 4` |
| 同上但 ping 也丢 | VM 离线 | 用户开机；不是脚本问题 |

### WEDGE 三段取证（决定「等」还是「修」）

不要靠单次超时下结论，三个探针同做：

| 探针 | 健康态 | 停摆态 | 说明 |
|---|---|---|---|
| `ping` | 0% 丢、0~2ms | 100% 丢 | 100% 丢=VM 离线，不是 WEDGE |
| 裸 TCP 连 :22 + 读 banner | 连接 <100ms 且立刻收到 `SSH-2.0-...` | **连接 7ms 但 12s 零字节** | 内核完成握手、sshd 未走到发 banner |
| 宿主侧 `curl :18443/health` | 200 | **也是 200** | 长连旧会话不受影响 ⇒ **health≠新建可用，别拿它当通道判据** |

静默 180s 后单次探测仍握手超时 ⇒ 排除「探测风暴把 sshd accept 槽抽干（MaxStartups）」；同时 VM 内 `ssh 127.0.0.1` 也卡死 ⇒ guest sshd 自身停摆（非宿主 NAT）。

修复（2026-11-16 实证有效，**不重启 VM**）：隧道长连还在时，经 MCP 下发 `system.service.control{name:"sshd",action:"restart"}`（L1，直调；约 1s）。重启只杀**新建**连接的接受能力，已建立的长连存活（隧道不断、`health` 持续 200），所以修完立刻 `ssh2-conn.mjs ping` 就能回到 `pong ready`。
| prepare-vm 报 node 缺失 | VM 内 node 走 nvm-windows，切版本会让全局 CLI 消失 | 重跑 4a（幂等）；仍缺则查 VM 内 `nvm list` |
| setup 超 420s 未监听 | 服务「僵而不绑」：8K 工作集、不占端口 | `schtasks /End /tn WinVMBridge.Service` 后 `/Run` |
| `task_state=Ready` 但服务其实在跑 / GUI 报 `SESSION_UNAVAILABLE` | schtasks 包装器退出后任务态回 Ready；实例落 Session 0 | 判据看 `listen_count=1` + `health_http=200`；GUI 需 `/End`+`/Run` 重触发到交互会话 |
| 拆除后残留僵尸 node（8K、不绑端口、taskkill/Process.Kill/CIM 全免疫） | 老版本 VM-START 遗留 | 只能 VM 内 `shutdown /r /t 5 /f`（**唯一需要重启的场景，且由用户在 VM 内执行**），再重跑 |
| **4c 报 `browser_tools=ERR:http-502`**（第 5 步同报 `browser=ERR:http-502`） | `agent-browser` 未装到 VM（4a 的 **DB-7** `npm i -g` 失败，安装侧按「可选依赖」降级不阻断） | 重跑 `--only 4`（4a 的 DB-7 会补装）；看 4a 日志的 `DB-7` 行；不需要该工具面则 `SKIP_UPSTREAMS=1` |
| **4c 报 `browser_tools=ERR:http-404`**（第 5 步同报 `browser=ERR:http-404`） | vm-service 是**旧版**（无 `/mcp/<id>` 路由）——最常见成因：`--only 4` 推了缓存里的旧 dist | 确认包根版本（2a 的 `版本 =`）与 VM 上 `C:\WinVMBridge` 的 `MANIFEST-deploy-*.txt`；用规范包重装（`VMDEPLOY_FORCE_FETCH=1`） |
| **4c 报 `desktop_tools=75!=25`**（第 5 步同报 `desktop=75!=25`） | 上游版本变了（白名单外工具数变），或有人改过 `DEFAULT_DESKTOP_TOOL_ALLOWLIST` | 按实际暴露数设 `EXP_DESKTOP_TOOLS`，**不要放宽成 `>=1`**（那就失去发现白名单漂移的能力） |
| **4c / 第 5 步报 `ERR:rpc-*` / `ERR:URLError`** | 上游进程起不来（缺原生二进制、被杀软拦） | 看 VM 侧 `C:\WinVMBridge\logs` 与该步日志尾部；`/health.upstreams[].lastError` 有同样信息 |

## 第 5 步：verify

| 现象 | 根因 | 处置 |
|---|---|---|
| `VERIFY=INCOMPLETE ENV_WINDOW=1` | 通道瞬态窗，取不到 VM 终态行。**环境问题，非功能失败** | 等健康窗只重跑 `verify.sh`；不宣称 PASS 也不误报 FAIL |
| `total-33!=34` / `skip-N!=4` | 探针项数被改动 | 同步改 `deploy-5-verify.sh` 的 `EXP_TOTAL/EXP_SKIP`。**刻意告警，别放宽** |
| `no-count` / `meter-missing` | 探针日志里找不到 `x/y` 计数 ⇒ 无法核验 | 看对应 `logs/<probe>.log` 尾部；探针崩了就是真 FAIL |
| 单项探针 > 300s | 服务端闸/网络 | 查该探针日志；`EXECUTION_TIMEOUT`（服务端）与 `timed out`（客户端）两形态别混 |
| `C3 storage.disk.list` / `C4 app.inventory.list` 恰好 `durationMs≈30200` 后 FAIL | VM 刚开机/刚从挂起恢复时的**冷启**：首调 WMI / 注册表全扫超过服务端 30s 预算。热态实测仅 2.7s / 3.3s | **不是缺陷，别改判据**（否则会掩盖真慢）。等 2~3 分钟重跑 `--only 5` 即 20/20。判据：单独 `command <tool>` 复调 < 5s ⇒ 确认冷启 |
| `VERIFY=FAIL:upstream`（第 5 步上游判据） | 服务 health=200（说明服务活着）但上游工具面取不到计数 ⇒ 真缺陷，不是环境窗 | 同 4c 的 `ERR:http-502/404/rpc-*` 处置；`SKIP_UPSTREAMS=1` 可显式跳过 |
| 第 5 步报 `⚠ 服务 health 非 200 ⇒ 归入通道瞬态窗` | 隧道/服务此刻不可用 | 该段记 `ENV_WINDOW`，整体给 `VERIFY=INCOMPLETE`（不判功能失败）；等健康窗只重跑 `verify.sh` |

## 卸载

| 现象 | 根因 | 处置 |
|---|---|---|
| 通道不在，第 2 步 `exit 2` | **正常输入**，不是故障 | 按提示在 VM 里手工删服务与目录；**绝不为此重建通道** |
| `HOST_PASS<11` 或 `HOST_FAIL>0` | host 清理项失败 | 看 `uninstall-host.log` 的 `[FAIL] HOST` 行 |
| **1c 报 `mcp.json 仍留 winvm-browser,winvm-desktop`** | **旧包卸载新装**：`uninstall.mjs` 的键表按包版本固化（V1.4.30 只有 `winvm`/`winvm-a2a`），装过含上游工具面的新包就漏 | v2.1.0 起 1c 自动按 `^winvm$|^winvm-` **命名空间兜底**并打印「卸载器未清的条目已兜底移除: …」——看到这行是兜底生效，不是失败。旧技能层遇到则手工删这两条或跑 `--only 1` |
| **2c 后 `UPSTREAM_LEFT=agent-desktop`** | `npm uninstall -g` 失败：npm 不在 PATH（**SSH 会话只拿机器 PATH，`C:\nodejs` 在用户 PATH**）或文件被占用 | ps1 与 2d 终态命令均已自拼 `Machine;User` PATH；仍失败看 `vm-remove.log` 的 `[WARN]`，或加 `--keep-upstreams` 声明保留 |
| `VM_PHASE_IN_HOST≠0` | `.env`/`vm-conn.json` 没屏蔽干净，host 相位跑成了双端 | 已有 trap 还原；若复现说明还有第四处 VM 目标来源，需补屏蔽 |
| 第 3 步 `TUNNEL=PENDING_USER` | 通道不在，只能用户在 VM 里跑 `-Rollback` | 照打印的那一条执行；宿主侧私钥/known_hosts 已同时清理 |
| 第 3 步 `3c FAIL health=000`（等满 30 轮 / 123s），但第 4 步 4b/4c 全 PASS | **从零部署的正常中间态**被当成故障：`/health` 是 VM 端 winvm service 的口径，而该服务由并行的第 4 步安装，此刻 18443 后面没人应答 | v2.0.0 起 3c 判据改为「本地端口在监听 + daemon 存活」，`health` 只作信息位（第 5 步才验端到端）。旧包上遇到就 `--only 3` 重跑（4b 已完成，此时 health 已是 200） |
| 第 3 步报 `daemon=0(pid=57857127001...)` 这种一长串数字 | `tunnel.pid` 是 **JSON**（`{"pid":57857,...}`），`tr -dc '0-9'` 把全部数字拼成一串 | 用 `tunnel_pid`（sed 取 `"pid":` 后数字）/`tunnel_alive`，勿手写解析 |

## 环境/工具类

| 现象 | 根因 | 处置 |
|---|---|---|
| 内联 PowerShell 报 ParserError / `$_` 变怪值 | 本地 bash 先展开了 `$`，或远端壳是 Git-Bash/MSYS | 复合逻辑写 `.ps1` → scp → `powershell -File`；短片段 `-EncodedCommand`。一律经 `ps-run.sh` |
| `-File` 载荷 rc=124 且**零输出** | 载荷耗时 > 超时窗。载荷自身实测 47~56s | 用 `VM_PS_TIMEOUT`(180s) 而不是 `VM_SSH_TIMEOUT`(25s)。**先量载荷耗时，勿先怀疑通道** |
| 计数判据恒失败（`HOST_FAIL=0 0` 之类） | `grep -c ... \|\| echo 0`：零匹配吐 `0` 且 rc=1，兜底再追加一个 0 | 一律 `awk '{n++} END{print n+0}'`；selfcheck 的 `no-grep-c` 断言会拦住 |
| Skill 工具加载出旧版 SKILL.md | 同名 skill 重复注册命中旧备份 | `grep '^version:' SKILL.md` 先自证版本；清理 `~/.workbuddy/skills/` 下重复/备份目录后重启会话 |
| 宿主侧要删文件 | 鸿蒙沙箱 `rm` 不可靠 | `node -e 'fs.unlinkSync(...)'`；禁 `rm -rf <目录>` |
