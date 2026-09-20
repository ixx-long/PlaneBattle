extends Node2D
## 全局规则仅由 Main 持有；其他场景通过信号提出请求。

enum GameState { READY, PLAYING, LEVEL_UP, GAME_OVER }

const ENEMY_SCENE: PackedScene = preload("res://scenes/Enemy.tscn")
const PLAYER_BULLET_SCENE: PackedScene = preload("res://scenes/PlayerBullet.tscn")
const ENEMY_BULLET_SCENE: PackedScene = preload("res://scenes/EnemyBullet.tscn")
const EXPLOSION_SCENE: PackedScene = preload("res://scenes/Explosion.tscn")
const BOSS_SCENE: PackedScene = preload("res://scenes/Boss.tscn")
const BEAM_SCENE: PackedScene = preload("res://scenes/Beam.tscn")
## 追踪导弹的弹体轮廓：带尾翼的弹形（机头 + 弹身 + 左右尾翼）。它只属于游隼型的那一路
## 武器，所以写在这里而不是塞进 SHIPS 表——表里的 bullet_hull 是"主弹幕"的形状，
## 两者混在一起以后会分不清哪一行管哪一路。顺序是绕多边形一圈，不能打乱。
const SEEKER_HULL: Array[Vector2] = [
	Vector2(0, -10), Vector2(3, -4), Vector2(3, 8), Vector2(7, 13), Vector2(3, 11.5),
	Vector2(-3, 11.5), Vector2(-7, 13), Vector2(-3, 8), Vector2(-3, -4),
]
## 波次/难度参数表的脚本。项目约定不写 class_name，所以用 preload 拿脚本再 new()，
## 作为 .tres 漏配时的兜底——tuning 为 null 时整局会直接崩在第一次生成敌机上。
const WAVE_TUNING_SCRIPT: GDScript = preload("res://scripts/WaveTuning.gd")

## 音频素材由 tools/generate_audio.py 用 Python 标准库合成，不含任何第三方文件。
const SFX_SHOOT: AudioStream = preload("res://assets/audio/shoot.wav")
const SFX_EXPLOSION: AudioStream = preload("res://assets/audio/explosion.wav")
const SFX_HURT: AudioStream = preload("res://assets/audio/hurt.wav")
const SFX_UPGRADE: AudioStream = preload("res://assets/audio/upgrade.wav")
const SFX_GAMEOVER: AudioStream = preload("res://assets/audio/gameover.wav")
const SFX_BOSS: AudioStream = preload("res://assets/audio/boss.wav")

## 总线名与 default_bus_layout.tres 里的一致；写错名字 Godot 会静默回落到 Master。
const MUSIC_BUS: String = "Music"
const SFX_BUS: String = "SFX"

## 最高分存档位置。user:// 是各平台约定的可写目录，绝不能写 res://。
const SAVE_PATH: String = "user://save.cfg"
const SAVE_SECTION: String = "records"
const SAVE_KEY: String = "best_score"
## 对局记录：每局结束追加一行 JSON。和最高分存档分成两个文件，因为两者的读写
## 节奏完全不同——最高分是“覆盖一个数”，对局记录是“追加一条并裁掉最旧的”。
## 一行一条 JSON 而不是塞进 ConfigFile：既能直接看懂，也能被外部脚本直接读。
const RUN_LOG_PATH: String = "user://runs.jsonl"
## 只保留最近多少局。记录是给调参用的，无限增长没有意义，还会让每次结算的
## 读写量越滚越大。
const RUN_LOG_LIMIT: int = 50
## 玩家设置与最高分放在同一个存档文件里，但用独立的节。
## `_save_best_score()` 是“先读取再回写”，所以两边不会互相覆盖；
## 反过来 `_save_settings()` 也一样——这正是当初把存档写成读-改-写的原因。
const SETTINGS_SECTION: String = "settings"
const SETTINGS_SHAKE: String = "screen_shake"
const SETTINGS_MUSIC: String = "music_percent"
const SETTINGS_SFX: String = "sfx_percent"
const SETTINGS_SHIP: String = "ship"
## 光束战机的持续音效间隔。射击键每秒触发 6 次以上，照搬会把背景音乐盖掉。
const BEAM_HUM_INTERVAL: float = 0.45

## 升级时的基础选项数；“幸运补给”每层再多给 1 个。
const BASE_OFFERS: int = 4

## 生命补给的基准上限；“机体强化”每层把它再 +1。
const BASE_MAX_LIVES: int = 6

## 能力池。max 为可叠加层数；达到上限（或对当前局面无意义）的能力不再出现在选项里，
## 避免出现“选了也没效果”的死选项。每项的实际效果写在 _apply_upgrade()，与文案一一对应。
## 按用途分组只是为了便于阅读，抽取选项时并不区分组别。
const UPGRADES: Array[Dictionary] = [
	# 射击
	{"id": "rapid_fire", "name": "射速强化", "detail": "射击冷却 -12%", "max": 6},
	{"id": "multishot", "name": "火力增援", "detail": "每次多射 1 发", "max": 4},
	{"id": "wing_shot", "name": "侧翼炮", "detail": "左右各追加 1 条平行弹道", "max": 3},
	{"id": "velocity", "name": "弹速强化", "detail": "子弹速度 +90", "max": 5},
	{"id": "pierce", "name": "穿透弹", "detail": "子弹可多穿 1 个敌机", "max": 3},
	{"id": "interceptor", "name": "拦截弹", "detail": "子弹可击落敌弹（一发换一发）", "max": 1},
	{"id": "caliber", "name": "弹体增幅", "detail": "子弹体积 +15%，更好命中", "max": 3},
	# 生存
	{"id": "shield", "name": "护盾延时", "detail": "受伤无敌 +0.25 秒", "max": 4},
	{"id": "repair", "name": "应急补给", "detail": "生命 +1", "max": 3},
	{"id": "vitality", "name": "机体强化", "detail": "生命上限 +1 并回复 1", "max": 3},
	{"id": "purge", "name": "紧急清屏", "detail": "立刻清除全部敌弹", "max": 1},
	# 机动与成长
	{"id": "thruster", "name": "引擎强化", "detail": "移动速度 +28", "max": 6},
	{"id": "insight", "name": "战术洞察", "detail": "经验获取 +25%", "max": 4},
	{"id": "bounty", "name": "战果结算", "detail": "得分 +20%", "max": 4},
	{"id": "steady", "name": "战术从容", "detail": "难度上升间隔 +3 秒", "max": 3},
	{"id": "fortune", "name": "幸运补给", "detail": "升级多 1 个选项", "max": 1},
]

