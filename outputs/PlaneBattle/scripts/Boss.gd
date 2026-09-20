extends Area2D
## Boss：走完一整轮波次后登场的里程碑敌人。
##
## 与普通敌机（Enemy）的三点不同，都写在代码里免得后面看混：
## · 生命 > 1：take_hit() 只扣血并广播 hp_changed，扣到 0 才发 destroyed 并释放。
##   但 dead 锁照样第一时间置位，保证同一帧挨了多发子弹不会出现第二次击破。
## · 撞到玩家不自我消耗：hit_player() 只让玩家扣血。否则拿机身去撞就能秒掉 Boss。
## · 自带攻击节奏：入场先降到 hold_y，然后横向巡航并按 ShootTimer 齐射扇形弹幕。
##   （这里刻意不用 “1. 2. 3.” 编号：嵌入开发文档后会与 Markdown 章节标题撞形状。）
##
## 数值一律由 Main 在 add_child 之前写进导出属性（与敌机同样的约定），
## 因此这个脚本不读参数表、也不依赖 Main 的任何内部状态。

signal destroyed(points: int)
signal hp_changed(hp: int)
signal shoot_requested(origin: Vector2, direction: Vector2, speed: float)
## 血量降到阈值时切到二阶段。Main 收到它才做"仪式"：全屏闪白、震屏、专属音效、
## 血条换色。**Boss 自己不放特效**——表现层的东西归 Main/HUD，与敌机爆炸同一条约定。
signal phase_changed(phase: int)

@export var max_hp: int = 40
@export var score_value: int = 500
## 入场后停留的高度、降落速度、横向巡航速度与左右可活动的边距。
@export var hold_y: float = 150.0
@export var enter_speed: float = 90.0
@export var cruise_speed: float = 72.0
@export var margin: float = 96.0
## 齐射节奏与弹幕形状。
@export var volley_interval: float = 1.5
@export var fan_count: int = 5
@export var fan_degrees: float = 64.0
@export var bullet_speed: float = 210.0
## --- 二阶段 ---
## 血量降到这个比例就换弹幕（默认 50%）。
@export var phase_two_ratio: float = 0.5
## 转阶段那一下的仪式时长：这期间**停火、停巡航**，给玩家看清"它变招了"。
@export var transition_seconds: float = 0.5
## 螺旋弹：每轮几发（均分整圈）、每轮转多少度、发射间隔、弹速。
@export var spiral_arms: int = 6
@export var spiral_step_degrees: float = 17.0
@export var spiral_interval: float = 0.75
@export var spiral_bullet_speed: float = 160.0

@onready var shoot_timer: Timer = $ShootTimer
@onready var muzzle: Marker2D = $Muzzle
@onready var core: Polygon2D = $Visual/Core
@onready var plate: Polygon2D = $Visual/Plate

var hp: int = 0
var dead: bool = false
## 入场是否已经结束。入场阶段不横向移动、也不开火。
var entered: bool = false
## 1 或 2。阶段只升不降，因此"转阶段"这件事在整场里只会发生一次。
var phase: int = 1
var _drift: float = 1.0
## 螺旋弹当前的角度。每放一轮就累加一个固定步长，把若干轮叠起来才看得出"在转"。
var _spiral_angle: float = 0.0
## 转阶段仪式的剩余时间。大于 0 时：不动、不开火。
var _transition_left: float = 0.0
## 一阶段的机体配色，用来在转阶段后换掉（不改规则，只是让"它急了"看得见）。
var _plate_color: Color = Color.WHITE

func _ready() -> void:
	# 进 enemy 组是为了复用 Player 与 PlayerBullet 既有的检测链路：
	# 两者都只看“是否在 enemy 组、是否有 take_hit / hit_player”，不需要为 Boss 开新分支。
	add_to_group("enemy")
	add_to_group("boss")
	hp = maxi(max_hp, 1)
	_plate_color = plate.color
	shoot_timer.timeout.connect(_on_shoot_timer_timeout)

