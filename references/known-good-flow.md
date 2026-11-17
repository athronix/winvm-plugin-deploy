# 已知良好流程（判据形态 + 耗时带宽）

用途：判断「慢是不是异常」「这一步本来该输出什么」。数据源=**2026-11-17 三轮真机实测**（v2.0.3）
+ v2.0.0 结构下的 `~/wbtmp/refactor-v2-*`、`e2e6-1429`。判据权威始终是 `SKILL.md` 与脚本内的实际断言。
⚠ 耗时带随 VM 侧负载浮动，**同一份代码实测出现过 2.5 倍差**（见 deploy-timeline §四）；超带先按 §四 归因，别直接判回归。

## 一、5 步部署的预期耗时带

前提：通道已建立、包已缓存（第二次及以后跑）。冷装另注。

| 步 | 子段 | 预期带 | 异常信号 |
|---|---|---|---|
| **1** | 1a 判通道 | <2s | >10s = ssh2 ready 超时，看是否 WEDGE |
| | 1b 备钥 | <1s（复用） | `ssh-keygen` 不可用 |
| | 1c 打印命令 | <3s（双源 HEAD 探测，**不再调任何 API**） | >20s = VM 侧 raw 源不可达 |
| | 1d 验证 | 用户粘完 5s 内 | 超 60s 仍不通 = VM 侧脚本失败，查 `-Continue` |
| **2** | 2a 取包 | 0~2s（缓存命中）/ 60~180s（首下 3MB + 解压） | `SHA256_MISMATCH` 立即停 |
| | 2b MANIFEST | 1~3s | 失败=陈旧层或白名单漂移 |
| | 2d install-host | 1~3s | >30s 或 `errno=12` = 宿主内存压力 |
| | 2e connector skills | 0~1s，判据 **`skills=10`** | <10 = 装的是旧包（两个上游技能面未随包分发） |
| **3** | 3a 对齐 identityFile | <1s | — |
| | 3b 起隧道 | 0s（已 healthy 跳过）/ 1~3s（restart） | restart 后会扰动第 4 步的握手（见 troubleshooting） |
| | 3c health | 1~5s | >60s 反复 000 = daemon 或 VM 端 18443 不通 |
| **4** | 4.0 通道门禁 | 0s（正常）/ ≤60s（等健康窗） | 超时=WEDGE，止损别重启 VM |
| | 4a prepare-vm | 20~65s（**全部 `[SKIP]` 也要 6 次远程往返**；实测 20/27/65s 三轮） | >90s = VM 侧慢或握手超时 |
| | 4b setup --only-vm | **61~155s**（`[VM]` 96s + `[VM-START]` 44s + `[QA-PROBE]` 15s；每轮无条件重推 8MB 并重装，无内容短路） | >420s 未监听 = 僵尸 task |
| | 4c vmcheck | 13~38s | 七判据任一不符 |
| | **4d 上游工具面** | **3~12s**（首次触发懒启动 12s，已就绪 3s） | 判据必须是 `OK browser=33 desktop=10`；`ERR:http-502`=上游未装、`ERR:http-404`=服务是旧版 |
| **5** | 探针 | **16~38s**（34 项，v1.9.2 起分级）；`PROBE_DEEP=1` 38 项更长 | 单项 >300s 查服务端闸 |
| | 复用（stamp 新鲜同包） | ~0s | 报 `no-count`= 无法核验判 FAIL |
| | 5d 终态矩阵 | 8~26s（实测 8/8/13/15s） | `ENV_WINDOW=1` = 环境瞬态窗 |
| | **5e 上游工具面** | **3s** | 同 4d 口径；health=200 时失败=真缺陷 |

**全链参考**：热跑（通道在/包缓存）实测 **126s / 135s / 274s / 413s** 四轮；探针冷跑再加 ~20s。
其中第 4 步是唯一大头（占 75%~91%），第 1~3 步合计通常 <10s。
**274s 那轮不是回归**：`4b` 从 61s 涨到 155s 是「覆盖已存在目录的重装」+ `4a` 六项探测往返 65s，判据全绿（分解见 deploy-timeline §四）。
**413s 那轮也不是回归**：样本是「先完整 undeploy 再全新 deploy」的从零闭环 —— `[VM]` 全新解压 165.6s + **上游 CLI 首次 `npm i -g` 47.9s** + `4a` 76s + `4c` 38s（分解见 deploy-timeline §六）。上游装过之后再跑即回到 0s。

## 二、3 步卸载的预期耗时带

| 步 | 预期带 | 异常信号 |
|---|---|---|
| 1a 停隧道 | 1~3s | health 仍 200 = daemon 自愈重启 |
| 1b 卸 host 端 | 20~40s | `HOST_PASS<11` 或 `VM_PHASE_IN_HOST≠0` |
| 1c host 复核 | 1~3s | 出现 `卸载器未清的条目已兜底移除: …` 属**正常兜底**（旧包卸载新装），不是失败；`mcp_left` 非空才是失败 |
| 2a 通道判定 | <2s | 通道不在 = 正常（`exit 2`） |
| 2b scp 卸载脚本 | 1~3s | 通道瞬态 → 稍后重跑本步 |
| 2c 停服务+删模块+卸上游 | **58~70s**（僵尸 node 清理 + `npm uninstall -g` 两个包） | 无 `VM_CLEANUP_DONE`；`UPSTREAM_LEFT` 非 `NONE` |
| 2d VM 六点 | 17~35s | 残留目录/任务/端口/上游 CLI |
| 3 拆通道 | 0s（默认保留）/ 60~120s（SYSTEM post 动作 + 等通道消失） | `PENDING_USER` = 需用户在 VM 执行 |

**全链参考**：默认（保留通道）实测 **79s / 105s**；带拆通道再加 ~70~90s。

## 三、关键判据的原文形态

| 步 | 判据行形态 |
|---|---|
| 1a | `[OK] 1a (1s) channel=READY key=id_ed25519_winvm → 1b~1d SKIP` |
| 1c | `NEED_USER_ACTION=1` + `脚本来源: <url>` + `公钥指纹: 256 SHA256:...` |
| 2b | `[OK] 2b (2s) RESULT: PASS ...`（manifest 末行） |
| 3c | `[OK] 3c (3s) health=200` |
| 4c | `task_state=... listen_count=1 health_http=200` |
| 4d | `OK browser=33 desktop=10`（`[OK] 4d (12s) browser=33 desktop=10`） |
| 5 | `[OK] 5 (...) PROBES 34/34 SKIP=4 deep=0` |
| 5d | `VM: task=Running listen=1 sshd=Running` + `health=200` + `connector skills=10` |
| 5e | `OK browser=33 desktop=10` |
| 部署收尾 | `DEPLOY=PASS` + `ALL_DONE=1` |
| verify | `VERIFY=PASS` / `VERIFY=INCOMPLETE ENV_WINDOW=1` / `VERIFY=FAIL:<段>` |
| 卸载收尾 | `UNDEPLOY=PASS host=clean vm=clean tunnel=no` |

## 四、判「慢是否异常」的次序

1. 先看 `steps.tsv` 哪一段超带（`~/wbtmp/winvm-deploy-*/steps.tsv`）。
2. 第 4 步超带 → 看 `prepare-vm.log` / `setup.log` 里的相位名；`setup.log` 自带相位计时。
3. 任何 `rc=124` 且**零输出** → 先量载荷耗时（`VM_PS_TIMEOUT` 是否够），别先怀疑通道。
4. 通道类异常 → 用**新建连接**实测（`ssh2-conn.mjs ping`）复判；`health=200` 不算证据。