## 可选战机。开局由玩家选定，形态因此**不进抽卡池**——不会稀释 16 项能力的抽取，
## 也不会出现"什么都拿一点"导致覆盖形状与输出同时膨胀。
##
## 第一版刻意只改**武器行为与外形**，不碰移速/生命/冷却：三台战机各自换一套武器，
## 需要验证的组合已经翻了三倍，再叠加数值取舍，出问题时就分不清是形态还是数值造成的。
## 数值取舍留到形态稳定之后当调味。
##
## 每台战机的"代价"都必须是真实存在的，否则形态就只是纯增强：
## 追踪弹弹道弯曲 ⇒ 形不成弹幕墙 ⇒ 拦截弹几乎失效（这条是自然涌现的，不需要额外写规则）。
const SHIPS: Array[Dictionary] = [
	{
		"id": "parallel",
		"name": "标准型",
		"detail": "平行弹幕 · 每级一条竖直车道，弹幕墙能靠拦截弹清掉敌弹",
		"seeker_interval": 0.0,
		"seeker_speed_scale": 1.0,
		"seeker_turn_rate": 0.0,
		"seeker_lock_range": 0.0,
		"beam": false,
		"beam_width": 0.0,
		"beam_range": 0.0,
		"beam_tick_interval": 0.0,
		# **每台战机只用自己的那一套弹体**：形状、弹体色、亮芯色都在这里，
		# 生成子弹时由 _spawn_player_bullet() 一次性写进去。判定盒不跟着变——
		# 视觉可以有个性，命中盒不能有个性（那会让"看得见"和"打得中"变成两件事）。
		"bullet_hull": [Vector2(0, -12), Vector2(4, -6), Vector2(4, 10), Vector2(-4, 10), Vector2(-4, -6)],
		"bullet_color": Color(0.02, 0.55, 0.67, 1),
		"bullet_core_color": Color(0.68, 0.96, 1, 1),
		"hull": [Vector2(0, -32), Vector2(10, -7), Vector2(27, 13), Vector2(27, 21), Vector2(8, 15),
			Vector2(7, 28), Vector2(-7, 28), Vector2(-8, 15), Vector2(-27, 21), Vector2(-27, 13), Vector2(-10, -7)],
		"hull_color": Color(0.04, 0.42, 0.55, 1),
		"cockpit_color": Color(0.64, 0.95, 0.99, 1),
		"engine_color": Color(1, 0.65, 0.23, 1),
	},
	{
		"id": "homing",
		"name": "游隼型",
		"detail": "追踪导弹 · 主弹幕照直飞，另按节奏射出全屏追踪弹",
		# **seeker_interval 是这台战机的平衡支点，不是手感参数**，改它必须重跑威胁基准。
		#
		# 走过的弯路值得完整记下来，因为它推翻了两版设计：
		#   版一"每发子弹都追踪"：基准实测击毁率 96%、每架开火 0.00、到达/秒 0。
		#   原因是结构性的——敌机朝玩家下来，只要射程不受限，追踪一定撞得上；而满配
		#   每秒 148 发、在飞约 170 发，上半屏会被整个清空。
		#   版二"只在 110 像素内锁定"：威胁回来了（15.33 达标），但 110 像素几乎贴着玩家，
		#   **玩家根本看不见追踪**——真人试玩直接反馈"没有追踪效果"，等于功能没做出来。
		#   量清边界后确认：射程 110 → 15.33 达标、150 → 11.67 掉线，**可见与有威胁直接冲突，
		#   调参救不了**。
		# 所以改成现在这样：**主弹幕照直（弹幕墙与拦截弹不受影响），追踪由少量、全屏锁定、
		# 明显可辨的导弹提供**，用发射节奏控制总输出。可见性来自"导弹本身显眼"，而不是
		# 来自放宽锁定范围。
		"seeker_interval": 1.4,
		"seeker_speed_scale": 0.7,
		"seeker_turn_rate": 6.0,
		"seeker_lock_range": 900.0,
		"beam": false,
		"beam_width": 0.0,
		"beam_range": 0.0,
		"beam_tick_interval": 0.0,
		# 游隼型的弹体是**细长镖形 + 它自己的青绿配色**（与机身、座舱同一族颜色）：
		# 换战机时弹道一眼能看出换了人，而不是只有技能描述里写着不一样。
		"bullet_hull": [Vector2(0, -15), Vector2(3, -5), Vector2(3, 9), Vector2(-3, 9), Vector2(-3, -5)],
		"bullet_color": Color(0.05, 0.42, 0.36, 1),
		"bullet_core_color": Color(0.72, 0.98, 0.88, 1),
		"hull": [Vector2(0, -36), Vector2(7, -8), Vector2(20, 2), Vector2(31, 22), Vector2(12, 13),
			Vector2(6, 28), Vector2(-6, 28), Vector2(-12, 13), Vector2(-31, 22), Vector2(-20, 2), Vector2(-7, -8)],
		"hull_color": Color(0.06, 0.44, 0.38, 1),
		"cockpit_color": Color(0.72, 0.98, 0.88, 1),
		"engine_color": Color(1, 0.78, 0.32, 1),
	},
	{
		"id": "focus",
		"name": "聚焦型",
		"detail": "贯穿光束 · 出膛即中，射程内的敌机进柱即毁；代价是覆盖窄、够不着远处",
		# 光束**不是子弹**：没有飞行时间，敌机一进入这条竖线就在下一次结算时被击毁。
		# 两项代价缺一不可：
		#   ① 覆盖窄——每条光柱只有 beam_width 像素宽；
		#   ② **射程短**——光柱只延伸到玩家上方 beam_range 像素处，不再直达战斗区顶边。
		# 第②条是真人试玩反馈"太赖皮"之后加的，理由记在这里，免得以后有人当成多余的限制作删：
		# 出膛即中意味着**不需要预判**（子弹必须提前约 0.5 秒打在那个位置，光柱是"指到谁谁就没"），
		# 而全屏射程意味着玩家可以永远待在屏幕底部把上半屏扫干净、也能站在安全距离把 Boss 融化。
		# 量出来的证据：满配下光柱对 Boss 的真实输出 275/秒，是标准型（110/秒）的 2.5 倍，
		# 而且**站在屏幕底部不动**就有 141.8/秒（子弹系在同一个位置只有约 72/秒）——
		# Boss 5.1 秒被打空、还不用冒任何风险，这就是"赖皮"的量化定义。
		# 加上射程上限之后，"哪里能打"重新变成一个要主动上前做的选择。
		# **beam_range 与 beam_width 一样是平衡支点**，改它必须重跑 PursuitTest。
		"beam": true,
		# **beam_width / beam_range 是这台战机的平衡支点**，改它们必须重跑威胁基准：
		# 光柱越宽、越远，被瞬间清掉的敌机越多，敌方弹幕就越少。
		"beam_width": 10.0,
		# **340 是量出来的**，不是随手取的整数：玩家停在屏幕下方时，光柱上端离 Boss 下沿
		# 还有约 47 像素，"站着不动就能融化 Boss"因此被真正切断——追击基准实测站桩输出
		# 从 **141.8/秒变成 0**；而主动上前照样打得到（8.5 秒击破，与另外两台的 8.0 秒同级）。
		# 射程放宽到 380 时，往上挪十来个像素就能碰到 Boss，那条限制就退化成装饰了。
		# 前场代价实测很小（10 秒窗口下三台击毁率 80% / 87% / 84%，这台居中），
		# 但**短窗口会把它量得偏低**：敌人得先飞进射程，6 秒窗口里它只有 62%。
		"beam_range": 340.0,
		# 这台战机**不出子弹**（输出由光柱承担），所以它没有 bullet_hull / bullet_color——
		# 这是有意的而不是漏了：给它编一套永远用不上的弹体才是真的误导。
		# _spawn_player_bullet() 里的默认值负责兜底（万一以后改成"光柱 + 子弹"）。
		"beam_tick_interval": 0.08,
		"seeker_interval": 0.0,
		"seeker_speed_scale": 1.0,
		"seeker_turn_rate": 0.0,
		"seeker_lock_range": 0.0,
		"hull": [Vector2(0, -30), Vector2(14, -10), Vector2(18, 8), Vector2(30, 18), Vector2(10, 14),
			Vector2(8, 30), Vector2(-8, 30), Vector2(-10, 14), Vector2(-30, 18), Vector2(-18, 8), Vector2(-14, -10)],
		"hull_color": Color(0.33, 0.19, 0.55, 1),
		"cockpit_color": Color(0.85, 0.82, 1, 1),
		"engine_color": Color(0.55, 0.85, 1, 1),
	},
]

@export var initial_lives: int = 3
## 难度曲线与波次表。数值全部在 assets/wave_tuning.tres 里，Main 只读不写。
@export var tuning: Resource
## 升级所需经验的基数与每级增量：满足 xp_base + xp_growth * (等级 - 1)。
## 这两个数是玩家强度的“油门”：调小会让玩家在难度跟不上之前就把输出核心堆满。
@export var xp_base: int = 80
@export var xp_growth: int = 45
## 连击阶梯：连续击毁多少架升一档得分倍率，以及倍率上限。
## 连击会被“受伤”或“漏敌”打断，所以它同时奖励打得准与不让敌人溜走——
## 这正是给“苟着不打”这种玩法准备的解药：不打就没有倍率，漏了还要清零。
@export var combo_step: int = 5
@export var combo_max_multiplier: int = 5
## 玩家子弹的基础速度。
@export var player_bullet_speed: float = 640.0
## 所有子弹一律竖直向上，只靠水平偏移排成平行弹道，因此调的是像素间距而不是角度：
## bullet_spacing 是主弹幕内部相邻弹道的间距，wing_spacing 是侧翼炮从主弹幕外侧继续向外排开的间距。
@export var bullet_spacing: float = 14.0
@export var wing_spacing: float = 18.0
## 可视战斗区域的顶边，也是玩家子弹的有效范围上界：子弹升过这条线就销毁，
## 因此打不到还没露头的敌机。取顶部 HUD 色块的下沿（见 scenes/HUD.tscn 的 TopBar，
## 高 90），因为那一段被色块盖住、玩家看不见——敌机又是在 y=-48 出生的，
## 若子弹一直有效到屏幕外，玩家会看到“敌人刚露头就没了”。
@export var play_area_top: float = 90.0
## 受伤时的屏幕震动。可在导出参数里直接关闭（文档第 9 节要求的“支持关闭震动选项”）。
@export var screen_shake_enabled: bool = true
@export var screen_shake_strength: float = 9.0
@export var screen_shake_duration: float = 0.28
## 同时可叠加的音效路数。射速叠满后每秒会打出十几发，路数太少会互相打断。
@export var sfx_voices: int = 6

@onready var player = $Player
@onready var actors: Node2D = $Actors
@onready var enemy_timer: Timer = $EnemyTimer
@onready var hud = $CanvasLayer/HUD
@onready var music: AudioStreamPlayer = $Music
@onready var sfx_root: Node = $Sfx
## 震动只改 Camera2D 的 offset。它在 (240,400) 即画布中心，默认视图与“没有摄像机”完全一致；
## HUD 挂在 CanvasLayer 上、默认不跟随视口，所以震动时 UI 保持稳定。
@onready var camera: Camera2D = $Camera2D

var state: GameState = GameState.READY
var score: int = 0
var best_score: int = 0
var lives: int = 3
var survival_time: float = 0.0
var difficulty_level: int = 1
var run_id: int = 0
var rng := RandomNumberGenerator.new()

## 波次状态。wave_index 一直递增（取模决定用哪套编队），wave_cycle 记录走完几轮，
## spawned_in_wave 是本波已经放出去几架。
var wave_index: int = 0
var wave_cycle: int = 0
var spawned_in_wave: int = 0
## 当前在场的 Boss（没有则为 null），以及“下一拍该放 Boss 了”的待办标记。
## 走完一整轮波次后置位，等波间停顿结束再真正登场，中间那段空档就是预警时间。
var boss = null
var boss_pending: bool = false
## level_step_seconds 是 tuning.level_step_seconds 的运行时副本：
## “战术从容”会拉长它，直接改资源会把全局参数改脏，重开也没法还原。
var level_step_seconds: float = 15.0
## 连击、逃敌计数与逃敌累积的难度压力。三者互相牵制：
## 打得凶才涨倍率，漏一架就清零，而漏掉的敌机会永久抬高本局的难度。
var combo: int = 0
var escaped_count: int = 0
var escape_pressure: float = 0.0

## 本局战报。score/lives/survival_time/escaped_count 已经能推出的事不重复记，
## 这里只补三件现有字段推不出来的：击毁总数、受伤次数、连击达到过的最高倍率。
## 峰值倍率必须单独记：受伤会把 combo 清零，光看结算时的 combo 永远是 0。
var kills: int = 0
## 其中属于 Boss 的次数。kills 是总数（含 Boss），这一项让“一架普通敌机”与
## “一个多血 Boss”在事后分析里能分开。
var boss_kills: int = 0
var hits_taken: int = 0
var peak_combo_multiplier: int = 1
## 每次受伤时的生存时间点。这不是玩法数据，而是给“这一局是被打死的、还是被主动结束的”
## 提供判据：真被逼死时几次受伤会间隔几十秒；主动送死会在最后几秒里连掉几条命。
## 缺了它，记录里只剩“存活 253 秒、受伤 5 次”，两种情况长得一模一样——
## 真人前两局恰好都是主动结束，而当时我正是照着这种记录得出了“难度不够”的结论。
var hit_times: Array[float] = []

## 玩家等级与经验；与随时长上升的 difficulty_level（难度）是两件事，互不影响。
var level: int = 1
var xp: int = 0
var xp_multiplier: float = 1.0
var score_multiplier: float = 1.0
## 本条命局的生命上限与升级选项数；都会被能力抬高，重开时复位。
var max_lives: int = BASE_MAX_LIVES
var max_offers: int = BASE_OFFERS
## id -> 已叠加层数。
var upgrade_stacks: Dictionary = {}
## 当前待选的升级项；为空表示不在抉择状态。
var offers: Array[Dictionary] = []

