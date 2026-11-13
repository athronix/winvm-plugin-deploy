---
name: winvm-plugin-deploy
description: "WinVM Bridge（workbuddy-virtual-win-plugin）鸿蒙宿主与 Windows VM 双端安装/卸载/复验的唯一执行权威。v1.6.0 起 SSH 免密通道生命周期能力**内置**（独立技能 hos-winvm-ssh-tunnel v2.3.0 的 SKILL.md 全文 + 6 脚本 + 5 参考文档已整体并入，部署只需安装本技能一个，无需再装第二个 skill）+ 三流程职责定界：卸载=host 端+vm 端+ssh 通道三段且通道坏时绝不重建（VM 侧两件合并成一个用户脚本）；部署=通道保障（在则不建，不在才引导内置一键脚本让用户配合）+两端自动部署；verify=deploy ready 后由 WorkBuddy 自调的健康与功能性监测。封装 roundtrip.sh 一键往返模板、channel.sh 通道单一动作、VM 侧本地卸载 ps1 与合并包、ssh2 后端、远端 PowerShell 铁律执行器、分步计时与问题百科。Use when: 部署/重装/卸载 winvm-plugin；按技能 URL 安装/卸载/验证；VM ssh 连不上、通道已毁、发布包下载失败、安装前置体检、插件健康复验；需要构建/验证/拆除 VM 免密 SSH 通道。"
version: 1.6.0
agent_created: true
---

# WinVM 插件部署技能（winvm-plugin-deploy）

把「鸿蒙宿主 ⇄ Windows VM 安装 WinVM Bridge」做成**可执行流程 + 脚本 + 问题百科**。本技能是本项目部署/安装/启动/验证/卸载**全部环节的唯一执行权威**（迭代28 用户裁定；旧 `deploy.prompt`/`undeploy.prompt` 已退役=历史档案，不再是判据来源、不入发布包）。免密通道的**创建/验证/精确拆除**能力自 v1.6.0 起**内置**：独立技能 `hos-winvm-ssh-tunnel` v2.3.0 的 `SKILL.md` 全文与 6 个脚本、5 份参考文档已整体并入本技能（见 `references/hos-winvm-ssh-tunnel.md`），**部署只需安装本技能一个，无需再按 `INSTALL_PROMPT.md` 装第二个 skill**。

## 三流程职责定界（v1.5.0 · 用户 2026-11-13 裁定 · 最高优先级）

| 动词 | SSH 通道 | host 端 | vm 端 | 人工介入 |
|---|---|---|---|---|
| **undeploy** | **只判状态，绝不重建**；通道坏是正常输入 | WorkBuddy 本地卸载（无需通道） | 通道在→WorkBuddy 自己卸；通道不在→**与通道卸载合并成一份 VM 侧脚本**交给用户 | 仅通道坏时：用户在 VM 管理员 PowerShell 执行 `RUN-ME.ps1` 一次 |
| **deploy** | **在则不建**；不在才按内置一键脚本让用户配合建立 | WorkBuddy 经通道部署 | WorkBuddy 经通道部署 | 仅从零建通道：用户 VM 粘贴一次 |
| **verify** | 只用现役通道，不建不修 | — | — | **无**，deploy ready 后由 WorkBuddy 自己调用 `verify.sh` |

**卸载 = 恰好三段，顺序不可换**：① host 端 ② vm 端 ③ ssh 通道。②③ 可合并。
- 通道**在**：② 由 WorkBuddy 经 ssh2 完成；③ 把内置 `-Rollback` 设为 **VM 侧 SYSTEM post 动作**（`WbTunnelRollback` 计划任务），让 VM Windows 在本会话断开后自己执行——避免拆 sshd 时自断通道。
- 通道**不在**：① 仍由 WorkBuddy 本地完成；②③ 由 `build-vm-bundle.sh` 合成**一个目录**（`vm-remove-local.ps1` + `wb-rollback.ps1` + `RUN-ME.ps1`），用户一次执行即可。**绝不为了卸载去重建通道**（旧 P-2「通道失效→外委重建」已废止）。

> 版本史：v1.6.0=通道生命周期内置（并入 hos-winvm-ssh-tunnel v2.3.0：6 脚本 + 6 参考文档，一次安装即可）；v1.5.0=三流程语义重构 + 通道单一动作 + VM 侧合并包 + F-02/03/05/07/09 修复；v1.4.3=E2E2 整改（R4 快照/R4b 位置/R6 判稳插段）；v1.4.2=E2E1 整改（密钥三级链/交付待办显形）；v1.4.1=旧模式退役、本技能升唯一权威；v1.4.0=通道生命周期外委 hos；v1.3.0=roundtrip 模板+探针新鲜复用。canonical=`athronix/winvm-plugin-deploy`，发布形态=双端 release 资产 `winvm-plugin-deploy-skill.zip`。

