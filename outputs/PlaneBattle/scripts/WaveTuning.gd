extends Resource
## 难度曲线与波次表。
##
## 这些数值原本散落在 Main 的公式里，抽成 Resource 之后可以在检查器里直接调，
## 也能为不同关卡换一份 .tres 而不动代码。Main 只读不写这份资源——运行时需要
## 变化的部分（例如“战术从容”会拉长升级间隔）在 Main 里另存一份副本，
## 否则一改就把全局资源改脏了。
##
## 所有速度与间隔都带下限/上限。这里有一个**已经踩过两次**的坑，务必记住：
## 这些参数撞到下限（或上限）之后就不再变化，难度会提前"冻死"。
##
## 第一次的结论是把 max_level 从 12 抬高到 30，理由是"上限太低导致参数没机会生效"。
## 但那个诊断只对了一半——真正冻死难度的往往是**下限**：生成间隔在难度 13 触底、
## 射击间隔在 18 触底，此后无论等级涨到多少都不再收紧。抬高上限对此毫无帮助。
## 这一点后来被真人第一局的数据坐实：那局难度 25、其中 21 级来自计时，但 L18→L25
## 的最后 84 秒里所有压力参数都是常数，玩家明确反馈"中段太顺，像在等死"。
##
## 因此每个"间隔"类参数都多了一个 tail 系数：撞到下限之后，每多出一级再乘一次 tail，
## 曲线不会停。线性段保持原样，所以前中期的手感不受影响，改的只是尾段。
## 以后新增任何带 floor/cap 的压力参数，都要顺便想清楚它触底在哪一级、之后靠什么继续加压。

@export_group("难度曲线")
## 生存多少秒难度 +1，以及难度的**基准**上限。
@export var level_step_seconds: float = 12.0
@export var max_level: int = 30
## 难度上限还会随玩家等级继续放宽。
## 难度是时间的函数、玩家强度是等级的函数，两者不同步就一定会失衡：
## 玩家越强，允许难度爬到的位置就该越高，否则中后期只剩“玩家单方面变强”。
@export var max_level_per_player_level: int = 1

@export_group("生成节奏")
## 同一波内相邻两架敌机的间隔：随难度递减，撞到 spawn_interval_floor 之后
## 每多出一级再乘一次 spawn_interval_tail（见文件开头关于"难度冻死"的说明）。
@export var spawn_interval_base: float = 1.05
@export var spawn_interval_decay: float = 0.075
@export var spawn_interval_floor: float = 0.18
## 撞到下限之后每一级的额外收紧系数。1.0 表示"撞底即冻结"（旧行为）。
## 0.983 意味着每超出一级间隔再缩短 1.7%：单看一级几乎察觉不到，
## 但 L13→L25 累积下来密度约 +23%，玩家感受到的是"一直在变难"而不是"撞墙后变平"。
@export var spawn_interval_tail: float = 0.983
## 开局到第一波之间的缓冲，以及两波之间的停顿。
@export var first_wave_delay: float = 0.65
@export var wave_gap: float = 1.4
## 每走完一整轮波次，每一波再多来几架；这是长期生存时唯一的额外压力来源，
## 因此必须封顶，否则波次会无限膨胀。
@export var cycle_count_bonus_cap: int = 3

@export_group("敌机数值")
@export var speed_min: float = 100.0
@export var speed_max: float = 150.0
@export var speed_per_level: float = 14.0
@export var speed_cap: float = 460.0
## 基础开火概率。这个值决定“开局有多少敌机会还手”——设得太低时，
## 前几分钟接近八成的敌机都是无害靶子，玩家自然觉得简单。
@export var shooter_chance_base: float = 0.45
@export var shooter_chance_per_level: float = 0.04
@export var shooter_chance_cap: float = 0.85
@export var shoot_interval_base: float = 1.8
@export var shoot_interval_decay: float = 0.08
@export var shoot_interval_floor: float = 0.45
## 与 spawn_interval_tail 同理：射击间隔在难度 18 触底，之后靠这一段继续收紧。
## 这是后期最要紧的杠杆——密度受物理限制（再密就是躲不掉的弹幕，是"难"而不是"有意思"），
## 而"同一批敌机打得更勤"提高的是闪避负担，不受实体数量限制。
@export var shoot_interval_tail: float = 0.98
@export var first_shot_delay_min: float = 0.55
@export var first_shot_delay_max: float = 1.1
## 齐射：难度每高多少级，敌机一次多打一发；发数上限；相邻两发的张角。
## 这是**唯一不受“敌机活多久”影响的加压方式**，也是本作后期难度的真正支点。
## 实测背景：满配玩家每秒打出 148 发、铺成 11 条弹道，敌机往往在开火窗口之前就被
## 打死——基准量出每架敌机平均只开 0.56~0.79 枪（按存活时间本该 2~4 枪），
## 也就是说威胁是在**源头**被掐死的。此时再怎么调密度、速度、开火概率都没用，
## 因为那些参数乘的是“敌机能开几枪”，而那个数已经被玩家火力压到接近 0。
## 让一次开火打出多发，等于把这条链路翻过来：玩家火力越强、敌机死得越快，
## 单发式敌人的总输出越低，而齐射式敌人的**首发**一定能打出 N 发。
@export var volley_every_levels: int = 10
@export var volley_cap: int = 3
@export var volley_spread_degrees: float = 13.0
@export var bullet_speed_base: float = 240.0
@export var bullet_speed_per_level: float = 12.0
@export var bullet_speed_cap: float = 560.0
## 瞄准射击的比例：波次自带的 aim_ratio 加上“每级难度”的增量，再按上限夹紧。
## 这是唯一能制造“必须移动”压力的手段——没有瞄准，压力只能靠弹幕密度堆，
## 而密度一高画面就变成密不透风的下落弹，是“难”而不是“有意思”。
@export var aim_ratio_per_level: float = 0.01
@export var aim_ratio_cap: float = 0.85

