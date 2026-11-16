# 已知良好流程（判据形态 + 耗时带宽）

用途：判断「慢是不是异常」「这一步本来该输出什么」。数据源=v2.0.0 结构下的真机实测
（`~/wbtmp/refactor-v2-*`、`e2e6-1429`）。判据权威始终是 `SKILL.md` 与脚本内的实际断言。

## 一、5 步部署的预期耗时带

前提：通道已建立、包已缓存（第二次及以后跑）。冷装另注。

| 步 | 子段 | 预期带 | 异常信号 |
|---|---|---|---|
| **1** | 1a 判通道 | <2s | >10s = ssh2 ready 超时，看是否 WEDGE |
| | 1b 备钥 | <1s（复用） | `ssh-keygen` 不可用 |
| | 1c 打印命令 | <2s（含 URL HEAD + latest 解析） | >20s = gitee API 慢 |
| | 1d 验证 | 用户粘完 5s 内 | 超 60s 仍不通 = VM 侧脚本失败，查 `-Continue` |
| **2** | 2a 取包 | 0~2s（缓存命中）/ 60~180s（首下 3MB + 解压） | `SHA256_MISMATCH` 立即停 |
| | 2b MANIFEST | 1~3s | 失败=陈旧层或白名单漂移 |
| | 2d install-host | 1~3s | >30s 或 `errno=12` = 宿主内存压力 |
| **3** | 3a 对齐 identityFile | <1s | — |
| | 3b 起隧道 | 0s（已 healthy 跳过）/ 1~3s（restart） | restart 后会扰动第 4 步的握手（见 troubleshooting） |
| | 3c health | 1~5s | >60s 反复 000 = daemon 或 VM 端 18443 不通 |
| **4** | 4.0 通道门禁 | 0s（正常）/ ≤60s（等健康窗） | 超时=WEDGE，止损别重启 VM |
| | 4a prepare-vm | 20~30s（依赖已就绪仍要 3 次远程往返） | >90s = VM 侧慢或握手超时 |
| | 4b setup --only-vm | 40~70s（BUILD+scp+install+VM-START） | >420s 未监听 = 僵尸 task |
| | 4c vmcheck | 10~20s | 七判据任一不符 |
| **5** | 探针 | 34 项 ~100s；`PROBE_DEEP=1` 38 项 ~200s | 单项 >300s 查服务端闸 |
| | 复用（stamp 新鲜同包） | ~0s | 报 `no-count`= 无法核验判 FAIL |
| | 5d 终态矩阵 | 8~15s | `ENV_WINDOW=1` = 环境瞬态窗 |

**全链参考**：热跑（通道在/包缓存/探针复用）**约 90~120s**；探针冷跑 **约 190~230s**；
其中第 4 步是唯一的大头（占 60~70%），第 1~3 步合计通常 <10s。

## 二、3 步卸载的预期耗时带

| 步 | 预期带 | 异常信号 |
|---|---|---|
| 1a 停隧道 | 1~3s | health 仍 200 = daemon 自愈重启 |
| 1b 卸 host 端 | 20~40s | `HOST_PASS<11` 或 `VM_PHASE_IN_HOST≠0` |
| 1c host 复核 | 1~3s | 残留 mcp 条目 |
| 2a 通道判定 | <2s | 通道不在 = 正常（`exit 2`） |
| 2b scp 卸载脚本 | 1~3s | 通道瞬态 → 稍后重跑本步 |
| 2c 停服务+删模块 | 15~30s | 无 `VM_CLEANUP_DONE` |
| 2d VM 五点 | 5~12s | 残留目录/任务/端口 |
| 3 拆通道 | 0s（默认保留）/ 60~120s（SYSTEM post 动作 + 等通道消失） | `PENDING_USER` = 需用户在 VM 执行 |

**全链参考**：默认（保留通道）**约 45~70s**；带拆通道 **约 110~190s**。

## 三、关键判据的原文形态

| 步 | 判据行形态 |
|---|---|
| 1a | `[OK] 1a (1s) channel=READY key=id_ed25519_winvm → 1b~1d SKIP` |
| 1c | `NEED_USER_ACTION=1` + `脚本来源: <url>` + `公钥指纹: 256 SHA256:...` |
| 2b | `[OK] 2b (2s) RESULT: PASS ...`（manifest 末行） |
| 3c | `[OK] 3c (3s) health=200` |
| 4c | `task_state=... listen_count=1 health_http=200` |
| 5 | `[OK] 5 (...) PROBES 34/34 SKIP=4 deep=0` |
| 5d | `VM: task=Ready listen=1 sshd=Running` + `health=200` + `connector skills=8` |
| 部署收尾 | `DEPLOY=PASS` + `ALL_DONE=1` |
| verify | `VERIFY=PASS` / `VERIFY=INCOMPLETE ENV_WINDOW=1` / `VERIFY=FAIL:<段>` |
| 卸载收尾 | `UNDEPLOY=PASS host=clean vm=clean tunnel=no` |

## 四、判「慢是否异常」的次序

1. 先看 `steps.tsv` 哪一段超带（`~/wbtmp/winvm-deploy-*/steps.tsv`）。
2. 第 4 步超带 → 看 `prepare-vm.log` / `setup.log` 里的相位名；`setup.log` 自带相位计时。
3. 任何 `rc=124` 且**零输出** → 先量载荷耗时（`VM_PS_TIMEOUT` 是否够），别先怀疑通道。
4. 通道类异常 → 用**新建连接**实测（`ssh2-conn.mjs ping`）复判；`health=200` 不算证据。
