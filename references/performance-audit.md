# 效率审计（v2.0.0 结构）

记录「时间花在哪、哪些是物理下限、哪些是可省」。历史逐动作审计（v1.9.1 的 23 动作版）已归档到
`references/legacy/`；本文件只保留仍然成立的结论 + v2.0.0 实测。

## 一、结构简化带来的直接收益

| 项目 | v1.9.2（旧编排层） | v2.0.0 | 说明 |
|---|---|---|---|
| 脚本数 | 24 个（含 roundtrip/run-flow/context/action-* 五件套） | **11 个现行 + 7 个底座** | 编排层从 18 个降到 8 个步脚本 |
| 第 1~3 步实测 | 取包 + 通道 + 隧道 ≈ 100s | **≈ 6s**（缓存命中 + 隧道已就绪短路） | 3b 幂等跳过 restart 是主因 |
| 探针跑几次 | deploy 跑一次，verify 复用（靠 4 防线 stamp） | 同（stamp 内联进 `deploy-5-verify.sh`） | 无第二次冷跑 |
| 动作级留痕 | `actions.tsv` + `action-catalog.tsv` + `action-report.sh` | `steps.tsv` 六列 | catalog 的"下一步命令"改由脚本自身打印 |

### 全链实测（v2.0.0 首轮 E2E，2026-11-16 18:23:32 起）

环境：通道已就绪、发布包已缓存、VM 端已装过一次（幂等重装）。

| 阶段 | 分步 | 小计 |
|---|---|---|
| A（第 1‖2 步） | 1a 1s · 2a 0s · 2b 1s · 2c 0s · 2d 1s · 2e 0s | **2s** |
| B（第 3‖4 步） | 3a 0s · 3b 1s(SKIP already-healthy) · 3c 1s ／ 4.0 1s · 4a 64s · 4b 168s · 4c 33s | **2s / 266s** |
| C（第 5 步） | 5 探针（复用上一轮 34/34）1s · 5d 矩阵 17s | **19s** |
| **WALL_S** | | **293s** |

结论：**时间几乎全在第 4 步**（4a 依赖补齐 64s + 4b 推包重装 168s 占 79%），第 1/2/3/5 步合计 <25s。要再快只能动 4b（VM 端重装），属物理下限（tar + 3MB 传输 + 远端解包 + 服务冷启），不做投机优化。

## 二、物理下限（不可再压，别再优化这些）

| 项 | 量级 | 为什么是下限 |
|---|---|---|
| VM 端 BUILD + scp + install | 30~50s | tar 打包 + 3MB 传输 + 远端解包，网络与磁盘实打实 |
| VM-START（起服务到端口监听） | 10~20s | Windows 服务启动 + node 冷启 |
| prepare-vm 全 SKIP | 20~30s | 依赖已就绪仍要 3 次远程往返（每次含 PS 冷启 8~10s） |
| 三探针 34 项 | ~100s | 每项都是真实 MCP/HTTP 往返；深度项（LLM 委派 30s、盘扫 100s）已默认 SKIP |
| 终态矩阵 | 8~15s | 一次 VM 探测（PS 冷启 + schtasks + .NET 监听查询） |
| 宿主 PS 冷启 | 8~10s / 次 | 每个 `-c` / `-File` 载荷都要付 |

## 三、已实施的关键优化（别回退）

| 优化 | 效果 | 落在哪 |
|---|---|---|
| CIM 全枚举 → 原生原语 | `Get-ScheduledTask`→`schtasks /fo CSV`；`Get-NetTCPConnection`→`.NET GetActiveTcpListeners()`：单次 20~35s → <1s | `deploy-4/5`、`undeploy-2` |
| 传输预算 / 载荷预算分离 | 载荷 25s→180s，消除「跑完才输出」被截断成 rc=124 零输出的假红 | `ps-run.sh` `_payload` |
| 探针分级 | 38 项 269s → 34 项 ~100s；`PROBE_DEEP=1` 恢复全量 | `deploy-5-verify.sh` + 包内探针 |
| 隧道 restart 幂等短路 | 避免重建 ssh 连接扰动第 4 步（并省 2~3s） | `deploy-3-tunnel.sh` 3b |
| 探针新鲜复用内联 | deploy 后立刻 verify 省 ~100s | `deploy-5-verify.sh` stamp 判定 |
| install-host 拆 `--no-tunnel` | host 侧安装从 ~40s 降到 1~3s，隧道独立成第 3 步可单独计时/单独重跑 | `deploy-2-host.sh` 2d |

## 四、刻意不做的事（有理由，不要"顺手优化"）

| 想法 | 为什么不 |
|---|---|
| 把 3 和 4 改成串行 | 用户裁定并行；且 3 已幂等短路，实际冲突面只剩"首次 restart"一种，用 4 的 60s 健康窗门禁 + 一次重试兜住 |
| undeploy 异步删文件 | 用户裁定不接受：异步删除会让"卸载完成"的判据失去意义（无法确认真的删掉了） |
| 提高 `VM_SSH_TIMEOUT` 到 180s | 会让"真断线"场景从 25s 变 180s 才报错，把瞬态掩盖成长时间挂起；载荷已走独立预算 |
| 把探针再砍几项 | 34 项已是"能证明链路真的通"的最小集；再砍就只剩"端口开着"这种弱证据 |
| deploy 幂等重跑的 ultra-short 模式 | 未实现。当前热跑 90~120s，主要花在第 4 步的重复安装（幂等但不可跳过，除非引入"装态指纹"）——属可选优化，需先定义指纹失效条件 |

## 五、2026-11-16 实测（v2.0.0 首次真机）

`VM_HOST=172.16.100.2 RELEASE_TAG=V1.4.29 bash scripts/deploy.sh`：

```
1a 判断 host↔VM 免密通道                          1s  READY（1b~1d SKIP）
2a 取发布包（sha256 校验 + 隔离解压）              0s  缓存命中
2b MANIFEST 对账                                 2s  PASS
2c 两端结构就位检查                               0s
2d install-host --yes --no-tunnel                1s  PASS
2e host 端交付判据（connector skills ≥8）          0s
3a 对齐 vm-conn.json 的 identityFile             0s
3b 起隧道服务（幂等）                              2s  restart
3c 验证隧道（/health = 200）                      3s  PASS
-------------------------------------------------  WALL_S=6（到第 3 步完成）
4a prepare-vm --ensure-node                      26s  FAIL ← 通道 WEDGE
```

4a 的失败不是结构问题：当时 `ping` 通（3~9ms）、隧道 `health=200`（长连活着），
但**新建 ssh 连接握手超时**（`Timed out while waiting for handshake`）——典型 WEDGE。
第 1~3 步在同一时点全部 PASS，说明前面三步的判据与实现都成立。

**结论**：1~3 步从旧版约 100s 压到 **6s**，且每步都可单独重跑；第 4、5 步待健康窗复验。
