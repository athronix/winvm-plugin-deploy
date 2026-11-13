# 可逆性契约（build ⇄ destroy 成对，journal v2）

**规矩：每做一步，就把「变更前状态 + 变更后状态 + 逆操作」写进 journal；destroy 只按逆序回放，并把每条的撤销结果写回 journal。**

- VM 侧账本：`%ProgramData%\ssh\wb-tunnel-state.json`（schema v2）
- 宿主机侧账本：`$HOME/.workbuddy/.state/hos-winvm-ssh-tunnel/host-state.json`（包外，`WB_TUNNEL_STATE_DIR` 可覆盖）

## 为什么必须"记日志"而不是"推导"

如果销毁逻辑靠自己重新推导"当初做了什么"，条件一多必然漏项或误删 —— 尤其"服务本来就在"和"服务是我们装的"这两种情况长得一样。正解：build 每个写操作追加一条 `{before, undo}`，destroy 只按逆序执行 undo。新增一步只需多记一条，销毁端零改动。

## 账本结构

| 字段 | 内容 | 为什么需要 |
|---|---|---|
| `params` | user / port / harden / skipInstall / openSshZipPath / downloadTimeout + 公钥全文、blob、sha256、注释 | 复原时必须知道"按什么参数做的"；公钥 sha 用来核对是不是同一把钥 |
| `env` | 主机名 / OS / PowerShell 版本 / 是否管理员 / 脚本路径 + sha256 + 版本 | 排障时确认"哪一版、什么环境" |
| `baseline` | 首次构建前快照：服务、能力、配置(sha)、网络档、防火墙、授权文件(行数 + ACL SDDL)、账户策略 | 只在首次采集，之后不覆盖；destroy 的兜底参考 |
| `ops[]` | 每条写操作 `{id,ts,tsLast,times,stage,stageName,action,key,before,after,result,undo,undoState,undoTs,undoResult}` | 回滚唯一依据，逐条可审计；同 `(action,key)` 重跑 = upsert |
| `rollbacks[]` | 每次回滚汇总 `{ts,dryRun,total,done,skipped,kept,failed,notes,tempCleaned}` | "撤过几次、结果如何" |
| `status` | `active` / `rolledback` / `partial` | 防新旧混账：`rolledback` 的账本下次 build 自动归档重开 |

一条 op：

```jsonc
{ "id": 2, "ts": "2026-11-09T18:40:01+08:00", "tsLast": "2026-11-09T18:52:13+08:00",
  "times": 3,                      // 被幂等应用了 3 次，仍然只有一条
  "stage": 4, "stageName": "配置 sshd_config（含安全基线）",
  "action": "write-sshd-config",
  "key": "sshd_config",            // upsert 判重键（同 action + 同 key = 同一目标）
  "before": { "path": "…\\sshd_config", "port": 22, "sha256Before": "…" },
  "after":  { "sha256After": "…" },
  "result": "ok",
  "undo":   { "type": "restore_file", "path": "…\\sshd_config", "from": "…\\sshd_config.wb-orig" },
  "undoState": "pending", "undoTs": null, "undoResult": null }
```

## undo 类型

| undo.type | 含义 | 何时记录 |
|---|---|---|
| `restore_file` | 用留档覆盖回去 | 改了已存在的文件（sshd_config） |
| `delete_file` | 删除本次创建的文件 | 留档 `.wb-orig`、`.bak-<ts>` |
| `remove_key_line` | 只删本通道 blob 那一行（可附 ACL 还原 / 目录清理） | 往授权文件追加了公钥 |
| `restore_acl` | 用 SDDL 还原 ACL | 单独改过 ACL |
| `remove_firewall_rule` | 删除本次新建的规则 | 规则原来不存在 |
| `restore_firewall_rule` | 还原 Enabled/Profile/LocalPort/RemoteAddress | 规则原来存在、被改过 |
| `restore_net_profile` | 改回原网络档 | 把 Public 改成了 Private |
| `restore_service_starttype` | 还原服务 StartType | 把 Manual/Disabled 改成 Automatic |
| `remove_capability` | 移除 Windows 能力 | 用可选功能装的 sshd |
| `uninstall_openssh` | 卸载程序 + 删目录（可带 winget） | 用 msi/zip/winget 装的 sshd |
| `restart_service` | 重启使还原生效 | 改完配置 |
| `delete_task` | 删除一次性计划任务 | destroy 通过计划任务触发时 |

## 构建幂等：三道闸门

同一份脚本可以毫无顾虑跑 N 次；只在"真的变了"的地方记一条。

| 闸门 | 判据 | 效果 |
|---|---|---|
| **内容闸门**（文件类） | 目标内容 sha256 与现有文件一致 | 跳过备份/写入/重启，不产生 `.bak-*`、不记 journal |
| **状态闸门**（服务/防火墙/网络档） | 当前值已等于目标值 | 跳过改动，不记 journal |
| **journal upsert**（兜底） | 同 `(action,key)` 且 `undoState != done` 已存在 | 不追加新条目：`before` 保留**首次**、`after`/`result` 刷新、`times+1`、`tsLast` 更新 |

三条不变量：

1. **baseline 只有一份**：`status != rolledback` 时永远沿用旧账本（不归档、不重采），destroy 回到"最初"而不是"上一次"。
2. **`before` 永远指向最初**：upsert 只改 `after`，所以"Port 22 → 2222 → 22"最终 `before=22/after=22`，destroy 仍是正确的一步还原。
3. **"改过又改回"也算一条**：`undoState` 保持 `pending`，destroy 照常撤（重复撤同一目标幂等），不会因"看起来没变"而漏撤。

