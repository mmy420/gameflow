# GameFlow 实施计划

> SPEC 讲「是什么、为什么」，本文讲「先做什么、怎么算做完」。
> 每个阶段结束时系统都**处于可用状态**——不是半成品，是「能力少一点但不会坏事」的成品。

---

## 阶段划分与依赖

```
0 地基 ──▶ 1 巡检(A) ──▶ 2 解压(B,不删) ──▶ 3 开删除 ──▶ 4 投递
  │                                                          │
  └──────────────────▶ 5 Codex 操作面（可与 1-4 并行）         │
                                                              ▼
                                                    6 MTool(C)（可选，随时）
```

**0 → 1 → 2 → 3 → 4 是硬顺序**，理由是破坏面单调递增：0 和 1 一个字节都不写用户数据，2 只写不删，3 才开始删（限枢纽内），4 才跨卷搬。
**5 可以随时插入**——脚本能直接用命令行跑，skills 只是包一层触发。但其中 0.1 的 `prefix_rule` 实测要最早做（见下）。

---

## 阶段 0 · 地基

**这一阶段一行业务逻辑都不写。** 它的产出是「知道自己站在什么地面上」+「一套所有人共用的底层」。

### 0.1 先打掉四条实测（半天）

不做这个，后面每一行代码都建在假设上。逐条命令见 SPEC §11。

| # | 测什么 | 不测的后果 |
|---|---|---|
| 1 | 环境快照：`7z.exe` 在不在 PATH、版本、是否只有 WinRAR/Bandizip GUI；`$PSVersionTable`；枢纽卷文件系统；系统 ACP；`LongPathsEnabled`；`Get-ExecutionPolicy -List` | SPEC 每一节都建在沙上 |
| 2 | Codex 沙盒能否写 `D:\GameHub`（project 开在 `D:\GameFlow`，配 `sandbox_workspace_write.writable_roots`） | 执行体 A 第一步写文件就失败，或被迫开 full access（不可接受） |
| 3 | `prefix_rule` 对 `powershell.exe -NoProfile -Command "…"` 的拆分语义（`codex execpolicy check`） | 7z 免审批写不出来 → 每次解压都要人点一次 → A 失去无人值守的意义。**这条决定阶段 5 的形态，所以要最早测** |
| 26 | 真实游戏包的最长内部条目路径（拿现有 3–5 个已解压目录跑 `7z l -slt` 求 `Path` 最大长度与中位数） | 不知道 MAX_PATH 预算够不够 → 不知道目录名降级会不会频繁触发 → 可能要重选枢纽根名字 |

**产出**：一份 `docs/preflight-findings.md`，把四条的实测结果与结论写下来。后续任何与之矛盾的 SPEC 断言，以这份为准。

### 0.2 `Preflight.ps1` — **已写好，等你在 Windows 上跑**

`scripts\Preflight.ps1`。**只读**，不写任何文件（除非你给 `-OutFile`）。它把 0.1 里除 #2/#3 之外的全部探测都固化了，包括 #26 的最长内部路径测量。

```powershell
cd D:\GameFlow
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Preflight.ps1 `
    -HubRoot D:\GameHub `
    -SampleGameDirs 'D:\你已解压的某个游戏','E:\另一个' `
    -OutFile .\docs\preflight.json