var _bullet_speed: float = 640.0
var _bullet_count: int = 1
var _bullet_pierce: int = 0
var _wing_pairs: int = 0
var _bullet_scale: float = 1.0
var _bullet_intercepts: bool = false
## Player 的导出初值。能力会直接改这些属性，重开时据此还原。
var _base_shoot_cooldown: float = 0.0
var _base_speed: float = 0.0
var _base_invulnerability: float = 0.0
var _shake_tween: Tween
var _sfx_players: Array[AudioStreamPlayer] = []
var _sfx_cursor: int = 0
## 玩家音量设置（0~100）。初始值从音频总线的实际音量反推，所以面板一打开
## 显示的就是真实状态，而不是一个写死的 100%。
var music_percent: int = 100
var sfx_percent: int = 100
## 当前战机（SHIPS 里的 id）。开局选定并记住，形态因此不进抽卡池。
var ship_id: String = "parallel"
## 追踪弹的目标指示器。做成一个不可见的 Marker2D：Main 每帧只算一次"最近的敌机"，
## 子弹做一次 O(1) 的组查询去读它。
## **不能**让每颗子弹各自遍历敌机——满配每秒 148 发，那会变成每秒几千次全表搜索。
## 这个写法与 Enemy 瞄准玩家时用 `get_first_node_in_group("player")` 是同一个套路。
var _target_marker: Marker2D
## 追踪导弹的发射冷却。用累加器而不是 Timer：它的周期完全由当前战机的数据决定，
## 换战机时不必去 reschedule 一个节点，也不会在换局时留下未触发的回调。
var _seeker_cooldown: float = 0.0
## 光束战机的持续音效节奏计数（见 BEAM_HUM_INTERVAL）。
var _beam_hum_left: float = 0.0
## 当前战机在场上的光束。与 bullets 不同，光束是**常驻节点**而不是每次射击生成，
## 所以 Main 持有一个数组、按车道数增减（见 _sync_beams）。
var beams: Array[Area2D] = []

func _ready() -> void:
	# tuning 是 Resource 类型（项目约定不写 class_name，没法标成具体类型），所以
	# 检查器里理论上能挂任意资源。这里不止判空，还确认它确实带 waves 字段：
	# 缺了就换一份默认值，否则会在第一次生成敌机时炸在 tuning.waves 上。
	if tuning == null or tuning.get("waves") == null:
		push_warning("波次参数资源缺失或类型不对，改用默认值：%s" % name)
		tuning = WAVE_TUNING_SCRIPT.new()
	rng.randomize()
	enemy_timer.timeout.connect(_on_enemy_timer_timeout)
	hud.start_game.connect(start_game)
	hud.restart_game.connect(restart_game)
	hud.upgrade_chosen.connect(choose_upgrade)
	hud.pause_toggle_requested.connect(toggle_pause)
	hud.pause_restarted.connect(_on_pause_restarted)
	hud.shake_toggled.connect(_on_shake_toggled)
	hud.volume_changed.connect(_on_volume_changed)
	hud.ship_selected.connect(select_ship)
	hud.change_ship_requested.connect(return_to_hangar)
	player.player_hit.connect(_on_player_hit)
	player.shoot_requested.connect(_on_player_shoot_requested)
	# 在能力改动之前记录 Player 的导出初值，供每次重开还原。
	_base_shoot_cooldown = player.shoot_cooldown
	_base_speed = player.speed
	_base_invulnerability = player.invulnerability_duration
	_build_audio()
	_reset_upgrades()
	lives = initial_lives
	_load_best_score()
	_load_settings()
	_build_target_marker()
	_apply_ship()
	player.deactivate()
	_refresh_hud()
	hud.show_start(SHIPS, selected_ship_index())

func _process(delta: float) -> void:
	if state != GameState.PLAYING:
		return
	survival_time += delta
	# 逃敌压力**累加到时间轴上再取整**，而不是各自 int() 之后相加。
	# 旧写法有两个台阶：int(escape_pressure) 每跨过 1.0，难度就在那一瞬间凭空多跳一级
	# （漏 3 架 = 1.02，正好跨过），玩家会觉得“怎么突然变难”，而且那一下与时间进度无关。
	# 累加进时间轴之后，漏敌只是把下一次升级**提前**，升级本身仍然是那条平滑的时间曲线；
	# 压力本身没有变小——漏得越多，难度来得越早，这一条没变。
	difficulty_level = clampi(
		1 + int(survival_time / maxf(level_step_seconds, 1.0) + escape_pressure),
		1,
		effective_max_level()
	)
	_refresh_hud()

func combo_multiplier() -> int:
	# 0~4 连击 ×1，5~9 ×2……到 combo_max_multiplier 封顶。
	# 单独抽成函数，一是让倍率可以被直接断言，二是让 add_score 只关心“乘多少”。
	return mini(1 + combo / maxi(combo_step, 1), maxi(combo_max_multiplier, 1))

func _on_enemy_escaped() -> void:
	if state != GameState.PLAYING:
		return
	# 漏敌的两重代价：连击归零（丢掉已经攒起来的得分倍率），
	# 并把本局难度永久抬高一点。没有这两条时，“躲着不打”是严格最优解。
	combo = 0
	escaped_count += 1
	escape_pressure = minf(
		tuning.escape_pressure_cap,
		escape_pressure + tuning.escape_pressure_per_enemy
	)
	_refresh_hud()

func effective_max_level() -> int:
	# 难度上限 = 基准上限 + 玩家等级增量。
	# 难度只随时间增长、玩家强度只随等级增长，两者不同步就一定会失衡：
	# 中后期会出现“玩家一直在变强、敌人早就封顶”。让上限跟着玩家等级抬，
	# 是唯一不依赖反复手调数值的根治办法。
	return int(tuning.max_level) + maxi(level - 1, 0) * int(tuning.max_level_per_player_level)

func player_dps_proxy() -> float:
	# “每秒能打出多少发”就是玩家当前的输出强度：本作所有敌机都是一发击毁，
	# 所以伤害与弹幕密度完全等价，不需要另算伤害公式。
	#
	# 追踪导弹**不需要额外折算**：它仍然是"每发子弹 × 每秒发数"，只是弹道会拐弯，
	# 因此 Boss 血量自动就是对的。
	#
	# 光束**必须**在这里折算，否则 Boss 会按一个偏低的输出算血量、死得比
	# boss_target_seconds 快得多：它没有子弹，输出 = 光柱条数 × 每秒结算次数。
	if ship_uses_beam():
		return float(lane_count()) / maxf(beam_tick_interval(), 0.01)
	var per_shot: float = float(lane_count())
	return per_shot / maxf(player.shoot_cooldown, 0.01)

func current_ship() -> Dictionary:
	for entry in SHIPS:
		if entry["id"] == ship_id:
			return entry
	# 存档里可能留着一个已经不存在的战机 id（改版后）。退回第一台并出声，
	# 而不是让 current_ship() 返回空字典、然后在别处崩在缺字段上。
	push_warning("未知的战机 id，改用默认战机：%s" % ship_id)
	return SHIPS[0]

func selected_ship_index() -> int:
	for index in range(SHIPS.size()):
		if SHIPS[index]["id"] == ship_id:
			return index
	return 0

func ship_has_seekers() -> bool:
	return float(current_ship().get("seeker_interval", 0.0)) > 0.0

func ship_uses_beam() -> bool:
	return bool(current_ship().get("beam", false))

func beam_tick_interval() -> float:
	# “弹速强化”在光束战机上映射为**充能更快**：缩短结算间隔 = 提高每秒伤害
	# （普通敌机一次结算即毁，所以只有对 Boss 才有意义）。这样它在这台战机上仍是
	# 一个有效选项，而不是一个选了没变化的死选项。
	return maxf(
		0.03,
		float(current_ship().get("beam_tick_interval", 0.08)) - 0.008 * float(_stacks_of("velocity"))
	)

func beam_length(muzzle_y: float) -> float:
	# 光柱长度 = min(射程, 到战斗区顶边的距离)。两个限制各管一件事：
	#   · 射程（beam_range）：这台战机必须在**近处**才烧得到敌人，于是“隔着半屏清场”、
	#     “待在屏幕底部融化 Boss”这两件最赖皮的事都做不成了；
	#   · 战斗区顶边（play_area_top）：光柱不会伸到顶部信息栏后面去杀还没露头的敌机
	#     （与玩家子弹同样的边界，理由见 play_area_top 的注释）。
	# 写成函数是为了让两条边界都能被直接断言，而不是埋在几何重建里靠眼睛看。
	var reach: float = maxf(muzzle_y - play_area_top, 1.0)
	var beam_range: float = float(current_ship().get("beam_range", 0.0))
	if beam_range <= 0.0:
		return reach
	return clampf(beam_range, 1.0, reach)

func lane_count() -> int:
	# 车道数：子弹与光束共用同一个口径，所以两台战机的“多发/侧翼炮”含义完全一致。
	return _bullet_count + _wing_pairs * 2

func _lane_offsets() -> Array[float]:
	# 车道水平偏移的**唯一来源**：子弹与光束都从这里取，避免两处各写一份然后悄悄分叉。
	# _bullet_count 为 1 且没有侧翼炮时偏移为 0，与最早的单发行为完全一致。
	var offsets: Array[float] = []
	var center: float = float(_bullet_count - 1) * 0.5
	for index in range(_bullet_count):
		offsets.append((float(index) - center) * bullet_spacing)
	var outermost: float = center * bullet_spacing
	for pair in range(_wing_pairs):
		var gap: float = outermost + wing_spacing * float(pair + 1)
		offsets.append(-gap)
		offsets.append(gap)
	offsets.sort()
	return offsets

