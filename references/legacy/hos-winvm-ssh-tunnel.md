
# hos-winvm-ssh-tunnel（SSH 免密通道生命周期 · 已并入 winvm-plugin-deploy）

> **本文定位（v1.6.0 合并说明）**
> 本文是独立技能 `hos-winvm-ssh-tunnel` **v2.3.0** 的 `SKILL.md` 全文，自 `winvm-plugin-deploy` v1.6.0 起整体并入本技能，作为 SSH 免密通道**创建 / 验证 / 精确拆除**的权威指引。
> **部署、安装、卸载 WinVM Bridge 只需安装 `winvm-plugin-deploy` 一个技能**，不再需要按 `INSTALL_PROMPT.md` 另装第二个技能；原独立技能仓保持不动，仍可单独使用，两者共用同一份运行期审计账本。

## 合并后的路径映射

本文位于 `references/`，markdown 链接按本文所在目录重写；代码块中的命令一律相对技能根 `~/.workbuddy/skills/winvm-plugin-deploy/` 执行。

| 原独立技能内路径 | 本技能内路径 |
|---|---|
| `SKILL.md` | `references/hos-winvm-ssh-tunnel.md`（本文） |
| `references/operations.md` | `references/hos-operations.md` |
| `references/pitfalls.md` | `references/hos-pitfalls.md` |
| `references/rollback-contract.md` | `references/hos-rollback-contract.md` |
| `references/troubleshooting.md` | `references/hos-troubleshooting.md`（避与主技能同名问题百科冲突） |
| `references/verification.md` | `references/hos-verification.md` |
| `scripts/*.sh` / `scripts/*.ps1`（6 件，保持原名） | `scripts/` 同名；脚本内 `SKILLDIR` 自定位到 `$(dirname $0)/..`，合并后自动指向本技能根 |
| `assets/` / `templates/` | **原技能无此两类文件**，故本次无文件并入（本技能 `assets/` 仍为空目录） |

> 运行期状态 `$HOME/.workbuddy/.state/hos-winvm-ssh-tunnel/host-state.json` 与 VM 侧 `%ProgramData%\ssh\wb-tunnel-state.json` **刻意保持不变**（与独立技能共用同一份 journal / 基线，避免现场账本失联）。
> 文中「本 skill」均指该通道能力；与主流程冲突时以主技能 `SKILL.md` 的「三流程职责定界」为准（尤其 **卸载时通道坏绝不重建**）。

---

**目标**：让 AI Agent 在宿主机（HarmonyOS 沙箱）上，以「用户只做一次粘贴」的最小协助，完成 Windows VM 的 SSH 免密通道**构建 → 验证 → 销毁**全循环，且每一步可逆、可重跑、可审计。

## 三步主线

```sh
S=~/.workbuddy/skills/winvm-plugin-deploy/scripts

sh $S/host-generate-key.sh          # 1) 宿主机：生成密钥 + 打印「公钥已填好」的 VM 一键脚本
                                    # 2) 用户：VM 管理员 PowerShell 粘贴执行一次（唯一人工步骤）
sh $S/verify-tunnel.sh 172.16.100.2 User   # 3) 宿主机：四段式验收
```

销毁（先预演，再真跑）：

```sh
DRYRUN=1 sh $S/destroy-tunnel.sh    # 预演：逐条打印将撤销什么
        sh $S/destroy-tunnel.sh     # 真销毁：VM 侧回滚 → 宿主机侧回滚
```

细节按需加载：[操作全流程](./hos-operations.md) ｜ [可逆性契约与 journal](./hos-rollback-contract.md) ｜ [实测证据](./hos-verification.md) ｜ [坑与陷阱](./hos-pitfalls.md) ｜ [排错表](./hos-troubleshooting.md)

## 五条不可动摇的底线

