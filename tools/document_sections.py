"""完整开发文档的说明段落；源码在构建时从项目原文件逐字嵌入。"""
INTRO = r'''# 飞机大作战：Godot 4.7.2 完整开发文档

> 交付形式：完整可导入项目 + 本文所有源码。代码标识符为英文，解释和注释为中文。无需外部图片、音乐、插件或 .NET。本文中的每一段文件代码都可以原样复制；没有省略号代替实现。
>
> 版本依据：Godot 官方 4.7.2 归档及维护版说明（2026-08-18）；本项目使用 GDScript 和 Godot 4.x API。实测版本、范围与结果见第 10 节。

## 1. 项目概览

### 1.1 游戏规则

- **名称**：飞机大作战 · Flight School。
- **类型**：480 × 800 逻辑分辨率、2D 竖版、无尽生存射击。
- **操作**：WASD 或方向键移动；按住空格连续射击；点击开始；结束后点击重新开始或按 R；升级时按数字键 1/2/3 选能力。待开始界面也支持 R；进行中 R 不重开，避免误触。
- **核心循环**：移动躲避 → 射击击毁 → 得分与经验 → 升级选能力变强 → 敌机同时变快/变密/更常射击 → 尽量延长生存。
- **生命**：初始 3，敌机或敌弹触碰扣 1；受伤后 1.2 秒无敌并闪烁；同一物理帧多次碰撞最多扣 1。
- **计分**：普通红色敌机 10 分、橙色直射敌机与紫色瞄准敌机 20 分，均为一发击毁。撞毁敌机不加分。**三种颜色对应三种威胁**：红色不还手、橙色朝正下方打、紫色朝你所在的位置打——不做颜色区分的话，“谁在瞄我”玩家根本读不出来。
- **连击倍率**：连续击毁敌机累积连击，每 5 次升一档得分倍率（×1 → ×5 封顶）；**受伤或漏敌都会清零**。它奖励“打得凶”，并且与下面的漏敌代价是一对：不打就没有倍率，漏一架还要把攒好的赔进去。
- **漏敌要付代价**：敌机从画面底部溜走时，除了清零连击，还会**永久抬高本局的难度压力**——每漏一架相当于多熬过一小段生存时间，累积有上限。没有这一条时，“躲着不打”是严格最优解：玩家可以永远待在安全车道里，既不会被扣什么，也没什么可失去的。
- **等级与经验**：击毁敌机同时获得等于其分值的经验（普通 10、射击 20），这是唯一的经验来源；撞毁与漏过的敌机不给经验。经验满格即升级，第 n 级所需经验为 `xp_base + xp_growth × (n - 1)`（默认 80 + 45 × (n - 1)），所以前期升级快、后期变慢。
- **升级抉择**：升级时**整局暂停**，弹出四张互不重复的能力卡，按数字键 1/2/3/4（叠了“幸运补给”后是 1–5）或直接点击选中一项后继续。一次拿到大量经验会连续弹出多次抉择，多余经验不会被吞掉；能力全部叠满时不再弹面板，直接升级。
- **能力**：共 16 项且均可叠加，按用途分为射击、生存、机动与成长三类——射速强化、火力增援（多发）、侧翼炮、弹速强化、穿透弹、拦截弹（击落敌弹，**一发换一发**）、弹体增幅；护盾延时、应急补给、机体强化（抬高生命上限）、紧急清屏；引擎强化、战术洞察、战果结算、战术从容、幸运补给（多一个选项）。已叠满、或对当前局面没有意义的能力（例如生命已满时的补给）不会再出现在选项里，避免出现“选了没效果”的死选项。得分倍率只提高分数，不会顺带加快升级。
- **多发是平行弹幕，不是扇形**：所有子弹一律竖直向上，多发与侧翼炮只把子弹按固定的水平间距排开，因此不会出现斜飞的子弹，弹道之间也不重叠。
- **玩家子弹只在看得见的战斗区域内有效**：子弹升过顶部信息栏的下沿（`play_area_top`，默认 90 像素）就销毁，侧向则以屏幕为界。这条规则解决的是一个具体的手感问题——敌机在 y=-48 出生，而顶部色块盖住 0~90 这一段，如果子弹一直有效到屏幕之外，就会**在玩家根本看不见的地方把敌机打死**，看起来像“敌人刚露头就没了”。边界取 90 而不是 0，正是因为那 90 像素同样被色块挡着，玩家看不见。回归测试用成对断言钉住它：“栏下打不到”与“露头打得死”必须同时成立。
- **视觉与受力反馈**：敌机被击毁时在原地爆出一圈碎片并闪一道白光；玩家受伤时画面震动一下并整屏闪红；得分时分数标签脉冲、升级时进度条前进。屏幕震动可以在 Main 的导出参数里直接关闭（`screen_shake_enabled`），强度与时长也可调。
- **音频**：射击、击毁、受伤、升级、结算各有音效，另有一段 8 秒循环的背景音乐。音乐走 Music 总线、音效走 SFX 总线，总线布局写在 `default_bus_layout.tres`。素材是程序合成的（见第 2 节），不是外部下载。六个音效播放器组成一个音效池，因此连射时后一发不会掐掉前一发。
- **等级与难度是两件事**：等级是玩家成长，随击毁敌机上升；难度是生存压力，随生存时间上升。两者独立，HUD 分开显示。能力与等级**每局重置**，重开后回到 Lv 1、经验 0、无任何能力。
- **最高分**：持久保存到 `user://save.cfg`（`ConfigFile`，节 `records`，键 `best_score`）。顶栏“最高”始终显示含本局在内的最好成绩，所以局中超过旧纪录会立刻反映出来；只在结算时比较并写盘，避免局中反复读写。存档缺失属于首次运行的正常情况；读取失败、内容损坏（不是非负整数）或写盘失败都只记一条警告，绝不阻断本局结算与重开。中途退出不会记录尚未结算的分数。
- **本局战报**：结算面板不再只有分数与时长，而是六行本局小结——生存秒数、到达难度、到达等级、击毁数、最高倍率、受伤次数、漏敌架数、以及本局走过的能力路线。这些数字里，`生存`/`难度`/`等级`顶栏已经有了，战报只补顶栏看不到的部分，因此**不重复显示分数与最高分**。为此新增了三个计数器：`kills`、`hits_taken`、`peak_combo_multiplier`。峰值倍率必须单独记——受伤会把 `combo` 清零，光看结算时的 `combo` 永远是 0。结算是跨局边界，`combo` 也会在这里清零，否则顶栏会一直挂着一个看起来仍在生效的倍率标签。
- **对局记录**：每局结束把上面这些数字追加一行 JSON 到 `user://runs.jsonl`（含结构化的能力路线 `build`，形如 `{"rapid_fire": 3}`），只保留最近 50 局。它和最高分分成两个文件：最高分是“覆盖一个数”，对局记录是“追加一条并裁掉最旧的”，读写节奏完全不同。一行一条 JSON 而不是塞进 `ConfigFile`，是为了既能直接看懂，也能被外部脚本直接读——这一项的用途就是**拿真人游玩数据来调难度**，而不是靠猜。空行与写坏的行会被静默丢弃（这是一种自我修复），因此读脏文件也不会影响结算；写盘失败同样只记警告，不阻断结算。
- **记录会自证规则版本**：每行都带一个 `rules` 指纹（`Main.tuning_fingerprint()`），由等级步长、两个间隔下限与尾段系数、Boss 经验级数、漏敌压力、齐射阶梯与上限这几项拼成，例如 `L9 S0.180 St0.983 H0.450 Ht0.980 B0.50 E0.34 V10/3`。**这不是装饰**：改动参数后再请人试玩时，必须能确定某条记录来自改前还是改后，否则会拿两套规则的数据作对比。这一点是靠教训换来的——第二轮试玩时只能靠文件时间戳去推断，而那是最脆弱的证据；后来齐射参数加进难度体系时，指纹也同步补上了，否则它恰好在最关键的一项上失去自证能力。指纹只取与难度相关的字段而不是全字段哈希：哈希更完整，但看不出“到底动了哪一项”，而这个指纹的用途正是横向对比。
- **记录必须能区分“被打死”和“自己送死”**：每行还带 `hit_times`——每次受伤发生时的生存秒数。少了它，记录里只剩“存活 253 秒、受伤 5 次”，而**主动送死与被逼死长得一模一样**。真人前两局恰好都是玩家自己结束的，当时只有汇总数字，于是得出了“玩家跑得比曲线快”这种建立在删失数据上的错误结论。真实玩法下两次受伤至少隔一次无敌时间，所以主动送死的特征很好认：最后几次受伤以接近无敌时长的间隔（约 1 秒出头）连续出现，而不是几十秒一次。分析对局数据前**先看这个序列**。
- **一键启动**：本仓库根目录附 `play.bat`，双击即用自带的 Godot 引擎打开工程，关闭游戏窗口后会打印对局记录的完整路径。中文提示放在 `tools/play.ps1`（UTF-8 带 BOM），`play.bat` 刻意只写 ASCII：cmd.exe 解析 .bat 时按当前 ANSI 代码页逐字节读取，非 ASCII 文本会被拆坏甚至把命令行断错，`chcp 65001` 也救不回已经读进来的行。额外参数会原样透传给引擎（`play.bat --headless --quit-after 90` 可用于自检）。交付 ZIP 里不含这个启动器，因为它依赖本机 `tools/godot-4.7.2/` 下的引擎，而引擎二进制不随源码交付。
- **失败**：生命变为 0，停止生成/移动/射击，清空敌机和子弹，弹出本局战报；打破纪录时战报里提示“新纪录”。
- **胜利**：无固定通关条件；目标是持续刷新最高分与生存时间。
- **敌机会齐射**：难度每高 10 级，一次开火多打一发（最高 3 发，以基准方向为中心左右对称散开）。**这是后期难度的真正支点**，理由是一条实测出来的因果链：玩家叠满后每秒打出 148 发、铺成 11 条弹道，敌机常常在“开火窗口”之前就被打死——基准量出**每架敌机平均只开 0.69 枪**（按存活 1.8 秒、射击间隔 0.34 秒本该 2~4 枪）。密度、速度、开火概率、瞄准比例乘的都是“敌机能开几枪”，而那个数已经被玩家火力压到接近 0，所以**在敌人那一侧怎么调都没用**。齐射把总输出改成由**首发**决定：玩家火力越强、敌机死得越快，单发式敌人的输出越低，而齐射式敌人那一下一定打出 N 发。修复后同一基准从 0.69 发/架、3.33 发/秒到达，变成约 2.7 发/架、16 发/秒到达。
- **难度**：每 9 秒升一级，**基准**上限 30 级；生成间隔最低 0.18 秒，敌机/敌弹速度、射击概率与射击频率都随等级增长。难度仍然有封顶，但这个上限**会随玩家等级一起放宽**（见下），另外**漏敌也会把难度顶上去**。这个 9 秒是调过的：早先 15 秒、后改 12 秒，真人试玩后压到 9 秒——因为玩家明显跑在曲线前面（5 分钟就打到难度 30 以上），让曲线提前到达比在末端加码更有效。
- **撞到下限之后不会变平**：生成间隔与射击间隔各有下限（分别在难度 13 与 18 撞底），但撞底之后每多出一级仍会按 `spawn_interval_tail` / `shoot_interval_tail` 继续收紧——曲线只是放缓，不会停止。这不是可有可无的修饰：**“线性衰减 + 下限”的写法撞底即冻结**，曾经导致难度 18 之后的所有参数都是常数，玩家在中段会明显感到“数字在涨、威胁没变，像在等死”。线性段保持原样，所以前中期手感不受影响。
- **难度上限随玩家等级放宽**：`有效上限 = max_level + (玩家等级 - 1) × max_level_per_player_level`。这是本作平衡的关键一条——难度只是时间的函数、玩家强度只是等级的函数，两者不同步就一定会失衡：玩到中后期会出现“玩家一直在变强、敌人早就封顶”。让上限跟着玩家等级抬，是唯一不必反复手调数值就能根治的办法。**但要注意**：这条机制只有在“每一级都真的更危险”时才有意义。在补上尾段收紧之前，它一度形同空转——发出去的高等级里不含任何新增威胁。
- **瞄准射击**：一部分会开火的敌机改为**朝玩家当前位置**打，而不是一律竖直向下。比例＝波次自带的 `aim_ratio` ＋ 每级难度的增量，再按 `aim_ratio_cap` 夹紧（第一波 15% 起步，精锐波 65%，封顶 85%）。每级增量是 **0.02**（早先 0.01）：难度 15 时第一波约 43%、难度 30 时约 73%，也就是后期大部分敌机都在瞄你。这是唯一能制造“必须移动”压力的手段——只提高弹幕密度的话，画面会变成密不透风的下落弹，那是“难”而不是“有意思”。**要注意这是个“前置”杠杆**：它有 0.85 的硬上限（比例不可能超过 100%），高瞄准的波次在难度 11~30 就会陆续撞顶，此后再加难度靠的是前面说的间隔尾段，而不是它。基础开火概率也一并调高过：0.22 时开局接近八成敌机是不还手的靶子。
- **波次**：敌机不是匀速细流，而是按波次成组出现。每套编队有固定的架数与出场位置——`random` 随机散开、`line` 横列铺满宽度、`arc` 两翼夹击；一波放完留出一段停顿再开下一波，玩家因此有整理弹幕、找回节奏的间隙。五套编队循环播放，每走完一整轮每波再多来几架（有上限）。**波次与难度是两套独立的东西**：难度是随时间上升的数值压力，波次是出场的编排方式，两者叠加后仍受硬上限约束。
- **所有数值都在 `assets/wave_tuning.tres`**：难度曲线、生成节奏、敌机数值、波次表、Boss 数值全部集中在这个资源里，可以在检查器里直接调，不必改代码。速度、弹速、射击间隔、开火概率与生成间隔都保留上下限——没有这些夹紧，后期会出现玩家无论如何都躲不掉的弹幕。
- **Boss**：每走完一整轮五波后登场一次，是无限模式里的里程碑而不是通关条件（下方“胜利”一条仍然成立）。它有入场、横向巡航、扇形齐射三段行为，生命远大于普通敌机——挨打只扣血，归零才崩解；撞到玩家时它自己不消耗。齐射的火力随轮次增长，但和普通敌机一样处处有上限。击破它除了奖励分，还会额外补**半级**经验（`boss_xp_levels`）——**不是一整级**：一整级时单个 Boss 的总经验收益约等于 100 架普通敌机，真人第一局里 9 个 Boss 就占了约 71% 的总经验，升级节奏会变成由 Boss 的固定排程决定，而不是由“打得多准”决定。半级既保留“熬到 Boss 就能变强”的奖励感，又把主动权还给击毁数。
- **Boss 血量按玩家输出反推，而不是按轮次线性增长**：`血量 ≈ 玩家每秒发数 × boss_target_seconds`（默认 7 秒），再按上下限夹紧。玩家的输出跨度有二十多倍，任何线性血量曲线都会在某些 build 下失真——要么前期打不动、要么后期一碰就碎。按当前输出反推能自动适配任何 build。
- **无敌接触规则**：无敌期间不扣血，但接触的敌机/敌弹仍被消耗，不留在玩家身上等待无敌结束。

### 1.2 为什么适合入门到进阶

八个独立场景把职责拆开：Main 管规则，Player 管操控，Enemy 管敌人，Boss 是带状态机的强化版敌人，两种 Bullet 管弹药，Explosion 只管播一段特效，HUD 管展示。练习场景实例化、节点路径、向量、delta、输入映射、Area2D、Timer、@export、@onready、signal、Tween、await、ConfigFile 存档、ProgressBar、Camera2D、粒子系统、AudioStreamPlayer 与音频总线、自定义 Resource 参数表、多血量敌人的状态机，以及资源文件。进一步学习幂等碰撞、延迟释放、异步跨局隔离、存档容错、暂停语义（含哪些节点必须设 PROCESS_MODE_ALWAYS）、派生状态与手动改写的冲突，以及自动化回归测试。无贴图依赖让问题集中在逻辑而非素材导入——爆炸的粒子贴图用内置 GradientTexture2D 画出，音频由脚本合成，没有引入任何外部素材文件。

流程：READY（开始）→ PLAYING（生存）→ LEVEL_UP（升级抉择，整局暂停）→ PLAYING → GAME_OVER（结算）→ PLAYING（重开）。生命/计分/等级/经验只能经 Main 修改。节点之间用信号和小接口协作，不访问脆弱的 `/root/Main` 硬编码路径，也不用 Autoload。

## 2. 项目目录结构

解压后在项目管理器导入 **PlaneBattle/project.godot**。以下 `res://` 始终指 project.godot 所在目录，而不是解压包的外层目录。

```text
res://
├── project.godot
├── default_bus_layout.tres
├── scenes/
│   ├── Main.tscn
│   ├── Player.tscn
│   ├── PlayerBullet.tscn
│   ├── Enemy.tscn
│   ├── EnemyBullet.tscn
│   ├── Explosion.tscn
│   ├── Boss.tscn
│   └── HUD.tscn
├── scripts/
│   ├── Main.gd
│   ├── Player.gd
│   ├── PlayerBullet.gd
│   ├── Enemy.gd
│   ├── EnemyBullet.gd
│   ├── Explosion.gd
│   ├── Boss.gd
│   ├── HUD.gd
│   └── WaveTuning.gd
├── assets/
│   ├── ui_theme.tres
│   ├── wave_tuning.tres
│   └── audio/
│       ├── bgm.wav
│       ├── shoot.wav
│       ├── explosion.wav
│       ├── hurt.wav
│       ├── upgrade.wav
│       ├── gameover.wav
│       └── boss.wav
└── tests/
    ├── SmokeTest.gd
    ├── VisualTest.gd
    ├── StressTest.gd
    └── ThreatTest.gd
```

`assets/` 是资源目录，字体/按钮主题在 ui_theme.tres 中；飞机与子弹由 Polygon2D 绘制；背景由 ColorRect/Line2D 组成。`assets/audio/` 是七个 WAV 音频（总长约 11 秒、469 KB），**不是下载来的素材，而是由 `tools/generate_audio.py` 用 Python 标准库合成出来的**——固定随机种子，任何人重跑都会得到逐字节相同的文件，因此不存在授权问题。要换成正式音频，直接覆盖同名文件即可，游戏代码不需要改。Godot 首次导入生成的 `.godot/` 与 `.gd.uid` 不必手写；不要把缓存作为必需源码。

**关于“所有代码都能复制”的边界**：本文逐字嵌入的是全部文本资源（`.gd`、`.tscn`、`.tres`、`project.godot`），共 21 个文件。七个 WAV 是二进制，无法以文本形式粘贴——它们随交付 ZIP 一起提供，源文件也保留了生成脚本 `tools/generate_audio.py`（该脚本随 ZIP 附在 `tools/` 下），需要时重跑即可得到完全相同的音频。

## 3. 输入映射设置

Project → Project Settings → Input Map，新增下列**完全同名、全小写**动作，点击 + 添加 Physical Key；Deadzone 可设 0.2。

| 动作名 | 按键 | 用途 |
| --- | --- | --- |
| move_left | A、左方向键 | 向左 |
| move_right | D、右方向键 | 向右 |
| move_up | W、上方向键 | 向上 |
| move_down | S、下方向键 | 向下 |
| shoot | Space | 按住连发 |
| restart | R | 结算后重开；开始界面开始 |
| choice_1 | 数字键 1 | 升级时选第 1 项能力 |
| choice_2 | 数字键 2 | 升级时选第 2 项能力 |
| choice_3 | 数字键 3 | 升级时选第 3 项能力 |
| choice_4 | 数字键 4 | 升级时选第 4 项能力 |
| choice_5 | 数字键 5 | 升级时选第 5 项能力（仅在叠了“幸运补给”后出现） |

玩家每个物理帧使用 `Input.get_vector("move_left", "move_right", "move_up", "move_down")`，返回长度不超过 1 的方向向量，所以斜走不更快。移动位移为方向 × speed × delta。`Input.is_action_pressed("shoot")` 表示持续按住，不是仅第一次按下；射速由 cooldown_left 控制。

Main 用 `_unhandled_input(event)` 配合 `event.is_action_pressed("restart")` 和 `not event.is_echo()` 防按键自动重复。按钮使用 Focus Mode = None，释放焦点，避免空格变成按钮点击。五个 `choice_*` 动作由 **HUD** 而不是 Main 处理：升级时 Main 已随整棵树暂停（见 5.8 与 10.2），只有设为 PROCESS_MODE_ALWAYS 的 HUD 还能收到输入。项目文件已经配置这些动作，导入交付项目不需要重复添加。

### 3.1 完整项目配置 `res://project.godot`

手工新建时：关闭项目编辑器后再用下面内容替换 project.godot；否则编辑器退出时可能覆盖外部改动。复制后重新导入。Project Settings 中等效设置为：Viewport 480×800、Window Override 480×800、Stretch Mode = canvas_items、Aspect = keep、渲染 Compatibility、物理频率 120 Hz。
'''
AFTER_PROJECT = r'''
## 4. 碰撞层与遮罩设置

Project Settings → Layer Names → 2D Physics，给前四层命名 Player、Enemy、PlayerBullet、EnemyBullet。在每个 Area2D 根节点设置 Collision Layer / Mask：

| 对象 | 编辑器勾选 Layer | 编辑器勾选 Mask | collision_layer 整数 | collision_mask 整数 | Monitoring / Monitorable |
| --- | --- | --- | --- | --- | --- |
| Player | 第 1 层 | 第 2、4 层 | 1 | 10（2 + 8） | true / true，非游戏期代码关闭 |
| Enemy | 第 2 层 | 全不选 | 2 | 0 | false / true |
| PlayerBullet | 第 3 层 | 第 2、4 层 | 4 | 10（2 + 8） | true / true |
| EnemyBullet | 第 4 层 | 第 1 层 | 8 | 1 | true / true |

**层编号不等于位掩码数值！** 第 n 层对应 `1 << (n - 1)`。题目中“Mask 2 | 4”指**勾选第 2 与第 4 层**；代码不能写 `2 | 4`（那是 6，检测第 2、3 层），本例必须写 `2 | 8` 或 `10`。同理 PlayerBullet 第 3 层的整数是 4，EnemyBullet 第 4 层是 8。

PlayerBullet 的 Mask 是 10 而不是 2，因为它要**同时检测敌机（第 2 层）和敌弹（第 4 层）**——“拦截弹”能力要求玩家子弹能击落敌弹，遮罩不含第 4 层就永远收不到那个 area_entered。多检测一层并不会带来重复回调：EnemyBullet 的 Mask 只有第 1 层，看不到 PlayerBullet，所以这条链路天然单向，只由玩家子弹发起。未开拦截时子弹的处理器会显式忽略敌弹分组，行为与旧版完全一致。

Layer 表示“我属于什么”，Mask 表示“我要检测什么”。检测者 monitoring=true，目标 monitorable=true，目标层落在检测者 Mask 内，且有效 CollisionShape2D 重叠，才能发出 area_entered。

Enemy 的 Mask=0，不能期待 Enemy 自己的 area_entered 检测玩家。正确链路是 Player.area_entered → Enemy.hit_player(player)。EnemyBullet 与 Player 都能检测对方，因此双方都可能报告，必须去重。

去重采用三道锁：Player.invulnerable 在发出 player_hit 前立刻置 true；Enemy.dead 在计分前立刻置 true；Bullet.spent 在处理命中前立刻置 true。`queue_free()` 是帧末释放，不是立即消失；光调用它不能防重复伤害。停用检测用 set_deferred，防物理查询刷新期间改监测属性报错。

## 5. 场景节点树

所有名称和大小写须与下列树一致；每个根节点挂同名 `.gd`。碰撞形状 disabled=false，所有实体默认 rotation=0、scale=(1,1)。除了注明为实例的节点，均为普通新建节点。每个节点的全部序列化属性见本节的完整 .tscn，未写属性保持引擎默认。

### 5.1 Main

```text
Main (Node2D) [Main.gd]
├── Background (TextureRect) [480×800, z_index=-10, Mouse Filter=Ignore, 竖向渐变]
├── FlightLines (Node2D) [z_index=-9]
│   ├── Left (Line2D) [x=80, y=90..756, width=1]
│   ├── InnerLeft (Line2D) [x=160, 同上；颜色更淡]
│   ├── Center (Line2D) [x=240, 同上]
│   ├── InnerRight (Line2D) [x=320, 同上；颜色更淡]
│   └── Right (Line2D) [x=400, 同上]
├── Actors (Node2D) [仅动态敌机、敌弹、玩家弹与爆炸；初始为空]
├── Player (Player.tscn 实例) [position=(240,695)]
├── Camera2D (Camera2D) [position=(240,400)，即画布中心]
├── EnemyTimer (Timer) [Wait Time=1.05, One Shot=On, Autostart=Off]
├── Music (AudioStreamPlayer) [bus=Music, stream=bgm.wav, process_mode=Always]
├── Sfx (Node) [音效池容器；六个 AudioStreamPlayer 在代码里建立]
└── CanvasLayer (CanvasLayer) [layer=1]
    └── HUD (HUD.tscn 实例) [全屏 Control]
```

Actors 与 Player 同坐标系且没有变换。所有动态实体都放 Actors 下；**不要在这里存常驻装饰、容器或音频**，因为每次开局/结算会清空 Actors 的全部子节点。Background 只是画面，不是物理墙。

**背景为什么是渐变贴图而不是一块纯色**：原来的 `Background` 是一个 `ColorRect`，画面只有一块平色加三条竖线，显得很空。现在换成 `TextureRect`，贴图由**内置** `Gradient` + `GradientTexture2D` 程序生成（`fill=FILL_LINEAR`、`fill_from=(0.5,0)`、`fill_to=(0.5,1)`，即竖直方向），从上方略深的蓝灰过渡到下方接近白色；`expand_mode=1` 让节点保持 480×800 而不被贴图的 8×256 尺寸撑回去，`stretch_mode=0` 把它拉伸铺满。航道线同时加密到 5 条（x=80/160/240/320/400），外侧三条颜色较深、中间两条更淡，形成前后两层。**依然零外部图片**——这一点是项目的硬约束，背景也不例外。

**Camera2D 为什么必须有**：屏幕震动只能通过移动视图实现，而 Godot 里移动视图就是给 Camera2D 的 `offset` 赋值。它放在画布中心 (240,400)，`anchor_mode` 保持默认的 DRAG_CENTER，因此默认视图恰好就是 (0,0)–(480,800)，与“没有摄像机”完全一致——加上它不会改变任何既有坐标。震动时只改 `offset`，HUD 挂在 CanvasLayer 上、默认不跟随视口，所以界面保持稳定不跟着抖。Main 在开局与结算时都会把 `offset` 归零，避免画面停在偏移状态。

**音频的三个要点**：

1. **只有 Music 一个常驻播放器，音效走代码建的池**。`Sfx` 是个空容器，`Main._build_audio()` 按 `sfx_voices`（默认 6）在里面建 `AudioStreamPlayer`。场景树里不必摆六个几乎一样的节点，路数也能直接调。播放时优先挑空闲的那一路，全忙才按轮转覆盖最早的一路——射速叠满后每秒有十几发，只有一路播放器会把上一声掐断。
2. **Music 与每一路音效都设 `process_mode = Always`**。升级抉择会暂停整棵树，若播放器仍是默认的 PAUSABLE，选中能力那一下的提示音会被吃掉、背景音乐也会断掉一拍。这是全项目第二处需要动 process_mode 的地方（第一处是 HUD）。
3. **循环点用“时长 × 采样率”换算，不要拿 `data` 的字节数去推**。WAV 导入默认做 QOA 压缩（`.import` 里的 `compress/mode=2`），此时 `AudioStreamWAV.data` 里已经不是原始 PCM，`data.size() / 2` 算出来的循环点是错的。`_prepare_music()` 还把 `loop_mode` 显式设为前向循环——`.import` 里默认 `edit/loop_mode=0` 即不循环，导入一次就固定下来，不能指望它自己会循环。

总线路由在 `default_bus_layout.tres`：Master ← Music（-6 dB）与 SFX（-3 dB）。分开总线是为了让音乐和音效各自调音量、将来也能各挂效果器；写错总线名时 Godot 会静默回落到 Master，不会报错，所以回归测试里专门断言了两个总线的存在。

### 5.2 Player

```text
Player (Area2D) [Player.gd; Layer=1, Mask=10]
├── Visual (Node2D)
│   ├── Hull (Polygon2D) [青蓝机身，顶端 y=-32]
│   ├── Cockpit (Polygon2D) [浅青座舱]
│   └── Engine (Polygon2D) [尾部三角]
├── CollisionShape2D (CollisionShape2D) [RectangleShape2D, size=(34,42)]
└── Muzzle (Marker2D) [position=(0,-43)]
```

默认速度 340 px/s，射击冷却 0.16 s，无敌 1.2 s，边缘留白 (30,36)。玩家中心范围 x=30..450，y=118..764，上方预留 HUD。命中盒有意略小于飞机轮廓，提高躲避容错。

### 5.3 PlayerBullet

```text
PlayerBullet (Area2D) [PlayerBullet.gd; Layer=4, Mask=2]
├── Visual (Polygon2D) [青色窄弹]
└── CollisionShape2D (CollisionShape2D) [RectangleShape2D, size=(8,20)]
```

默认速度 640 px/s（可由“弹速强化”提高），**弹道一律竖直向上**：多发与侧翼炮都只改变水平位置，不改变方向。主弹幕以枪口为中心、按 `bullet_spacing`（默认 14 px）等距排开；侧翼炮接着主弹幕的最外侧、按 `wing_spacing`（默认 18 px）继续向外排。因此无论怎么叠加，所有子弹都是一条互不重叠的平行弹幕——`_bullet_count` 为 1 且没有侧翼炮时偏移为 0，与最早的单发行为完全一致。调参调的是像素间距而不是角度。

`direction` 默认正上方，因此机身图形的旋转量恒为 0。该属性保留下来是因为“能朝任意方向飞”属于子弹自身的能力，将来要做斜射不必改这个脚本；`_physics_process` 也仍然按方向向量推进，并在越过 `play_area_top` 或左右出界时销毁。

`pierce_left` 是“还能穿透几个敌机”，默认 0 即命中即消耗。命中时先调 `Enemy.take_hit()`：**只有返回 true（确实击毁）才扣穿透**，如果这一击没打中（敌机已被别的子弹击毁）就不消耗，让本弹继续飞。这个判断同时挡住了“同一敌机被同一颗穿透弹反复触发”的情况——`area_entered` 对同一目标只会触发一次，即使再次触发，`dead` 锁也会让 `take_hit()` 返回 false。

`intercepts` 为真时，子弹遇到敌弹会调用 `EnemyBullet.intercept()` 把它击落，**同时自己也消失——一发换一发**。这一点被推翻过一次：早先的版本是“击落后自身继续飞”，当时还在本节把它写成了优点；但满配玩家每秒 148 发、11 条弹道时，那条规则等于一面**无限次拦截的盾**，敌方火力根本到不了玩家面前。实测也表明它并非威胁数量的主要来源（通过率 73.5% → 73.9% 几乎没变），改成对等消耗去掉的是免费优势、而不是补上威胁。`intercept()` 返回是否真的击落，与 `take_hit()` 一样用于区分“已经被处理过”的情况。这项能力依赖本场景的 Mask 含第 4 层，见第 4 节。

`play_area_top`（由 Main 按难度规则统一赋值，默认 90）是子弹的有效范围上界：升过它就销毁，因此打不到还没从顶部色块下面钻出来的敌机。这与 `pierce_left`、`intercepts` 不同，它不是玩家能力，而是一条**全局的手感规则**——理由见第 1.1 节。

### 5.4 Enemy

```text
Enemy (Area2D) [Enemy.gd; Layer=2, Mask=0; Monitoring=Off, Monitorable=On]
├── Visual (Node2D)
│   ├── Hull (Polygon2D) [默认红色；可射击型代码改橙色]
│   └── Cockpit (Polygon2D)
├── CollisionShape2D (CollisionShape2D) [RectangleShape2D, size=(42,40)]
├── Muzzle (Marker2D) [position=(0,37)]
└── ShootTimer (Timer) [Wait Time=1.8, One Shot=On, Autostart=Off]
```

Main 在 add_child 前设好 speed、can_shoot、aims_at_player 等导出值，再由 _ready 使用；生成 x=38..442、y=-48。敌机进入 y>105 且 y<725 后才发射，y>864 销毁。默认参数只是编辑器初值，真正每次生成参数由 Main 的等级公式确定。

**弹道方向由发弹方决定**：`shoot_requested(origin, direction, speed)` 带上方向向量，普通敌机传正下方、瞄准型敌机传朝玩家的单位向量。Boss 用同一个签名，因此 Main 只需要一个接收函数，不必分辨是谁在打。瞄准的取值走 `fire_direction()`——单独抽成公开函数，是为了让“到底朝哪打”可以被直接断言，而不必靠观察弹道去猜；它用 `get_tree().get_first_node_in_group("player")` 找玩家，而不是硬编码路径，与项目一贯的组解耦方式一致。

`_ready` 里按威胁等级换色：红色不还手、橙色朝正下打、**紫色会瞄准你**。三种颜色对应三种行为，玩家才能一眼读出该先躲谁。

### 5.5 EnemyBullet

```text
EnemyBullet (Area2D) [EnemyBullet.gd; Layer=8, Mask=1]
├── Visual (Polygon2D) [橙色六边形]
├── Core (Polygon2D) [浅色内芯]
└── CollisionShape2D (CollisionShape2D) [CircleShape2D, radius=7]
```

默认速度 240 px/s，随等级增加，向下直飞，不追踪玩家；y>848 销毁。除命中玩家外，还可被玩家的“拦截弹”通过 `intercept()` 击落：两者都走同一套 `deactivate()` 消耗流程，区别只是前者的 `hit_player()` 会扣血、后者不扣。

### 5.6 Explosion

```text
Explosion (CPUParticles2D) [Explosion.gd; one_shot=On, emitting=Off; 无碰撞层]
└── Flash (Polygon2D) [白色八角形，初始 modulate.a=0.9]
```

敌机被击毁时由 Main 在**敌机所在位置**延迟实例化，播完自行 `queue_free`，不需要任何人回收。它是纯表现节点：没有 Area2D、不进任何碰撞层，因此不会影响命中判定。

两个取舍值得说明：

- **用 CPUParticles2D 而不是 GPUParticles2D**：本项目是 GL Compatibility 的 2D 原型，CPU 粒子不依赖 GPU 计算着色器，在低端设备与 Web 上更稳，而这里一次只有 14 个粒子，CPU 开销可以忽略。
- **粒子贴图用内置的 GradientTexture2D**：`Gradient` 从亮黄到透明、`fill=FILL_RADIAL`，画出来就是一个径向渐变的圆点。这样爆炸不需要任何图片文件，项目的“零外部素材依赖”得以保持。
- **尺寸是调大过的**：最初是 14 粒、贴图 16×16、缩放 0.6~1.5、初速 70~190，击毁特效偏小、容易被弹幕盖过去。现在是 20 粒、贴图 24×24、缩放 0.9~2.4、初速 90~240，白光八角形也从半径 19 放到 24。回归测试对“粒数与尺寸”各留了一条下限断言，防止它悄悄退回成看不见的小碎点。
- **命中白闪为什么长在爆炸上**：敌机是一击必毁、命中的当帧就 `queue_free` 的，真去烫它自己的颜色根本来不及显示一帧。把白闪做在爆炸这一侧、位置就是敌机被击毁的位置，观感相同，却不触碰敌机那套 `dead` 幂等锁和 `queue_free` 时序。`Flash` 的淡出由 Explosion 自己的 Tween 完成，`finished` 信号负责释放整个节点。

### 5.7 Boss

```text
Boss (Area2D) [Boss.gd; Layer=2, Mask=0; Monitoring=Off, Monitorable=On]
├── Visual (Node2D)
│   ├── Hull (Polygon2D) [深紫机身，宽约 184]
│   ├── Plate (Polygon2D) [浅一层的装甲板]
│   └── Core (Polygon2D) [琥珀色核心]
├── Muzzle (Marker2D) [position=(0,52)]
├── CollisionShape2D (CollisionShape2D) [RectangleShape2D, size=(150,78)]
└── ShootTimer (Timer) [Wait Time=1.5, One Shot=On, Autostart=Off]
```

走完一整轮波次后由 Main 生成，位置与数值全部由 Main 在 `add_child` 之前写好（与敌机同样的约定，所以这个脚本不读参数表、也不依赖 Main 的内部状态）。

**轮廓：顶部必须是有起伏的，不能是一条平直横边。** 最初的 `Hull` 顶边是 `(44,-40)` 到 `(-44,-40)` 一条 88 像素的水平线，配上两侧机翼看起来像一块板而不是一架敌机。现在改成中央尖顶加两侧缺口的轮廓（顶点序列为 `0,50 → 26,30 → 34,8 → 86,16 → 92,-10 → 58,-22 → 44,-34 → 22,-30 → 0,-46 → -22,-30 → -44,-34 → -58,-22 → -92,-10 → -86,16 → -34,8 → -26,30`），`Plate` 与 `Core` 同步做出内层的尖顶，因此远看是一台有中轴的机体。回归测试断言“顶部至少有三种不同高度”——直接针对“又变回平顶”这种退化。机体在中心上方延伸 46 像素、下方 50 像素，这个数字决定了它与顶部血条之间还剩多少空隙（见第 5.8 节）。

**它复用了普通敌机的两条链路，没有为它开新分支**：进 `enemy` 组，于是 Player 的 `area_entered` 会调它的 `hit_player()`、PlayerBullet 会调它的 `take_hit()`——两者都只看“是否在 enemy 组、有没有这两个方法”。这样碰撞层与遮罩表完全不用改。

它与普通敌机的三点区别都写在脚本开头：

1. **生命 > 1**：`take_hit()` 只扣血并广播 `hp_changed`，扣到 0 才发 `destroyed` 并释放。`dead` 锁仍然第一时间置位，保证同一帧挨了多发子弹不会出现第二次击破。
2. **撞到玩家不自我消耗**：`hit_player()` 只让玩家扣血。普通敌机是“撞上就同归于尽”，Boss 若照抄，拿机身去撞就能秒掉它。玩家的无敌帧负责去重。
3. **自带攻击节奏**：入场先降到 `hold_y`，再进入横向巡航并按 `ShootTimer` 齐射扇形弹幕。入场阶段不移动也不开火，那段时间是给玩家的准备。

击破后的处理收在 `Main._on_boss_destroyed()` 一个函数里——**文档第 1.1 节写的“无固定通关条件”保持不变，Boss 是里程碑而非胜利条件**；若以后要改成“击破即通关”，只需在这个函数里换成显示通关界面并停局，其余逻辑都不用动。

Boss 的扇形弹幕需要带角度的敌弹，因此 `EnemyBullet` 增加了 `direction`（默认正下方，普通敌机行为完全不变）。弹体图形是上下左右对称的六边形，所以不按方向旋转——转了也看不出来。

### 5.8 HUD

```text
HUD (Control) [HUD.gd; Full Rect; Mouse Filter=Ignore; PROCESS_MODE_ALWAYS; ui_theme.tres]
├── TopBar (ColorRect) [0,0 → 480,90]
├── DamageFlash (ColorRect) [0,0 → 480,800; 红色半透明; 初始 alpha=0]
├── ScoreLabel (Label) [22,14 → 196,47; font_size=23]
├── ComboLabel (Label) [200,17 → 288,47; 右对齐; 琥珀色; 初始 Hidden]
├── LivesLabel (Label) [292,18 → 458,48; 右对齐]
├── StatusLabel (Label) [22,54 → 240,80; font_size=15]
├── LevelLabel (Label) [248,54 → 318,80; font_size=15; 青色]
├── BestLabel (Label) [326,54 → 458,80; 右对齐; font_size=15]
├── XpBar (ProgressBar) [22,83 → 458,89; 高 6; show_percentage=false]
├── BossLabel (Label) [24,96 → 112,116; font_size=13; 红; 初始 Hidden]
├── BossBar (ProgressBar) [118,99 → 456,113; 初始 Hidden]
├── Overlay (ColorRect) [0,90 → 480,756; 浅色透明遮罩]
├── MessagePanel (Panel) [30,244 → 450,530]
├── MessageLabel (Label) [45,268 → 435,422; 水平/垂直居中]
├── StartButton (Button) [82,452 → 398,506; Focus=None]
├── RestartButton (Button) [同上; 初始 Hidden; Focus=None]
├── BottomBar (ColorRect) [0,756 → 480,800]
├── HintLabel (Label) [8,764 → 472,792; 居中; font_size=14]
├── LevelUpOverlay (ColorRect) [0,90 → 480,756; 深色半透明; 初始 Hidden]
├── LevelUpPanel (Panel) [24,120 → 456,**动态**; 初始 Hidden；下沿在 show_level_up() 里按实际张数设为最后一张卡 +26]
├── LevelUpTitle (Label) [40,138 → 440,172; font_size=22; 居中]
├── LevelUpHint (Label) [40,172 → 440,196; font_size=14; 居中]
├── UpgradeCard0 (Button) [44,206 → 436,288; Focus=None; 初始 Hidden]
├── UpgradeCard1 (Button) [44,300 → 436,382; 同上]
├── UpgradeCard2 (Button) [44,394 → 436,476; 同上]
├── UpgradeCard3 (Button) [44,488 → 436,570; 同上]
└── UpgradeCard4 (Button) [44,582 → 436,664; 同上]
```

只有按钮接受鼠标；其余节点 Mouse Filter=Ignore。HUD 根锚点 (0,0,1,1)，其余子节点按 480×800 逻辑画布固定布局，canvas_items 等比缩放、keep 留黑边，因此窗口变大小不会改变逻辑坐标或挤乱 UI。使用系统中文字体候选列表，Windows 自带微软雅黑，无需下载字体。

**DamageFlash 故意排在 TopBar 之后、各个 Label 之前**：HUD 的子节点按树序绘制，越靠后越在上层。这个位置让红色闪光盖住背景与顶栏色块，却压不住分数、生命、等级这些文字——受伤时画面泛红但信息仍然清楚。它的 alpha 平时为 0，受伤时由 `HUD.flash_damage()` 立刻抬高再补间回落，因此不需要额外的节点开关。**峰值 alpha 是 0.26 而不是早先的 0.38**：0.38 时整屏泛红偏重，会短暂盖住敌机弹道，而受伤那一下恰恰是玩家最需要看清弹幕的时刻。回归测试断言它不超过 0.30。

**Boss 血条放在 y=96..116**：这段正好在玩家可达范围（上边界 y=118）之上，所以一条常驻不了几秒的血条既醒目又不会挡住操作区。它平时隐藏，只在 Boss 战期间由 `show_boss()` / `hide_boss()` 开关；`update_boss()` 同时刷新条与旁边的 `BOSS n/m` 文字。**血条与机体之间必须留出空隙**：`boss_hold_y` 早先是 150，而机体轮廓在中心上方延伸 46 像素，于是机体顶边（104）顶到了血条下沿（113）上，看起来像糊在一起；现在把 `boss_hold_y` 提到 180，顶边落到 134，留出 21 像素。回归测试断言“机体顶边高于血条下沿至少 15 像素”，改任一处都会被发现。

**连击标签紧挨着分数**：ScoreLabel 收窄到 x=196，把 200..288 让给 `ComboLabel`（琥珀色、右对齐）。倍率为 ×1 时它是隐藏的——×1 是常态，常驻显示反而会盖住“现在有加成”这件事，所以 `update_combo()` 只在 `multiplier > 1` 时才显示它。

顶栏第二行由三个标签分列，从左到右为 StatusLabel（x=22..240）、LevelLabel（248..318）、BestLabel（326..458），彼此留 8px 间隔；经验条 XpBar 紧贴其下（y=83..89），用两个 StyleBoxFlat 子资源做轨道与填充，`show_percentage=false` 以免数字压在 6px 高的条上。这四处的矩形都在回归测试里断言过“文字不超出矩形、标签互不重叠”，改动文案或字号会立刻被测试发现。

TopBar、LevelLabel、BestLabel 与 XpBar 都在 y=90 以上，而 Overlay 从 y=90 起才覆盖，因此等级、经验与最高分在开始、战斗、升级、结算四种状态下都可见，弹窗里无需重复显示——这也是它们放在顶栏而不是消息面板的原因。**本局战报正是按这个前提写的**：它刻意不重复分数、最高分、等级与剩余生命，只补顶栏看不到的击毁数、最高倍率、受伤次数、漏敌架数与能力路线，一共 6 行。MessageLabel 高 154px、字号 18，6 行约 140px，正好落在固定矩形里；回归测试对宽度和高度**两项**都做了断言，改文案或加行会立刻被发现。

**升级面板与暂停**：HUD 根节点必须设 `process_mode = 3`（PROCESS_MODE_ALWAYS）。升级时 Main 执行 `get_tree().paused = true` 冻结整个世界，而 Godot 不会把输入派发给 PAUSABLE 节点，若 HUD 仍是默认的 INHERIT，五张能力卡会看得见却点不动、数字键也失效。把这一个根节点设为 ALWAYS 后，其子节点默认 INHERIT 一并生效——这是本项目唯一需要碰 process_mode 的地方。UpgradeCard 的 `focus_mode` 为 None，与开始/重开按钮一致，避免空格变成激活卡片的按键。

面板按“基础 4 个、幸运补给后 5 个”预留了 5 张卡片：卡片高 82、间距 12，从 y=206 排到 664。**面板下沿不是固定的**：`show_level_up()` 会把它设成“最后一张实际可见卡片的下沿 + 26”，因为最常见的 4 选 1 只用到 y=570，固定到 690 会在底部空出约 120 像素，看着像界面没画完。取最后一张卡的 `offset_bottom` 而不是把卡片几何抄一遍，好处是以后改卡片高度或间距时面板会自动跟随，不会两处对不上。`show_level_up()` 只显示实际给出的张数，多余的隐藏，因此 4 选 1 时不会留下点不动的空格子。这些几何关系在回归测试里有断言（文案不超出卡宽、4 张与 5 张时面板都必须紧贴最后一张卡、第 5 张不越出面板下沿、首张不压住标题），加能力或改字号会立刻被发现。

### 5.9 波次与难度参数表

难度与波次的全部数值都在 `assets/wave_tuning.tres`（脚本 `scripts/WaveTuning.gd`，继承 `Resource`）。Main 通过 `@export var tuning: Resource` 引用它，**只读不写**。

为什么做成 Resource 而不是写死在 Main 里：这些数值是要反复调的（生成间隔、速度曲线、开火概率、五套编队的架数与倍率），放在资源里可以在检查器里直接改、也能为不同关卡换一份 `.tres`，不必碰代码。项目约定所有脚本都不注册 `class_name`，所以 `tuning` 只能声明成 `Resource` 而不是更精确的类型——代价是检查器里理论上能挂错资源。为此 `_ready()` 里不止判空，还确认它确实带 `waves` 字段，缺了就换一份默认值并 `push_warning`，而不是等到第一次生成敌机时炸在 `tuning.waves` 上。

**Main 只读它，运行时需要变化的量另存副本**。“战术从容”会拉长难度上升间隔，改的必须是 Main 里的 `level_step_seconds` 副本，而不是 `tuning.level_step_seconds`——资源是全局共享的，直接改会把参数表弄脏，重开也回不来。`_reset_upgrades()` 从资源重新取一份即可复位。

参数表分成四组：

| 组 | 内容 |
| --- | --- |
| 难度曲线 | `level_step_seconds`、`max_level`、`max_level_per_player_level` |
| 生成节奏 | 波内间隔的基数/递减/下限/**尾段系数**、开局缓冲、波间停顿、每轮数量加成上限 |
| 敌机数值 | 速度区间与每级增量与上限、开火概率基数/增量/上限、射击间隔基数/递减/下限/**尾段系数**、首发延迟区间、**齐射发数的每级阶梯/上限/张角**、弹速基数/增量/上限、瞄准比例每级增量与上限 |
| 逃敌代价 | 每漏一架累积多少难度压力、压力上限 |
| 波次 | `waves` 数组，每项含 `name`、`count`、`formation`、`speed_scale`、`shooter_bonus`、`aim_ratio` |
| Boss | 目标击破秒数与血量上下限、入场高度与速度、巡航速度与边距、齐射间隔与下限与递减、扇形发数与上限与张角、弹速与上限、奖励分、**击破额外补几级经验（`boss_xp_levels`）** |

**为什么处处都有上限**：难度与波次加成是叠加生效的。精锐波速度 ×1.25 再乘上高难度等级的速度加成，如果不夹紧，后期会出现瞬间穿过屏幕、玩家无论如何都躲不掉的敌机与弹幕。生成间隔同理——没有下限的话，最高难度会把整波压进同一帧。`shooter_chance()` 与 `aim_ratio()` 单独抽成函数，就是为了让“夹紧”这件事可以被直接断言，而不必靠统计采样去猜。

**但撞上限/下限会让难度提前冻死——这是本表踩过两次的坑，第二次的教训和第一次相反，值得完整记下来。**

第一次的现象是：第一版把 `shoot_interval_floor` 设成 0.75，而它要难度 15 才触底、当时的上限只有 12，**等于这个参数从未生效**；`shooter_chance_cap` 在难度 7 就撞顶；`bullet_speed_cap` 从头到尾没被触到过。当时的结论是“上限设得太低”，于是把 `max_level` 从 12 抬到 30 并同步抬高各 cap。

**但这个诊断只对了一半。** 真正把难度冻住的是**下限触底的等级**：生成间隔在难度 13 撞上 0.18、射击间隔在 18 撞上 0.45，此后无论等级涨到多少都不再收紧——把上限从 12 抬到 30 对此毫无帮助。这一点后来被真人第一局的数据坐实：那局难度 25（其中 21 级来自计时），可 L18→L25 的最后 84 秒里**所有压力参数都是常数**，玩家反馈“中段太顺，像在等死”。同理，`max_level_per_player_level` 那套“上限随等级放宽”的机制也一度形同空转：它发出的高等级里不含任何新增威胁。

因此每个“间隔”类参数都多了一个 **tail 系数**：撞到下限之后，每多出一级再乘一次 tail，曲线不会停（`_tighten()` 统一实现）。**线性段逐值不变**，所以前中期手感零回归，改的只有尾段。回归测试对此有三条针对性守卫：难度 1~12 必须与线性公式逐值一致（证明前期没被顺手改坏）、难度 20/30/40 必须逐档更密（平台期一旦复发就失败）、射击间隔越过下限后仍须收紧且不会滑到 0。

**以后新增任何带 floor/cap 的压力参数，都要先想清楚它触底在哪一级、之后靠什么继续加压**——光记着“要有上限”是不够的。

### 5.10 为什么用 Area2D

弹幕游戏通常只关心“是否重叠并造成伤害”，不希望飞机/子弹撞上后推挤、滑动或受重力。Area2D 可手动改 position，用 area_entered 做重叠事件，因此更直接。CharacterBody2D 适合需要地板、墙壁、滑动的角色；Area2D 不会自动挡墙，所以本例靠 clampf 限制边界。若未来加可阻挡地形，可用 CharacterBody2D 根节点负责移动、Area2D 子节点作为受击盒，不能只换根类型不改逻辑。

### 5.11 完整场景与主题文件

可不点编辑器逐节点搭建：直接新建对应 UTF-8 文本文件，把下面的内容完整粘贴。`.tscn` 的 sub_resource 已包含碰撞形状，Polygon2D 坐标已包含美术轮廓，无额外绘图步骤。
'''
BEFORE_SCRIPTS = r'''
## 6. 完整 GDScript 代码

下面七个文件是项目实际使用的完整源码，不是伪代码。所有信号通过代码连接，场景无需额外编辑器信号连接。各脚本不注册 class_name，避免导入时的全局类扫描依赖；场景实例经鸭子类型调用已约定的方法，基础数值和 Godot 节点仍尽量显式类型。

职责链：Player 请求发弹 → Main 延迟实例化 PlayerBullet → PlayerBullet 调 Enemy.take_hit → Enemy.destroyed(points) → Main.add_score。玩家受伤由 Player.player_hit → Main 统一扣命；HUD 只展示。

延迟隔离：run_id 保证上一局 call_deferred 的生成请求不进入下一局；life_epoch 保证上一局无敌计时器恢复后不会关闭下一局无敌。实体 deactivation 立即改布尔锁/停处理/隐藏，再 set_deferred 关闭检测、queue_free 帧末释放。
'''
AFTER_SCRIPTS = r'''
## 7. 信号连接说明

**全部代码连接，不要在编辑器再连一次**。_ready 在节点进入树后调用且子节点已经就绪；同一节点本例只连接一次。重新开始复用 Main/Player/HUD，不会重新执行这些节点的 _ready，因此不会累计连接。

| 信号 | 接收函数 | 连接位置 |
| --- | --- | --- |
| EnemyTimer.timeout | Main._on_enemy_timer_timeout | Main._ready |
| HUD.start_game | Main.start_game | Main._ready |
| HUD.restart_game | Main.restart_game | Main._ready |
| HUD.upgrade_chosen(index) | Main.choose_upgrade | Main._ready |
| Player.player_hit | Main._on_player_hit | Main._ready |
| Player.shoot_requested(origin) | Main._on_player_shoot_requested | Main._ready |
| Enemy.destroyed(points) | Main.add_score | Main._create_enemy，add_child 之前 |
| Enemy.destroyed(points) | Main._on_enemy_destroyed(points, enemy) | 同一信号再连一次，用 bind 把敌机带进来，好把爆炸放在它被击毁的位置 |
| Enemy.escaped | Main._on_enemy_escaped | Main._create_enemy；被击毁不会发这个信号，所以两者互不干扰 |
| Enemy.shoot_requested(origin, direction, speed) | Main._on_enemy_shoot_requested | Main._create_enemy |
| Boss.destroyed(points) | Main._on_boss_destroyed | Main._start_boss，add_child 之前 |
| Boss.hp_changed(hp) | Main._on_boss_hp_changed | Main._start_boss |
| Boss.shoot_requested(origin, direction, speed) | Main._on_boss_shoot_requested | Main._start_boss；它只是转发给同一个接收函数 |
| Player.area_entered(area) | Player._on_area_entered | Player._ready |
| PlayerBullet.area_entered(area) | PlayerBullet._on_area_entered | PlayerBullet._ready |
| EnemyBullet.area_entered(area) | EnemyBullet._on_area_entered | EnemyBullet._ready |
| ShootTimer.timeout | Enemy._on_shoot_timer_timeout | Enemy._ready |
| StartButton.pressed | HUD._on_start_pressed | HUD._ready |
| RestartButton.pressed | HUD._on_restart_pressed | HUD._ready |
| UpgradeCard0..4.pressed | HUD._on_upgrade_card_pressed(index) | HUD._ready，用 bind 绑定下标 |

Enemy **不连接** area_entered（Mask=0）；Player 通知其 hit_player。玩家弹没有直接找 Main，而是用敌人的 destroyed 信号加分。`get_tree().create_timer(...).timeout` 通过 await 等待，不需要额外编辑器连接。

`Enemy.destroyed` 被连了两次：一次给 `add_score` 记分，一次给 `_on_enemy_destroyed` 放爆炸。之所以要用 `bind(enemy)` 把敌机自己传进去，是因为 `destroyed` 只带分值、不带位置，而爆炸必须落在敌机被击毁的地方。第二个回调里读 `enemy.global_position` 是安全的——`queue_free()` 只是排队，真正释放发生在帧末，此刻节点仍然有效；位置一读到就交给 `call_deferred` 生成，不在物理回调里直接改场景树。

**音频没有新增任何信号**：音效就挂在已有事件上——射击在 `_on_player_shoot_requested`、击毁在 `_on_enemy_destroyed`、受伤在 `_on_player_hit`、升级在 `_begin_level_up`、结算在 `game_over()`。刻意不给声音单开一条信号链：多一层转发只会让“什么时候该响”更难追。

三张能力卡共用一个接收函数，靠 `pressed.connect(_on_upgrade_card_pressed.bind(index))` 的 `bind` 区分下标，因此不需要写三个几乎相同的函数。数字键 1–5 不走信号连接，而是 HUD 在 `_unhandled_input` 里读 `choice_*` 动作后发出同一个 `upgrade_chosen` 信号——按钮与键盘最终汇入同一条路径，Main 只认一个入口。五张卡片共用同一个函数，加卡片只需要在场景里加节点并在 `upgrade_cards` 数组里登记。

若扩展为重复配置/对象池，在 connect 前用 `signal.is_connected(callable)` 判断；不要给本项目的场景再添加同等 `[connection]` 段。signal 是事件，不是节点路径；`$CanvasLayer/HUD` 与 `$HUD` 不可互换。

## 8. 场景搭建与运行步骤

### 8.1 方式 A：导入交付项目（推荐）

1. 下载并解压项目 ZIP 到新文件夹，保留 PlaneBattle 内目录结构。
2. 启动 **Godot 4.7.2 Standard**，项目管理器点击 Import，选择 PlaneBattle/project.godot，再 Import & Edit。不需要 .NET 版本，不需要 C# SDK。
3. 等待资源扫描结束，FileSystem 中打开 scenes/Main.tscn。
4. 按 F6 可运行 Main 场景；平时推荐 F5 运行项目已设置的主场景。在本仓库里还有一个更省事的入口：直接双击根目录的 `play.bat`，它会用 `tools/godot-4.7.2/` 下的引擎打开工程，退出后打印对局记录的存放路径（详见第 1.1 节）。
5. 点击“开始飞行”或按 R，WASD/方向键移动，按住空格射击。窗口需有键盘焦点；中文输入法下建议切英文模式。
6. 左上得分随击毁增长，右上生命随碰撞减少；等待 15 秒观察难度提高；生命耗尽后按 R 或点按钮重开。

### 8.2 方式 B：从空项目复制所有文件（最快学习复现）

1. Godot 项目管理器点 Create，名称“飞机大作战”，选择空目录，Renderer 选 Compatibility；创建后退出到项目管理器。
2. 在该目录创建 scenes、scripts、assets 三个文件夹；tests 是可选自测目录。
3. 将第 6 节九个脚本分别保存到对应 scripts/*.gd，将第 5.11 节八个场景与两份 .tres（主题与波次参数）保存到对应路径，编码 UTF-8。
4. 用第 3.1 节全文替换 project.godot，再次导入/打开该项目；不要把 Markdown 的代码围栏 ``` 一起粘进文件。
5. 打开 Main.tscn，检查右上 Renderer 为 Compatibility；F5 测试。完整配置已包含主场景、输入、碰撞层命名、窗口和物理频率，无需再设置。

### 8.3 方式 C：逐节点手工搭建（练习编辑器）

先复制 scripts/*.gd 和 assets/ui_theme.tres，脚本可能暂时提示找不到 .tscn，等所有场景建好会消失。也可先建好无脚本的全部场景骨架，再统一挂脚本。

1. **Player**：新建场景 → Other Node → Area2D，重命名 Player；按树加 Visual Node2D 和三个 Polygon2D。选 Polygon2D 在 Polygon 属性输入第 5.11 节的顶点坐标，或直接拖入交付场景。加 CollisionShape2D → New RectangleShape2D → Size 34×42；加 Marker2D 改名 Muzzle、Position(0,-43)。Layer 仅第1层，Mask 仅第2、4层，挂 Player.gd，保存 scenes/Player.tscn。
2. **PlayerBullet**：Area2D 根，添加 Polygon2D Visual 与 CollisionShape2D（矩形8×20）；Layer第3、Mask第2，挂 PlayerBullet.gd，保存同名场景。
3. **EnemyBullet**：Area2D 根，添加 Polygon2D Visual/Core 与圆形 CollisionShape2D（半径7）；Layer第4、Mask第1，挂 EnemyBullet.gd，保存。
4. **Enemy**：Area2D 根，Visual 及 Hull/Cockpit，碰撞矩形42×40，Muzzle(0,37)，ShootTimer Timer（Wait Time 1.8、One Shot勾选、Autostart不勾选）。Layer第2、Mask全关、Monitoring关闭、Monitorable开启；挂 Enemy.gd，保存。
5. **HUD**：Control 根，工具栏 Layout → Full Rect；拖 assets/ui_theme.tres 到 Theme。**把根的 Process Mode（Node → Process → Mode）设为 Always**，否则升级时暂停会让能力卡点不动。按节点树添加27个子节点并设对应矩形；Label文本和字号照场景源码；HUD根及非按钮 Mouse Filter=Ignore，按钮 Focus Mode=None，RestartButton、升级面板各节点与 Boss 血条初始隐藏，DamageFlash 的 alpha 设为 0。XpBar 与 BossBar 各用两个 StyleBoxFlat 子资源做轨道与填充。挂 HUD.gd，保存。
6. **Main**：Node2D 根；依次添加 Background、FlightLines及三条Line2D、Actors Node2D、实例化Player、Camera2D、EnemyTimer、Music（AudioStreamPlayer，Bus 选 Music、Stream 拖 bgm.wav、Process Mode 设 Always）、Sfx（普通 Node，留空）、CanvasLayer，再在 CanvasLayer 下实例化 HUD。CanvasLayer Layer=1；Player位置(240,695)；**Camera2D位置(240,400)**；EnemyTimer One Shot开、Autostart关；Background Ignore，z=-10；**再把 Inspector 里的 Tuning 拖成 assets/wave_tuning.tres**（不接也不会崩，会回落到默认值并打印一条警告）。挂 Main.gd，保存 scenes/Main.tscn。
7. **波次参数表**：新建资源 —— 在 FileSystem 里右键 assets → New Resource → 搜 `WaveTuning`（即 `res://scripts/WaveTuning.gd`）→ Create，命名 `wave_tuning.tres`。Inspector 里会看到四大组参数；保持默认值即可，也可以按第 5.9 节的说明自行调整。
8. **音频总线**：Audio 面板右上角切到 Bus Layout，新增 Music 与 SFX 两条总线（Send 都选 Master），Music 音量设 -6 dB、SFX 设 -3 dB，然后 Save 到项目根目录的 `default_bus_layout.tres`。这一步不做的话，代码里 `bus = "Music"` 会静默回落到 Master。
9. **Explosion**：新建场景 → Other Node → CPUParticles2D，重命名 Explosion；关掉 Emitting、勾上 One Shot，Amount=14、Lifetime=0.42、Explosiveness=1、Spread=180、初始速度 70..190、重力 (0,120)。Texture 选 New GradientTexture2D，宽度高度都设 16、Fill 选 Radial、gradient 设为“亮黄 → 橙 → 全透明”。再加一个 Polygon2D 子节点改名 Flash，用第 5.11 节给的八角形顶点、颜色纯白。挂 Explosion.gd，保存 scenes/Explosion.tscn。
10. **Boss**：新建场景 → Other Node → Area2D，重命名 Boss。Layer 第 2 层、Mask 全关、Monitoring 关闭、Monitorable 开启（与 Enemy 完全一致，因为两者复用同一条检测链路）。加 Visual Node2D 与 Hull/Plate/Core 三个 Polygon2D（顶点见第 5.11 节）、CollisionShape2D（矩形 150×78）、Marker2D 改名 Muzzle、Position(0,52)，以及 ShootTimer（Wait Time 1.5、One Shot 勾选、Autostart 不勾选）。挂 Boss.gd，保存 scenes/Boss.tscn。
11. **项目配置**：Project Settings 按第3节设置窗口480×800、canvas_items/keep和11个输入动作；Layer Names写四层；Physics → Common → Physics Ticks Per Second=120。Project → Project Settings → Application → Run → Main Scene选 Main.tscn，或首次F5时 Select Current。
12. **连接检查**：不要手动连接信号，代码自动连接。Actors 不加任何编辑器常驻子节点。不需要 Autoload、插件或额外导出资源。

### 8.4 人工验收清单

- 初始只有开始界面，计分0、生命3、Lv 01、经验条为空，不刷敌。
- 按住空格连续发弹；松开停止；四角移动不越界；斜向速度正常。
- 红机击毁+10，橙机击毁+20，一敌不重复加分；撞机不加分。
- 敌机/敌弹触碰扣1，闪烁期间多次接触不连扣；无敌结束再命中才再次扣血。
- 敌机和子弹飞出边界自动销毁；Remote场景树中 Actors 不随时间无限积累。
- 难度每 9 秒 +1，顶栏的难度读数应按这个节奏上涨；每次重开都恢复 0 分/3 命/难度 1/Lv 1。
- **中段必须一直在变难**：留意自己从难度 18 往后打时，敌机的密度与开火频率是否还在缓慢上升，而不是“数字在涨、手感不变”。若感觉到某个等级之后突然不再变难，那就是尾段收紧失效了。注意前期（难度 1~12）的手感是**刻意保持不变**的，前中期不该有变化。
- 顶栏“最高”在开始界面就显示已有纪录；打破纪录后结算界面出现“新纪录”，未打破则不出现。
- 打破纪录后关闭游戏再运行，顶栏“最高”仍是该分数；把 user://save.cfg 手动改成非法内容后再运行，最高分回到 0 且能正常开局。
- 结算面板应显示 6 行本局战报：生存秒数 / 到达难度 / 到达等级、击毁数、最高倍率、受伤次数 / 漏敌架数、本局能力路线。战报里**不该**再出现分数与最高分——顶栏一直显示着，重复显示只是挤占空间。
- 结算后顶栏那个琥珀色倍率标签应当消失。若它还在，说明结算没有把连击清零，玩家会以为加成还生效。
- 每局结束都会往 `user://runs.jsonl` 追加一行 JSON（本机路径可由 `play.bat` 退出时打印）。可以连打几局后打开它核对：分数、击毁数、受伤次数、漏敌数、峰值倍率、存活时长、是否破纪录、以及能力路线都与刚才那几局对得上；连续打 50 局以上时文件不应无限增长。
- 可以在游戏关闭时把 `runs.jsonl` 手动改成一行乱码再开一局：新的记录应当正常追加，乱码行被丢掉而不是让结算报错或卡住。
- 击毁敌机时经验条增长；满格后世界立刻停住，弹出四张卡片，卡片互不重复。
- 升级面板出现时，敌机、子弹、玩家全部静止，但按 1/2/3/4 与鼠标点击都能选中，选完立即恢复流动；叠了“幸运补给”后应出现第 5 张卡，并能按 5 选中。
- 逐项验证 16 种能力各有可见效果：射速变快、移动变快、无敌变长、每次多射一发、追加左右两条平行弹道、子弹更快、能穿两个敌机、能击落敌弹、子弹变大、生命+1、生命上限+1、当场清空敌弹、经验涨得更快、得分更高、难度上升更慢、升级多一个选项。
- 多发与侧翼炮叠在一起时，所有子弹都必须竖直向上、水平等距排成一条线，不能出现斜飞或两条弹道重叠在同一横坐标上。
- 紧急清屏只清敌弹：敌机与自己刚打出的子弹都应留在场上。
- 连续吃满多级经验时，会连续弹出多次抉择，而不是只让选一次。
- 击毁敌机时，敌机原地爆出一圈碎片并闪一道白光；爆炸播完自己消失，不会越积越多。
- 挨一下时画面震动一下并整屏闪红，随后都自动恢复；把 Main 的 `screen_shake_enabled` 关掉后应完全不再震动。
- 得分时分数标签会放大一下再缩回；升级时经验条前进。
- **结算与升级面板下方不该有大块空白**：4 选 1 时面板应紧贴第 4 张卡；叠了“幸运补给”变成 5 张时面板会变高，同样紧贴第 5 张。
- **Boss 登场时，顶部血条与机体之间应当能看见背景**，而不是贴在一起；机体顶部应是有尖顶与缺口的轮廓，不是一条平直的横边。
- **受伤红闪应当一眼可见但不该遮住弹幕**：泛红的同时敌机、子弹与自机都仍能看清。
- **击毁敌机时的爆炸应当有存在感**，不会被自己的弹幕盖过去。
- **背景是有层次的**：自上而下有轻微的颜色渐变，并且能看到 5 条浓淡不同的纵向航道线，而不是一块平色。
- 升级瞬间与结算瞬间，画面都不能停在震动偏移状态（摄像机 offset 必须归零）。
- 射击、击毁、受伤、升级、结算各有不同音效；背景音乐开局响起、结算停止。把系统音量调低也应能分辨出至少五种不同音色。
- 升级面板弹出时背景音乐不断、提示音照常响（整树暂停不应该把声音也掐掉）。
- 连续按住空格射击时，声音应连成一片而不是每发之间有明显断续。
- 敌机成波出现而不是匀速细流：一波放完有约 2 秒的空档，状态行“第 N 波”随之递增。
- 三套编队肉眼可辨：横列铺满整幅宽度、两翼左右交替且中间留出通道、随机散开。
- 反复玩到第二轮波次，每波敌机数量应比第一轮多，且不会无限增加。
- 把 `assets/wave_tuning.tres` 的 `spawn_interval_floor` 调到 1.5 再跑，出敌节奏应立刻变慢（验证参数确实是从资源读的，不是写死在代码里）。
- 走完五波后应出现一段短暂空档，然后 Boss 伴着一段低频警告音从上方降下，顶部弹出血条。
- Boss 战期间不再刷普通敌机；它的血条随每次命中下降，扣满才炸开多处特效并提示升级。
- 开一炮打中 Boss 若干次：它只掉血、不会像普通敌机那样一击即毁；把机身撞上去，它也不消失，只有自己掉命。
- 击破 Boss 后波次从第一套编队重新开始。
- 三种颜色的敌机行为不同：红色不还手、橙色朝正下方打、**紫色朝你打**。紫色的弹道应该明显指向你当前位置，而不是竖直落下。
- 连续击毁时分数旁出现琥珀色 `×N`：第 5 架起变 ×2，第 20 架起 ×5 封顶。
- 挨一下或漏掉一架，`×N` 立刻消失；不打敌机则它永远不会出现。
- 故意让敌机连续溜走，注意“难度”编号会**额外往上涨**——这是漏敌的代价，不只掉倍率。
- 精英波的紫色敌机会越来越多；站桩不动应该很快被打到。
- 难度上限随玩家等级增长：即使玩到十分钟，界面上的“难度”编号仍应继续上升，而不是停在某个数不动。
- Boss 血量应当随你的火力变化：满配时打它要好几秒，刚开局时明显更快。
- 重开后等级回到 Lv 1、经验清空、射速与移速回到初始值，且游戏没有卡在暂停状态。
- 最后一命结束后停止刷怪，场景无残弹；快速点击/按R不生成多架Player，不重复连接信号。
- Debugger中无解析错误、物理查询刷新错误或“previously freed instance”错误。

### 8.5 自动验证

项目额外附带 `res://tests/SmokeTest.gd`，是纯 GDScript 的 SceneTree 回归测试，不属于正式游戏节点树，不参与F5。包含按钮、输入、移动边界、真实物理碰撞、重复计分、无敌、清场、难度、射击敌人、越界、跨局计时、最高分持久化（含无存档、低分不覆盖、新实例读回、存档损坏回退）、本局战报与对局记录（含击毁数只认真击毁、漏敌不计入、峰值倍率不因受伤清零而回退、结算会清空连击并收起顶栏倍率、记录字段逐项与本局核对、只保留最近 50 局且裁掉的是最旧的、记录文件被写坏后仍能正常追加且坏行被丢弃、战报宽高都不溢出、记录带可随参数变化的规则指纹、受伤时间点序列单调不减且能识别出“连续送死”的对局），等级与经验、升级暂停、16 项能力逐项生效、多发弹生成与竖直平行弹道、侧翼炮对称性、弹体增幅真实缩放、拦截弹（含未开启时的对照组）、紧急清屏只清敌弹、得分与经验倍率互不干扰、穿透弹与对照组、幸运补给把选项加到 5 个、连续升级、死选项过滤、重开复位、爆炸生成位置与自行释放（含“击杀当帧触发升级时爆炸不被丢掉”这条回归）、受伤震动（含关闭选项与结算归零）、受伤红闪与得分脉冲的时间行为、音频总线与循环点、音效池配置与五类事件各自的触发、波次编队与出场位置、波次推进与波间停顿、速度/弹速/射击间隔/开火概率/瞄准比例的上下限夹紧、连击倍率的阶梯与上限、受伤与漏敌都会打断连击、漏敌累计并抬高难度压力且压力封顶、有效难度上限随玩家等级放宽、难度撞到下限之后仍持续收紧（含“难度 1~12 与线性公式逐值一致”的零回归对照，以及难度 20/30/40 逐档更密的平台期守卫）、敌机齐射（发数阶梯与封顶、一次真的打出多发且都变成场上敌弹、左右严格对称、单发时与旧行为逐值一致的对照）、玩家子弹出屏即失效（成对验证“顶部栏之下的敌机打不到、露头之后打得死”）、拦截弹一发换一发（击落敌弹的同时自身被消耗）、视觉收尾的回归守卫（4 张与 5 张时升级面板都必须紧贴最后一张卡、Boss 顶部轮廓至少有三种不同高度、Boss 机体顶边与血条之间留有空隙、受伤红闪峰值不超过 0.30、爆炸粒数与尺寸的下限、背景是竖向渐变贴图且航道线不少于 5 条），瞄准型敌机的弹道确实指向玩家且换用不同颜色标注、波次倍率真实生效、每轮数量加成及其上限、参数表缺失时的兜底、Boss 的登场时机与预警、入场与巡航边界、扇形齐射的方向与真实生成、撞机不自我消耗、多血量挨打与击破结算、Boss 血量随玩家输出变化（对比两套差距很大的 build）、血条同步、以及重开清场，还有固定矩形 UI 的溢出与重叠断言。它会在开头清空 user:// 存档以保证可重复，因此请只对测试用的 Godot 用户目录运行。不要把它挂到 Main。另附 VisualTest.gd 在真实图形模式下生成开始/战斗/特效/Boss/升级/结算六张截图，它会短暂显示游戏窗口，属于开发验收脚本，不属于正式玩法。三个测试脚本的完整代码列在第 6 节末尾。

**`res://tests/StressTest.gd` 是压力基准，不是玩法测试**。它把所有攻击类能力叠满、按住射击打满 6 秒，量出峰值对象数、真实帧时间与清场后的残留，用来支撑“要不要做对象池”这个决策（结论见下一条）。它用**墙钟**测帧时间而不是 `Performance.TIME_PROCESS`——无头模式下后者报出来的值明显偏大（同一段实测 33 ms，但 720 步根本不可能跑满 24 秒），拿它当帧时间会得出与事实相反的结论。敌机按**游戏真实的刷怪间隔**补（直接取 `get_spawn_interval()`），而不是写死一个步数——写死 0.3 秒一架比真实高难度还稀疏，“峰值在预算内”对敌机密度就不成立了。帧时间报 **p99** 而不是最大值：单次最大值被调度噪声主导（同一份代码四次运行量到 14.21 / 17.13 / 14.21 / 78.85 ms，而平均帧稳定在 8.24 ms）。

**`res://tests/ThreatTest.gd` 是威胁基准，量“后期还有没有威胁”**。它要回答的问题很具体：**敌方的火力有多少真的能穿过玩家弹幕、到达玩家面前**。指标有两个——**敌弹通过率**与**每架敌机开了几枪**——后者是核心诊断量。玩家固定在屏幕下方且全程不动，所以通过率与躲闪技术无关；同时它也是“最差情况”的命中数。这条基准的由来是一次方向性错误：真人反馈“一点威胁都没有”，而我此前几轮一直在**敌人那一侧**加码（密度、速度、开火概率、瞄准比例、难度曲线），而基准量出的真相是**每架敌机平均只开 0.69 枪**（按存活时间本该 2~4 枪）——玩家每秒 148 发、11 条弹道，把敌机在开火窗口之前就打死了，那些参数乘的都是“敌机能开几枪”，而它已经被压到接近 0。修法是齐射（见第 1.1 节）。它同样把结论固化成了断言：最高难度下每架敌机 ≥ 2.5 发、每秒 ≥ 12 发到达（修复前是 0.69 发与 3.33 发），一旦威胁再次被抹平就会失败。**门槛之所以敢贴着实测值定，是因为基准固定了随机种子**：出生横坐标、开火与瞄准判定都走 Main 的 rng，不固定时“到达/秒”会在 8~19 之间跳，下限定到 8.0 还是会偶发失败；固定后同一份代码连跑三次是 19.83 / 20.33 / 19.83。**注意：它必须把 `xp_multiplier` 设为 0**，否则击毁敌机会触发升级抉择把整树暂停，`_create_enemy` 直接返回，量出来的“通过率 0%”是一个由故障伪装成的结论（这个坑第一版就踩了）。

**无头也能验音频**：`--headless` 用的是 Dummy 音频驱动，听不到声音，但 `AudioStreamPlayer.playing` 反映的是真实的播放状态，所以“射击是否触发了射击音效”这类断言在无头下依然成立，不需要真的发声设备。

**两个测试脚本都带看门狗**。GDScript 没有 try/catch：`_run()` 里任何一处运行时错误（例如访问一个已经不存在的属性）都会让协程当场中断，末尾的 `quit()` 永远执行不到，进程就一直挂着——外层只能等到超时，报错还是一条看不出原因的 `TimeoutExpired`。看门狗把“挂死”换成一条明确的错误信息和非零退出码。这个问题在本项目里真实发生过一次，因此固化成了机制。

在终端运行（按本机引擎路径替换）：

```text
"C:/Godot/Godot_v4.7.2-stable_win64_console.exe" --headless --path "D:/YourProject/PlaneBattle" --script res://tests/SmokeTest.gd
```

### 8.6 导出 Windows / Web

1. Editor → Manage Export Templates → 为 **4.7.2** 下载并安装对应导出模板；编辑器与模板版本必须一致。
2. Project → Export → Add → Windows Desktop；Architecture=x86_64，输出路径选项目外 `builds/PlaneBattle.exe`。
3. 原型可勾 Embed PCK 以便单文件试用（正式签名发行需再评估签名/PCK策略）；点 Export Project，初测可开 Export With Debug，发行时关闭。未嵌入PCK时必须把生成的exe和pck一并分发。
4. Resource Filter 使用 Export All Resources；高级过滤可排除 tests/*。本项目所有动态场景均 preload，避免只导出选中资源时漏掉。
5. 运行导出的exe，重复人工验收。Windows Defender或SmartScreen可能警示未签名自制程序，正式分发需代码签名，不建议指导玩家全局关闭系统防护。
6. Web：仍用 Compatibility，添加 Web preset；若无需多线程可关闭线程支持，降低部署要求；开启线程时服务器需正确配置跨源隔离响应头。导出目录含html/wasm/pck等应全部上传HTTP服务，不能直接 file:// 双击html；用浏览器检查控制台与键盘焦点。
7. SystemFont 依赖设备字体。Windows 自带微软雅黑；其他桌面一般有相应候选字体。**Web或某些Linux设备不保证有中文字体**：正式跨平台发行时，加入具有合法分发许可的中文 .ttf/.otf，将 Theme 的 default_font 改为 FontFile，再重新导出。游戏原型在本机无需字体下载。

本交付是源码项目，不附带导出模板或发行exe，导出包需按上述步骤在你的目标平台验证。

## 9. 可选增强功能

以下是可选扩展，不是运行前置条件；本版已经实现难度递增与波次编排、Boss、无敌闪烁、最高分保存、16 项能力的等级抉择系统、爆炸粒子、受伤屏幕震动与视觉反馈（命中白闪、受伤红闪、得分脉冲），以及音效与循环背景音乐，其余默认未实现，不依赖任何缺失素材。

| 功能 | 推荐节点/API | 实现建议 |
| --- | --- | --- |
| 护盾/回血等道具掉落 | Area2D、Timer、自定义signal | 护盾、双发、回血已作为升级能力实现（第 6 节 Main 的能力池）；若要改成场上掉落，道具用独立碰撞层只检测Player，拾取发出信号给Main改规则，结束或重开清空增益计时 |
| 对象池 | Node容器、reset接口 | **已实测评估，结论是现在不做**，理由与重新评估的触发条件见下方说明 |

上表中已经落地的几项不再重复列出，实现位置如下：最高分保存见第 6 节 `Main.gd` 的 `_load_best_score()` / `_save_best_score()`；本局战报与对局记录见 `Main._build_run_report()` / `build_summary()` / `_append_run_log()` 与 `HUD.show_game_over()`；爆炸粒子见第 5.6 节的 Explosion 场景；受伤屏幕震动见第 5.1 节的 Camera2D 与 `Main._start_screen_shake()`；命中白闪、受伤红闪与得分脉冲见第 5.6 节与 5.8 节；射击/命中音效与背景音乐见第 5.1 节的 Music / Sfx 节点说明与 `Main._build_audio()`；波次与难度参数表见第 5.9 节；Boss 见第 5.7 节。

### 9.1 对象池：为什么现在不做

这一项和上面的“以后可以加”不同——它是一个**做过实测、有明确结论**的决定，所以单列出来，免得后来人凭直觉又去做一遍。

最坏情况是这样构造的：把射速、火力增援、侧翼炮、弹速、弹体增幅、穿透、拦截全部叠满（每次射击 11 发、冷却 0.074 秒），难度封顶，按住射击连续打满 6 秒，期间持续补充敌机。实测结果：

| 指标 | 实测值 | 参考 |
| --- | --- | --- |
| 峰值并发子弹 | **88 发** | 理论上限约 108（148 发/秒 × 0.73 秒存活） |
| 峰值 Actors 子节点 | **约 100 个** | 子弹 + 敌机 + 敌弹 + 爆炸 |
| 平均帧 | **8.2 ms** | |
| **帧时间 p99** | **约 12 ms** | 60 FPS 的预算是 16.7 ms |
| 停火后残留 | **0** | 实体全部自行释放 |

**为什么报 p99 而不是“最差帧”**：单次最大值在这个无头环境里被调度噪声主导——同一份代码连跑四次量到 14.21 / 17.13 / 14.21 / **78.85** ms，而平均帧始终稳定在 8.24 ms。拿那个最大值去论证“仍在 60 FPS 预算内”，等于用一个噪声样本当证据。p99 既剔除个别离群点，又能在真实性能回归时随整个分布一起上移。**基准的敌机是按游戏真实的刷怪间隔补的**（直接取 `get_spawn_interval()`），早先写死“0.3 秒一架”比真实高难度还稀疏，那时“峰值 Actors 在预算内”这条结论对敌机密度并不成立。

结论：对象周转比“需要池化”的量级低两个数量级，帧时间 p99 仍留在 60 FPS 预算内。而做对象池必须重做三处最要命的约定——`spent`/`dead` 幂等锁、`run_id` 跨局票据、以及 `_clear_entities()` 的统一清场——收益为零、风险不小。**因此保留 `queue_free`。**

**什么时候该回来重新评估**：`tests/StressTest.gd` 把上面的结论固化成了断言（峰值子弹 ≤ 250、峰值 Actors ≤ 320、停火后残留必须为 0）。它现在能过，说明结论仍然成立；**一旦它失败，就说明弹幕密度或实体数量已经涨到需要重新评估对象池的程度**，那时再动手也不迟。这比写一句“以后再说”有用得多——它给“以后”定了触发条件。

最高分保存已在本版实现，见第 6 节 `Main.gd` 的 `_load_best_score()` 与 `_save_best_score()`：存档写在 `user://`，不要写 `res://`（编辑器里能写，导出后通常只读）。若要扩展成排行榜、通关记录或设置项，在同一个存档文件里继续 `set_value` 新增键即可；`_save_best_score()` 采用“先读取再回写”，因此不会覆盖同文件中的其他键。

对局记录则是**刻意分出去**的：它写在 `user://runs.jsonl`，一行一条 JSON。原因是两者的读写节奏完全不同——最高分是“覆盖一个数”，对局记录是“追加一条并把最旧的裁掉”。若把不断增长的数组塞进 `ConfigFile`，每局都要把整个数组序列化再写回，既浪费又容易在一次写坏时丢掉全部历史；一行一条还能直接给外部脚本读。要再加统计项（例如每次升级的选择顺序、Boss 击杀耗时），在 `_build_run_report()` 的字典里加键即可，写盘与容错都不用动；上限改 `RUN_LOG_LIMIT`。

等级与能力系统也已在本版实现，见第 6 节 `Main.gd` 的 `UPGRADES` 表与 `_apply_upgrade()`。**加一项能力只需要两步**：在 `UPGRADES` 里加一行（id/name/detail/max），再到 `_apply_upgrade()` 的 match 里加一个分支；卡片文案会自动适配，回归测试会自动覆盖新文案是否放得下。要改节奏改 `xp_base` / `xp_growth`、要改选项数改 `BASE_OFFERS` 即可（注意 HUD 目前预留 5 张卡，超过 5 需要同时加节点与 `choice_*` 动作）。若要让能力跨局保留（类似永久成长），把 `upgrade_stacks` 一并存档，并在 `_reset_upgrades()` 里区分“每局重置”与“永久保留”两类即可——当前版本刻意让能力每局重置，以保证每局从同一起点开始。

## 10. 常见错误与兼容性注意事项

### 10.1 Godot 4.7.2 与 4.x

官方4.7.2维护版说明称对4.7.1暂无已知不兼容。本项目使用稳定4.x接口，不依赖4.7.2新增特性；不凭空声明其他4.x小版本都已测试。4.7.2发布说明未宣布本例Area2D/GDScript/Timer/Tween基础接口的专用破坏性变更，因此无需4.7.2特有替代写法。若迁移到别的小版本，应实际重新导入并运行测试。

### 10.2 排错表

| 问题 | 常见原因 | 本项目正确做法 |
| --- | --- | --- |
| 飞机不动/报动作不存在 | Input Map漏建、拼写不一致、游戏窗口没焦点 | 九个动作按表命名；看project.godot；点击窗口再操作 |
| 斜走更快 | 单独累加两个轴未归一化 | Input.get_vector返回限长向量 |
| 子弹碰不到敌机 | 没有形状、disabled=true、mask把层号当整数 | PlayerBullet layer=4 mask=2；Enemy layer=2 monitorable=true |
| Enemy不触发碰撞信号 | Mask=0且Monitoring关闭 | 正确设计：由Player检测Enemy并调用hit_player |
| body_entered永远不触发 | 对方是Area2D不是PhysicsBody2D | Area2D彼此用area_entered；不是body_entered |
| 受伤一次扣三命 | Player与EnemyBullet双向回调、同帧多物体 | invulnerable先置位，再emit；敌弹spent锁 |
| 一敌多次加分 | queue_free并非立即释放 | Enemy.dead先置位，再destroyed.emit；子弹spent锁 |
| flushing queries错误 | 物理回调直接改监测/形状、增删碰撞对象 | set_deferred关闭monitoring/monitorable；call_deferred生成；queue_free释放 |
| already freed instance | await/延迟回调或外部引用指向已释放节点 | is_instance_valid，必要时is_queued_for_deletion；不要保存裸对象长期引用 |
| 重开后无敌时间变短 | 旧局await在新局恢复 | life_epoch标识验证；run_id过滤旧局生成 |
| 最高分重开后丢失 | 写到了 res://（导出后通常只读）、节名/键名写错、写盘失败被静默忽略 | user://save.cfg 的 records/best_score；set_value 后 save 并检查 Error 返回值，失败只 push_warning，不阻断结算 |
| 最高分被脏存档带偏 | 无条件相信存档里的值 | 只接受 TYPE_INT 且 ≥0，其余退回 0 并警告；损坏存档在下次写盘时被自我修复 |
| 结算面板文案顶破固定矩形 | 战报是 6 行，比开始界面的 5 行多 | MessageLabel 固定高 154px、字号 18，6 行约 140px；回归测试对**宽和高**分别断言 `get_minimum_size()` 不超过矩形 |
| 结算后顶栏还挂着倍率标签 | 结算没有把 combo 清零，看着像加成还在生效 | `game_over()` 里 `combo = 0`；本局峰值另存在 `peak_combo_multiplier`，不受影响 |
| 战报里的最高倍率总是 ×1 | 用结算时的 `combo` 反推倍率，而它在受伤或结算时已被清零 | 峰值必须在击毁时记进 `peak_combo_multiplier`，不能事后从 `combo` 推 |
| 对局记录越写越大 | 忘了裁剪，或每局把整个文件重写成了追加 | `RUN_LOG_LIMIT` 只保留最近 50 局，超出从最旧的丢；`_append_run_log()` 读旧行 → 追加 → 一次性写回 |
| 读到乱码的 runs.jsonl 后日志里出现 JSON 报错 | 用了静态的 `JSON.parse_string()`，解析失败会直接往引擎日志写一条 ERROR | 改用 JSON 实例的 `parse()` 判断（返回错误码，不写日志）；容错是设计行为，不该在日志里留下像故障的报错 |
| 双击 play.bat 提示“不是内部或外部命令” | .bat 里写了中文：cmd.exe 按 ANSI 代码页逐字节解析，中文会把命令行断错 | .bat 只写 ASCII 并转发给 `tools/play.ps1`（UTF-8 带 BOM）；`chcp 65001` 救不回已经读进来的行 |
| 正常游玩时引擎报无法写 user:// 日志/存档 | 运行环境不允许写 `%APPDATA%`（例如受限沙箱或只读配置） | 引擎自己的日志写失败与应用逻辑无关；把 `APPDATA` 指向可写目录即可验证 |
| 难度中段“变平”、像在等死 | 压力参数撞上 floor/cap 后不再变化，难度数字还在涨但威胁没变 | `_tighten()` 在下限之后继续按 `*_tail` 逐级收紧；回归测试断言难度 20/30/40 逐档更密，且 1~12 与线性公式逐值一致 |
| 以为“抬高 max_level 就能解决难度冻死” | 抬的是上限，而冻住参数的往往是**下限触底的等级** | 生成间隔 L13 触底、射击间隔 L18 触底，与 max_level 无关；新增带 floor 的参数时要一并想清楚它触底在哪一级 |
| 一个 Boss 就让玩家连升好几级 | 击破奖励同时给分和经验，且额外补的经验过重 | `boss_xp_levels` 默认 0.5（半级）；一整级时单个 Boss 约等于 100 架普通敌机的经验 |
| 压力基准说“峰值在预算内”，但真到高难度会卡 | 基准按写死的间隔补敌机，比真实刷怪率还稀疏 | 基准直接取 `get_spawn_interval()`，压的是真实密度 |
| 压力基准的“最差帧”忽高忽低 | 单次最大值被调度噪声主导（四次同代码量到 14~79 ms，平均帧稳定在 8.24 ms） | 改报帧时间 p99：既剔除离群点，真回归时仍会随整个分布上移 |
| 后期“没有威胁”、怎么调密度都没用 | 敌机在开火窗口之前就被玩家火力打死，敌方总输出被掐死在源头 | 实测每架只开 0.69 枪；改用齐射（`volley_every_levels`/`volley_cap`）让总输出由首发决定，不依赖敌机活多久 |
| 以为威胁不足是拦截弹太强 | 拦截弹确实很强，但基准量出敌弹通过率本来就有 65~80% | 先量“敌弹通过率”与“每架开火数”再动手；瓶颈在源头，不在拦截 |
| 威胁基准量出“通过率 0%”，敌人却明明在开火 | 玩家击毁敌机触发了升级抉择，整树暂停后 `_create_enemy` 直接返回 | 基准里必须 `xp_multiplier = 0`（StressTest 有同样的注释警告）；断言“分母有效”以防故障伪装成结论 |
| Can't find overlapping areas when monitoring is off | 重开后第一帧监测开关仍等待延迟生效 | get_overlapping_areas前检查monitoring；本例已保护 |
| 暂停后UI按钮也停了 | get_tree().paused=true 后输入不再派发给 PAUSABLE 节点 | 本例升级时确实整树暂停；只把 HUD 根设为 PROCESS_MODE_ALWAYS（子节点 INHERIT 一并生效），三张能力卡与数字键因此在暂停中仍可用 |
| 升级面板看得见但点不动 / 数字键没反应 | 同上：HUD 仍为默认 INHERIT，被暂停拦住 | 检查 scenes/HUD.tscn 根节点的 process_mode=3；这是唯一需要改 process_mode 的地方 |
| 升级后世界不动了 | 选完没解除暂停，或路径提前 return | 选择与开新局都显式 _set_paused(false)；回归测试断言“结算会解除暂停”“重开会解除暂停” |
| 重开后还带着上一局的强化 | 能力直接改了 Player 的导出值却没有还原 | _ready 记录 _base_* 初值，_reset_upgrades() 每次开局还原射速/移速/无敌，并清空 upgrade_stacks、等级与经验 |
| 连升多级只让选一次 | 升级判定用了 if 而不是循环 | _check_level_up() 用 while；choose_upgrade() 结尾再判一次，多余经验不会被吞掉 |
| 选项出现“选了没效果” | 未过滤已叠满或无意义的能力 | is_upgrade_offered() 同时挡“层数达上限”和“生命已满时的补给/机体强化” |
| 拦截弹不起作用 | PlayerBullet 的 Mask 只有第 2 层，看不到第 4 层的敌弹 | PlayerBullet.tscn 的 collision_mask=10（2 \\| 8）；敌弹 Mask 只有第 1 层，所以链路天然单向，不会重复回调 |
| 拦截弹一下就没了 | 击落敌弹时把玩家子弹也一并消耗了（这是**有意为之**的平衡规则，不是缺陷） | `intercept()` 命中后自己 `deactivate()`：一发换一发。早先的版本是“击落后自身继续飞”，还被当成优点写进了本文档——直到实测发现它等于给满配玩家一面无限次拦截的盾 |
| 得分倍率顺带加快了升级 | 把 score_multiplier 也乘到了经验上 | 两者各乘各的：分数用 score_multiplier、经验用 xp_multiplier |
| 选项数量与卡片数对不上 | BASE_OFFERS 与 HUD 的卡片节点数不一致 | BASE_OFFERS=4，HUD 预留 5 张卡并配 choice_1..5；要加到 5 以上需同时加节点与输入动作 |
| 改能力文案后卡片被截断 | 固定矩形里塞了过长的文案 | 回归测试逐项断言“卡片文字宽度 ≤ 卡片宽度”，并检查第 5 张不越出面板下沿 |
| 屏幕震动把 HUD 也带着抖 | HUD 不在 CanvasLayer 上，或误开了 follow_viewport | HUD 挂在 CanvasLayer(layer=1)，默认不跟随视口；震动只改 Camera2D.offset，不去碰任何节点位置 |
| 加了 Camera2D 后画面整体偏移 | 摄像机没放在画布中心 | position=(240,400) 且 anchor_mode 保持默认 DRAG_CENTER，视图恰好等于 (0,0)–(480,800)，与没有摄像机时一致 |
| 结算画面一直歪着 | 震动补间没停、offset 没归零 | start_game() 与 game_over() 都调用 _stop_screen_shake()：kill 补间并把 offset 置零 |
| 震动“有时候没反应” | 随机取两个分量有可能恰好得到零向量 | _random_shake_offset() 取随机*方向*再乘固定长度，保证偏移量恒为非零 |
| 粒子不显示 | GPU 粒子在 GL Compatibility 下受限，或没给贴图 | 用 CPUParticles2D，贴图用内置 GradientTexture2D（Fill=Radial）画径向渐变圆点，不需要任何图片文件 |
| 爆炸越积越多 | 没接 finished 信号，或节点不在会被清空的容器里 | one_shot 播完发 finished → queue_free；爆炸加在 Actors 下，开局/结算会一并清空 |
| 连按导致闪红闪成一片 | 每次受伤都新建 Tween 且旧的没停 | flash_damage()/pulse_score() 持有 Tween 引用，先 kill 旧的再建新的 |
| 分数脉冲时文字“跳” | Label 默认轴心在左上角 | 先把 pivot_offset 设为 size 的一半再缩放，围绕中心放大 |
| 完全没有声音 | 总线名写错时 Godot 会**静默**回落到 Master；或素材没导入 | 总线名与 default_bus_layout.tres 严格一致；回归测试断言两条总线都存在；首次打开项目要等资源导入完成 |
| 背景音乐播一遍就停 | `.import` 里 `edit/loop_mode=0`（导入默认不循环） | `_prepare_music()` 在运行时把 `loop_mode` 设为 LOOP_FORWARD，并把 bgm.wav.import 的 `edit/loop_mode` 改成 1 |
| 循环点错乱、音乐突然跳回开头 | QOA 压缩后 `AudioStreamWAV.data` 不是原始 PCM，按字节数换算样本数会算错 | 循环点用 `get_length() × mix_rate` 换算，与压缩格式无关 |
| 升级时背景音乐断一拍、提示音不响 | 播放器是默认的 PAUSABLE，被整树暂停拦住了 | Music 与每一路音效都设 `process_mode = Always`（全局只有 HUD 和音频需要这样） |
| 连射时后一发把前一发掐断 | 只用了一个 AudioStreamPlayer | `Sfx` 容器下按 `sfx_voices` 建池，优先用空闲那一路，全忙才轮转覆盖 |
| 退出时报 “N resources still in use at exit” | 退出时播放器还握着 AudioStream 引用 | 收尾先 stop、再置空 stream、多等几帧再 queue_free；测试脚本已按此收尾，否则这条诊断会让流水线偶发失败 |
| 把音效挂在敌机节点上后声音断掉 | 敌机当帧 queue_free，播放器随节点一起消失 | 音效一律由 Main 的常驻音效池播放，不挂在任何会被释放的节点上 |
| 改了 wave_tuning.tres 却没有任何变化 | Main 上的 Tuning 没接、或改的是别的 .tres | 检查 Main 节点的 Tuning 属性指向 `res://assets/wave_tuning.tres`；没接时会回落默认值并打印一条警告 |
| 敌机不再成波、又变回匀速细流 | wave_index 被外部重置，或 tuning.waves 为空 | 空波次表时 current_wave() 返回空字典、每波按 1 架处理，属于兜底而非正常状态；回归测试断言波次表有 5 套编队 |
| 后期出现躲不掉的敌机/弹幕 | 难度与波次加成叠加后突破了上限 | 速度、弹速、射击间隔、开火概率、生成间隔全部有上下限，改参数表时不要把这些下限调得过激 |
| 手动改了 difficulty_level 却立刻被打回 | 它是 `_process` 每帧从 survival_time 重算的派生值 | 测试里设完必须立刻断言、中间不能 await；游戏逻辑不要手动写这个字段 |
| “战术从容”叠了几层后重开还留着 | 改的是共享的 tuning 资源而不是运行时副本 | 能力只改 Main 的 `level_step_seconds`，`_reset_upgrades()` 从 tuning 重新取一份 |
| 测试脚本挂死不退出、外层报 TimeoutExpired | GDScript 没有 try/catch，`_run()` 中的运行时错误会让协程中断、`quit()` 执行不到 | 两个测试脚本都装了看门狗定时器，超时会打印明确原因并以非零码退出。看门狗上限必须**明显小于**外层 90 秒子进程超时，否则超时先由外层触发，日志还停留在上一次运行的内容上 |
| Boss 一直不出现 | 要先把五波全部放完（`wave_index` 走满一轮）才会排 Boss | 这是设计如此；回归测试直接把指针推到最后一波来验证，不必真打五波 |
| 击杀瞬间没有爆炸特效 | 爆炸是帧末延迟生成，而击杀当帧可能触发升级把 state 变成 LEVEL_UP | `_spawn_explosion()` 的守卫只排除 READY/GAME_OVER，刻意放行 LEVEL_UP；Explosion 场景设了 PROCESS_MODE_ALWAYS，暂停期间照样播完 |
| Boss 被机身一撞就死了 | 照抄了普通敌机“撞上就同归于尽”的 hit_player | Boss 的 `hit_player()` 只让玩家扣血，自己不消耗；玩家的无敌帧负责去重 |
| 击破 Boss 后游戏卡在升级界面 | 奖励分同时是经验，可能一口气连升多级 | 这是设计如此；测试里用循环把整条抉择链收完，正常游玩由玩家一张张选 |
| Boss 血条位置挡住操作 | 血条压在玩家可达区域里 | 血条放在 y=96..116，正好在玩家上边界 y=118 之上 |
| Boss 血条贴住机体 | `boss_hold_y` 太小，而机体轮廓在中心上方延伸 46 像素，顶边正好顶到血条下沿 | `boss_hold_y` 从 150 提到 180：顶边从 104 落到 134，与血条下沿留出 21 像素；回归断言“至少 15 像素” |
| 无头下量到的帧时间大得离谱 | 用了 `Performance.TIME_PROCESS`，它在无头模式下的值与实际步进间隔对不上 | 压力基准改用墙钟（`Time.get_ticks_usec()`）测每一步的真实间隔；两者的差距一度让人误判成“性能有问题” |
| 后期难度突然不再上升 | 某个 cap 提前撞顶了（floor 触不到、cap 早就到），而调高 `max_level` 时没回头核对它们 | 每次抬高难度上限都要重新核对所有上下限；文档第 5.9 节记了第一版踩过的具体例子 |
| 玩久了觉得“敌人不长了，我一直在变强” | 难度是时间的函数、玩家强度是等级的函数，两者不同步 | `effective_max_level()` 让难度上限随玩家等级放宽；这是结构性修正，光调数值补不上 |
| 满配玩家几乎不会被敌弹打到 | 拦截弹让自己的密集弹幕变成了一面盾，敌弹在飞行中就被清掉 | 已改为**一发换一发**（见上一条）。注意实测结论：这条改动对“敌弹通过率”几乎没有影响（73.5% → 73.9%），因为玩家每秒 148 发对约 20 发敌弹，弹幕怎么都能扫到；它去掉的是免费的优势，真正决定威胁量的是敌方总输出 |
| 敌人还没露头就被打死了 | 敌机在 y=-48 出生，顶部栏盖住 0~90；子弹却一直有效到 y=-48，于是能在玩家看不见的区域里击杀 | `play_area_top`（默认 90，取顶部栏下沿）作为子弹的有效范围上界，升过它即销毁；断言成对验证“栏下打不到、露头打得死” |
| 玩久了发现“躲着不打”最省事 | 漏敌不付出任何代价，连击也从不累积 | 漏敌会清零连击并永久抬高本局难度压力；再加上连击倍率，让“打得凶”成为一个有回报的选择 |
| 连击倍率让绝对分数断言飘 | 连击跨用例残留，倍率跟着飘 | 夹具测试前显式 `game.combo = 0`；与 `score_multiplier` / `xp_multiplier` 是同一类隔离，已在三个夹具点做过 |
| 瞄准型敌机的弹道方向断言不稳定 | 直接比较浮点方向向量 | 用 `dot(Vector2.DOWN) < 0.99` 判断“不是竖直”，再用归一化后的相等比较确认指向玩家；同时给 `fire_direction()` 提供无玩家时的回落值 |
| 压力基准里实体永远清不完 | 射击击杀累积经验触发了升级，而升级会把整局暂停、实体不再移动 | 基准里把 `xp_multiplier` 设为 0 屏蔽升级——升级与对象周转无关，只需要它不干扰 |
| 定时器一直不刷敌 | 每帧都Timer.start，重置倒计时 | One Shot，只在开始和timeout内start；Autostart关闭 |
| Tween节点不存在 | 套用Godot3的Tween子节点用法 | Godot4用create_tween()，返回Tween对象；kill取消 |
| yield报错 | Godot3写法 | await get_tree().create_timer(seconds).timeout |
| connect参数不对 | 旧connect("signal",self,"method") | timer.timeout.connect(_on_timeout) |
| instance方法不存在 | Godot3 PackedScene.instance | Godot4 PackedScene.instantiate() |
| move_and_slide参数错误 | 混入Godot3语法 | Godot4 CharacterBody2D用velocity属性再move_and_slide()，调用不传velocity |
| Area2D没有velocity或move_and_slide | 根类型不符 | 本例Area2D直接position += direction*speed*delta，不调用角色移动方法 |
| UI挡住点击或空格变按钮激活 | ColorRect捕获鼠标/按钮键盘焦点 | 装饰Mouse Filter=Ignore，按钮Focus=None |
| 初始敌机立刻被Visible通知销毁 | 在屏幕外生成后错误处理可见状态 | 本例用坐标阈值越界，支持从y=-48生成 |
| 窗口缩放后飞机跑偏 | 拿屏幕像素当Viewport逻辑坐标 | get_viewport_rect().size、canvas_items+keep，不使用DisplayServer窗口像素来限位 |
| 子弹高速穿透 | 离散物理步长大于命中盒厚度 | 本版120Hz且速度封顶，典型相对位移远小于碰撞尺寸；更高速度需ShapeCast2D/RayCast2D扫过上一帧到下一帧，不能保证任意速度不穿透 |
| onready拿到null | 节点名/层级错、在入树前访问 | 名称照树；@onready用于入树后；生成敌机先设置普通导出变量再add_child |
| 中文显示方块 | 设备缺系统中文字体 | Theme SystemFont候选；发行版随包提供授权FontFile |
| 新建主题资源加载失败 | .tres缺[resource]、load_steps或外部路径错 | 直接复制完整ui_theme.tres；路径大小写严格一致 |
| 生命上限改了文字不对 | 扩展initial_lives但说明写固定3 | 核心HUD只显示剩余数；如改初始命数，同步修改开始说明文案 |

禁止混用 Godot 3 的 KinematicBody2D、export/onready（无@）、yield、旧版connect、PackedScene.instance、旧Tween节点以及带velocity参数的move_and_slide。不要用Godot3教程里的这些片段替换本项目脚本。

### 10.3 版本依据与官方文档

- Godot 4.7.2 下载归档：https://godotengine.org/download/archive/4.7.2-stable/
- Godot 4.7.2 维护版说明：https://godotengine.org/article/maintenance-release-godot-4-7-2/
- Area2D：https://docs.godotengine.org/en/4.7/classes/class_area2d.html
- Input：https://docs.godotengine.org/en/4.7/classes/class_input.html
- Timer：https://docs.godotengine.org/en/4.7/classes/class_timer.html
- Tween：https://docs.godotengine.org/en/4.7/classes/class_tween.html
- CharacterBody2D：https://docs.godotengine.org/en/4.7/classes/class_characterbody2d.html

### 10.4 实际验证记录

{{TEST_SUMMARY}}

## 11. 最短上手流程

1. 安装并启动 **Godot 4.7.2 Standard**。
2. 解压 **PlaneBattle-Godot-4.7.2.zip**。
3. 项目管理器点 **Import**，选择 **PlaneBattle/project.godot**。
4. 等待导入结束，按 **F5**。
5. 点击 **开始飞行**，**WASD/方向键**移动，**按住空格**射击。
6. 生命用尽后，按 **R** 重新开始。

不需要寻找素材，不需要手连信号，不需要安装插件。想从零复现就按第8.2节复制本文全部文件；想练习节点编辑器就按第8.3节逐节点搭建。
'''
