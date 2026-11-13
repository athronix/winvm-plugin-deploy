# WinVM 部署问题百科（现象 → 根因 → 解法）

按「执行者撞上的现象」组织；出处的 run/ISSUES 供深挖。**母项目能力门槛一律以发布链 tag 为准；本技能自身语义门槛以 `SKILL.md` frontmatter `version` 为准**（v1.6.0 起「三流程职责定界 + 通道生命周期内置」优先于任何旧记录）。

## A. 通道与网络（最高频）

| 现象 | 根因 | 解法 |
|---|---|---|
| **Skill 工具加载出旧版 SKILL.md（v1.2.2 等）** | `~/.workbuddy/.skill-list-cache.json` 里注册了多个同名 `winvm-plugin-deploy`（旧 unzip 备份 + backup-symlink），工具按索引命中了最旧的一个 | `bash scripts/context.sh collect --fix-registry` 把重复目录隔离到 `~/wbtmp/skill-registry-quarantine/`、去重缓存并使其签名失效；重启会话触发重扫。**执行前务必 `grep '^version:'` 自证技能版本**，绝不拿旧备份当判据 |
| **U1 假 FAIL：`HOST_PASS=11 HOST_FAIL=0 0`**（`[FAIL] HOST` 实为 0，`APPLY complete` 在场） | `HOST_FAIL="$(grep -c '\[FAIL\] HOST' log \|\| echo 0)"`：grep 零匹配输出 `0` 且 rc=1，`\|\| echo 0` 再追加一个 ⇒ `$'0\n0'` ⇒ `!= "0"` 恒真（E2E3 baseline 162s 掐断整链，deploy/verify 全没跑） | **v1.7.0 已修**：改 `awk '/\[FAIL\] HOST/{n++} END{print n+0}'` + `: "${HOST_FAIL:=0}"`；判据改为 `HOST_FAIL=0 && HOST_PASS>=11 && HOST_VRF>=1`（只看 HOST verification 行，不依赖整体 rc——host-only 时 `failures++` 会让 `APPLY complete` 缺席且 rc=1，属预期）。全仓同反模式（roundtrip R4 显示计数）一并清除 |
| **U1 出现 `--- VM: <user>@<ip> (generated .ps1 pushed via scp)` / 卸载耗时翻倍** | `uninstall.mjs resolveVmTarget` 有第四级回退=**包根 `.env` 的 `VM_HOST/VM_USER`**；旧 U1 只藏了 `vm-conn.json` + unset env 链，VM 目标仍能解析 ⇒ PART 1 偷偷跑了完整 VM 卸载，PART 2 又重复一遍；通道坏时该相位还会挂死（与「卸载通道坏是正常输入」冲突） | **v1.7.0 已修**：U1 临时把 `$PKG/.env` 改名为 `.env.host-phase-hidden`，`trap restore_env EXIT` 保证任何退出路径恢复；`unset` 扩到 `WINVM_VM_SSH_PORT`；外层 `timeout 180` 兜底；判据加 `VM_PHASE=0` 硬断言。这样 U1 真正 host-only，U2 是唯一 VM 卸载动作 |
| **部署被要求先安装第二个 skill**（提示按 `INSTALL_PROMPT.md` 装 `hos-winvm-ssh-tunnel`） | 旧版技能（≤v1.5.0）把通道生命周期外委给独立技能 | **v1.6.0 起已内置**：升级/重新取 `winvm-plugin-deploy` v1.6.0+ 技能包即可，6 个通道脚本在 `scripts/`，权威全文在 `references/hos-winvm-ssh-tunnel.md`；仅当显式设 `HOS_TUNNEL_SKILL` 时才走独立技能路径（向后兼容） |
| **deploy 时通道不在**（`channel.sh ensure` → `NEED_USER_ACTION=1`；`deploy.sh` C1 → `DEPLOY_NEED_USER_ACTION=1` rc=2） | 宿主机→VM 从未建过公钥通道，或通道已被销毁 | **仅 deploy 允许建通道**：`channel.sh ensure` 调内置 `scripts/host-generate-key.sh "$WINVM_VM_KEY" …` 打印整段一键脚本 → 用户在 VM 管理员 PowerShell 粘贴一次 → `channel.sh confirm`（内置四段验收 + `ssh2-conn.mjs ping` 权威复核）→ 重跑 `deploy.sh --apply`。通道已在则不建（`CHANNEL_EXISTS=1`）。密钥单一事实源=`WINVM_VM_KEY` 三级链，禁止两把钥并存都试；内置 `scripts/verify-tunnel.sh` 走 ssh 二进制，灭窗期失败≠没建好。**undeploy 通道不在绝不重建**（见下行）。 |
| **undeploy 时通道已不在 / 拆到一半断了** | **正常输入，不是故障**（旧 P-2「通道失效→外委重建」v1.5.0 已废止） | 绝不重建通道：WorkBuddy 本地完成 host 段，`build-vm-bundle.sh` 把 VM 卸载 + 内置 `-Rollback` 合并成 `VM_BUNDLE` 目录，用户在 VM 管理员 PowerShell 执行 `RUN-ME.ps1` 一次；判据 `TUNNEL_POST_MERGED=1` + `VM_BUNDLE=`。通道在时则由 `channel.sh post` 把回滚设为 VM 侧 SYSTEM 任务 `WbTunnelRollback`（会话自断后仍能跑完）。 |
| `vmssh whoami` 挂起、**rc=124 且 stderr 为空**（TCP 已连、认证阶段不回；run13 定谳=VM 开机后 3~10min 挂起期+密集重试自毒半开槽） | sshd 连接位被占满/开机期 auth 挂起（Windows OpenSSH 开机负载+域解析慢；BatchMode/ConnectTimeout 救不了 TCP 层挂起） | ①ssh/scp 外层必包 `timeout`；②**probe 五试间隔 15s**（【run15 更正：旧『3s 太密会自毒』已被密测证伪——17:33 窗开 2s×12 连发全通；间隔实为相位观察节拍，非安全阀】)；③调用方 timeout 预算 ≥3×(VM_SSH_TIMEOUT+15)+余量（如 35s×3+30≈150s 起，**外层小于内层=白跑**）；④冷开机期判 RED 前至少等 5 分钟再单发复测；⑤>10min 仍挂=VM 内管理员 `Restart-Service sshd`；⑥禁并发多轨同 VM |
| **ssh 新连持续 rc=124 全灭，但 tunnel health 稳定 200** | **run14 定谳修正：这【不是】暂停**——隧道 HTTP 持续 200=vCPU 一直活着（暂停时 vm-service 必无应答）；真形态=**sshd 监听栈坏死**（TCP accept 得进、协议层无响应；lastBootUpTime 未变佐证没重启），restart-service/taskkill /F /T 树全无效（后者还瞬断既有隧道=副作用慎用）。真·暂停指纹=ssh 与隧道【都】间歇挂 | 解药=guest 整机重启；重启后健康窗实测仅 ~7-11min，长链 driver 抢不进=环境级故障上报用户（Defender 网络过滤/vEthernet 交换机/域），勿循环耗轮次；rhythm-check 已带 SSHD_STACK_WEDGE/PERIODIC_SUSPEND 二分 |恶化曲线实录（run14/15 同夜）：boot 窗 7min→restart-service 放 1 枪→闪窗→16min 零窗；越早处置越可能抢进链（≥15min 稳定窗是 driver 全链硬前提） |
| **用户整机重启后窗仍塌缩**（run15g 终态：11:21 boot→11:24 单发 rc=0→11:25 起 driver 五试全 124） | WEDGE 已进【持久态】：整机重启从解药降级为只能开 3 分钟级窗，sshd 新入站路径坏死与 boot 无关 | 停止窗口赌局；根因排查移交 VM 桌面（管理员 PS）：①Get-WinEvent Microsoft-Windows-OpenSSH* ②Defender 网络检查系统/实时保护临时关 60s 对照 ③宿主虚拟化 App 里重置 VM 网络适配器（NAT⇄桥接）。期间 MCP 隧道侧一切照常（38/38 实证） |
| **run15h 定位法（三步定谳 sshd 无罪）** | ①能力通道在 guest 内跑 TcpClient 自连 `127.0.0.1:22` 与 `VM 自身 LAN IP:22` → 双双秒回 banner + ②宿主 ping VM 通、TCP 握手成功但 banner 时有时无 + ③guest 内 CloseWait/SynRecv=0 无半开堆积 ⇒ **sshd/防火墙/Defender 全部排除，坏=宿主↔VM 虚拟交换机（vEthernet/WVMBr）入站新连接的数据面丢包**（SYN/ACK 控制面过、后续数据包黑洞）；重启 sshd/guest 都解释不了也治不了它 | 处置移向【网络层而非 sshd】：guest 内关 NIC offload（TCP/IPv4 checksum + LSO V2，经典『TCP 连上无数据』解药）与关 NIC 电源管理；宿主虚拟化 App 里重置 VM 网络适配器；两法都不算重启 VM。⚠ 经能力通道远程改 NIC 有瞬断既有隧道风险（改完 VM 桌面兜底恢复），默认让用户在 VM 控制台执行。【v1.1.7 更正：本行『数据面丢包』定性被 run15i 证伪——14:59 全链认证通+15:16-18 banner 28/28 秒回；banner 能到=数据面无罪，灭窗坏在 sshd 子进程/lsass 认证段（PerSource 节流嫌疑）；offload/重置网卡指示作废】 |
| **相位开合实证（run15g~n 全天采样定档）** | 灭/开与重试密度、参数形态（裸/CT8~15/±SAI±SHK±p22）、静置时长（120s grace 不够）全无关；同日实测：17:09 开(10/10)、17:22 灭(裸+probe+grace 全 124)、17:33 开(2s×12 全通)、17:38-50 灭(20 连)—**窗=2~5min 开合的随机相位**，同秒分叉 0.2s-vs-20s 排除拥塞渐变模型，指向 sshd 子进程/lsass 段的相位式抽风（机制未定，网络层/认证限流/半开堆积/DNS 全部排除）。**run20 定案解法=换后端**：VM_SSH_BACKEND=ssh2 走 node ssh2 库（同秒二进制 124 时 ssh2 恒 READY<1s），全链三段 0/0/0 实锤（run20）；根因仍在环境侧（建议项：VM 桌面查 OpenSSH operational 日志+lsass 性能，低优先） | driver 编排改**窗驱动短段制**：段前单发探窗（CT6/12s），命中即冲最短链（undeploy 段实测 ~2min 可完成），塌了退 25s 再探；长链赌窗=已知必败（run15 全天 6 轮拦停零误伤为证） |
| `Permission denied (publickey)`（明明免密在） | 宿主 `~/.ssh` 属主随 uid 漂移（沙箱 uid 跨调用变化），known_hosts/id_ed25519 权限位失效 | 编排走独立选项 `-F /dev/null -o UserKnownHostsFile=/dev/null`（vm-conn 密码通道已内建）；长期=两把密钥分开（GitHub 用 id_ed25519_github，VM 通道重建用默认键） |
| sshd 在跑、端口在听，但 TCP 超时 | 防火墙规则 Profile 与网卡 Profile 不匹配（R3） | VM 管理员：`Set-NetFirewallRule -Name OpenSSH-Server-In-TCP -Profile Any`；诊断见 preflight FW= 行 |
| 连不上且 ping 通 | VM 被 hypervisor 暂停/睡眠 | VM 管理端设「自动暂停=从不 + 开机自启」；guest 内电源只是部分（prepare-vm DB-5） |
| **ping 100% 丢包** | VM 整机离线（hypervisor 关机/暂停/网络断开） | **P-4 人工点：非任何脚本可解**——用户在 VM 管理端开机/恢复后重试；期间 skill 离线件（env-detect/download-verify/pack 校验）不受阻可先行 |
| ssh 传 `/End` 变 `C:/.../End`、`$_` 变路径 | 远端默认壳=Git-Bash/MSYS 改写 | 铁律通道（见 B 首行） |
| 内联 PowerShell 报 ParserError/怪值 | 双引号命令串里 `$_`/`$p` 被**本地** bash 先展开（run11 0.4 实测） | 与远端同权对待：单引号 heredoc 写 `.ps1` → ps-run；短片段 `-c` 走 EncodedCommand |