1. **账户保持空密码**。任何环节都不得 `net user <user> <密码>`、`Set-LocalUser -Password` 去"临时设密码"。空密码不是障碍：**公钥认证根本不核对密码**。
2. **只用两端 OS 原生能力**：宿主机 `ssh`/`ssh-keygen`/`python3`；Windows 原生 OpenSSH + PowerShell + 服务/防火墙。不用 MCP、不用桥、不用文件 API 代写。
3. **公钥由管理员在 VM 本机写入一次**。这是标准装机动作，不是捷径；原因见下节。
4. **最小必要变更**：只为"建通道"做必须改动，其余保持原状。密码认证方法默认保留（`PasswordAuthentication yes`）；要减攻击面必须显式 `-Harden`。已有 sshd/别人的公钥/已有配置 → 一律叠加而非覆盖，destroy 只撤自己那份。
5. **只对宿主机开放**：`ListenAddress <VM内网IP>` + `127.0.0.1`（不写 `0.0.0.0`），防火墙 `RemoteAddress` 收窄到 `-AllowFrom`。**同端口多条 Allow 是「或」关系**，留一条任意来源就等于没设，所以脚本会扫描并收窄所有覆盖该端口的既有规则（逐条记 journal）。

### `PermitEmptyPasswords` 恒为 `no`（不是可选项）

OpenSSH `auth2-none.c`：账户密码为空**且** `permit_empty_passwd=yes` 时 **none 认证直接成功**；而 ssh 客户端**总是先发 none**。后果是 `Accepted none`（**无需任何凭据**）顶替掉 `publickey`，且**表面完全正常**——能连、能跑命令、验证脚本全绿。详见 [pitfalls 第 5 条](./hos-pitfalls.md)。

因此 `-EmptyPasswordMode auto`（默认）**只探测不放开**；`yes` 会打红并让 build 自检 FAIL。空密码账户只能走公钥，这正是本 skill 的用途。

> 由此推论：**「允许空密码密码登录」与「禁止匿名登录」是同一个开关**，无法只开一半。这也是密码认证方法开着、而空密码账户实际不能用密码登录的原因——不是配置没生效。

## 分工：为什么用户只需一步

- **Agent 全自动**：生成密钥 → 产出"公钥已填、零编辑"的 ps1 → 部署后连通性验证。
- **用户唯一一步**：VM 上以【管理员】PowerShell 执行一次 ps1（RDP 剪贴板，约 10 秒）。
- **为什么免不了**：VM 上此刻没有任何可用公钥，而"把公钥写进授权文件"本身需要一个**已被信任的凭据**。公钥还没进去就没有凭据；密码通道即使开着，也不该拿它远程改 `sshd_config`（会把一次性装机变成依赖口令的远程运维，并把空密码暴露成远程入口）。
- **一旦 VM 上有任一可用公钥**，后续全部可远程自动：改配置、轮换、收紧、销毁都不再需要用户。

### VM 侧脚本的三种运行形态（选一种，别混用）

| 形态 | 怎么跑 | 能带参数吗 | 适用 |
|---|---|---|---|
| A 整段粘贴 | 管理员 PowerShell 里粘贴 ps1 全文 | **不能**（交互式会话没有命令行参数绑定） | 只做正式构建、想零落地文件 |
| B 存文件再跑（**推荐**） | 另存为 `%USERPROFILE%\winvm-sshd-oneclick.ps1`，再 `powershell -NoProfile -ExecutionPolicy Bypass -File ...` | 能（`-DryRun`/`-Rollback` 等全部可用） | 要预演、要回滚、要反复测试 |
| C pwsh 7 | 不要用 | — | Windows 默认**没有** `pwsh`；且 `*-WindowsCapability` 依赖的 DISM 模块在 7 下常加载失败 |

