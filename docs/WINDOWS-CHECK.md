# Windows 侧检测规格

> 本项目在 macOS 上开发。以下几类事实**在开发机上原理上无法验证**，只能在目标机做。
> 这份文档说清楚：**测什么、怎么测、每个结果意味着什么、哪些结果会推翻设计。**

---

## 为什么必须做这一步

PLAN 写着「不做这个，后面每一行代码都建在假设上」。具体地说，现在有四个参数是空的，
而已经写好的代码要拿它们当输入：

| 未知 | 谁在等它 | 不测的后果 |
|---|---|---|
| 系统 **ACP** | `Paths.ps1` 的 dirname 算法 | 不知道你的日文/中文标题会不会被降级成 `g0042-a1b2c3d4` |
| 真实包的**最长内部路径 `E`** | §2.5 的 MAX_PATH 预算 | 你那个 `…\202609\` 布局比设计基准少 10 字符，够不够不知道 |
| **7-Zip 版本 + handler 名逐字拼写** | `container-types.json` 的递归白名单 | 拼错 → 每个包都落 `WAITING_FOR_RULE` → 流水线整体停摆 |
| **`prefix_rule` 对 PowerShell 的拆分语义** | 阶段 5 的 Codex 操作面 | 不通过则每次解压都要人点一次，**A 失去无人值守的意义** |

最后一条不是实现细节，是**可能推翻一条核心主张**。

---

## 前置：把仓库放到 Windows 上

```powershell
git clone https://github.com/mmy420/gameflow.git D:\GameFlow
cd D:\GameFlow
```

仓库根就是将来的 `D:\GameFlow`。**这一步不写任何数据**，`D:\GameHub` 还不需要存在。

如果 `.ps1` 跑不起来报「禁止运行脚本」：

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

（检测脚本本身都带 `-ExecutionPolicy Bypass`，理论上不需要改。但阶段 5 的 Codex skill 会需要，见 §8.4。）

---

## 第一步 · 一条命令跑完全部检测

```powershell
cd D:\GameFlow
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\Invoke-WindowsCheck.ps1 `
    -HubRoot D:\GameHub `
    -SampleGameDirs 'D:\你已解压的某个游戏','E:\另一个'
```

**用 `powershell.exe`（5.1）跑，不要用 `pwsh`。** 理由：Codex 的 Windows agent 调的就是 5.1，
这套东西得先证明自己在 5.1 上能跑。脚本内部会自己再用 pwsh 跑一遍做对比。

**`-SampleGameDirs` 尽量给。** 不给就测不到最长内部路径，而那条直接决定你的目录名会不会
频繁被降级成一串字母。给两三个真实的、已经解压好的游戏目录即可，**脚本只读不改**。

### 它会做什么、不会做什么

| 会 | 不会 |
|---|---|
| 读注册表若干项（ACP、LongPaths、ExecutionPolicy） | ❌ 改注册表 |
| 在系统临时目录建工作区，跑完删掉 | ❌ 碰你的游戏库、`D:\GameHub`、任何现有文件 |
| 用 `tests\fixtures\` 里的小样本调 7-Zip | ❌ 装任何东西 |
| 起一个子进程持锁 8 秒（测互斥） | ❌ 联网 |
| 写一份 `docs\windows-check.json` | ❌ 删除任何东西 |

耗时约 1–3 分钟（大头是 `-SampleGameDirs` 的递归扫描）。

### 跑完把什么贴回来

```
D:\GameFlow\docs\windows-check.json
```

整份贴回对话即可。里面**不含**密码、账号、文件内容——只有环境参数、退出码、
文件名形态、测试通过数。（唯一可能带路径的是你给的 `-SampleGameDirs`。）

---

## 八项检测分别在验什么

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
103 条用例全绿，但那不代表它们在 Windows PowerShell 5.1 上也对。

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

### W3 · 跨进程互斥

**macOS 上原理上测不了这一条**：Unix 的 .NET `FileShare` 是进程内咨询语义，
Windows 是强制锁。而整个并发安全都建立在它上面（§8.8.6）。

脚本起一个子进程持锁 8 秒，主进程尝试抢同一把锁。

| 字段 | 必须是 | 不是的话意味着 |
|---|---|---|
| `blocked_while_held` | `true` | **互斥根本不成立** —— A 与 B 会同时动同一个条目 |
| `free_after_release` | `true` | 有陈旧锁问题 —— 选 `FileShare.None` 而不是 PID 检测的核心理由不成立 |

`verdict: FAIL` 是**阻塞性**的，必须先解决才能往下走。

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

---

## 第二步 · 两条脚本测不到的，要在 Codex 里做

这两条**必须在 Codex 会话里做**，因为它们问的是 Codex 自己的行为。

### ① 沙盒能不能写到 `D:\GameHub`（§11 #2）

在 Codex 里打开 project = `D:\GameFlow`，配：

```toml
[sandbox_workspace_write]
writable_roots = ["D:\\GameHub"]
```

然后让 agent 实际写一个文件到 `D:\GameHub\_probe.txt`。

- 写得进去 → 执行体 A 可以由 Codex 触发
- 写不进去 → A 要么改由任务计划独占触发，要么被迫开 `danger-full-access`（**安全上不可接受**）

### ② `prefix_rule` 对 PowerShell 的拆分语义（§11 #3）

**这条最要紧——它可能推翻「A 无人值守」这个卖点。**

官方 rules 文档全文零提及 `powershell` / `pwsh` / `cmd.exe`，很可能整条调用被当成
单一 invocation，于是 `pattern = ["7z","t"]` 这种按子命令的规则根本匹配不上。

```powershell
codex execpolicy check --rules <你的规则文件> -- powershell.exe -NoProfile -Command "& '7z.exe' t x.7z"
```

看它是把整条 `powershell.exe …` 当一个 invocation，还是拆出了里面的 `7z t`。

- 能拆 → 7z 免审批写得出来，A 真正无人值守
- 不能拆 → **每次解压都要人点一次**，需要重新设计阶段 5（例如把 7z 调用收敛成
  一个固定入口脚本，对那个脚本整体放行）

---

## 拿到结果之后会发生什么

我会按结果做三件事：

1. **修代码**——W2 里 5.1 下的任何非预期失败
2. **改 SPEC**——W4/W5/W6/W7 的结论写回对应小节，把 `【待测】` 换成 `【实测】`，
   并在 §11 里划掉已解决的条目
3. **解冻阶段 1**——`New-Batch.ps1` 需要真实 ACP 才能调 `Get-GfDirName`，
   拿到 W1 就能开工

如果 W3 是 FAIL，或者 ② 表明 `prefix_rule` 拆不开，那会先有一轮设计修正。

---

## 出问题怎么办

脚本**从未在 Windows 上执行过**，首次跑大概率有一两处要修。任何报错直接贴回来，
包括完整的错误信息与行号。不用自己 debug。

如果某一项卡住超过 3 分钟，`Ctrl+C` 中断即可——每项都在独立的 `Probe` 块里，
中断一项不影响别项，已跑完的部分仍会写进 JSON。