```

- 用 `powershell.exe`（5.1）跑，不要用 `pwsh` —— **Codex 那一层就是 5.1**，这个脚本要先证明自己在 5.1 上能跑。
- `-SampleGameDirs` 给不给都能跑，但**不给就测不到 §11 #26**，那条决定目录名降级会不会频繁触发。
- 退出码：`0` = 无 FAIL，`3` = 有 FAIL（前置条件不满足）。

**完成判据**：跑出来没有 FAIL；`preflight.json` 里 `archiver.sevenzip_path`、`hub.filesystem`、`codepage.acp`、`internal_paths.worst_E` 四个字段都有值。

**#2 与 #3 这个脚本测不到**，必须在 Codex 会话里做（脚本末尾会把这两条打出来提醒）：

- **#2**：Codex 里开 project = `D:\GameFlow`，配 `sandbox_workspace_write.writable_roots = ["D:\\GameHub"]`，让 agent 实际写一个文件
- **#3**：`codex execpolicy check --rules <rules> -- powershell.exe -NoProfile -Command "& '7z.exe' t x.7z"`，看 `prefix_rule` 是整条匹配还是按子命令拆分

### 0.3 `scripts\lib\` 六个模块

这是全项目的地基，A 和 B 共用。**六个模块写错的代价都是静默的**，所以每个都要先有测试。

| 模块 | 职责 | 最容易写错的地方（SPEC 出处） |
|---|---|---|
| `Io.ps1` | UTF-8 无 BOM 读写、`-LiteralPath` 强制 | 5.1 的 `-Encoding utf8` 带 BOM、裸 `>` 是 UTF-16LE、`Get-Content` 按 ANSI 解码中文（§8.8.2）。**这是最容易造成真实数据损坏的一条** |
| `Json.ps1` | 读写 JSON | 裸 `ConvertTo-Json` 默认 `-Depth 2`，第 4 层被静默截断；一律显式 `-Depth 10`（§8.8.3） |
| `Journal.ps1` | `events.jsonl` 追加 + 重放重建 `state.json` | 必须 `-Compress`；整行一次 `Write` + `Flush($true)` + 立即关闭；读取端丢弃尾部半行；**按文件行序重放，不按 `seq` 排序**（§3.3、§8.8.5） |
| `Lock.ps1` | 批次锁 + 条目锁 | `FileShare.None` 独占句柄；**不要**用 lock 文件 + PID 检测（§8.8.6） |
| `Paths.ps1` | `dirname` 生成、MAX_PATH 预算断言、**I6 路径围栏** | `dirname` 算法九步顺序不可换；ACP 往返必须用 `EncoderExceptionFallback`（默认的替换 fallback 会静默成功）（§3.2A） |
| `SevenZip.ps1` | 唯一的 7z 封装 | `exit == 0` 严格相等（`1` 是"有文件被静默跳过"）；每包单独调用；**永不传具体 `-t` 类型名**；stdin 重定向 + 超时（§6.2.1） |

**完成判据**：每个模块有对应的 fixture 测试且全绿。`Paths.ps1` 的 `dirname` 算法要用日文标题、含 `:` `?` 的标题、超长标题、保留设备名（`NUL.txt`）各跑一遍。

**先把 `tests\fixtures\` 从调研产物拷过来**——`lab7z/`、`lab/`、`fixtures/` 里已经造好了带密码的、多重嵌套的、分卷的、伪装扩展名的、Shift-JIS 名的、路径穿越的样本，直接可用。

---

## 阶段 1 · 执行体 A（只读巡检）

**A 一个字节都不删。** 这一阶段跑完，你就有了一个「能告诉你现在是什么状况」的系统。

| 任务 | 产出 | 完成判据 |
|---|---|---|
| 1.1 批次清单 schema + `New-Batch.ps1` | `templates\batch.template.json` | 给一组链接密码，生成合法批次；`dirname` 正确推导；非法 `group` / 超预算 `destination_root` 被拒（退出码 2） |
| 1.2 认领归位 | `Invoke-Sweep.ps1` 的 claim 段 | `_inbox` 里的文件按「`expected_files` 精确名 → 分卷组名 → 站点模式 → `claims.json`」归位；**认不出来的一律不动**，进报告「待认领」区 |
| 1.3 下载完成判定 G1–G6 | 同上 | 六重与条件全实现。**用真实下载验 G2**：下载途中跑巡检，必须判为未完成 |
| 1.4 归档识别 + 卷集归组 | 同上 | 魔数表按偏移读；**先按命名分组再判型**（中间卷魔数是垃圾）；缺卷检出 |
| 1.5 只读预检 | 同上 | `7z l -slt` **不带密码**；体积预算、压缩比（`sum(Size)/Physical Size`）、路径穿越自查；头加密包 `exit 255` → `WAITING_FOR_PASSWORD` |
| 1.6 对账报告 | `Get-BatchReport.ps1` | 五区分组、好读；每个停机态给出具体人工动作 |
| 1.7 计划任务注册 | 一段注册脚本 | `Interactive` + `Limited` + `IgnoreNew`；**非 S4U** |

**反向判据（不可协商）**：跑 A 前后对整个枢纽做全量快照比对，**除了 `.gameflow\` 和 `_reports\`，一个字节都没变**。

**跑到这里你能用它做什么**：把一批游戏丢进 `_inbox`，它会告诉你哪些下完了、哪些缺卷、哪些缺密码、哪些认不出来。解压还得手动。

---

## 阶段 2 · 执行体 B（解压，删除关闭）

配置里 `delete_archives = false`。**只写不删，全部可撤销。**

| 任务 | 产出 | 完成判据 |
|---|---|---|
| 2.1 密码链 | `Invoke-Work.ps1` 的 password 段 | P0 先试且不占预算；密码库按 `hit_count` 降序，**≤8 次 7z 探测**；用尽 → `WAITING_FOR_PASSWORD`。**排序第一键必须是 `priority_tier`**，否则你给的密码会被高命中的库内候选挤到后面 |
| 2.2 密码库 | `vault.clixml` + `Add-VaultEntry` / `Reset-VaultStats` | 三个必填字段（`secure` / `hit_count` / `added_at`）；DPAPI 加密；命中后 `hit_count += 1` |
| 2.3 解压与递归 | 同上 | 解到 `_stg\<8hex>\`；`-t*` 强制单层；**深度按「解开一个白名单容器 = +1」计**，不按调用次数；`max_depth=5` 触顶 → `BLOCKED_RESOURCE` |
| 2.4 分卷 `.NNN` 重建 | 同上 | C7 的唯一硬例外。**整组补齐**，只对 `_stg\<8hex>-p\` 里的副本操作，原文件永不改名 |
| 2.5 逐条目校验 | 同上 | `exists` + `size` 对账；symlink / junction / reparse 一律拒绝；**永不用 `-snld20`** |
| 2.6 内容判定 | 同上 | `content_files > 0`；只有 readme 时**把它喂给密码抽取器**（很可能就是密码文件），不是直接判失败 |
| 2.7 落地 | 同上 | `_stg` → `<hub>\games\<dirname>\`，同卷 rename |

**完成判据**：拿 3–5 个**真实**压缩包（含带密码、多重嵌套、分卷各一个）跑通到 `EXTRACTED`。
**反向判据**：源包**一个不少地**躺在枢纽里。

**跑到这里你能用它做什么**：全自动下载 + 解压。压缩包还得你自己删。

---

## 阶段 3 · 打开删除

`delete_archives = true`。**这是第一个不可撤销的阶段。**

| 任务 | 产出 | 完成判据 |
|---|---|---|
| 3.1 D1–D12 十二条与条件 | `Invoke-Work.ps1` 的 delete gate | 逐条实现。`D2` 必须 `exit -eq 0` **严格相等**——写成 `-le 1` 就是在部分解压失败时删掉唯一的源文件 |
| 3.2 I6 路径围栏 | `Paths.ps1` | **每一次** `Remove-Item` 前断言目标在 `hub_root` 内；规范化全路径前缀比对；不跟随 reparse point |
| 3.3 删除由已落盘状态 gate | 同上 | 读 `state.json` 的 `verified` + `consumed_by`，**不现场重判**（幂等的唯一来源） |
| 3.4 SHA-256 记录 | `manifest.json` | 删除前写入。误删后至少能确认重下的是不是同一个包 |
| 3.5 两段式删除 | `_trash\<batch-id>\` | `< trash_max_bytes` 的先进 trash，`trash_days` 后清理 |
| 3.6 Defender 预检 | 同上 | 在 `_stg` 里做、**落地之前**；三级分流；`-DisableRemediation` 的 stdout 解析器（格式见 0.1 的实测） |
| 3.7 完整状态机 | `Journal.ps1` + 各处 | 全部停机态的进入、解除、幂等、崩溃恢复 |
| 3.8 B 的计划任务 | 注册脚本 | `Interactive` + **`Highest`**（`MpCmdRun` 要提权） |

**反向判据（最重要的一组）**：
- 故意让一个包解压不完整（删掉一个分卷）→ **源包一个都没删**
- 故意造一个路径穿越样本 → 落 `BLOCKED_RESOURCE`，无文件被删
- 解压中途 `Stop-Process -Force` → 重跑能从 `events.jsonl` 完全恢复，不重复删除

**跑到这里你能用它做什么**：SPEC §1.7 描述的完整第一阶段，除了游戏还待在枢纽里。

---

## 阶段 4 · 投递

| 任务 | 产出 | 完成判据 |
|---|---|---|
| 4.1 `Invoke-Deliver.ps1` | 新脚本 | 同卷 rename / 跨卷复制+删源两条路径 |
| 4.2 `DELIVERING` + `WAITING_FOR_DESTINATION` | 状态机 | `destination_root` 为 `null` 时停在等待态，`gf-deliver -To` 解除 |
| 4.3 `destination_root` 校验 | `New-Batch.ps1` | 卷存在且 NTFS、可写、不在 OneDrive / `Program Files` 下、**按投递那一条算预算**；报告开头回显 |
| 4.4 `.gameflow\` 迁移 | 同上 | 随目录搬走，搬完回写新绝对路径 |
| 4.5 **终态核验 F1–F6** | 同上 | 六条全过才进 `COMPLETE`（SPEC §6.14）：目标无归档、枢纽侧已消失、staging 已回收、`_inbox` 无残留、源包全删、目标无临时物 |

**F1 必须用容器白名单 + 扩展名排除表**，不能用「7z 能不能打开」——`.pak` / `.apk` / `.jar` / `.docx` 本来就是 zip 格式，用错判据会让任何带 `.pak` 的 Unity 游戏永远卡在核验不过。

**反向判据**：目标已存在同名目录 → **不覆盖不合并**，落 `BLOCKED_RESOURCE`，枢纽那份原封不动。跨卷复制中途强杀 → 枢纽那份仍然完整。带 `.pak` 的真实 Unity 游戏投递后必须能过 F1。

完整验收见 SPEC §10.3.5。

---

## 阶段 5 · Codex 操作面（可与 1–4 并行）

六个 skill 放 `.agents\skills\`，`allow_implicit_invocation: false`。

| skill | 脚本 | 什么时候能做 |
|---|---|---|
| `gf-new-batch` | `New-Batch.ps1` | 阶段 1 之后 |
| `gf-sweep` | `Invoke-Sweep.ps1` | 阶段 1 之后 |
| `gf-reconcile` | `Get-BatchReport.ps1` | 阶段 1 之后 |
| `gf-work` | `Invoke-Work.ps1` | 阶段 2 之后 |
| `gf-deliver` | `Invoke-Deliver.ps1` | 阶段 4 之后 |
| `gf-foreground` | 无（GUI） | 阶段 6 |

配套三件：`AGENTS.md` 的红线、`config.toml` 的 `writable_roots`、`Set-ExecutionPolicy RemoteSigned`。

**入口参数纪律**：只接收 `-BatchId <slug>` 这类无空格无歧义 token。最外层永远是 5.1 的解析规则，带空格或中文的路径在那里就被拆坏了。

---

## 阶段 6 · MTool（可选，随时）

只在需要翻译时做。**它是唯一占前台的部分**，也是唯一无法被替代的 Computer Use 用途。

先做引擎识别（有序判定表，SPEC §7.6）与 `mtool-profiles` schema，再做前台流程。
注意 `UNKNOWN` ≠ 不支持（Enigma Virtual Box 打包的 MV 就判 UNKNOWN 但能处理）→ 停 `WAITING_FOR_MTOOL_RULE`，不判失败。

---

## 贯穿始终的三条纪律

1. **测试库根与生产库根隔离。** 所有测试走 `-Profile test`（解析到 `D:\GameTst`），脚本发现解析结果等于生产值就**立即退出、不做任何 IO**。删除用例只用自己现造的合成样本，**永不用你手上的真实包**。

2. **每个阶段先写反向判据的测试。** 正向判据错了是功能缺失，反向判据错了是数据丢失。上面每个阶段都标了反向判据，先写它们。

3. **遇到与 SPEC 矛盾的实测结果，改 SPEC，不要改代码去迁就。** SPEC 里标 `【待测】` 的地方本来就是待修正的，而且 §12 决策台账记着每条决策**被否决的替代方案**——推翻之前先读那一栏。

---

## 关于范围

这份计划覆盖 SPEC 的全部内容。如果只想先用起来，**阶段 0–3 就是一个完整可用的系统**（下载→解压→删包，游戏待在枢纽里，手动搬走）；阶段 4 让它自动搬，阶段 5 让它能用一句话触发，阶段 6 加翻译。

每个阶段之间都可以停很久，系统不会处于半坏状态。
