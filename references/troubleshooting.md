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
| 三轮都没建起来 | 密钥 / 网络 / 权限三者之一 | 看 `1b.*`/`1c.*` 各轮日志；VM 侧 build 段应有 `[+]` 行而无 `[x]` |
| `ping` 100% 丢包 | VM 整机离线（关机/暂停/断网） | 用户在 VM 管理端开机/恢复。脚本救不了，别循环重试 |

**通道判定只用新建连接实测**（`ssh2-conn.mjs ping`）。`health=200` 是**长连**健康，不等于新建可用——
两者分叉正是 WEDGE 的指纹。

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

## 第 5 步：verify

| 现象 | 根因 | 处置 |
|---|---|---|
| `VERIFY=INCOMPLETE ENV_WINDOW=1` | 通道瞬态窗，取不到 VM 终态行。**环境问题，非功能失败** | 等健康窗只重跑 `verify.sh`；不宣称 PASS 也不误报 FAIL |
| `total-33!=34` / `skip-N!=4` | 探针项数被改动 | 同步改 `deploy-5-verify.sh` 的 `EXP_TOTAL/EXP_SKIP`。**刻意告警，别放宽** |
| `no-count` / `meter-missing` | 探针日志里找不到 `x/y` 计数 ⇒ 无法核验 | 看对应 `logs/<probe>.log` 尾部；探针崩了就是真 FAIL |
| 单项探针 > 300s | 服务端闸/网络 | 查该探针日志；`EXECUTION_TIMEOUT`（服务端）与 `timed out`（客户端）两形态别混 |

## 卸载

| 现象 | 根因 | 处置 |
|---|---|---|
| 通道不在，第 2 步 `exit 2` | **正常输入**，不是故障 | 按提示在 VM 里手工删服务与目录；**绝不为此重建通道** |
| `HOST_PASS<11` 或 `HOST_FAIL>0` | host 清理项失败 | 看 `uninstall-host.log` 的 `[FAIL] HOST` 行 |
| `VM_PHASE_IN_HOST≠0` | `.env`/`vm-conn.json` 没屏蔽干净，host 相位跑成了双端 | 已有 trap 还原；若复现说明还有第四处 VM 目标来源，需补屏蔽 |
| 第 3 步 `TUNNEL=PENDING_USER` | 通道不在，只能用户在 VM 里跑 `-Rollback` | 照打印的那一条执行；宿主侧私钥/known_hosts 已同时清理 |

## 环境/工具类

| 现象 | 根因 | 处置 |
|---|---|---|
| 内联 PowerShell 报 ParserError / `$_` 变怪值 | 本地 bash 先展开了 `$`，或远端壳是 Git-Bash/MSYS | 复合逻辑写 `.ps1` → scp → `powershell -File`；短片段 `-EncodedCommand`。一律经 `ps-run.sh` |
| `-File` 载荷 rc=124 且**零输出** | 载荷耗时 > 超时窗。载荷自身实测 47~56s | 用 `VM_PS_TIMEOUT`(180s) 而不是 `VM_SSH_TIMEOUT`(25s)。**先量载荷耗时，勿先怀疑通道** |
| 计数判据恒失败（`HOST_FAIL=0 0` 之类） | `grep -c ... \|\| echo 0`：零匹配吐 `0` 且 rc=1，兜底再追加一个 0 | 一律 `awk '{n++} END{print n+0}'`；selfcheck 的 `no-grep-c` 断言会拦住 |
| Skill 工具加载出旧版 SKILL.md | 同名 skill 重复注册命中旧备份 | `grep '^version:' SKILL.md` 先自证版本；清理 `~/.workbuddy/skills/` 下重复/备份目录后重启会话 |
| 宿主侧要删文件 | 鸿蒙沙箱 `rm` 不可靠 | `node -e 'fs.unlinkSync(...)'`；禁 `rm -rf <目录>` |
