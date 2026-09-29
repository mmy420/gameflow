# Windows 侧检测规格

> 本项目在 macOS 上开发。以下几类事实**在开发机上无法验证**，只能在目标机做。
> 这份文档说清楚：**测什么、怎么测、每个结果意味着什么、哪些结果会改变设计。**
>
> 最后更新 2026-09-29：修正 #3 的测法（原测法已被证明无效，见「第三部分」），
> 修正 W3 的竞态，新增 W9 与执行上下文记录，新增「交给 Codex 执行」的指令。

---

## 为什么必须做这一步

已经写好的代码要拿下面几个参数当输入，而它们现在都是空的：

| 未知 | 谁在等它 | 不测的后果 |
|---|---|---|
| 系统 **ACP** | `Paths.ps1` 的 dirname 算法 | 不知道你的中文/日文标题会不会被降级成 `g0042-a1b2c3d4` |
| 真实包的**最长内部路径 `E`** | §2.5 的 MAX_PATH 预算 | 你那个 `…\202609\` 布局比设计基准少 10 字符，够不够不知道 |
| **7-Zip 版本 + handler 名逐字拼写** | `container-types.json` 的递归白名单 | 拼错 → 每个包都落 `WAITING_FOR_RULE` → 流水线整体停摆 |
| 5.1 下 lib 的真实行为 | 全部后续脚本 | lib 至今只在 macOS + pwsh 7.6 上跑过 |
| Codex 沙盒能否写枢纽 / 审批次数 | 「对 Codex 说一句话就触发」这条路径 | 见第三部分——**影响比之前说的小** |

---

## 第一部分 · 交给 Windows 上的 Codex 执行（推荐）

### 你先做三件事（约 2 分钟）

**① 建一个空的枢纽目录**（后面反正要用；W9 需要它存在才能测写权限，不存在时 W9 只会跳过、不会替你建）：

```powershell
mkdir D:\GameHub
```

**② 给 Codex 配置可写目录**。编辑 `%USERPROFILE%\.codex\config.toml`，加：

```toml
[sandbox_workspace_write]
writable_roots = ["D:\\GameHub"]
```

然后**重启 Codex**（配置在会话启动时读取）。这一步是在测「我们打算用的配置在 Windows 沙盒下到底生不生效」——W9 会给出答案。

**③ 准备两三个已解压的真实游戏目录的路径**，填进下面指令里的 `-SampleGameDirs`。脚本对它们**只读**。这一项决定目录名降级会不会频繁触发，**尽量给**。

### 然后把这段话原样发给 Codex

```
请在这台 Windows 机器上执行 GameFlow 的环境检测。严格按下面做：只执行和汇报，
不要修改仓库里的任何文件，不要尝试修复失败项，不要换别的命令重试。

1. 若 D:\GameFlow 不存在：git clone https://github.com/mmy420/gameflow.git D:\GameFlow
   若已存在：在 D:\GameFlow 里执行 git pull
2. 读一遍 D:\GameFlow\docs\WINDOWS-CHECK.md，了解每一项在测什么。
3. 用 Windows PowerShell 5.1（powershell.exe，不要用 pwsh）执行下面这条命令，一字不改：

   powershell -NoProfile -ExecutionPolicy Bypass -File D:\GameFlow\tests\windows\Invoke-WindowsCheck.ps1 -HubRoot D:\GameHub -ProbeHubWrite -SampleGameDirs '游戏目录1','游戏目录2'

4. 跑完后，把 D:\GameFlow\docs\windows-check.json 的完整内容原样输出，并附上脚本最后打印的汇总。
5. 不要删除任何文件，不要安装任何软件。任何一项失败都如实汇报。
```

**「一字不改」和「不要修复」是故意的**：这次要测的正是 Codex 调 5.1 这条真实路径。Codex 若自作主张换成 `pwsh`、加参数、或改脚本重跑，测到的就是另一个程序。

### 跑的过程中，你只需要观察一件事

**Codex 一共弹了几次审批，每次审批框里显示的命令原文是什么。** 截图或抄下来一起发回。

这是第三部分那个问题的答案：检测脚本内部会起十几个子进程（`powershell.exe`、`pwsh.exe`、`7z.exe`）。

- **只为顶层命令弹了一次** → 脚本内部起的子进程不会被逐个审批 → 将来「对 Codex 说一句话触发作业」最多点一次批准
- **每个子进程都弹** → 那条路径不可用，作业只能走计划任务或你在终端里手动跑

`git clone` 那一步需要联网，Codex 默认沙盒不联网，它大概率会请你批准联网——那一次不算。

### 跑完把什么发回来

`D:\GameFlow\docs\windows-check.json` 的完整内容 + 审批次数与命令原文。JSON 里**不含**密码、账号、文件内容；唯一可能带路径的是你给的 `-SampleGameDirs`。

---

## 备选 · 你自己在终端跑

不想经过 Codex，或 Codex 那次结果里有沙盒拦截（见下方「执行上下文」），就在普通终端里跑：

```powershell
git clone https://github.com/mmy420/gameflow.git D:\GameFlow
cd D:\GameFlow
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\Invoke-WindowsCheck.ps1 `
    -HubRoot D:\GameHub -SampleGameDirs '游戏目录1','游戏目录2'
```