func _sync_beams() -> void:
	# 光束的条数与水平位置**照抄子弹车道的算法**，这样两台战机的升级含义一致，
	# 平衡对比也干净：差别只在“瞬间命中”与“覆盖宽窄”，而不在车道布局。
	var wanted: int = lane_count() if (ship_uses_beam() and state == GameState.PLAYING) else 0
	while beams.size() > wanted:
		var extra = beams.pop_back()
		if is_instance_valid(extra):
			extra.queue_free()
	var width_now: float = float(current_ship().get("beam_width", 10.0))
	while beams.size() < wanted:
		var beam = BEAM_SCENE.instantiate()
		# 只预置宽度：_ready() 会立刻用它建出多边形与碰撞形状，预置晚了第一帧形状就是错的。
		# 结算间隔与拦截标志不在这里写，交给下面统一的 refresh——同一个参数两处各写一份
		# 正是“只对新光柱生效”那类 bug 的温床。
		beam.beam_width = width_now
		actors.add_child(beam)
		beams.append(beam)
	if beams.is_empty():
		return
	var offsets_now: Array[float] = _lane_offsets()
	var muzzle_y: float = player.global_position.y - 34.0
	var length_now: float = beam_length(muzzle_y)
	var interval_now: float = beam_tick_interval()
	for index in range(beams.size()):
		var beam = beams[index]
		if not is_instance_valid(beam):
			continue
		beam.global_position = Vector2(player.global_position.x + offsets_now[index], muzzle_y)
		# 尺寸、结算间隔、拦截标志都在这里同步：玩家是在**局中**拿到“弹速强化 / 拦截弹”的，
		# 屏幕上的光柱必须立刻换节奏、立刻开始拦敌弹，否则升级看起来没生效。
		beam.refresh(width_now, length_now, interval_now, _bullet_intercepts)

func set_ship(id: String) -> bool:
	# 返回是否真的换成了：存档与测试都需要知道"这个 id 认不认"。
	for entry in SHIPS:
		if entry["id"] == id:
			ship_id = id
			_apply_ship()
			_save_settings()
			# 让开始界面同步：**按钮选中态与下面的说明文字都要跟着变**。
			# 少了这一句，点击按钮只会改状态、界面纹丝不动——玩家会以为没点到。
			hud.refresh_ship_choice(SHIPS, selected_ship_index())
			return true
	push_warning("忽略未知的战机 id：%s" % id)
	return false

func select_ship(index: int) -> void:
	# 来自开始界面的按钮。越界直接忽略，不让 UI 的一个坏下标改掉游戏状态。
	if index < 0 or index >= SHIPS.size():
		return
	set_ship(SHIPS[index]["id"])

func _apply_ship() -> void:
	# 规则归 Main、显示归 Player：这里把选中的战机数据交给 Player，由它换外形与配色。
	player.apply_ship(current_ship())

func return_to_hangar() -> void:
	# 结算后回到开始界面，否则玩家打完一局就再也见不到战机选择——
	# READY 只在启动时出现一次，没有这条回路就等于"战机只能选一次、永远不能改"。
	if state == GameState.PLAYING:
		_set_paused(false)
		player.deactivate()
		_clear_entities()
		enemy_timer.stop()
	state = GameState.READY
	_stop_screen_shake()
	hud.hide_level_up()
	hud.hide_pause()
	hud.hide_boss()
	offers = []
	_refresh_hud()
	hud.show_start(SHIPS, selected_ship_index())

func _build_target_marker() -> void:
	# 纯运行时的管道节点，所以用代码建而不是摆进场景（与 Sfx 音效池同样的理由）。
	_target_marker = Marker2D.new()
	_target_marker.name = "TargetMarker"
	_target_marker.add_to_group("player_target")
	add_child(_target_marker)

func _update_target_marker() -> void:
	# 每帧只做一次全表扫描，而不是让每颗追踪弹各自扫一遍。
	# 只有带追踪导弹的战机才需要——平行弹幕的子弹不看这个指示器。
	if not ship_has_seekers():
		_release_target()
		return
	# 追踪导弹是**全屏锁定**的：可见性由导弹本身显眼提供，而不是靠把锁定范围放宽
	# （那条路已经证明走不通，见 SHIPS 里 seeker_interval 的说明）。
	var lock_range: float = float(current_ship().get("seeker_lock_range", 0.0))
	var nearest: Node2D = null
	var best_distance: float = lock_range * lock_range
	for enemy in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(enemy) or enemy.is_queued_for_deletion():
			continue
		var distance: float = enemy.global_position.distance_squared_to(player.global_position)
		if distance < best_distance:
			best_distance = distance
			nearest = enemy
	if nearest != null:
		_target_marker.global_position = nearest.global_position
		if not _target_marker.is_in_group("player_target"):
			_target_marker.add_to_group("player_target")
	else:
		# 没有目标时**必须把指示器摘出组**，让在飞的导弹不再拐向一个不存在的坐标。
		# 第一版是把它摆到玩家正上方当替身，结果两侧车道的子弹全都朝中间拐、
		# 弹幕从"一排平行车道"变成"一束"——症状是参数怎么改都量出逐位相同的结果。
		_release_target()

func _update_seeker_launcher(delta: float) -> void:
	# 追踪导弹按固定节奏发射，**不是每发子弹都追踪**：满配每秒 13.5 次射击，若每发都
	# 追踪，敌方弹幕会被打到 0（实测击毁率 96%、到达每秒 0）。节奏是这台战机的平衡支点。
	var interval: float = float(current_ship().get("seeker_interval", 0.0))
	if interval <= 0.0:
		return
	_seeker_cooldown -= delta
	if _seeker_cooldown > 0.0:
		return
	# 没有目标就不发射：打空气既没有意义，也会让"射程/节奏"的实测变得不可解释。
	if get_tree().get_first_node_in_group("player_target") == null:
		return
	_seeker_cooldown = interval
	_spawn_seeker()

func _spawn_seeker() -> void:
	var bullet = PLAYER_BULLET_SCENE.instantiate()
	bullet.speed = _bullet_speed * float(current_ship().get("seeker_speed_scale", 1.0))
	bullet.homing = true
	bullet.homing_turn_rate = float(current_ship().get("seeker_turn_rate", 6.0))
	bullet.play_area_top = play_area_top
	# 导弹是**单发目标**，刻意不继承穿透：继承之后一发能连杀 4 架（穿透×3 时），
	# 实测把击毁率从 56% 推到 80%、威胁掉到 9.17。单发目标同时让"发射节奏 → 击杀数"
	# 变成一比一，平衡才好预测。
	bullet.pierce_left = 0
	bullet.intercepts = _bullet_intercepts
	# 让导弹一眼可辨：比主弹幕更大，**换成带尾翼的弹体**，并且**真的换掉弹体颜色**
	# （不是用 modulate 乘法调色）。可见性就是这么来的——不靠放宽锁定范围
	# （那条路会让威胁归零）。
	bullet.scale = Vector2.ONE * _bullet_scale * 1.6
	bullet.body_polygon = PackedVector2Array(SEEKER_HULL)
	bullet.body_color = Color(1.0, 0.62, 0.18, 1.0)
	bullet.core_color = Color(1.0, 0.93, 0.72, 1.0)
	actors.add_child(bullet)
	bullet.global_position = player.global_position + Vector2.UP * 34.0

func _release_target() -> void:
	if _target_marker != null and _target_marker.is_in_group("player_target"):
		_target_marker.remove_from_group("player_target")

func _physics_process(delta: float) -> void:
	if state != GameState.PLAYING:
		return
	_update_target_marker()
	_update_seeker_launcher(delta)
	_sync_beams()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("restart") and not event.is_echo():
		if state == GameState.GAME_OVER:
			restart_game()
		elif state == GameState.READY:
			start_game()

func start_game(force: bool = false) -> void:
	# force 供暂停面板的“重新开始”使用：那时 state 仍是 PLAYING，
	# 而普通情况下 PLAYING 期间重开是要被挡掉的（避免误触 R）。
	if state == GameState.PLAYING and not force:
		return
	# 先使上一局的延迟生成请求失效，再复位场景。
	run_id += 1
	enemy_timer.stop()
	_clear_entities()
	# 抉择界面可能还开着（例如外部直接重开），必须收起并解除暂停，否则游戏会卡死。
	_set_paused(false)
	_stop_screen_shake()
	hud.hide_level_up()
	# 从暂停面板重开时面板也开着，一并收起（它自己不会因为 _set_paused 而消失）。
	hud.hide_pause()
	offers = []
	_reset_upgrades()
	score = 0
	lives = initial_lives
	survival_time = 0.0
	difficulty_level = 1
	# 波次回到第一波、清掉轮次计数：重开一定从同一套编排开始，不能接着上一轮的进度。
	wave_index = 0
	wave_cycle = 0
	spawned_in_wave = 0
	combo = 0
	escaped_count = 0
	escape_pressure = 0.0
	kills = 0
	boss_kills = 0
	hits_taken = 0
	peak_combo_multiplier = 1
	hit_times.clear()
	boss = null
	boss_pending = false
	hud.hide_boss()
	state = GameState.PLAYING
	var bounds: Rect2 = get_viewport_rect()
	player.reset_for_game(Vector2(bounds.size.x * 0.5, bounds.size.y - 105.0))
	_refresh_hud()
	hud.show_playing()
	_play_music()
	enemy_timer.start(tuning.first_wave_delay)

func restart_game() -> void:
	if state != GameState.PLAYING:
		start_game()

func add_score(points: int) -> void:
	if state != GameState.PLAYING or points <= 0:
		return
	combo += 1
	# 击毁数就在这里累加：生产路径上 add_score 只在击毁时被调用（敌机与 Boss 各一处），
	# 比在两个信号处理函数里分别记一次更难漏。测试里直接调 add_score 也会计入，
	# 这是有意保持的一致性——否则“得分的击毁”和“计入的击毁”会出现两套口径。
	kills += 1
	peak_combo_multiplier = maxi(peak_combo_multiplier, combo_multiplier())
	score += int(round(float(points) * score_multiplier * float(combo_multiplier())))
	# 击毁奖励同时是唯一经验来源：撞毁与漏过的敌机不发 destroyed，因此不给经验。
	# 得分与经验各乘各的倍率：连击与“战果结算”都只影响分数，不会顺带加快升级。
	xp += int(round(float(points) * xp_multiplier))
	_refresh_hud()
	hud.pulse_score()
	_check_level_up()