## URL 单指令入口（用户只发一句「请依据 skill {skill_url} 安装/卸载/验证 winvm-plugin」）

1. **取技能本体**（技能已加载/已在 `~/.workbuddy/skills/` 在场——含 symlink——**跳过**；勿用 unzip 覆盖 symlink）：`curl -fsSL --connect-timeout 20 --max-time 300 -o ~/wbtmp/winvm-plugin-deploy-skill.zip "<skill_url>"`（`-o` 必须用资产原名，旁挂 sha256 内登记原名；gitee 302→foruda 一次性签名，**禁 `-C -`**，失败整文件重试）→ `unzip -o <zip> -d ~/.workbuddy/skills/`。后续 `scripts/…` 相对 `~/.workbuddy/skills/winvm-plugin-deploy/`。
2. **环境事实**：`VM_HOST` / `VM_USER`（未知 → P-1 问用户，唯一允许的流程提问点）。**此处不判通道、不建通道**——通道归属由动词决定（见上表）。
3. **取发布包**：`bash scripts/env-detect.sh` → `source ~/wbtmp/vmdeploy-env.sh` → `bash scripts/download-verify.sh` → 记末行 `PKG_ROOT=`。
4. **按动词路由**：`VM_HOST=<ip> ACTION=<full|deploy|undeploy|verify> bash scripts/roundtrip.sh`（后台一次调用；完成后**只读末块 `== ROUNDTRIP_RESULT ==`**，含 `VERDICT`/`WALL_S`/三段 PASS/FAIL/TOP5，勿分段轮询）。动态参数仅 `RELEASE_TAG`/`SKIP_DOWNLOAD`/`VM_USER`/`PROBE_FRESH_BUDGET_S`。
   - `full` 的卸载段**默认 `--keep-tunnel`**（往返重装不拆通道，省掉第二次人工建通道）；单独 `undeploy` 才默认拆通道（可用 `--keep-tunnel` 保留）。
   - 分步 driver（deploy/undeploy/verify/download-verify）保留=排障定点重跑；roundtrip 内部按序调用它们（单一事实源）。
5. **卡住**：查 `references/troubleshooting.md`；通道灭相位不是停跑理由（ssh2 免疫）；红线——绝不主动重启 VM。

> 技能包 URL 权威来源 = 双端 release 资产 `winvm-plugin-deploy-skill.zip`（gitee 主：`https://gitee.com/athronix/workbuddy-virtual-win-plugin/releases/download/<tag>/winvm-plugin-deploy-skill.zip`；≥V1.4.24 随每 tag 发布）。只给仓库页/说「最新版」时，`curl https://gitee.com/api/v5/repos/athronix/workbuddy-virtual-win-plugin/releases/latest` 现解 tag 再拼 URL。

## 铁律

1. **三流程职责以「三流程职责定界」表为准**；卸载路径出现 `ensure`/`host-generate-key`/「重建通道」字样即为违规。
2. **取包** gitee 主、github 备；tag 现解 `releases/latest`。
3. **远端 PowerShell 铁律**：复合逻辑=写 `.ps1` → scp → `powershell -File`；短片段=`-EncodedCommand`（base64 UTF-16LE）。禁双引号内联含 `$` 的 PS；一律经 `scripts/ps-run.sh`。VM 侧脚本**全 ASCII**（ps-run.sh 有门禁）。
4. **宿主删文件禁 `rm`** → `node -e 'fs.unlinkSync(...)'`；禁 `rm -rf <目录>`。
5. **ssh/scp 必包外层 timeout**（`vm-conn.sh` 内建 `VM_SSH_TIMEOUT=25`）。
6. **统一后端**：`channel.sh`/`deploy.sh`/`undeploy.sh`/`verify.sh`/`roundtrip.sh` 一律 `export VM_SSH_BACKEND=ssh2`（v1.5.0 起由脚本自身保证，勿再手工 export）。
7. **密钥单一事实源**：`WINVM_VM_KEY` 三级链 env > `~/.workbuddy/winvm/vm-conn.json` identityFile > `~/.ssh/id_ed25519`；`channel.sh ensure` 把该值作为内置 `host-generate-key.sh` 第 1 参，禁止双钥并存都试。
8. **密码只走环境变量**（askpass / `WINVM_VM_PASSWORD`），不落盘不进命令行。
9. **通道拆除恒为 VM 侧 post 动作**（SYSTEM 计划任务），或合并进用户 bundle；不在宿主侧同步拆 sshd。
10. **每步判据不过=停**，按四元组（现象/根因/证据/处置）记录并查表，不跳步硬推。