## B. 安装/拆除

| 现象 | 根因 | 解法 |
|---|---|---|
| Step3 apply「cd C:/WinVMBridge 找不到路径」反复失败（上百次） | ≤V1.4.8 安装载荷=Git-Bash 专属语法而 sshd 默认壳 cmd.exe（R8 隐藏前置） | ≥V1.4.9 已根除（跨壳 .ps1/EncodedCommand）；**不需要**装 Git for Windows/改 DefaultShell |
| apply 报 420s 未监听，服务像没起 | 首实例「僵而不绑」（8K 工作集不占端口）；端口反查对其全盲 | ≥V1.4.15 VM-START 命令行签名清扫根治（I-6.16）+V1.4.16 修击杀实现（I-6.17：PS5.1 CMSL 无 `.Terminate()`→Invoke-CimMethod）；旧包=按脚本重跑本步 |
| 拆除 rc=1，FAIL=C:/WinVMBridge absent(observed:True)+no vm-service process(True) | 残留僵尸 node：8K/无子/不绑端口，**管理员三式强杀全免疫**（taskkill /F、Process.Kill、CIM Terminate 皆无效） | 终极解=VM 内 `shutdown /r /t 5 /f` 重启 guest（~60s sshd 恢复）→ 复跑 undeploy（19/19 rc=0） |
| uninstall rc=1 但自报 0 failure 且唯一 FAIL=workspace kept | ≤V1.4.8 已知保留项断言误报（I-6.7） | 以 U4 独立复核为准继续；V1.4.9+ 已修 |
| task_state=Ready 但服务其实在跑 / GUI 能力报 SESSION_UNAVAILABLE | schtasks 包装器退出后任务态=Ready；实例落 Session 0 | `SKILL.md` 安装主流程 C3.3 兜底判据（Ready+listen=1+200=可继续）；GUI 需 `schtasks /End+/Run` 重触发落交互会话（run9/10 实测） |
| E7 `EXC timed out` | 探针客户端窗 ≤V1.4.15 硬编码 120s（I-6.13） | ≥V1.4.16 包内探针 330s；旧包换仓库 HEAD 探针跑 |
| E7 `EXECUTION_TIMEOUT` 且 durationMs≈120000 | 服务端能力闸 120s（I-6.14，客户端修好后露出的下一层） | ≥V1.4.17 盘扫族 300s；勿再当"瞬态"复跑放行 |
| 探针链总时长比基线慢 ~50-100s | 冷启带宽：llmSession/ps-bridge starting 拖慢 E4/E7 首批（run12：深冷 239s vs 热 97s） | 判据=零超时零复跑；X-5 三档带（~97/~145/≤250s）内勿误判回归 |
| BUILD 相位 exit 127 整链 rc=1 | 发布包不随发 typescript（白名单本意），纯净宿主无法 npm run build；且 dist 预构建其实可用（X-7 假败） | ≥V1.4.20 自动降级 SKIP；或恒用 `--skip-build`（发布包标准入口） |
| **prepare-vm --ensure-node 显示完成但 node 仍缺**（`vm -v` 报找不到；TEMP 有完整 node.zip 而 `C:\nodejs` 空） | E2Q2：远端下载+解压超 ssh2 exec 300s 硬窗 → 超时回落二进制一发（若钥又不符=Permission denied 静默）⇒ **rc=0 假完成**，解压段被截断。判据=zip 完整在 %TEMP% 而 node.exe 缺 | 补跑解压段（铁律 .ps1：Expand-Archive→Copy 到 C:\nodejs→Machine PATH 前置→`node.exe -v` 实判 v24.21.0）；勿整跑 apply 赌重下（zip 已在场解压段 <60s）。delivery 异步化（fire+poll 落盘标记）在册 backlog |
| **拆机后背靠背装 RED（ping rc=111 / 二进制 rc=255 "Permission denied"，非 124）** | e2e2R6：undeploy 会触发 sshd/系统重启，之后存在**认证段瞬态窗**——光谱三形态：124 挂起 / 111 瞬拒 / 255 公钥拒（"VM 开机期"文案只覆盖 124）。瞬拒期刚过钥又可用（S8→复测 2s 通） | **v1.5.0 F-09**：`wait-channel.sh` 已改为复用 `vm-conn.sh` 密钥链 + ssh2（旧裸 ssh 错钥=必然假 UNSTABLE）；roundtrip full 的 R2.5 **作 gate**：连击 UNSTABLE 先用 `channel.sh confirm` 的 ssh2 新建连接复核，复核通=继续，复核也败=止损退出（旧 `|| true` 吞掉仍进 R3=805s 假 FAIL）。手工分步=拆后 `bash scripts/wait-channel.sh 2 4`；勿据此查钥/重建通道（钥是对的，只是窗）；绝不重启 VM。 |
| **卸载后 R2.5 四轮 DOWN、channel.confirm 报 `Permission denied (publickey,password,keyboard-interactive)`，被判「环境灭窗」** | **F-22（E2E3 第二轮实锤：这是确定性密钥漂移，不是环境窗）**：部署端默认探测会把 `vm-conn.json.identityFile` 写成 `~/.ssh/id_ed25519`，而 VM 授权的可能是 `~/.ssh/id_ed25519_winvm`；旧 `context.sh collect` 无验证直接采信 ⇒ 卸载 U2 误判通道坏→生成 VM 合并包→判稳 4×DOWN→GATE 停链。同秒双钥新建连接实测：`id_ed25519` ssh2 ping rc=111（All configured authentication methods failed）、`id_ed25519_winvm` rc=0（pong ready） | **v1.7.0 F-22**：`context.sh collect` 对候选钥（env → vm-conn.json → `id_ed25519_winvm` → `id_ed25519`）逐一做 **1 发 ssh2 ping 新建连接实测**，冻结第一个 READY 并写 `VM_KEY_PROBE=READY` 到 context.env；全败才保留首选并标 `ALL_FAILED` 交下游 GATE 判读。复核命令=`WINVM_VM_KEY=<候选> node scripts/ssh2-conn.mjs ping`（逐钥对照 rc）。**勿据此查防火墙/重装 sshd/重启 VM**；链内 `WINVM_VM_KEY` 已 export，部署端读同一 env 会把正确钥写回 vm-conn.json。 |
| **env-check（C3.0）rc=124 且日志缺 ENV_PRECHECK（E2E3 实证）** | 三因叠加：F-19 旧 `ps-run.sh` 远端清理串用 JS 模板 ``${base}``（bash 变量，JS 未定义）⇒ 每次 PS 调用后必抛 ReferenceError、EncodedCommand 为空、临时 .ps1 泄漏且白耗一次 ssh2 往返；F-20 通道瞬态截断 30s timeout 时日志已有 `NODE_OK=true`/`CLI_OK=true` 却缺 `ENV_PRECHECK` 行，旧实现直接汇入 `FAILED_STEPS` ⇒ deploy rc=1 ⇒ R3 FAIL ⇒ R4 verify 被 SKIP（假红拖垮整链）；F-21 旧判据 `grep -q ENV_PRECHECK` 连 `ENV_PRECHECK=FAIL` 也命中（假绿） | **v1.7.0 三修（确定性、有界、可证伪）**：F-19 清理串改 `process.argv[1]` 零插值（本地实测 base64 解码=`Remove-Item -LiteralPath "vm-env-check.ps1" -Force -ErrorAction SilentlyContinue`）；F-20 C3.0 只在 rc∈{124,111,255} 或日志含 `vmssh: ssh2 传输层失败`、且 `NODE_OK=true`+`CLI_OK=true` 在场时**幂等复跑 1 次只读 env-check**，达标即 `PASS retry=1`，首试日志留 `env-check.attempt1.log`；F-21 判据收紧为 `ENV_PRECHECK=PASS` **且** `BLOCKERS=none`。配置性失败（BLOCKERS≠none / NODE_OK=false）与 `ENV_PRECHECK=FAIL` 绝不吞，仍按 P-2 处置、绝不重启 VM；四用例行为守卫（瞬态复跑 / 假绿拦截 / 配置失败不吞 / 非传输类不重试）=ALL_GREEN。 |
| `.env` 填了 WINVM_VM_PASSWORD 隧道仍要密码失败 | ≤V1.4.19 setup 只读 process.env 不回注（X-6） | ≥V1.4.20 凭据自动回注（白名单+env 优先）；旧版=运行前 source 一个含 export 的 env.sh |
| 隧道段 V8 FATAL errno=12 | $NODE 选中脆弱 hnp node（.mjs 执行崩、-e 正常） | v3.0.x 探测冒烟门禁自动避开；旧版手动 export NODE 到 bundle node 再 `tunnel ensure` |
| deploy 中途 VM 重启/断电后一切卡住 | sshd 未起+hypervisor 层状态 | 恢复 VM → vm_channel_probe → 从失败相位重跑（全链幂等；setup 重试吸收此类瞬态） |
| 想彻底拆干净重灌 | —— | 标准流程=`undeploy.sh --apply`（v1.5.0 三段：host→vm→ssh 通道）→ `deploy.sh --apply`（通道保障→两端部署）；两 driver 幂等。**往返用 `roundtrip.sh` full：卸载段默认 `--keep-tunnel`**，否则拆掉通道后重装要再人工建一次；单独 `undeploy` 才默认拆通道 |
| `VERIFY=INCOMPLETE ENV_WINDOW=1`（rc=2） | deploy ready 后 VM 通道落在瞬态窗，VM 终态行取不到；**环境问题非功能失败** | 不建/不修通道、不重启 VM；等健康窗后只重跑 `verify.sh`。旧版直接计 `VERIFY=FAIL`，v1.5.0 起既不计功能失败、也不宣称 PASS |