func _on_player_hit() -> void:
	if state != GameState.PLAYING:
		return
	lives = maxi(lives - 1, 0)
	# 受伤打断连击：这是“打得凶”必须承担的风险。
	combo = 0
	hits_taken += 1
	hit_times.append(snappedf(survival_time, 0.1))
	_refresh_hud()
	# 受伤反馈：立刻震一下屏幕并让画面闪一下红，扣命这件事必须被看见。
	_start_screen_shake()
	hud.flash_damage()
	_play_sfx(SFX_HURT)
	if lives == 0:
		game_over()

func game_over() -> void:
	if state != GameState.PLAYING:
		return
	state = GameState.GAME_OVER
	run_id += 1
	enemy_timer.stop()
	player.deactivate()
	_clear_entities()
	# 结算必须解除暂停，否则重开后整个世界都不再前进。
	_set_paused(false)
	hud.hide_pause()
	# 震动也要停掉并归零，否则结算画面会一直歪着。
	_stop_screen_shake()
	hud.hide_level_up()
	hud.hide_boss()
	boss = null
	boss_pending = false
	offers = []
	# 这一局已经结束，连击也就没有意义了：不清掉的话顶栏会一直挂着一个看起来仍在
	# 生效的倍率标签。本局达到过的最高倍率另有 peak_combo_multiplier 记着，不会丢。
	combo = 0
	# 纪录只在结算时判定，避免局中反复写盘。
	var is_new_record: bool = score > best_score
	if is_new_record:
		best_score = score
		_save_best_score()
	var report: Dictionary = _build_run_report(is_new_record)
	# 先落盘再刷新界面：界面出问题不该连带把这一局的数据弄丢。
	_append_run_log(report)
	_refresh_hud()
	hud.show_game_over(report)
	# 结算：停掉循环音乐，改放一段下行音，把“这局结束了”说清楚。
	_stop_music()
	_play_sfx(SFX_GAMEOVER)

func _tighten(base: float, floor_value: float, decay: float, tail: float, level_offset: float) -> float:
	# “线性递减 + 下限”的常规写法有个致命副作用：撞到下限之后难度就**彻底冻住**了。
	# 本表第一版把 max_level 从 12 抬到 30，理由是“参数没机会生效”——但那抬错了地方，
	# 真正冻死难度的是下限触底的等级（生成间隔 L13、射击间隔 L18），与上限无关。
	# 真人第一局的数据坐实了这一点：那局难度 25、21 级来自计时，可 L18→L25 的最后
	# 84 秒里所有压力参数都是常数，玩家反馈“中段像在等死”。
	# 所以下限之后补一段尾巴：每多出一级，间隔再乘一次 tail。线性段保持原样，
	# 前中期的曲线与手感完全不变，改的只有尾段。
	var linear: float = base - level_offset * decay
	if linear >= floor_value:
		return linear
	# 已经超出下限多少个“一级的衰减量”——也就是撞底之后又过了多少级。
	var levels_past: float = (floor_value - linear) / maxf(decay, 0.000001)
	return floor_value * pow(tail, levels_past)

func get_spawn_interval() -> float:
	# 同一波内相邻两架敌机的间隔。随难度递减，但永不低于下限：
	# 否则高难度下会一瞬间把整波压进同一帧，玩家没有任何反应空间。
	return _tighten(
		tuning.spawn_interval_base,
		tuning.spawn_interval_floor,
		tuning.spawn_interval_decay,
		tuning.spawn_interval_tail,
		float(difficulty_level - 1)
	)

func volley_count_for(level: int) -> int:
	# 某个难度下敌机一次打几发。单独抽成函数，理由与 shooter_chance / aim_ratio 相同：
	# 让“阶梯与上限”可以被直接断言，而不必靠统计采样去猜。
	return clampi(
		1 + int(float(maxi(level, 1) - 1) / float(maxi(tuning.volley_every_levels, 1))),
		1,
		maxi(tuning.volley_cap, 1)
	)

func current_wave() -> Dictionary:
	if tuning.waves.is_empty():
		return {}
	return tuning.waves[wave_index % tuning.waves.size()]

func shooter_chance() -> float:
	# 当前难度与本波加成下的开火概率，已按上限夹紧。单独抽成函数是为了让“夹紧”
	# 这件事可以被直接断言，而不必靠统计采样去猜。
	return clampf(
		tuning.shooter_chance_base
			+ float(difficulty_level - 1) * tuning.shooter_chance_per_level
			+ float(current_wave().get("shooter_bonus", 0.0)),
		0.0,
		tuning.shooter_chance_cap
	)

func aim_ratio() -> float:
	# 会瞄准玩家的敌机比例：本波自带的 + 每级难度的增量，再夹紧。
	# 这是唯一能制造“必须移动”压力的手段——只靠提高弹幕密度的话，
	# 画面会变成密不透风的下落弹，那是“难”而不是“有意思”。
	return clampf(
		float(current_wave().get("aim_ratio", 0.0))
			+ float(difficulty_level - 1) * tuning.aim_ratio_per_level,
		0.0,
		tuning.aim_ratio_cap
	)

func current_wave_count() -> int:
	var wave: Dictionary = current_wave()
	if wave.is_empty():
		return 1
	# 每走完一整轮波次，每波再多来几架；有上限，否则长期生存时波次会无限膨胀。
	return int(wave.get("count", 1)) + mini(wave_cycle, int(tuning.cycle_count_bonus_cap))

func _on_enemy_timer_timeout() -> void:
	if state != GameState.PLAYING:
		return
	if boss_pending:
		# 上一拍走完了一整轮，这一拍轮到 Boss 登场；波次在它被击破前都停着。
		_start_boss()
		return
	if spawned_in_wave >= current_wave_count():
		# 本波放完，停一拍再开下一波。这个“呼吸间隙”是波次节奏与匀速细流最大的手感差别：
		# 玩家有机会整理弹幕、捡回节奏，而不是被无休止地磨。
		wave_index += 1
		if wave_index % maxi(tuning.waves.size(), 1) == 0:
			# 走完一整轮：这一轮以 Boss 收尾。下面那段 wave_gap 就是它的预警时间。
			wave_cycle += 1
			boss_pending = true
		spawned_in_wave = 0
		_refresh_hud()
		enemy_timer.start(tuning.wave_gap)
		return
	_create_enemy.call_deferred(run_id, _wave_spawn_x(spawned_in_wave, current_wave_count()))
	spawned_in_wave += 1
	# One Shot 定时器每次读取新难度，避免反复 start 导致永远不超时。
	enemy_timer.start(get_spawn_interval())

func _start_boss() -> void:
	boss_pending = false
	# Boss 战期间不刷普通敌机：计时器一停，玩家的注意力就只有一件事。
	enemy_timer.stop()
	var cycle_index: int = maxi(wave_cycle - 1, 0)
	boss = BOSS_SCENE.instantiate()
	# 导出值一律在 add_child 之前写好，_ready() 才能直接使用（与敌机同样的约定）。
	# 血量按玩家**当前每秒能打出多少发**反推，而不是按轮次线性增长：
	# 玩家输出跨度有二十多倍，线性曲线要么前期打不动、要么后期一碰就碎。
	boss.max_hp = clampi(
		int(round(player_dps_proxy() * tuning.boss_target_seconds)),
		int(tuning.boss_hp_floor),
		int(tuning.boss_hp_cap)
	)
	boss.score_value = int(tuning.boss_score)
	boss.hold_y = tuning.boss_hold_y
	boss.enter_speed = tuning.boss_enter_speed
	boss.cruise_speed = tuning.boss_cruise_speed
	boss.margin = tuning.boss_margin
	boss.volley_interval = maxf(
		tuning.boss_volley_interval_floor,
		tuning.boss_volley_interval - float(cycle_index) * tuning.boss_volley_decay
	)
	boss.fan_count = mini(
		int(tuning.boss_fan_count) + cycle_index,
		int(tuning.boss_fan_count_cap)
	)
	boss.fan_degrees = tuning.boss_fan_degrees
	boss.bullet_speed = minf(
		tuning.boss_bullet_speed_cap,
		tuning.boss_bullet_speed + float(cycle_index) * 18.0
	)
	boss.destroyed.connect(_on_boss_destroyed)
	boss.hp_changed.connect(_on_boss_hp_changed)
	boss.shoot_requested.connect(_on_boss_shoot_requested)
	actors.add_child(boss)
	boss.position = Vector2(get_viewport_rect().size.x * 0.5, -120.0)
	_play_sfx(SFX_BOSS)
	hud.show_boss(boss.hp, boss.max_hp)
	_refresh_hud()

func _on_boss_hp_changed(hp: int) -> void:
	if is_instance_valid(boss):
		hud.update_boss(hp, boss.max_hp)
	_refresh_hud()

func _on_boss_destroyed(points: int) -> void:
	if not is_instance_valid(boss):
		return
	# 击破后的处理刻意收在这一个函数里：若以后要改成“击破即通关”，
	# 只需在这里换成显示通关界面并停局，其余逻辑都不用动。
	var center: Vector2 = boss.global_position
	boss = null
	# 单独记一次 Boss 击毁。`kills` 是“击毁总数”，Boss 也会走 add_score 被算进去——
	# 那是有意的（击毁就是击毁），但把 1 点血的敌机和上万血的 Boss 混在一个数字里，
	# 事后按击毁数分析时就分不出“这一局打了多少架普通敌机”，所以记录里另存一份。
	boss_kills += 1
	hud.hide_boss()
	_play_sfx(SFX_EXPLOSION)
	# 这么大的目标不该只炸一下：沿机身撒开几处，看起来才是整体崩解。
	for offset in [Vector2(-58, -12), Vector2(0, 20), Vector2(58, -10), Vector2(-22, 30), Vector2(28, -26)]:
		_spawn_explosion.call_deferred(center + offset, run_id)
	add_score(points)
	# 击破 Boss 是这一轮的收尾，顺带补一次升级抉择，给玩家一次变强的机会。
	# 但只补**半级**：补一整级时，Boss 的总经验收益相当于约 100 架普通敌机，真人
	# 第一局里 9 个 Boss 就贡献了约 71% 的总经验——升级节奏于是由 Boss 的固定排程
	# 决定，而不是由“打得多准”决定。半级保留了“熬到 Boss 就能变强”的奖励感，
	# 又把主动权还给击毁数。
	xp += int(round(float(xp_required(level)) * tuning.boss_xp_levels))
	_refresh_hud()
	_check_level_up()
	# 波次从下一轮继续。注意此时 wave_index 已经取模归零，所以又是从第 1 套编队开始。
	spawned_in_wave = 0
	enemy_timer.start(tuning.wave_gap)