`key` 取值：`sshd`（服务/安装/重启）、`sshd_config`（配置/留档）、授权文件路径、防火墙规则名、网卡别名、备份文件名。

## 回滚的幂等与可续跑

1. 逐条**逆序**处理；`undoState=done` 直接跳过（打印"上次已撤销完成 → 跳过（幂等）"）。
2. **每条执行完立刻保存账本** —— 中途断电/关窗口，重跑只补没做的。
3. 单条失败记 `undoState=failed` 并继续处理其余项，最后 `status=partial` + 失败清单；再跑一次只补失败项。
4. `-KeepService` 跳过的记 `kept`（不是 done），以后不带该开关还能补撤。
5. 全部成功 → `status=rolledback`，并清理 `%TEMP%` 残留（preview/zip/解压目录）、`wb-rollback.ps1`、`WbTunnelRollback` 计划任务。
6. 回滚**不清空账本**（审计用）；下次 build 见 `status=rolledback` 就把旧账本复制成 `wb-tunnel-state.history-<ts>.json` 后重开。
7. 旧账本读入时自动补齐缺失字段（`Ensure-Prop`/`Upgrade-WbState`），不会因为"对象没有 undoState 属性"崩在半路。给 `ops[]` 加字段后必须走这一步，且用 `PSNoteProperty::new` 才能安全承载 `$null`。

## 逐项对照：build 动作 ↔ 记录的 before ↔ 记录的 undo

| 变更项 | build 动作 | 记录的 before | 记录的 undo |
|---|---|---|---|
| 宿主机密钥 | `ssh-keygen` | 是否已存在、是否本 skill 拥有（按注释标记） | 拥有的才删；原本就有且非我们的 → 保留 |
| known_hosts | 首次连接写入指纹 | 构建前是否已有该主机记录 | 原本没有才移除 |
| sshd 服务 | 联网安装 | `serviceExisted` + `method` + `capability` 原状态 | 原本没装才卸载（capability / zip / winget 三条路径分别撤） |
| 服务启动类型 | 改 Automatic | 原 StartType | 还原原 StartType |
| sshd_config | 改 Port / 基线 / ListenAddress | 原文件路径 + sha256 | 还原 `.wb-orig` + 删自己的备份 |
| 公钥 | 追加一行 | 文件是否存在、行是否已存在、原 ACL SDDL | 只删本 blob 那一行；原本不存在→删文件；原本存在→还原 ACL；`.ssh` 目录也还原 |
| ACL | `icacls /inheritance:r` + SID | 文件/目录的 SDDL | 用 SDDL 精确还原 |
| 防火墙 | 新建/收窄规则 | existed / enabled / profile / localPort / remoteAddress | 新建的删；改过的逐字段还原 |
| 网络档 | Public→Private | 原 category | 改回原档位 |
| LSA `LimitBlankPasswordUse` | 仅 `-EmptyPasswordMode yes` 时改 0 | 原值（含"原本不存在"） | 原本不存在→删值；原本 `1`→还原 `1` |
| 临时文件 | zip / preview / 解压目录 | — | 回滚时统一清理 |

**undo 顺序必须是"后记先撤"**：例如"还原 sshd_config ← 删除 `.wb-orig`"，日志必须先记 `delete_file(.wb-orig)`、再记 `restore_file(...)`，逆序回放才会"先还原、后删留档"。顺序记反 = 还原时源文件已被自己删掉。

## 命令

```sh
sh scripts/host-generate-key.sh          # 构建：生成 + 打印 VM 一键脚本
DRYRUN=1 sh scripts/destroy-tunnel.sh    # 预演
        sh scripts/destroy-tunnel.sh     # 真销毁
```

`-DryRun`（VM 侧）与 `DRYRUN=1`（宿主机侧）都是**零副作用预演**；`-Rollback -DryRun` 逐条打印 undo 类型与参数，不落盘、不改账本。**零副作用包括日志**：预演日志一律落 `%TEMP%`，否则预演会创建系统目录，破坏承诺。

## 运行日志与错误报告（VM 侧）

每阶段打印 `[n/9] 名称 开始 HH:mm:ss` 与结束用时；长操作（下载、winget）前明确提示"预计 1-5 分钟、界面不动是正常的"——任何时刻都能判断跑到哪、是否卡住。所有输出同时进控制台与日志。

| 文件（`%ProgramData%\ssh\` 下） | 内容 |
|---|---|
| `wb-tunnel-build-<ts>.log` | 构建全过程（阶段/步骤/journal 编号/耗时/每步结果） |
| `wb-tunnel-rollback-<ts>.log` | 回滚全过程（每条 undo 的 before/after 与结果） |
| `wb-tunnel-diag-<ts>.log` | `-Continue` 体检报告 |
| `wb-tunnel-error-<ts>.log` | 失败现场：异常 + 调用栈 + 出错位置 + 尾日志 80 行 + 完整 journal |
| `wb-tunnel-state.json` | 账本 |

出错时脚本打印该文件绝对路径并提示"整段复制回来"。DryRun 的日志落 `%TEMP%`，保证预演连 `%ProgramData%` 都不碰。

## 宿主机侧回滚

`host-rollback.sh` 按宿主机状态目录里的 `host-state.json` 精确撤销：本 skill 创建的密钥才删、原本就有的保留；known_hosts 条目原本没有才移除；最后删基线文件本身。支持 `DRYRUN=1`。