## C. 宿主环境特例（鸿蒙沙箱）

| 现象 | 根因 | 解法 |
|---|---|---|
| `/bin/bash` bad interpreter / heredoc 误解析 | 系统 shim 损坏 | `env-detect.sh` 探测健康 bash（含"能执行带 shebang 的脚本文件"冒烟）；退化路径=node -e / 写文件执行 |
| `rm` bad interpreter | 同上 | `fs_rm`（node fs）；日日志/证据目录勿 rm -rf |
| shell-init getcwd 警告刷屏 | 沙箱固有 | 判据字段 ASCII 不受影响；X-4 放行（capture 用 2>/dev/null）。**v1.7.0 起**：`step.sh::_error_excerpt` 内置 deny-list，这三行不再进 `error_excerpt`（F-25） |
| `actions.tsv` 的 `log_path`/`error_excerpt` 整表恒为 `-` | `step.sh log` 收到的是**动作名**（`env-check`/`prepare-vm`），而 `end` 收到的是**环节号**（`3.0`/`3.2`），找不到同名日志（F-23，E2E3 实证） | ≥v1.7.0 由 `logs/.index` 记 epoch→名，`end` 在自身 `[begin,end]` 窗口内取最后写入的驱动日志；旧 run dir 用 `v170_backfill_actions.py` 事后回填（保留 `.orig`） |
| 无错误关键字的日志也留空摘录（非 `-`） | `grep … \| cut \|\| echo "-"` 的管道退出码取末命令，`\|\|` 永不触发（F-24） | ≥v1.7.0 先捕获再归一：空→`-` |
| 大文档批量 Edit 后内容缩水/出现字面 `\n` | python 普通串转义 | 每处 assert count==1 + 写后 grep 扫 `|\n|` 字面（项目铁律） |
| 明文密码落 .env | 交付残留风险 | env.example 注释化该键；部署完删行（deploy-reports 提醒） |
| **「判稳失败/NO_CHANNEL」但同刻手工单发却通** | 调用方外层 `timeout` < 被包脚本最坏时长（rounds×120s 量级），把仍在判稳的循环中途杀成失败假象；或 reboot 后 100s 短睡就开测而 Windows+sshd 实需 5-8min | 外层预算 ≥ rounds×120（wait-channel 头注）；restart 后首轮前 sleep ≥240s；判稳失败先**手工单发复测一次**再定性（run14 18:45 假失败/18:44 已通的错位实证） |
| **verify 终态 connector skills=0**（历轮基线 8；disabledTools/health 均正常） | 宿主侧外部因素可清空 `~/.workbuddy/connectors/skills/`（run15g 实证：目录 mtime 落在宿主重启窗口，非本项目任何脚本所为——undeploy 当时根本没跑） | `install-host --yes` 重跑即幂等恢复 8/8（run15g 实测 rc=0）；verify.sh 已把该项打进终态矩阵，见 0 即跑 install-host，勿查 VM |
| 一行式内嵌 python/sed 报 syntax error/rc=127 撕碎整链 | 双引号里嵌套单引号被 shell eval 拆坏（run13 实证：token 提取一行式炸整链；与「禁内联含 $」同源的第二形态） | 复杂逻辑一律 `cat > x.py <<'EOF'` 落盘再跑；令牌经文件/环境变量中转并即删；同族=python 普通串 `\n`/路径转义坑 |
| **URL 入口装技能后 ssh2 后端报「ssh2 解析失败」**（技能在 `~/.workbuddy/skills/`、包在 `$DEPLOY_ROOT`） | ≤V1.4.24 缺陷：ssh2-conn 候选链写死 `../../../..`+旧绝对路径，技能装到用户级目录后距包根八层深、且 DEPLOY_ROOT 可覆写——两候选全不命中（11-06 新机模拟实锤） | ≥V1.4.25 候选链动态化（env PKG_ROOT > pkg-root.txt 状态 > DEPLOY_ROOT 常规落点）；旧版绕行=显式 `export PKG_ROOT=<包根>` 无效时进包根跑 driver |
| sha256sum -c 报 no such file（本地保存名≠旁挂内登记名） | 下载时 `-o` 改名了，sidecar 用的是发布资产名 | curl `-o` 必须用资产原名（skill_url 尾段即原名）；判据失败先 `ls` 核对名形再重跑 |