```powershell
# 预演（零副作用，连 C:\ProgramData 都不写，日志落 %TEMP%）
powershell -NoProfile -ExecutionPolicy Bypass -File %USERPROFILE%\winvm-sshd-oneclick.ps1 -DryRun
# 正式构建（幂等，可反复执行，每步写 journal）
powershell -NoProfile -ExecutionPolicy Bypass -File %USERPROFILE%\winvm-sshd-oneclick.ps1
# 只读体检（出问题先跑这个）
powershell -NoProfile -ExecutionPolicy Bypass -File %USERPROFILE%\winvm-sshd-oneclick.ps1 -Continue
# 回滚（先看计划再真跑；幂等，重跑只补失败项）
powershell -NoProfile -ExecutionPolicy Bypass -File %USERPROFILE%\winvm-sshd-oneclick.ps1 -Rollback -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File %USERPROFILE%\winvm-sshd-oneclick.ps1 -Rollback
# 已手动下好安装包（最省时）：跳过下载直接装，可逆性不丢
powershell -NoProfile -ExecutionPolicy Bypass -File %USERPROFILE%\winvm-sshd-oneclick.ps1 -MsiPath %USERPROFILE%\OpenSSH-Win64-v10.4.0.0.msi
```

- 文件来自网络/剪贴板时先 `Unblock-File .\winvm-sshd-oneclick.ps1`（否则 RemoteSigned 拦）。
- 另存时编码选 **UTF-8 带 BOM** 或 **ANSI**：PS 5.1 对无 BOM 的 UTF-8 按 GBK 解析，中文会引发语法错。
- **`-DryRun` 的诚实边界**：跑到"生成配置 + `sshd -t`"就 `return`，不写配置/公钥/防火墙/不重启；sshd 未装时连语法校验都跳过。补盲区用 `-Continue`（15 项只读检查 + 一句人话结论），不要手敲命令。

## 阶段速览

每步的命令、参数、配置项与判定标准见 [references/hos-operations.md](./hos-operations.md)。

| 阶段 | 做什么 | 关键判据 |
|---|---|---|
| **A** 宿主机 gen-key | `ssh-keygen -t ed25519` 无 passphrase；写宿主机基线；把公钥注入 ps1 整段输出 | 打印 SHA256 指纹；私钥 `600` 且不进仓库 |
| **B** 装 OpenSSH Server | 联网、MSI 优先（`msiexec /i /qn`），zip / winget 回退，Capability 仅显式指定 | `Get-Service sshd` 存在；装完记 ProductCode 供卸载 |
| **C** 启动 sshd | `Set-Service -StartupType Automatic` + `Start-Service`。**先起服务再改配置** | `sc qc sshd` = `AUTO_START`，`sc query` = `RUNNING` |
| **D** 写 sshd_config | 先备份 → 只改全局区（第一个 `Match` 之前）→ 幂等（有则改无则插）→ `sshd -t` 通过才落盘 | `sshd -t` 无输出；`Port` 与防火墙一致 |
| **E** 公钥 + ACL + 防火墙 | 管理员写 `%ProgramData%\ssh\administrators_authorized_keys`；按 SID 收紧 ACL；防火墙 `-Profile Any` 且来源收窄 | 授权文件 ASCII 一行一钥；ACL 仅 Administrators+SYSTEM |
| **F** 验证 + 验收 | `verify-tunnel.sh` 四段：TCP → **none 必须被拒** → 认证方式通告 → 纯公钥登录 | 三段同时成立：none 被拒 + 公钥成功 + ETW `Accepted publickey` |
| **G** destroy | `destroy-tunnel.sh`：VM 侧 `-Rollback`（SYSTEM 计划任务，避免卸载时自断）→ 宿主机侧回滚 | 判定标准是**免密登录不再可用**，不是"22 端口关了" |

### 验证必须四段，缺一即可能"绿着错"