## 卸载主流程（三段，v1.5.0）

```bash
VM_HOST=<ip> bash scripts/undeploy.sh                 # DRY-RUN：打印三段计划 + CHANNEL_UP
VM_HOST=<ip> bash scripts/undeploy.sh --apply        # 执行三段
VM_HOST=<ip> bash scripts/undeploy.sh --apply --keep-tunnel      # 保留 ssh 通道
VM_HOST=<ip> bash scripts/undeploy.sh --apply --purge-workspace  # 破坏性：连 C:/WinVMWorkspace 一起删
```

| 段 | 动作 | 通道在 | 通道不在 |
|---|---|---|---|
| **1 host** | `delivery/uninstall.mjs --apply` 的 host 相位（无 VM 目标→VM 相位按设计跳过），判据=`[PASS] HOST` ≥11 且零 `[FAIL] HOST` | 同 | 同（**不需要通道**） |
| **2 vm** | 推 `scripts/vm-remove-local.ps1` → `ps-run.sh -c "& .\vm-remove-local.ps1 -Apply"`，判据 `VM_CLEANUP_DONE` + POST STATUS | WorkBuddy 执行 | `build-vm-bundle.sh` 产出 `VM_BUNDLE=`，标 `NEED_USER_ACTION=1` |
| **3 ssh 通道** | 内置 `winvm-setup-sshd-and-key.ps1 -Rollback` + 内置 `host-rollback.sh`；判据=免密登录不再可用（**不是** 22 端口关了） | `channel.sh post`：scp 模板 → VM SYSTEM 任务 `WbTunnelRollback` → 宿主回滚 | 已合并进 `RUN-ME.ps1`（`-ScheduleTunnelRollback`），宿主侧仍由 WorkBuddy 跑 `host-rollback.sh` |

**通道不在时交给用户的唯一动作**：把 `VM_BUNDLE` 目录拷到 VM → 管理员 PowerShell 执行 `powershell -NoProfile -ExecutionPolicy Bypass -File .\RUN-ME.ps1`。目录内已含 vm 卸载 + 通道回滚两件，`PASTE-THIS.txt` 有完整说明。宿主侧 `vm-conn.json` 拆前留 `.roundtrip` 快照（供后续 deploy 的 P0 前恢复）。

**独立复核（U4）**：`health=000` / `GLOBAL_MCP_CLEAN` / VM 五点 `False False 0 * True`；通道不在时 VM 终态标 `PENDING_USER`（不算失败）。存留项（trash / 下载物）默认保留。

## 安装主流程（通道保障 + 两端部署）

```bash
# 首选：一次后台调用，LLM 只在 取环境事实 / 发命令 / 读末块 三处介入
VM_HOST=<ip> ACTION=deploy bash scripts/roundtrip.sh
# 分步（排障/细粒度计时）
bash scripts/channel.sh ensure        # 通道在→CHANNEL_EXISTS=1 直接过；不在→打印内置一键脚本，rc=2 等用户粘贴
#   ... 用户在 VM 管理员 PowerShell 粘贴一次 ...
bash scripts/channel.sh confirm       # 内置四段验收 + ssh2 ping 复核定论
bash scripts/deploy.sh --apply        # 通道→取包→ENV_PRECHECK→prepare/setup→vmcheck→install-host→三探针→交付
```

- `channel.sh ensure` 只做「在/不在」判定；**通道已建立就不再建立**，也不会重装密钥（内置脚本幂等，但仍不调用）。
- 两端部署全部经现役通道由 WorkBuddy 完成；`deploy.sh` 的 C1 不再自行探测通道（复用 `channel.sh` 结果），消除重复 probe。
- C5 三探针全过先落 `deploy_ok=0` 候选 stamp，**只有末尾全链零 FAIL（`FAILED_STEPS` 为空）才升为 `deploy_ok=1`**；开跑即作废旧 stamp，中途硬阻断也不留可复用假绿。`probe-fresh.sh` 第四防线读该字段，杜绝「部分失败却 verify 复用 PASS」。
- 交付待办（`[MANUAL]` / `DB-4` VM 内 codebuddy 登录）由 C6 显形到终端并落 `handoff` 行，属结构性人工项、不阻断。