**两条路径各跑一次、对比结果，信息量最大**：终端那次给出这台机器的真实情况，Codex 那次给出沙盒会拦掉什么。

---

## 它会做什么、不会做什么

| 会 | 不会 |
|---|---|
| 读注册表若干项（ACP、LongPaths、ExecutionPolicy） | ❌ 改注册表 |
| 在系统临时目录建工作区，跑完删掉 | ❌ 碰你的游戏库或任何现有文件 |
| 用 `tests\fixtures\` 里的小样本调 7-Zip | ❌ 装东西、联网 |
| 起子进程持锁（测互斥） | ❌ 删除任何非本脚本创建的东西 |
| **仅当给了 `-ProbeHubWrite`**：在 `D:\GameHub` 建一个 `_gameflow_probe_<随机>.tmp` 并立刻删掉 | ❌ 不给该开关时对 `D:\GameHub` 零写入 |
| 写一份 `docs\windows-check.json` | |

耗时约 1–3 分钟，大头是 `-SampleGameDirs` 的递归扫描。

---

## 执行上下文（为什么脚本要记录「谁在跑」）

在 Codex 里跑时，沙盒可能拦截写临时目录、起子进程等动作。**那些失败是沙盒造成的，不是这台机器的事实**——不区分的话，会把沙盒拦截误读成「这台机器上互斥不成立」之类的错误结论。

所以 JSON 顶部有一段 `context`：

| 字段 | 意思 |
|---|---|
| `likely_under_codex` | 检测到 `CODEX*` 环境变量 → 大概率在 Codex 里跑 |
| `codex_env` | 这些变量的**名字**；只有名字含 `SANDBOX` 的才记值（模式标志，非机密） |
| `user` | Codex 的 elevated 沙盒会换成独立的本地用户，这一格能看出来 |
| `temp_writable` | 临时目录能不能写。**`false` 时 W3/W5/W6/W7/W8 的失败全部不可信** |

---

## 第二部分 · 九项检测分别在验什么

### W1 · 环境快照

调用 `scripts\Preflight.ps1`。产出 ACP、7-Zip 版本与 handler 名、PowerShell 版本、
枢纽卷文件系统、`LongPathsEnabled`、`ExecutionPolicy`、Defender 状态、MTool 签名、
最长内部路径。**这一项解开前三个未知。**

判读要点：

- `archiver.sevenzip_path` 为空 → **硬阻塞**。WinRAR/Bandizip 的 GUI 顶替不了，
  SPEC 全部退出码判据都以 7-Zip 命令行为准。
- `archiver.handlers` → 直接决定 `container-types.json` 怎么写。
- `codepage.acp` → 936 的话**日文假名标题不会降级**（已在 macOS 实证：GBK 含完整假名区）；
  真正会降级的是韩文、emoji、GBK 未收的罕用字。
- `internal_paths.worst_E` → 代进 §2.5.3a 的表，看你那个按月分组的布局还剩多少余量。

### W2 · 单元测试在 5.1 与 pwsh 下各跑一遍

**这是本次最重要的一项。** lib 六个模块至今**只在 macOS + pwsh 7.6 上跑过**，
104 条用例全绿，但那说明的是「在我选的那条路上按我的意图工作」，**说明不了它在你那条路上能跑**。

预期：

- `powershell`（5.1）：`Paths` / `Journal` / `Lock` 应当全绿。
  **`SevenZip` 会失败**——它要求 pwsh 7.4+（`ProcessStartInfo.ArgumentList` 在
  .NET Framework 上不存在），这是契约 SZ-4 明文规定的，失败信息应当是那句明确的抛错。
- `pwsh`：全部应当全绿。若没装 pwsh，这一格是 `present: false`，
  那么 **B 拒绝运行**（§9.11 规定不降级），需要装。

任何**其它**失败都是真问题，尤其注意：

- `Paths` 的 dirname 用例失败 → 很可能是 5.1 与 .NET Core 的 `Normalize` / `StringInfo`
  行为差异，会影响所有目录名。
- `Journal` 的中文用例失败 → 编码路径有问题，是本项目最容易造成真实数据损坏的一类。
- `Lock` 的「跨进程」用例失败 → 见 W3。

### W3 · 跨进程互斥

整个并发安全建立在它上面（§8.8.6）：A 与 B 不能同时动同一个游戏条目。

**平台边界**（2026-09-29 实测修正，此前「macOS 上原理上测不了」的说法过头了）：.NET 在 Unix 上用 `flock` 实现 `FileShare.None`，彼此都是 .NET 进程时**跨进程互斥同样生效**，已在 macOS 上真跑通过。**只能在 Windows 上验的是**：强制锁（非 .NET 进程也被挡）与跨会话（计划任务会话 vs 交互会话）。

测法是**握手**而不是「睡几秒赌它已经拿到锁」：子进程拿到锁后写一个标志文件，主进程**看到标志才去抢**。旧版本只等 2 秒，而 5.1 冷启动（加上 Defender 首次扫描新脚本）常超过 2 秒——子进程还没拿到锁、主进程先抢到了，就会报出**假的 FAIL**。

| 字段 | 必须是 | 不是的话意味着 |
|---|---|---|
| `holder_acquired` | `true` | 子进程没起来或被拦了——本轮**什么也没测到** |
| `blocked_while_held` | `true` | **互斥根本不成立** —— A 与 B 会同时动同一个条目 |
| `free_after_release` | `true` | 有陈旧锁问题 —— 选 `FileShare.None` 而不是 PID 检测的核心理由不成立 |

| `verdict` | 含义 |
|---|---|
| `PASS` | 互斥成立 |
| `FAIL` | **阻塞性**，必须先解决才能往下走 |
| `INCONCLUSIVE` | 子进程没拿到锁，**不是 FAIL**。多半是 Codex 沙盒拦了子进程——在普通终端重跑这一项 |

`holder_wait_seconds` 顺带量出了 5.1 在你机器上的冷启动耗时。

### W4 · 加密包 + stdin 重定向会不会挂

SPEC §6.2.4 的陷阱 T6。macOS 上把 stdin 重定向自 `/dev/null` 会得到 exit 255
（真实含义是「需要密码」），但 **Windows 的控制台密码读取可能走 `CONIN$` 而不是 stdin**，
那样重定向就挡不住挂起。

- `hung: false` → 重定向有效，超时是第二道保险
- `hung: true` → **超时不是可选项，是唯一保险**。后台挂死一个无输出的进程
  是本项目最难发现的故障模式

两种结果都不阻塞（`SevenZip.ps1` 本来就强制设超时），但结论要写进 SPEC。

### W5 · Shift-JIS ZIP 的落地文件名形态

日文资源包的现实问题：ZIP 不带 UTF-8 标志位时，文件名是裸 CP932 字节。

fixture `sjis-legacy.zip` 是精确构造的：`bit11=0`，文件名是 `ねこぱら.txt` 的 CP932 字节。

判读：

- `landed_name == ねこぱら.txt` → 你的 ACP 恰好能正确解码，这类包不需要特殊处理
- 落成乱码（`ねこぱら` 变成别的汉字）→ §6.11 的事后修复有用武之地
- 落成 `U+EFxx` 私用区转义 → macOS 用的是这种，Windows 大概率不同，
  §6.11 的「96% 可逆的 GBK↔CP932 修复」算法要按实际形态重写
- `mcp_changed_result` → **§11 #20 的答案**。三方证据互相矛盾：官方 `method.htm`
  明写 `-m` 只适用 `a/h/d/rn/u`（不含 `x/l/t`），macOS 实测无效，社区说 Windows 有效。
  这一格给出定论。

### W6 · 路径穿越条目落到哪

fixture `traversal.zip` 含七种恶意路径，包括 `../`、绝对路径、`C:\` 盘符、反斜杠分隔符。

- `escaped` 为空 → 7-Zip 全部剥干净了（与 macOS 一致）
- `escaped` 非空 → **有文件落到了解压目录之外**，§6.6 的自查不是保险而是必需

无论哪种，SPEC 的姿态不变（7-Zip 的拦截是**静默的**，exit 0、零警告，
所以必须自己扫 `l -slt` 的 `Path`）。这一项是在量化风险，不是在决定要不要做。

### W7 · `-snz` 的 MOTW 传播默认值

§11 #6。官方 changelog 与开关速查表**都没写默认值**，只有社区说默认关闭。

- `propagated_default: false` → 社区共识确认，§6.10 的策略成立
- `propagated_default: true` → 与假设相反，§6.10 要重写

若 `source_marked: false`，说明你的卷不是 NTFS 或 ADS 被禁，这一项无意义
（exFAT 上根本没有 `Zone.Identifier` 备用数据流）。

### W8 · 长路径

造一个 300+ 字符的路径试建。SPEC 的姿态是**从源头压短路径**、不依赖长路径开关，
所以这一项**不阻塞**，只是确认代价：如果它能建，说明 §2.5 的 248 闸门偏保守，
将来可以放宽；不能建则维持现状。

### W9 · 能不能写枢纽（仅当给了 `-ProbeHubWrite`）

在 `D:\GameHub` 里建一个唯一命名的探测文件并立刻删掉。`D:\GameHub` 不存在时直接跳过，**不会替你把枢纽建出来**。

**在 Codex 里跑时，这一格就是 §11 #2 的答案**：

| 结果 | 意味着 |
|---|---|
| `wrote: true` | `writable_roots` 在 Windows 沙盒下生效，Codex 能直接驱动作业 |
| `wrote: false` | 配置没生效或沙盒不允许 —— Codex 触发作业时要么逐次申请越权，要么作业只走计划任务 |

在普通终端里跑时，这一格测的只是你这个用户对 `D:\GameHub` 有没有写权限。

---

## 第三部分 · Codex 审批：原测法无效，已换成观察审批次数

### 原测法为什么作废

SPEC §8.5.3 原本让你跑 `codex execpolicy check --rules … -- powershell.exe -Command "7z t …"`，看规则能不能拆开 PowerShell 调用、命中 `["7z","t"]`。

**2026-09-29 在 macOS 的 codex-cli 0.150.1 上实测，这个方法测不出拆分**——加了一个对照组：官方文档**明说会拆**的 `bash -lc "7z t a.7z"`，在 `execpolicy check` 里同样**不命中**。`bash -c`、`sh -c`、`zsh -lc`、`/bin/bash -lc` 一律不命中。

结论：**`execpolicy check` 是裸 argv 前缀匹配器**，不做文档里说的 tree-sitter 拆分——拆分发生在 agent 的审批路径里，不在这个独立检查器里。所以你在 Windows 上照原方法做，② 必然显示「未命中」，而那什么也证明不了（它连 bash 都不拆）。

同一次实测里，**固定形状的入口脚本**（`pwsh.exe -NoProfile -File D:\GameFlow\scripts\Invoke-Work.ps1 …`）是**能命中**的——它不需要任何拆分，按原样前缀就能匹配。这支持 SPEC §8.5.3 的推荐：规则不该给 `7z` 写，该给入口脚本写。

探测用的规则文件在 `tests\windows\execpolicy-probe.rules`，可以自己复现。

### 这个问题的分量，比之前说的小

我之前反复说这条「可能推翻『A 无人值守』这个卖点」。**那是说重了**：

- **无人值守路径根本不经过 Codex**。按 D-10 与 D-38，A 与 B 都挂 **Windows 任务计划**运行，Codex 的审批系统不在这条链上。
- 这个问题**只影响「你对 Codex 说一句话、让它手动触发一次」这条路径**。
- 而在那条路径上，所有 7z 调用都发生在入口脚本自己起的子进程里（§8.5.4）。只要 Codex 不对脚本内部的子进程逐个审批，**最坏也就是每次手动触发点一次批准**。

所以真正要验的是：**Codex 会不会对脚本内部起的子进程逐个审批**。第一部分让你数审批次数，就是在验这个——检测脚本内部恰好会起十几个子进程，是现成的实验。

---

## 拿到结果之后会发生什么

1. **修代码**——W2 里 5.1 下的任何非预期失败
2. **改 SPEC**——W4/W5/W6/W7/W9 的结论写回对应小节，把 `【待测】` 换成 `【实测】`，在 §11 里划掉已解决的条目
3. **解冻阶段 1**——`New-Batch.ps1` 需要真实 ACP 才能调 `Get-GfDirName`，`container-types.json` 需要 handler 名，拿到 W1 就能开工

若 W3 是 `FAIL`，会先有一轮并发设计修正。若审批是逐个弹的，「Codex 一句话触发」这条路径降级为「只触发计划任务」，不影响无人值守。

---

## 出问题怎么办

脚本**从未在 Windows 上执行过**，首次跑大概率有一两处要修。任何报错直接贴回来，包括完整的错误信息与行号。不用自己 debug，也别让 Codex 去修——修过的脚本测出来的就不是原来那个了。

某一项卡住超过 3 分钟，`Ctrl+C` 中断即可——每项都在独立的 `Probe` 块里，中断一项不影响别项，已跑完的部分仍会写进 JSON。