@export_group("逃敌代价")
## 敌机从画面底部溜走时累积的难度压力，以及它的上限。
## 没有这条时，“躲着不打”是严格最优解：漏敌不扣任何东西，
## 玩家可以永远待在安全车道里——游戏既没有压力也没有目标。
## 每溜走一架就相当于多熬过一小段生存时间，溜得越多天越难。
@export var escape_pressure_per_enemy: float = 0.34
@export var escape_pressure_cap: float = 12.0

@export_group("Boss")
## Boss 血量按玩家**当前每秒能打出多少发**反推，而不是按轮次线性增长：
## 本作所有敌机一发击毁，所以“每秒发数”就等价于玩家的输出强度。
## 玩家的输出跨度有二十多倍，任何线性血量曲线都会在某些 build 下失真——
## 要么前期打不动，要么后期一碰就碎。
@export var boss_target_seconds: float = 7.0
@export var boss_hp_floor: int = 45
## 血量上限。它**不是**"Boss 不该太肉"的保险丝而已——设小了会直接改写上面那 7 秒：
## 满配聚焦型（光柱）的每秒伤害是 275，公式给出 1925，被 1400 截掉之后 Boss 只剩
## **5.1 秒**的寿命。也就是说，"按 7 秒设计"这件事在最高输出的那台战机上从来没有成立过。
## 现在取 2400：它仍然拦住任何离谱的数值，但已经高于所有合法 build 的公式值（275 × 7 = 1925），
## 于是上限不再参与实际平衡，只管兜底。改这个值请连带复核"三台战机各自的击破秒数"。
@export var boss_hp_cap: int = 2400
## 入场后停在距顶部多远处、以多快降下来，以及之后的横向巡航速度与可活动边距。
@export var boss_hold_y: float = 150.0
@export var boss_enter_speed: float = 90.0
@export var boss_cruise_speed: float = 72.0
@export var boss_margin: float = 96.0
## 每轮齐射的间隔（随轮次缩短但有下限）、扇形发数与总张角、弹速。
@export var boss_volley_interval: float = 1.1
@export var boss_volley_interval_floor: float = 0.7
@export var boss_volley_decay: float = 0.15
@export var boss_fan_count: int = 5
@export var boss_fan_count_cap: int = 11
@export var boss_fan_degrees: float = 64.0
@export var boss_bullet_speed: float = 210.0
@export var boss_bullet_speed_cap: float = 520.0
## 击破奖励分。注意它**同时是经验**，给太高会让玩家一口气连升数级。
@export var boss_score: int = 500
## 击破 Boss 额外补几级经验（0.5 = 半级）。
## 原本补一整级时，Boss 的总经验收益（击杀分 ×经验倍率 + 一整级）相当于约 100 架
## 普通敌机，真人第一局里 9 个 Boss 贡献了约 71% 的总经验——升级节奏于是由 Boss 的
## 固定排程决定，而不是由"打得多准"决定。半级保留了"熬到 Boss 就能变强"的奖励感，
## 又把主动权还给击毁数。
@export var boss_xp_levels: float = 0.5

@export_group("波次")
## 波次按顺序循环播放。每项：name 显示名、count 架数、formation 编队、
## speed_scale 速度倍率、shooter_bonus 射击概率加成、aim_ratio 瞄准射击比例。
## formation 取 random（随机散开）/ line（横列铺满）/ arc（两翼夹击）。
@export var waves: Array[Dictionary] = [
	{"name": "侦察队", "count": 4, "formation": "random", "speed_scale": 1.00, "shooter_bonus": 0.00, "aim_ratio": 0.15},
	{"name": "横列", "count": 5, "formation": "line", "speed_scale": 1.05, "shooter_bonus": 0.00, "aim_ratio": 0.25},
	{"name": "两翼", "count": 6, "formation": "arc", "speed_scale": 1.10, "shooter_bonus": 0.05, "aim_ratio": 0.35},
	{"name": "混编", "count": 6, "formation": "random", "speed_scale": 1.15, "shooter_bonus": 0.12, "aim_ratio": 0.50},
	{"name": "精锐", "count": 5, "formation": "line", "speed_scale": 1.25, "shooter_bonus": 0.20, "aim_ratio": 0.65},
]
