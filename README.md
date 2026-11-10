# winvm-plugin-deploy

WinVM Bridge（[workbuddy-virtual-win-plugin](https://github.com/athronix/workbuddy-virtual-win-plugin)）鸿蒙宿主 ⇄ Windows VM **双端一键安装 / 拆除 / 复验**专用技能（athronix skill 矩阵成员，canonical 独立仓）。

- 技能主体：`SKILL.md`（frontmatter 触发元数据 + 主流程/子流程编排 + 铁律）
- `scripts/` — 可执行 driver：`roundtrip.sh`（一键往返模板，动态参数仅 VM_HOST/VM_USER/ACTION/tag）、deploy/undeploy/verify、download-verify、preflight、env-detect、ssh2 通道后端、计时 step 等
- `references/` — `troubleshooting.md` 问题百科（现象→根因→解法，30+ 实战条目）与 `known-good-flow.md` 耗时基线带

## 消费方式（任意 AI Agent）

- WorkBuddy 本机：symlink 挂载 `~/.workbuddy/skills/winvm-plugin-deploy`（改动即时生效，免重装）
- 其它机器：clone 本仓（**私有仓，需 PAT `contents:read`**）或下载 Release zip `winvm-plugin-deploy-<version>.zip` 解压到该 Agent 的 skills 目录
- URL 单指令入口（生产分发形态）：发布链同时产出 `winvm-plugin-deploy-skill.zip`（随母项目双端 release，见母项目 `delivery/pack-release.mjs`），对新机发「请依据 skill {skill_url} 安装/卸载/验证 winvm-plugin」即可全自主

## 版本纪律

frontmatter `version` 为唯一版本源（SemVer：文案 PATCH / 兼容能力 MINOR / 破坏结构 MAJOR）；发布走 skill-dev-git 通道（package → tag `v*` → GitHub Release asset）。当前 v1.3.1：roundtrip 模板+探针新鲜复用（时间预算战役）+ symlink 兼容修复。
