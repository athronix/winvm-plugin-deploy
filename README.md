# winvm-plugin-deploy

WinVM Bridge（[workbuddy-virtual-win-plugin](https://github.com/athronix/workbuddy-virtual-win-plugin)）鸿蒙宿主 ⇄ Windows VM **双端一键安装 / 拆除 / 复验**专用技能（athronix skill 矩阵成员，canonical 独立仓）。

- 技能主体：`SKILL.md`（frontmatter 触发元数据 + 主流程/子流程编排 + 铁律）
- **v1.7.0 首选入口**：`scripts/run-flow.sh`（一次调用完成 卸载→安装→验证；`context.sh` 前置冻结全部动态参数；`action-catalog.tsv` 全分支确定性路由；`action-report.sh` 生成过程执行环节信息表；默认前台只打最终表，`VERBOSE=1` 出中间信息）
- **v1.9.0 传输预算 / 载荷预算解耦**：`vm-conn.sh` 新增 `VM_SSH_EXEC_TIMEOUT`（默认回落 `VM_SSH_TIMEOUT`）与 `VM_SSH_TRIES`；`ps-run.sh` 的 PowerShell **载荷**执行统一经 `_payload` 前缀，走独立预算 `VM_PS_TIMEOUT`（默认 180s、2 试），连接/握手/scp/远端清理仍 25s。根因：`vmcheck.ps1` 自身实测 47/53/56s（`Get-ScheduledTask` 全枚举 + `Get-NetTCPConnection` + `/health` + PS 冷启）> 旧 30s 每次窗，且 `-File` 载荷「跑完才输出」⇒ 超时=零输出 rc=124，被误读成通道坏。守卫 `F-26` + 变异 `M6`
- **v1.8.0 自检门禁**：`scripts/selfcheck.sh`（16 项静态+行为断言，不需要 VM；`--mutate` 跑 6 组变异证明断言可证伪；末行 `SELFCHECK=ALL_GREEN` / `MUTATION_RESULT=ALL_CAUGHT`；整条链零删除，工作区默认保留并打印 `WORK_DIR=`，确需清理传 `SELFCHECK_CLEAN=1`）
- `scripts/` — 可执行 driver：`roundtrip.sh`（一键往返模板，动态参数仅 VM_HOST/VM_USER/ACTION/tag）、`deploy.sh`/`undeploy.sh`/`verify.sh` 三流程、`channel.sh`（通道单一动作 status/ensure/confirm/post）、`vm-remove-local.ps1` + `build-vm-bundle.sh`（通道坏时 VM 侧合并包）、download-verify、preflight、env-detect、ssh2 通道后端、计时 step 等；**v1.6.0 起另含内置通道组** `host-generate-key.sh` / `winvm-setup-sshd-and-key.ps1` / `verify-tunnel.sh` / `destroy-tunnel.sh` / `host-rollback.sh` / `vm-diag.ps1`（并入自 `hos-winvm-ssh-tunnel` v2.3.0）
- `references/` — `troubleshooting.md` 问题百科（现象→根因→解法，30+ 实战条目）、`known-good-flow.md` 耗时基线带，以及 **v1.6.0 并入的通道生命周期六件套** `hos-winvm-ssh-tunnel.md`（原独立技能 `SKILL.md` 全文）+ `hos-operations.md` / `hos-rollback-contract.md` / `hos-verification.md` / `hos-pitfalls.md` / `hos-troubleshooting.md`

## 消费方式（任意 AI Agent）

- WorkBuddy 本机：symlink 挂载 `~/.workbuddy/skills/winvm-plugin-deploy`（改动即时生效，免重装）
- 其它机器：clone 本仓（**私有仓，需 PAT `contents:read`**）或下载 Release zip `winvm-plugin-deploy-<version>.zip` 解压到该 Agent 的 skills 目录
- URL 单指令入口（生产分发形态）：发布链同时产出 `winvm-plugin-deploy-skill.zip`（随母项目双端 release，见母项目 `delivery/pack-release.mjs`），对新机发「请依据 skill {skill_url} 安装/卸载/验证 winvm-plugin」即可全自主

## 环境设置（skill-dev-git 规范）

- 本仓 `core.sshCommand=~/.workbuddy/git-ssh.sh`（host-aware 密钥分流，裸 `git push` 即用对钥；勿依赖 ~/.ssh/config——hmdfs 属主权限 ssh 拒用）。
- 远端=athronix/winvm-plugin-deploy（private）；gh CLI 缺位时发布走 skill_dev.py 的 API 通道（`via:"api"`），token=hosts.yml（scope 含 workflow）。
- 发布链：改内容落 canonical → `skill_dev.py commit`/`push` → version 变则 `package`+`release`（gh 主路径，缺位自动 API 降级）→ **GitHub `athronix/skills` 聚合仓 sync dispatch 并等 run 完成** → API 读 `marketplace.json` 核对该条 version（raw CDN 有缓存假象）→ **Gitee `athronix/skills` 从 GitHub 聚合仓镜像同步（remote_mirror/pull）+ 双端 HEAD 追平确认**。`release` 默认内置后两段轮询；`--no-wait` 只跳过确认。

## 版本纪律

frontmatter `version` 为唯一版本源（SemVer：文案 PATCH / 兼容能力 MINOR / 破坏结构 MAJOR）；发布走 skill-dev-git 通道（package → tag `v*` → GitHub Release asset → 双聚合仓同步）。**当前 v1.9.0**：传输预算与载荷预算解耦（`VM_PS_TIMEOUT=180` 默认 + `_payload` 前缀 + `F-26`/`M6` 守卫；E2E4 定谳「探针 rc=124 且零载荷输出 ≠ 通道坏，先量载荷耗时」）；**v1.8.0**：自检门禁 `scripts/selfcheck.sh` 随技能分发（16 项断言 + `--mutate` 6 组变异自证；F-21 改为解析 `_envcheck_ok()` 函数体的结构化断言——字符串存在式会假绿）；**v1.7.0**：一次执行统一入口 `run-flow.sh` + `context.sh` 前置冻结 + 动作级日志/环节表 + 全分支决策表；补丁轮收编 E2E3 实证 F-19/F-20/F-21（`ps-run.sh` 清理串零插值 / C3.0 有界幂等复跑 / `ENV_PRECHECK=PASS`∧`BLOCKERS=none` 判据）；F-22 密钥实测择优（`context.sh collect` 用 ssh2 新建连接逐钥验证，冻结第一个 READY，避免 `vm-conn.json` 陈旧 identityFile 把部署链误导入「通道坏」分支）；F-23/F-24/F-25 动作级观测链三修（驱动日志与 step 编号解耦解析 / 空摘录归一 `-` / 沙箱 getcwd 噪声白名单）。**E2E3 真机基线**：`run-flow.sh` `ACTION=full` 单次调用 994s、23 个动作全 PASS、`VERDICT=YES`。**v1.6.0 起** SSH 免密通道生命周期**内置**——独立技能 `hos-winvm-ssh-tunnel` v2.3.0 的 `SKILL.md` 全文与 6 脚本 + 5 参考文档整体并入，`HOS` 默认指向本技能根，**部署只需装本技能一个**；三流程职责定界与判据不变。历史：v1.7.0 统一入口 `run-flow.sh` + 参数前置冻结 + 动作级日志/环节表 + E2E3 真机全绿 · v1.6.0 通道生命周期内置（部署只需一个 skill） · v1.5.0 三流程职责定界（卸载三段且通道坏绝不重建 / 部署通道在则不建 / verify 仅 deploy ready 后自调）+ `channel.sh` 通道单一动作 + VM 侧合并包 + F-02/03/05/07/09 缺陷修复 · v1.4.3 E2E2 整改 · v1.4.2 E2E1 整改 · v1.4.1 旧 .prompt 退役 · v1.3.0 roundtrip 模板+探针新鲜复用。