func _on_boss_shoot_requested(origin: Vector2, direction: Vector2, speed: float) -> void:
	_on_enemy_shoot_requested(origin, direction, speed)

func _wave_spawn_x(index: int, count: int) -> float:
	# 编队只决定出场横坐标；纵坐标一律从画面顶部外开始，与单机生成时一致。
	var margin: float = 38.0
	var width: float = get_viewport_rect().size.x
	var usable: float = width - margin * 2.0
	match String(current_wave().get("formation", "random")):
		"line":
			# 横列：整波均匀铺满宽度，形成一道留有空隙的墙。
			if count <= 1:
				return width * 0.5
			return margin + usable * float(index) / float(count - 1)
		"arc":
			# 两翼：左右交替、由外向内，中间天然留出一条通道。
			var inward: float = minf(0.45, 0.06 * float(index / 2))
			var offset: float = margin + usable * inward
			return offset if index % 2 == 0 else width - offset
		_:
			return rng.randf_range(margin, margin + usable)

func _create_enemy(ticket: int, at_x: float = -1.0) -> void:
	if state != GameState.PLAYING or ticket != run_id:
		return
	var wave: Dictionary = current_wave()
	var level_offset: float = float(difficulty_level - 1)
	var speed_scale: float = float(wave.get("speed_scale", 1.0))
	var margin: float = 38.0
	# at_x 缺省为负表示“随机散开”，单机测试与旧调用都走这条分支。
	var spawn_x: float = at_x
	if spawn_x < 0.0:
		spawn_x = rng.randf_range(margin, get_viewport_rect().size.x - margin)

	var enemy = ENEMY_SCENE.instantiate()
	enemy.position = Vector2(spawn_x, -48.0)
	# 速度、射击频率、弹速一律夹在上下限内：难度与波次加成叠加后也不能突破，
	# 否则后期会出现玩家无论如何都躲不掉的弹幕。
	enemy.speed = minf(
		tuning.speed_cap,
		rng.randf_range(tuning.speed_min, tuning.speed_max) * speed_scale
			+ level_offset * tuning.speed_per_level
	)
	enemy.can_shoot = rng.randf() < shooter_chance()
	# 齐射发数随难度上升。这是后期难度的真正支点：玩家火力一强，敌机就会在开火窗口
	# 之前被秒杀（基准实测每架只来得及开 0.56~0.79 枪），单发式敌人的输出被直接抹平，
	# 这时把密度、速度、开火概率调多高都没用。齐射把总输出改成由首发决定，绕开了这一点。
	enemy.volley_count = volley_count_for(difficulty_level)
	enemy.volley_spread_degrees = tuning.volley_spread_degrees
	# 一部分会开火的敌机改为瞄准玩家当前位置，而不是一律竖直向下。
	enemy.aims_at_player = rng.randf() < aim_ratio()
	enemy.score_value = 20 if enemy.can_shoot else 10
	enemy.shoot_interval = _tighten(
		tuning.shoot_interval_base,
		tuning.shoot_interval_floor,
		tuning.shoot_interval_decay,
		tuning.shoot_interval_tail,
		level_offset
	)
	enemy.first_shot_delay = rng.randf_range(tuning.first_shot_delay_min, tuning.first_shot_delay_max)
	enemy.bullet_speed = minf(
		tuning.bullet_speed_cap,
		tuning.bullet_speed_base + level_offset * tuning.bullet_speed_per_level
	)
	enemy.destroyed.connect(add_score)
	# 逃敌要单独接：被击毁不会发这个信号，所以两者不会互相干扰。
	enemy.escaped.connect(_on_enemy_escaped)
	# 第二个连接专门用来把爆炸放在敌机被击毁的位置：destroyed 只带分值，
	# 位置要靠 bind 把敌机自己传进来才拿得到。
	enemy.destroyed.connect(_on_enemy_destroyed.bind(enemy))
	enemy.shoot_requested.connect(_on_enemy_shoot_requested)
	actors.add_child(enemy)

func _on_enemy_destroyed(_points: int, enemy) -> void:
	if not is_instance_valid(enemy):
		return
	# 爆炸音效与爆炸同一次事件，但**不挂在敌机身上**：敌机当帧就 queue_free，
	# 挂在它身上的播放器会随节点一起消失，声音直接断掉。
	_play_sfx(SFX_EXPLOSION)
	# 此刻仍在信号回调内，敌机只是 queue_free 了、还没真正释放，位置可以安全读取。
	# 生成动作照例延迟到帧末，避免在物理回调里改动碰撞世界。
	_spawn_explosion.call_deferred(enemy.global_position, run_id)

func _spawn_explosion(at: Vector2, ticket: int) -> void:
	# 只排除“这局还没开始 / 已经结束”，刻意**不排除 LEVEL_UP**：
	# 击毁敌机可能当帧就触发升级抉择，而爆炸是延迟到帧末生成的，那时 state 已经是
	# LEVEL_UP。若把 LEVEL_UP 一并挡掉，击杀瞬间反而一点爆炸都没有——Boss 因为给分多
	# 必然触发升级，这个坑是一定会踩到的。
	if state == GameState.GAME_OVER or state == GameState.READY or ticket != run_id:
		return
	var burst = EXPLOSION_SCENE.instantiate()
	# **位置必须在 add_child 之前写好。** Explosion._ready() 一进来就把 emitting 打开，
	# 而 one_shot + explosiveness=1 会在那一瞬间把整批粒子按当时的坐标发射出去——之后再挪
	# 节点，粒子已经留在原地了。真机上踩过一次：这里写成"先 add_child、再设坐标"，结果
	# **所有击毁特效都画在左上角**，而当时的断言查的是节点位置（那个值是对的），一直绿着。
	# 这条与敌机/Boss 的约定是同一个："导出值与位置一律在 add_child 之前写好"。
	burst.position = at
	actors.add_child(burst)

func _on_player_shoot_requested(origin: Vector2) -> void:
	if ship_uses_beam():
		# 光束战机不生成子弹：输出由持续存在的光柱承担（见 _sync_beams）。
		# 音效按低得多的节奏播放——射击键每秒触发 6 次以上，照搬会把背景音乐盖掉，
		# 而"持续光束"本来也不该是一串短促的点射声。
		_beam_hum_left -= 1.0 / maxf(player.shoot_cooldown, 0.01)
		if _beam_hum_left <= 0.0:
			_beam_hum_left = BEAM_HUM_INTERVAL
			_play_sfx(SFX_SHOOT)
		return
	# 音效在请求处就播，跟子弹一样延迟生成会让声音比画面晚一拍。
	_play_sfx(SFX_SHOOT)
	# 统一延迟添加物理对象，规避 flushing queries 时更改碰撞世界。
	_create_player_bullet.call_deferred(origin, run_id)

func _create_player_bullet(origin: Vector2, ticket: int) -> void:
	if state != GameState.PLAYING or ticket != run_id:
		return
	# 车道偏移取自 _lane_offsets()：光束用的是同一份，两台战机的车道布局因此逐值一致。
	for offset in _lane_offsets():
		_spawn_player_bullet(origin + Vector2(offset, 0.0))

func _spawn_player_bullet(at: Vector2) -> void:
	var bullet = PLAYER_BULLET_SCENE.instantiate()
	bullet.speed = _bullet_speed
	bullet.pierce_left = _bullet_pierce
	bullet.intercepts = _bullet_intercepts
	bullet.play_area_top = play_area_top
	# **弹体外观取自当前战机**：每台战机只用自己的那一套（形状 + 弹体色 + 亮芯色）。
	# 表里没有这一项的战机（聚焦型：它不出子弹）就用脚本里的默认值。
	var ship: Dictionary = current_ship()
	bullet.body_polygon = PackedVector2Array(
		ship.get("bullet_hull", bullet.body_polygon)
	)
	bullet.body_color = ship.get("bullet_color", bullet.body_color)
	bullet.core_color = ship.get("bullet_core_color", bullet.core_color)
	# 主弹幕**一律照直飞**：弹幕墙与拦截弹都依赖它保持竖直，追踪是另一路武器
	# （见 _spawn_seeker）。把追踪做进主弹幕会让满配每秒 13.5 次射击全部命中，
	# 敌方弹幕会被打到 0。
	bullet.homing = false
	# direction 保持默认的正上方，弹道竖直，所以图形旋转量恒为 0。
	# 弹体增幅：直接缩放节点，碰撞形状与图形一起变大，因此“更好命中”是真的生效。
	bullet.scale = Vector2.ONE * _bullet_scale
	actors.add_child(bullet)
	bullet.global_position = at

func _on_enemy_shoot_requested(origin: Vector2, direction: Vector2, shot_speed: float) -> void:
	# 普通敌机与 Boss 现在共用同一个入口：方向由发弹方决定，
	# 竖直下落与瞄准射击都走这一条，Main 不必区分是谁在打。
	_create_enemy_bullet.call_deferred(origin, direction, shot_speed, run_id)

func _create_enemy_bullet(origin: Vector2, direction: Vector2, shot_speed: float, ticket: int) -> void:
	if state != GameState.PLAYING or ticket != run_id:
		return
	var bullet = ENEMY_BULLET_SCENE.instantiate()
	bullet.speed = shot_speed
	bullet.direction = direction
	actors.add_child(bullet)
	bullet.global_position = origin

func _clear_entities() -> void:
	# 只清理专用容器，不会误删 Player、HUD 或其他场景。
	for entity in actors.get_children():
		if entity.has_method("deactivate"):
			entity.deactivate()
		entity.queue_free()
	# Boss 与光束都在 actors 里、会被上面一并释放，这里同步丢掉引用，
	# 免得后续还拿着一个即将失效的对象（光束数组尤其要注意：长度不归零的话，
	# 下一局 _sync_beams 会以为光束还在、只去更新已经释放的节点）。
	boss = null
	beams.clear()

