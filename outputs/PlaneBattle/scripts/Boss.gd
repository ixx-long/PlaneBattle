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

@onready var shoot_timer: Timer = $ShootTimer
@onready var muzzle: Marker2D = $Muzzle

var hp: int = 0
var dead: bool = false
## 入场是否已经结束。入场阶段不横向移动、也不开火。
var entered: bool = false
var _drift: float = 1.0

func _ready() -> void:
	# 进 enemy 组是为了复用 Player 与 PlayerBullet 既有的检测链路：
	# 两者都只看“是否在 enemy 组、是否有 take_hit / hit_player”，不需要为 Boss 开新分支。
	add_to_group("enemy")
	add_to_group("boss")
	hp = maxi(max_hp, 1)
	shoot_timer.timeout.connect(_on_shoot_timer_timeout)

func _physics_process(delta: float) -> void:
	if dead:
		return
	if not entered:
		position.y += enter_speed * delta
		if position.y >= hold_y:
			position.y = hold_y
			entered = true
			# 给玩家一点反应时间再开第一炮。
			shoot_timer.start(0.8)
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
	if dead or not entered:
		return
	fire_fan()
	shoot_timer.start(volley_interval)

func fire_fan() -> void:
	# 以正下方为中心的扇形齐射。count 为 1 时张角自然收敛成 0，退化为单发。
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

func take_hit() -> bool:
	# 与 Enemy 相同的约定：dead 之后返回 false，调用方据此避免重复结算。
	# 区别只是这里扣的是血量，扣到 0 才真正击破。
	if dead:
		return false
	hp -= 1
	hp_changed.emit(hp)
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