1. **TCP 可达** —— 只证明端口通。
2. **`none` 必须被拒**（`PreferredAuthentications=none` 空手上门）—— **命门**。若服务端接受，说明不需要凭据就能登录，此时第 3 段的成功是假象。
3. **认证方式通告** —— 从 `Permission denied (publickey,password,...)` 读方法列表：有 `password` = 密码登录仍开放（预期）；上了 `-Harden` 则应消失。**不输任何密码**就能判定。
4. **纯公钥登录** —— 必须同时带 `IdentitiesOnly=yes` **和** `PreferredAuthentications=publickey`。少任一个，在"空密码 + `PermitEmptyPasswords yes`"的机器上都会静默退化成 none/空密码。

## 反模式（明确不做）

- 给账户设密码（含"临时设一次再清空"）——属旁路，公钥方案不需要。
- `PermitEmptyPasswords yes` —— 等于开启 none 匿名登录，公钥彻底失效；"绿着错的"比直接失败危险得多。
- 用外部 MCP/桥/文件 API 建 SSH —— 循环依赖（SSH 常是其下游），且 WinVM 文件 API 把 `%ProgramData%\*` 列黑名单，写不了管理员授权文件。
- "先加新钥再删旧钥"冒充从零 —— 那是轮换，不是构建。
- `Add-Content` 硬写 sshd_config —— 制造重复行、可能写进 `Match` 块导致服务起不来。
- 用"22 端口关了"当销毁成功标准 —— 构建前 sshd 就存在的机器，destroy 后 22 依然开着才叫正确还原。

## 安全收尾

- 私钥 `600`、不进仓库、定期 `ROTATE=1` 轮换。
- 安全基线默认**不收紧**（保留密码认证是既定需求）；要收攻击面显式 `-Harden` 重跑，去掉开关重跑即恢复。
- 吊销：删授权文件对应行 + 宿主机 `ssh-keygen -R <ip>`。
- 账户空密码的安全边界靠三层共同保证，**缺一不可**：① 公钥认证（唯一日常入口）；② `ListenAddress` + 防火墙来源限制（外部根本连不上 22）；③ `PermitEmptyPasswords no`（杜绝 none 匿名）。少了 ③，①② 都还在、验证也全绿，但宿主机上**任何进程**都能以该账户身份无凭据登录。

## 环境与文件

宿主机需要 `ssh`、`ssh-keygen`、`python3`、`sh`；VM 需要 Windows 10/11 或 Server 2019+、管理员权限、能访问外网（或用 `-MsiPath` 离线安装包）。

| 脚本 | 侧 | 作用 |
|---|---|---|
| [`scripts/host-generate-key.sh`](../scripts/host-generate-key.sh) | 宿主机 | 生成/轮换密钥、打印指纹、写宿主机基线 `$HOME/.workbuddy/.state/hos-winvm-ssh-tunnel/host-state.json`、产出公钥已填的 ps1 |
| [`scripts/winvm-setup-sshd-and-key.ps1`](../scripts/winvm-setup-sshd-and-key.ps1) | Windows | build / `-Rollback` / `-Continue` 三态一体；全部写操作进 journal v2 |
| [`scripts/verify-tunnel.sh`](../scripts/verify-tunnel.sh) | 宿主机 | 四段式验收（none 被拒优先于公钥成功） |
| [`scripts/vm-diag.ps1`](../scripts/vm-diag.ps1) | Windows（宿主 scp + ssh 触发） | 只读全量体检，约 50 s，零副作用，排障第一步 |
| [`scripts/host-rollback.sh`](../scripts/host-rollback.sh) | 宿主机 | 按基线撤销密钥 / known_hosts / 基线文件，支持 `DRYRUN=1` |
| [`scripts/destroy-tunnel.sh`](../scripts/destroy-tunnel.sh) | 宿主机 | destroy 总入口：先 VM 侧再宿主机侧 |

运行期状态（都在 skill 包之外，不会被打包分发）：宿主机 `$HOME/.workbuddy/.state/hos-winvm-ssh-tunnel/host-state.json`（密钥归属基线）；VM `%ProgramData%\ssh\wb-tunnel-state.json`（journal v2）。两者都是**审计凭据**，回滚不清空，下次 build 归档重开。