func _refresh_hud() -> void:
	# HUD 只负责显示，数值一律由 Main 计算后传入；集中一处刷新，避免漏改某个调用点。
	# 最高分显示的是“含本局在内”的最好成绩，所以局中超过旧纪录会立刻反映出来。
	hud.update_stats(score, lives, survival_time, difficulty_level, wave_index % maxi(tuning.waves.size(), 1) + 1)
	hud.update_best(maxi(best_score, score))
	hud.update_progress(level, xp, xp_required(level))
	hud.update_combo(combo_multiplier())
	if is_instance_valid(boss):
		hud.update_boss(boss.hp, boss.max_hp)

func xp_required(for_level: int) -> int:
	# 线性增长：前期升级快、后期变慢，但始终可预期，便于调参。
	return xp_base + xp_growth * (for_level - 1)

func choose_upgrade(index: int) -> void:
	if state != GameState.LEVEL_UP or index < 0 or index >= offers.size():
		return
	var chosen: Dictionary = offers[index]
	offers = []
	hud.hide_level_up()
	_set_paused(false)
	var id: String = chosen["id"]
	upgrade_stacks[id] = _stacks_of(id) + 1
	_apply_upgrade(id)
	_advance_level()
	state = GameState.PLAYING
	_refresh_hud()
	# 一次拿到大量经验可能连升多级，所以这里继续检查，而不是只升一级。
	_check_level_up()

func _check_level_up() -> void:
	# while 而非 if：能力全部叠满时没有可选项，此时直接升级并继续判定。
	while state == GameState.PLAYING and xp >= xp_required(level):
		var candidates: Array[Dictionary] = _available_upgrades()
		if candidates.is_empty():
			_advance_level()
			continue
		_begin_level_up(candidates)
		return

func _begin_level_up(candidates: Array[Dictionary]) -> void:
	state = GameState.LEVEL_UP
	offers = _pick_offers(candidates)
	_set_paused(true)
	# 这一刻世界已经停了，但音效播放器是 PROCESS_MODE_ALWAYS，所以提示音照常响。
	_play_sfx(SFX_UPGRADE)
	_refresh_hud()
	hud.show_level_up(level, offers)

func _advance_level() -> void:
	# 正常路径一定满足 xp >= 本级所需经验；clamp 只是让函数对任何输入都安全。
	xp = maxi(0, xp - xp_required(level))
	level += 1

func _pick_offers(candidates: Array[Dictionary]) -> Array[Dictionary]:
	# 从候选池里不放回地抽，因此一次给出的选项必然互不重复。
	# 抽几个由 max_offers 决定，它会被“幸运补给”抬高，也可能被候选数量截断。
	var pool: Array[Dictionary] = candidates.duplicate()
	var picked: Array[Dictionary] = []
	for _index in range(mini(max_offers, pool.size())):
		var choice: int = rng.randi_range(0, pool.size() - 1)
		picked.append(pool[choice])
		pool.remove_at(choice)
	return picked

func _available_upgrades() -> Array[Dictionary]:
	var available: Array[Dictionary] = []
	for upgrade in UPGRADES:
		if is_upgrade_offered(upgrade["id"]):
			available.append(upgrade)
	return available

func is_upgrade_offered(id: String) -> bool:
	if _stacks_of(id) >= _max_stacks_of(id):
		return false
	# 生命已满时补给不产生任何效果，不能再占一个选项位。上限本身可被“机体强化”抬高。
	if (id == "repair" or id == "vitality") and lives >= max_lives:
		return false
	# 穿透弹对光束没有意义：光柱本来就穿透整列敌人，叠了不会有任何变化。
	# 与其给出一个“选了没效果”的选项，不如不提供——这正是 is_upgrade_offered 存在的理由。
	if id == "pierce" and ship_uses_beam():
		return false
	return true

func _apply_upgrade(id: String) -> void:
	match id:
		"rapid_fire":
			player.shoot_cooldown = maxf(0.05, player.shoot_cooldown * 0.88)
		"multishot":
			_bullet_count += 1
		"wing_shot":
			_wing_pairs += 1
		"velocity":
			_bullet_speed += 90.0
		"pierce":
			_bullet_pierce += 1
		"interceptor":
			_bullet_intercepts = true
		"caliber":
			_bullet_scale += 0.15
		"shield":
			player.invulnerability_duration += 0.25
		"repair":
			lives = mini(lives + 1, max_lives)
		"vitality":
			max_lives += 1
			lives = mini(lives + 1, max_lives)
		"purge":
			_purge_enemy_bullets()
		"thruster":
			player.speed += 28.0
		"insight":
			xp_multiplier = minf(2.0, xp_multiplier + 0.25)
		"bounty":
			score_multiplier = minf(2.0, score_multiplier + 0.20)
		"steady":
			# 改的是运行时副本而不是资源本身：资源是全局共享的，改它会把参数表弄脏，
			# 重开也回不来。
			level_step_seconds += 3.0
		"fortune":
			max_offers += 1
		_:
			push_warning("未知能力，已忽略：%s" % id)

func _purge_enemy_bullets() -> void:
	# 只清敌弹，不动敌机与玩家自己的子弹；立即生效，所以选完这一项当场就能松一口气。
	for entity in actors.get_children():
		if entity.is_in_group("enemy_bullet") and entity.has_method("deactivate"):
			entity.deactivate()
			entity.queue_free()

func _reset_upgrades() -> void:
	# 能力会直接改 Player 的属性与难度间隔，所以必须回到基线，
	# 否则重开会带着上一局的强化继续打。
	upgrade_stacks.clear()
	offers = []
	level = 1
	xp = 0
	xp_multiplier = 1.0
	score_multiplier = 1.0
	max_lives = BASE_MAX_LIVES
	max_offers = BASE_OFFERS
	# 从资源重新取一份，而不是记一个 _base_ 常量：参数表改了这里自动跟上。
	level_step_seconds = float(tuning.level_step_seconds)
	player.shoot_cooldown = _base_shoot_cooldown
	player.speed = _base_speed
	player.invulnerability_duration = _base_invulnerability
	_bullet_speed = player_bullet_speed
	_bullet_count = 1
	_bullet_pierce = 0
	_wing_pairs = 0
	_bullet_scale = 1.0
	_bullet_intercepts = false

func _stacks_of(id: String) -> int:
	return int(upgrade_stacks.get(id, 0))

func _max_stacks_of(id: String) -> int:
	return int(upgrade_by_id(id).get("max", 0))

func upgrade_by_id(id: String) -> Dictionary:
	for upgrade in UPGRADES:
		if upgrade["id"] == id:
			return upgrade
	return {}

func _set_paused(value: bool) -> void:
	# 只有升级抉择期间才暂停：规则、敌机与子弹全部冻结，而 HUD 设为
	# PROCESS_MODE_ALWAYS，所以选项按钮与数字键在暂停时仍然可用。
	get_tree().paused = value