## 复验与汇报（verify）

```bash
bash scripts/verify.sh                # 仅在 deploy ready 后由 WorkBuddy 自调；不建通道、不修通道
bash scripts/step.sh report           # 计时汇总
```

三探针 38 项（**仅当 stamp 带 `deploy_ok=1`** 且新鲜窗 600s 内同包根才 3×REUSED）+ 终态矩阵（fresh / disabledTools=8 / health=200 / skills=8 / VM 三点）。VM 通道落在瞬态窗时标 `ENV_WINDOW=1` → `VERIFY=INCOMPLETE rc=2`（环境问题非功能失败，既不误报 FAIL 也不假绿 PASS）；等健康窗只重跑 `verify.sh`，绝不重启 VM。`skills=0` ⇒ 宿主侧外部擦除，`install-host --yes` 幂等恢复（非 VM 问题）。

## SSH 免密通道生命周期（创建/验证/拆除 = 内置，v1.6.0 并入 hos-winvm-ssh-tunnel v2.3.0）

**分工定界（v1.6.0 变更）**：鸿蒙宿主 WorkBuddy 沙箱 → Windows VM 的 SSH 免密通道从零创建、四段验证、按 journal 精确拆除，能力自 v1.6.0 起**内置于本技能**——独立技能 `hos-winvm-ssh-tunnel` v2.3.0 的 `SKILL.md` 全文已作为 [`references/hos-winvm-ssh-tunnel.md`](references/hos-winvm-ssh-tunnel.md) 并入，其 6 个脚本原样置于 `scripts/`、5 份参考文档以 `hos-*.md` 置于 `references/`。**部署 / 卸载 / 复验 WinVM Bridge 只需安装 `winvm-plugin-deploy` 一个技能**，不再需要按 `INSTALL_PROMPT.md` 另装第二个 skill；原独立技能仓保持不动、仍可单独使用，两者共用同一份运行期审计账本。

> 可选（仅在需要独立运维通道、不跑本插件部署时）：按 https://raw.githubusercontent.com/athronix/skills/main/INSTALL_PROMPT.md 安装独立的 `hos-winvm-ssh-tunnel` skill。**这不是部署本插件的前置条件**。若显式设置 `HOS_TUNNEL_SKILL=<独立技能根>`，`channel.sh` / `undeploy.sh` / `build-vm-bundle.sh` 会优先用该路径（向后兼容）；否则一律用本技能自带的 `scripts/`。

其主线（细节与全部底线见 [references/hos-winvm-ssh-tunnel.md](references/hos-winvm-ssh-tunnel.md)，操作全流程见 [references/hos-operations.md](references/hos-operations.md)）：`scripts/host-generate-key.sh [key_path] [vm_user] [vm_port] [vm_ip]` 生成密钥并打印「公钥已填好」的 VM 一键脚本 → **用户在 VM 管理员 PowerShell 粘贴执行一次=唯一人工步骤** → `scripts/verify-tunnel.sh <VM_IP> <user> <key> <port>` 四段验收（none 必被拒优先于公钥成功）→ 拆除用 `scripts/destroy-tunnel.sh`（`DRYRUN=1` 预演；内部 VM 侧即 `schtasks /Create /TN WbTunnelRollback … /RU SYSTEM` 的 post 动作 + 内置 `scripts/host-rollback.sh`）。

**三处衔接口（v1.5.0 改写，v1.6.0 改为内置路径；旧 P-2 已废止）**：
1. **deploy 通道不在** → `channel.sh ensure` 调内置 `scripts/host-generate-key.sh "$WINVM_VM_KEY" …`，打印整段给用户；用户粘贴后 `channel.sh confirm` 验收。
2. **undeploy 通道不在** → **不建通道**；`build-vm-bundle.sh` 把内置 `scripts/winvm-setup-sshd-and-key.ps1` 复制为 `wb-rollback.ps1`，与 vm 卸载脚本合并给用户一次执行。
3. **undeploy 通道在** → `channel.sh post` 把同一模板推到 VM 并以 SYSTEM 计划任务触发 `-Rollback`；宿主侧内置 `scripts/host-rollback.sh` 精确撤销本技能创建的私钥/known_hosts/基线。