## D. gitee 发布面（取包主源特有）

| 现象 | 根因 | 解法 |
|---|---|---|
| gitee 下载二次续传 403 | 302→foruda 是**一次性签名** URL | 失败=整文件重试（勿 `-C -`）；github 备源可续传（见 `SKILL.md`「URL 单指令入口」章） |
| `sha256sum -c` 报 no such file winvm-overall-... | sidecar 内是相对名 | 判据①必须 `cd pkg/` 后跑（driver 已内建） |
| gitee API 建 release 422 / 改库 400 | POST /releases 必带 `target_commitish`；PATCH /repos 必带 `name` | publish-release.mjs --mirror-gitee 已内建；手工调 API 时记住 |
| 附件"删了又出现"重复 | attach_files 无 upsert 且落盘名会小写化 | 同名判定要大小写不敏感；先 DELETE 再 POST（mirror 逻辑已处理） |

## E. 版本门槛速查（问题 ↔ 修复起始版本）

R8 跨壳=V1.4.9 · KEEP 误报=V1.4.9 · 探测冒烟/僵尸重启=V1.4.16（D1/I-6.15b 文案） · VM-START 清扫=V1.4.15、击杀生效=V1.4.16 · 服务端闸 300s=V1.4.17 · 探针窗 330s=V1.4.17 · 避坑清单 X-1~X-6=v3.0.6~v3.0.7 · gitee 主源=v3.1.0 · .env 凭据回注+BUILD 降级=V1.4.20 · ssh2 后端全量=V1.4.21 · 技能入包=V1.4.23 · 独立技能包上架=V1.4.24 · **URL 入口 ssh2 候选链修复=V1.4.25** · 技能矩阵化（canonical 独立仓+roundtrip 模板+通道外委 hos+技能单权威=旧 .prompt 退发布链）=**V1.4.26**（技能包 v1.4.1 起随该 tag 双端上架） · **技能 v1.5.0**=三流程职责定界 + `channel.sh` 通道单一动作 + VM 侧合并包 + 探针复用全绿门（`deploy_ok=1`）+ 判稳 gate + verify `ENV_WINDOW`（本技能自身版本；需母项目 V1.4.27+ pack 才随包分发） · **技能 v1.7.0**=一次执行统一入口 `run-flow.sh` + 环境事实前置冻结 `context.sh` + 动作级日志 `actions.tsv`/`states/*` + 全分支决策表 `action-catalog.tsv` + 过程执行环节信息表 `action-report.sh`（前台只打最终表，`VERBOSE=1` 出中间信息）+ F-17 假红/F-18 重复卸载/skill 注册漂移三修复 · **技能 v1.8.0**=自检门禁 `scripts/selfcheck.sh`（15 项 + `--mutate` 5 组变异自证） · **技能 v1.6.0**=通道生命周期内置（并入 `hos-winvm-ssh-tunnel` v2.3.0：6 脚本 + 6 参考文档，`HOS` 默认指向本技能根，**一次安装即可、不再需要装第二个 skill**）。