func _start_screen_shake() -> void:
	if not screen_shake_enabled or screen_shake_strength <= 0.0:
		return
	_stop_screen_shake()
	# 先立刻给一个偏移再开始衰减：冲击感是即时的，断言也就不必等一个帧才成立。
	camera.offset = _random_shake_offset()
	_shake_tween = create_tween()
	_shake_tween.tween_property(camera, "offset", Vector2.ZERO, screen_shake_duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func _stop_screen_shake() -> void:
	if _shake_tween != null and _shake_tween.is_valid():
		_shake_tween.kill()
	_shake_tween = null
	camera.offset = Vector2.ZERO

func _random_shake_offset() -> Vector2:
	# 取随机方向乘以固定长度，保证偏移量一定非零——纯随机取两个分量有可能恰好得到零向量，
	# 那样“震了一下”就变成什么都没发生。
	var angle: float = rng.randf_range(0.0, TAU)
	return Vector2(cos(angle), sin(angle)) * screen_shake_strength

func _build_audio() -> void:
	# 音效池在代码里建：路数可调，场景树也不必摆六个几乎一样的节点。
	# process_mode 设为 ALWAYS 的理由与 HUD 相同——升级抉择会暂停整棵树，
	# 若音效播放器仍是默认的 PAUSABLE，选能力那一下的提示音就会被吃掉。
	for _index in range(maxi(sfx_voices, 1)):
		var voice := AudioStreamPlayer.new()
		voice.bus = SFX_BUS
		voice.process_mode = Node.PROCESS_MODE_ALWAYS
		sfx_root.add_child(voice)
		_sfx_players.append(voice)
	_prepare_music()

func _prepare_music() -> void:
	if not (music.stream is AudioStreamWAV):
		push_warning("背景音乐未装载为 AudioStreamWAV：%s" % music.name)
		return
	var wav: AudioStreamWAV = music.stream
	# 循环点用“时长 × 采样率”换算，而不是拿 data 的字节数除样本宽度：
	# WAV 导入默认会做 QOA 压缩（.import 里的 compress/mode=2），此时 data 里
	# 已经不是原始 PCM，按字节数换算会得到一个完全错误的循环点。
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = int(round(wav.get_length() * float(wav.mix_rate)))

func _play_sfx(stream: AudioStream) -> void:
	if stream == null or _sfx_players.is_empty():
		return
	# 先用空闲的那一路；全忙时按轮转覆盖最早的一路，避免池满就完全没声音。
	var chosen: AudioStreamPlayer = null
	for voice in _sfx_players:
		if not voice.playing:
			chosen = voice
			break
	if chosen == null:
		chosen = _sfx_players[_sfx_cursor]
		_sfx_cursor = (_sfx_cursor + 1) % _sfx_players.size()
	chosen.stream = stream
	chosen.play()

func _play_music() -> void:
	if music.stream == null:
		return
	# 每局从头开始，重开时听感一致；循环点由 _prepare_music() 设好。
	music.play()

func _stop_music() -> void:
	music.stop()

func _load_best_score() -> void:
	best_score = 0
	if not FileAccess.file_exists(SAVE_PATH):
		# 首次运行没有存档，这是正常情况，不是错误。
		return
	var config := ConfigFile.new()
	var error: Error = config.load(SAVE_PATH)
	if error != OK:
		push_warning("最高分存档读取失败（%s），本次从 0 开始：%s" % [error_string(error), SAVE_PATH])
		return
	var stored: Variant = config.get_value(SAVE_SECTION, SAVE_KEY, 0)
	# 存档可能被外部改坏；只接受非负整数，其余一律退回 0，不让脏数据进入计分。
	if typeof(stored) == TYPE_INT and stored >= 0:
		best_score = stored
	else:
		push_warning("最高分存档内容无效，已忽略：%s" % SAVE_PATH)

func _save_best_score() -> void:
	# 先读取再回写：存档缺失（首次刷新纪录）或已损坏都从空配置起步，后者顺带自我修复；
	# 这样将来在同一文件中新增其他键时，也不会被整文件覆盖。
	var config := ConfigFile.new()
	var load_error: Error = config.load(SAVE_PATH)
	if load_error != OK and load_error != ERR_FILE_NOT_FOUND:
		push_warning("最高分存档读取失败（%s），将重新写入：%s" % [error_string(load_error), SAVE_PATH])
	config.set_value(SAVE_SECTION, SAVE_KEY, best_score)
	var save_error: Error = config.save(SAVE_PATH)
	if save_error != OK:
		# 写盘失败不阻断结算：纪录仍留在内存中，本次显示与重开都照常。
		push_warning("最高分存档写入失败（%s）：%s" % [error_string(save_error), SAVE_PATH])

func tuning_fingerprint() -> String:
	# 对局记录必须能自证“这一局是按哪套规则跑的”。没有它，改完参数再请真人试玩时，
	# 就只能靠文件时间戳去推断某条记录来自改前还是改后——那是最脆弱的证据，稍不留神
	# 就会拿两套规则的数据作对比并得出错误结论。这里只取与难度直接相关的少数字段：
	# 全字段哈希虽然更完整，却看不出“到底动了哪一项”，而这个指纹的用途正是横向对比。
	return "L%.0f S%.3f St%.3f H%.3f Ht%.3f B%.2f E%.2f V%d/%d" % [
		tuning.level_step_seconds,
		tuning.spawn_interval_floor,
		tuning.spawn_interval_tail,
		tuning.shoot_interval_floor,
		tuning.shoot_interval_tail,
		tuning.boss_xp_levels,
		tuning.escape_pressure_per_enemy,
		tuning.volley_every_levels,
		tuning.volley_cap,
	]

func _build_run_report(is_new_record: bool) -> Dictionary:
	# 这一份字典同时喂给两个去处：屏幕上的结算战报，和写进磁盘的对局记录。
	# 只留一个来源，才不会出现“屏幕写 61、记录写 60”这种对不上的情况。
	# build 保留原始的 id→层数结构（供后续分析哪条能力路线活得久），
	# build_text 是给界面用的成品文案（名字与层数只有 UPGRADES 知道）。
	return {
		"time": snappedf(survival_time, 0.1),
		"score": score,
		"best": best_score,
		"level": level,
		"difficulty": difficulty_level,
		"kills": kills,
		"boss_kills": boss_kills,
		"hits": hits_taken,
		"hit_times": hit_times.duplicate(),
		"escapes": escaped_count,
		"peak_combo": peak_combo_multiplier,
		# 战机也要进记录：否则事后看试玩数据时，分不清某一局的战绩属于哪种武器形态。
		"ship": ship_id,
		"record": is_new_record,
		"build": upgrade_stacks.duplicate(),
		"build_text": build_summary(),
		"rules": tuning_fingerprint(),
	}

func build_summary() -> String:
	# 结算行有宽度上限，所以最多只列最先拿到的两项，其余用“等 N 项”收口。
	var parts: Array[String] = []
	var total: int = 0
	for entry in UPGRADES:
		var stacks: int = int(upgrade_stacks.get(entry["id"], 0))
		if stacks <= 0:
			continue
		total += 1
		if parts.size() < 2:
			parts.append("%s×%d" % [entry["name"], stacks])
	if total == 0:
		return "未获得能力"
	var summary: String = " · ".join(parts)
	if total > parts.size():
		summary += " 等 %d 项" % total
	return summary

func is_json_object(line: String) -> bool:
	# 用 JSON 实例的 parse()（返回错误码）而不是静态的 JSON.parse_string()：后者解析
	# 失败时会直接往引擎日志里写一条 ERROR。而“读到坏行就丢掉”是这里有意为之的容错，
	# 不该在日志里留下一条看起来像故障的报错——那会让日志判读失去意义。
	var json := JSON.new()
	if json.parse(line) != OK:
		return false
	return typeof(json.data) == TYPE_DICTIONARY

func _append_run_log(record: Dictionary) -> void:
	var lines := PackedStringArray()
	if FileAccess.file_exists(RUN_LOG_PATH):
		var reader: FileAccess = FileAccess.open(RUN_LOG_PATH, FileAccess.READ)
		if reader == null:
			push_warning("对局记录读取失败（%s），本次将重建：%s"
				% [error_string(FileAccess.get_open_error()), RUN_LOG_PATH])
		else:
			while not reader.eof_reached():
				var line: String = reader.get_line().strip_edges()
				# 空行与被写坏的行直接丢掉。记录文件不承载任何游戏状态，留着垃圾只会
				# 让后面按它调参时踩坑；顺手把坏行清掉也算一种自我修复。
				if line != "" and is_json_object(line):
					lines.append(line)
			reader.close()
	lines.append(JSON.stringify(record))
	# 只保留最近若干局：超出部分从最旧的开始丢。
	if lines.size() > RUN_LOG_LIMIT:
		lines = lines.slice(lines.size() - RUN_LOG_LIMIT)
	var writer: FileAccess = FileAccess.open(RUN_LOG_PATH, FileAccess.WRITE)
	if writer == null:
		# 写盘失败不阻断结算：少一局记录无所谓，游戏必须照常能继续玩。
		push_warning("对局记录写入失败（%s）：%s"
			% [error_string(FileAccess.get_open_error()), RUN_LOG_PATH])
		return
	for line in lines:
		writer.store_line(line)
	writer.close()

func toggle_pause() -> void:
	# 只有“正在游戏”才允许暂停：开始界面、结算界面各有自己的语义，
	# 而升级抉择期间整树已经暂停，再叠一层会让状态变得含糊。
	if state != GameState.PLAYING:
		return
	if get_tree().paused:
		_set_paused(false)
		hud.hide_pause()
	else:
		_set_paused(true)
		# 打开面板时把三项设置的真实值一起带过去——HUD 只负责显示，不持有规则。
		hud.show_pause(screen_shake_enabled, music_percent, sfx_percent)

func _on_pause_restarted() -> void:
	# state 仍是 PLAYING，所以要 force；解除暂停由 start_game 自己负责，这里先收起面板。
	start_game(true)

func _on_shake_toggled(enabled: bool) -> void:
	screen_shake_enabled = enabled
	_save_settings()

func _on_volume_changed(bus_name: String, percent: int) -> void:
	if bus_name == "Music":
		music_percent = clampi(percent, 0, 100)
	else:
		sfx_percent = clampi(percent, 0, 100)
	_apply_audio_settings()
	_save_settings()

func _load_settings() -> void:
	# 默认值取自音频总线**当前的实际音量**，而不是写死 100%：
	# 总线布局里 Music 是 -6 dB、SFX 是 -3 dB，直接写 100 会让面板显示的值与实况不符。
	music_percent = _bus_percent("Music")
	sfx_percent = _bus_percent("SFX")
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		# 存档损坏不是错误：设置退回默认值即可，最高分那边有自己的告警。
		return
	screen_shake_enabled = bool(config.get_value(SETTINGS_SECTION, SETTINGS_SHAKE, screen_shake_enabled))
	music_percent = clampi(int(config.get_value(SETTINGS_SECTION, SETTINGS_MUSIC, music_percent)), 0, 100)
	sfx_percent = clampi(int(config.get_value(SETTINGS_SECTION, SETTINGS_SFX, sfx_percent)), 0, 100)
	# 战机也记住：玩家选过一次之后不该每局都要重选。
	var stored_ship: String = str(config.get_value(SETTINGS_SECTION, SETTINGS_SHIP, ship_id))
	for entry in SHIPS:
		if entry["id"] == stored_ship:
			ship_id = stored_ship
			break
	_apply_audio_settings()

func _save_settings() -> void:
	# 与 _save_best_score() 一样先读取再回写：records 与 settings 两个节互不覆盖。
	var config := ConfigFile.new()
	config.load(SAVE_PATH)
	config.set_value(SETTINGS_SECTION, SETTINGS_SHAKE, screen_shake_enabled)
	config.set_value(SETTINGS_SECTION, SETTINGS_MUSIC, music_percent)
	config.set_value(SETTINGS_SECTION, SETTINGS_SFX, sfx_percent)
	config.set_value(SETTINGS_SECTION, SETTINGS_SHIP, ship_id)
	var error: Error = config.save(SAVE_PATH)
	if error != OK:
		# 写盘失败不阻断游玩：设置仍留在内存里，本局照常。
		push_warning("设置写入失败（%s）：%s" % [error_string(error), SAVE_PATH])

func _bus_percent(bus_name: String) -> int:
	var index: int = AudioServer.get_bus_index(bus_name)
	if index < 0 or AudioServer.is_bus_mute(index):
		return 0
	return clampi(int(round(db_to_linear(AudioServer.get_bus_volume_db(index)) * 100.0)), 0, 100)

func _apply_audio_settings() -> void:
	_set_bus_percent("Music", music_percent)
	_set_bus_percent("SFX", sfx_percent)

func _set_bus_percent(bus_name: String, percent: int) -> void:
	var index: int = AudioServer.get_bus_index(bus_name)
	if index < 0:
		# 总线不存在说明 default_bus_layout.tres 没被加载，代码里的 bus="Music" 会静默回落，
		# 音量滑条则会变成一个没有任何作用的控件——所以这里必须出声，不能沉默。
		push_warning("找不到音频总线，音量设置无效：%s" % bus_name)
		return
	AudioServer.set_bus_mute(index, percent <= 0)
	# 线性 0 换算出的是 -inf dB，所以先夹一个极小值再换算。
	AudioServer.set_bus_volume_db(index, linear_to_db(maxf(float(percent) / 100.0, 0.0001)))