**接口适配注记（11-11 / 11-13 三次实核，勿凭记忆改）**：
- **密钥接线**：通道脚本默认 `~/.ssh/id_ed25519_winvm`；本技能 `vm-conn.sh`/ssh2 后端默认 `~/.ssh/id_ed25519`。`channel.sh ensure` 显式把 `$WINVM_VM_KEY`（三级链结果）作为 `host-generate-key.sh` 第 1 参，两侧因此共用同一把钥；`vm-conn.sh` 恒带 `-i $WINVM_VM_KEY -o IdentitiesOnly=yes`。
- **`-Rollback` 不需要公钥**：内置模板按 journal v2 逆序撤销（公钥行 blob 已记在 journal），故通道已断也能在 VM 本机执行；这正是「通道不在也能拆通道」的依据。
- **验证判读**：`verify-tunnel.sh` / `destroy-tunnel.sh` 走 **ssh 二进制**，本宿主 WB 沙箱对 VM 呈相位挂起 ⇒ **二进制失败 ≠ 通道没建好**，一律用 `node scripts/ssh2-conn.mjs ping` 复核定论。
- **禁止误用**：`destroy-tunnel.sh` 在「22 可达但免密不通」时会提示「a) 先重建再 destroy」——**本技能卸载路径禁走 a)**，只走 b)（VM 管理员本机执行 `-Rollback`）。
- **运行期状态共用**：`$HOME/.workbuddy/.state/hos-winvm-ssh-tunnel/host-state.json` 与 VM `%ProgramData%\ssh\wb-tunnel-state.json` 保持原名，合并前后账本不迁移（改路径会与现场状态失联）。
- **合并接线**：6 个通道脚本内 `SKILLDIR="$(dirname $0)/.."` 自定位，合并后自动指向本技能根；`HOS` 变量默认值由独立技能挂载点改为 `$(dirname "$_here")`，故 `$HOS/scripts/...` 全部落到本技能 `scripts/`。
- **密码前提**：通道能力底线=账户空密码、公钥认证不核对密码；本 VM 现役 User 非空密码且通道已建，两拓扑都支持公钥，无冲突。
- **红线共守**：绝不主动重启 VM/guest。

## 通道后端与包根选择

**ssh2 后端**：鸿蒙 WB 沙箱 OpenSSH 二进制对 VM 相位挂起（灭窗 rc=124 空 stderr），同秒实测 ssh2 库 READY 654ms 而二进制 124。`vm-conn.sh` 的 `vmssh/vmscp/probe` 在 `VM_SSH_BACKEND=ssh2` 时全走 `ssh2-conn.mjs`（exec/put/get/ping；基础设施 rc=111 三试 5s → 二进制兜底一发）。v1.5.0 起各 driver 自行 export，无需手工设置。

**包根三级默认（pkg-root.sh 单一事实源）**：env `PKG_ROOT` > `$DEPLOY_ROOT/pkg-root.txt` > 现探（内层优先、MANIFEST 版本匹配） > 报错带处置文案。日志统一 `LOGD="${VMDEPLOY_LOG_DIR:-${VMDEPLOY_RUN_DIR:-…}}"`，三 driver 与 step.sh 同径（v1.5.0 修复日志双落点分裂）。

## 通道坏的定位阶梯（简）

1. **永不重启 VM**（用户最高红线）。通道坏=探测并利用健康窗跑最短链，无窗则止损上报。
2. **banner 能到=数据面无罪**；灭窗坏在 sshd 认证/会话建立段（124 挂起 / 111 瞬拒 / 255 公钥拒三形态），非网络层。窗口判定必用**新建连接实测**（长连健康≠新建可用）。
3. **判稳器作 gate**：`wait-channel.sh 2 4` 复用 `vm-conn.sh` 的密钥链与 ssh2 后端（新建连接实测）；`CHANNEL_UNSTABLE` 时 roundtrip 先用 `channel.sh confirm` 的 ssh2 ping 权威复核——复核通则继续（二进制判稳失败≠通道不存在），复核也败才 **止损退出**，不再背靠背硬跑 deploy。

## 卡住时（先查表再动手）

`references/troubleshooting.md`（A 通道 / B 安装拆除 / C 宿主特例 / D gitee / E 版本门槛）。高频：