func _physics_process(delta: float) -> void:
	if dead:
		return
	if _transition_left > 0.0:
		# 转阶段仪式：这半秒里**停火、也停巡航**。停住是有意的——变招需要一个句读，
		# 否则玩家只会觉得"弹幕忽然变密了"，而不会觉得"它换了打法"。
		_transition_left -= delta
		if _transition_left <= 0.0:
			_transition_left = 0.0
			shoot_timer.start(spiral_interval)
		return
	if not entered:
		position.y += enter_speed * delta
		if position.y >= hold_y:
			position.y = hold_y
			entered = true
			# 给玩家一点反应时间再开第一炮。
			shoot_timer.start(0.8)
		return
	if phase >= 2:
		# 二阶段**不再横向巡航**：它停在原地转弹幕。位置固定下来以后，"螺旋"才看得出
		# 是在转（一边漂一边转，观感只是"某处有弹在飞"）。
		return
	position.x += cruise_speed * _drift * delta
	var width: float = get_viewport_rect().size.x
	if position.x <= margin:
		position.x = margin
		_drift = 1.0
	elif position.x >= width - margin:
		position.x = width - margin
		_drift = -1.0

func _on_shoot_timer_timeout() -> void:
	if dead or not entered or _transition_left > 0.0:
		return
	if phase >= 2:
		fire_spiral()
		shoot_timer.start(spiral_interval)
		return
	fire_fan()
	shoot_timer.start(volley_interval)

func fire_fan() -> void:
	# 一阶段：以正下方为中心的扇形齐射。count 为 1 时张角自然收敛成 0，退化为单发。
	var count: int = maxi(fan_count, 1)
	var center: float = float(count - 1) * 0.5
	var step: float = fan_degrees / maxf(float(count - 1), 1.0)
	for index in range(count):
		var degrees: float = (float(index) - center) * step
		shoot_requested.emit(
			muzzle.global_position,
			Vector2.DOWN.rotated(deg_to_rad(degrees)),
			bullet_speed
		)

func fire_spiral() -> void:
	# 二阶段：一组弹均分整圈射出，**每轮整体再转一个固定角**。
	# "螺旋"就是这么来的：单看任何一轮都是个正多边形，只有把相邻几轮叠起来才看得出在转，
	# 所以步长（`spiral_step_degrees`）与发射间隔必须一起调——步长太小像静止的多边形，
	# 太大又变成乱射。发射点是**机体中心**而不是炮口：径向弹幕从核心冒出来才像"转"。
	var count: int = maxi(spiral_arms, 1)
	for index in range(count):
		var degrees: float = _spiral_angle + 360.0 * float(index) / float(count)
		shoot_requested.emit(
			global_position,
			Vector2.DOWN.rotated(deg_to_rad(degrees)),
			spiral_bullet_speed
		)
	_spiral_angle = fposmod(_spiral_angle + spiral_step_degrees, 360.0)

func in_transition() -> bool:
	# 转阶段仪式是否还在进行（这期间停火、停巡航）。抽成方法而不是让调用方读内部计时器：
	# 回归测试要断言"这半秒里它真的停了"，而读内部字段会把测试绑死在实现上。
	return _transition_left > 0.0

func _maybe_enter_phase_two() -> void:
	# 只升不降：阶段是"这一场发生过什么"，不是"当前血量落在哪一段"。因此挨了第 51% 的
	# 那一刀之后，哪怕血量被补回去（本作没有回血，但规则要自洽）也不会退回一阶段。
	if phase >= 2 or dead:
		return
	if float(hp) > float(max_hp) * phase_two_ratio:
		return
	phase = 2
	_transition_left = maxf(transition_seconds, 0.0)
	shoot_timer.stop()
	# 换配色：机体装甲变暖、核心变亮，配合全屏闪光与震屏，让"变招"同时看得见、听得到。
	plate.color = Color(0.62, 0.22, 0.30, 1)
	core.color = Color(1.0, 0.78, 0.35, 1)
	phase_changed.emit(phase)

func take_hit() -> bool:
	# 与 Enemy 相同的约定：dead 之后返回 false，调用方据此避免重复结算。
	# 区别只是这里扣的是血量，扣到 0 才真正击破。
	if dead:
		return false
	hp -= 1
	hp_changed.emit(hp)
	_maybe_enter_phase_two()
	if hp <= 0:
		deactivate()
		destroyed.emit(score_value)
		queue_free()
	return true

func hit_player(target: Area2D) -> void:
	# Boss 撞到玩家只让玩家扣血，自己不消耗——玩家的无敌帧负责去重。
	if dead or not is_instance_valid(target) or not target.has_method("take_damage"):
		return
	target.take_damage()

func deactivate() -> void:
	# 名字与 Enemy/Bullet 保持一致，这样 _clear_entities() 能一视同仁地停用它。
	dead = true
	visible = false
	shoot_timer.stop()
	set_physics_process(false)
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