## F. 自检门禁（v1.8.0 · 本地可验证面）

改完脚本/文档、发布前一律先跑 `bash scripts/selfcheck.sh`（不需要 VM、不碰通道）。

| 现象 | 根因 | 解法 |
|---|---|---|
| FAIL `bash -n all scripts` | 改脚本时语法破坏 | 看 FAIL 行尾 `(文件, 错误首行)`，修完重跑 |
| FAIL `control chars zero` | 编辑引入 NUL/控制字符（多轮编辑静默损坏的典型表现） | 行尾给出文件名，重写该文件或剔控制字符 |
| FAIL `frontmatter name/version` | version 不是 `x.y.z` | 改 SKILL.md frontmatter（唯一版本源） |
| FAIL `V11 SKILL.md string anchors` | 改文案时删掉了 pack V11 依赖的字符串 | 见 FAIL 的 `missing=[...]`，把锚点补回（V11 fail-loud 拒产包） |
| FAIL `packaging whitelist captures new files` | 新脚本不在 `scripts/`/`references/`/`assets/` 下 | 挪进三目录之一，`copySkillEntry` 白名单才收 |
| FAIL `F-21 strict verdict` | 判据被改成宽匹配（全文搜字符串） | 恢复 `_envcheck_ok()` 函数体内 `ENV_PRECHECK=PASS` ∧ `BLOCKERS=none` ∧ `&&` 串联 |
| FAIL `F-23/24/25 action-trace guard` | `step.sh` 的日志索引 / 空摘录归一 / 噪声白名单被改坏 | 按 `known-good-flow.md` 观测链口径恢复 |
| FAIL `markdown relative links` | 文档改名/移动后链接断 | 按 `(文件, 目标)` 修 |
| 自检绿但实际坏了 | 断言是「字符串存在式」，抓不住逻辑改动 | 跑 `--mutate`：对应变异若 MISSED 即假绿，改成结构化解析 |
| `--mutate` 报 `HARNESS_CRASH … SAFE_DELETE_BULK_CONFIRM_REQUIRED` | 沙箱批量删除护栏（50 个/回合）把**子进程**拦死，子进程异常退出又没有 FAIL 行 | 自检已改「零删除 + 每例独立目录」；若仍出现，说明有人把清理逻辑加回去了——恢复默认不清理（`SELFCHECK_CLEAN` 才是删） |
| 自检跑完留下一个工作区目录 | **设计如此**：默认不清理（见上条） | 路径打在 `WORK_DIR=`；要清就 `SELFCHECK_CLEAN=1`，或把 `SELFCHECK_WORK` 指到 `$TMPDIR` |

**判据**：常规出 `SELFCHECK=ALL_GREEN checks=15 fails=0`；`--mutate` 出 `MUTATION_RESULT=ALL_CAUGHT`。
两项都绿才可发布。`SKIP`（无 node / 非 git 检出）不算 FAIL，但汇报时要点明跳过了哪项。