| 现象 | 根因 | 处置 |
|---|---|---|
| 卸载时通道不通 | 正常输入，不是故障 | 不重建；HOST 本地卸 + VM 合并包给用户 |
| ssh 无输出无限挂起 | VM sshd 连接位占满 | 外层 timeout（已内建）；灭窗用 ssh2 |
| 远端 PS ParserError / `$_` 变怪值 | 本地或远端壳吞改写 | 只走 `ps-run.sh` |
| `ensure-node` rc=0 但 node 仍缺 | 远端长任务超 ssh2 exec 300s 窗 | 按 B 表补跑解压段；delivery 异步化在册 |
| C3.0 env-check rc=124 | VM 重载期通道排队假 FAIL | 不阻断，幂等复跑收敛 |
| `VERIFY=FAIL` 但 health=200 | 旧账回显 / 二进制后端灭窗 | 只读本轮末块；verify 已统一 ssh2 |

## 脚本清单（scripts/）

| 脚本 | 职责 |
|---|---|
| `channel.sh` | **v1.5.0 通道单一动作**：`status`（只判不建）/ `ensure`（deploy 通道保障）/ `confirm`（四段验收+ssh2 复核）/ `post`（VM SYSTEM post 动作拆通道） |
| `vm-remove-local.ps1` | **v1.5.0 VM 端本地卸载**（对齐 `uninstall.mjs buildVmPs1`；`-Apply` / `-PurgeWorkspace` / `-ScheduleTunnelRollback`），全 ASCII |
| `build-vm-bundle.sh` | **v1.5.0 通道坏时**产出 VM 侧合并包（vm 卸载 + hos `-Rollback` + `RUN-ME.ps1` + `PASTE-THIS.txt`） |
| `roundtrip.sh` | 一键往返模板（首选入口）；full 卸载段默认保留通道；R2.5 判稳结果作 gate；末块 `ROUNDTRIP_RESULT` 机器可读 |
| `deploy.sh` / `undeploy.sh` / `verify.sh` | 三流程 driver（deploy/undeploy 默认 dry-run、`--apply` 执行；verify 直接跑；全程 step 计时） |
| `env-detect.sh` / `download-verify.sh` / `pkg-root.sh` | 运行时冒烟、取包三件套、包根三级选根单一事实源 |
| `vm-conn.sh` / `ssh2-conn.mjs` / `ps-run.sh` | 双通道+ssh2 后端、后端实体、远端 PS 铁律执行器 |
| `preflight.sh` / `wait-channel.sh` / `probe-fresh.sh` / `step.sh` | 体检、判稳器（gate）、探针新鲜四防线、计时留痕 |
| `self-rescue.sh` / `env.example` | 能力通道自救（restart-guest 禁用）、`.env` 模板 |
| **内置通道组（v1.6.0）** `host-generate-key.sh` / `winvm-setup-sshd-and-key.ps1` / `verify-tunnel.sh` / `destroy-tunnel.sh` / `host-rollback.sh` / `vm-diag.ps1` | 免密通道创建 / VM 侧 build·`-Rollback`·`-Continue` / 四段验收 / 精确拆除 / 宿主回滚 / 只读体检（原 `hos-winvm-ssh-tunnel` v2.3.0；脚本内 `SKILLDIR` 自定位到本技能根） |

## references（按需加载）

- `troubleshooting.md` — 现象→根因→解法百科（含版本门槛表）
- `known-good-flow.md` — 判据摘录 + 预期耗时带（判「慢是否异常」）
- **[`hos-winvm-ssh-tunnel.md`](references/hos-winvm-ssh-tunnel.md)** — v1.6.0 并入的通道生命周期权威全文（原独立技能 `SKILL.md`，内部链接已按 `references/` 重写）
- `hos-operations.md` / `hos-rollback-contract.md` / `hos-verification.md` / `hos-pitfalls.md` / `hos-troubleshooting.md` — 通道能力五份按需加载参考（原技能 `references/`，交叉链接已重写）

## 权威文档关系

本技能是**唯一执行权威**（部署/安装/启动/验证/卸载全流程；免密通道生命周期自 v1.6.0 起**内置**，已并入 hos-winvm-ssh-tunnel v2.3.0）。母仓库 `docs/deploy/deploy-strategy.md`、`docs/deploy/deploy-reports/` 仅作深参考；`deploy.prompt`/`undeploy.prompt` 自迭代28 起降级退役，**一律以本技能 SKILL.md 与 `references/troubleshooting.md` 为判据来源**（历史 .prompt 仅存档不回改、不再入发布包）。发布包完整性由 pack **V11** 断言钉：技能四件 + URL 入口章 + roundtrip + 通道生命周期章 + 四 driver 在场——v1.6.0 全部保留，新增脚本与参考文档经 `copySkillEntry` 目录白名单自动入包（母项目 pack V11 断言面为字符串包含，合并后仍全绿）。
