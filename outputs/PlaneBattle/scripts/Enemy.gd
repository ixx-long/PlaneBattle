extends Area2D
## Mask 为 0，Enemy 不主动检测 Player，而由 Player 通知 hit_player。

signal destroyed(points: int)
## 从画面底部溜走时发出。**被击毁不会发这个信号**——take_hit / hit_player 都会先
## 停掉物理处理，所以 _physics_process 里那条越界分支不会在死亡后再跑一次。
signal escaped
## 方向由发弹方决定：普通敌机竖直下落，瞄准型敌机朝玩家当前位置打。
## 与 Boss 用同一个签名，Main 因此只需要一个接收函数。
signal shoot_requested(origin: Vector2, direction: Vector2, speed: float)

@export var speed: float = 120.0
@export var score_value: int = 10
@export var can_shoot: bool = false
@export var shoot_interval: float = 1.8
@export var first_shot_delay: float = 0.8
@export var bullet_speed: float = 240.0
## 是否瞄准玩家。由 Main 按波次与难度决定，_ready 里据此换色以便玩家读出威胁。
@export var aims_at_player: bool = false
## 一次开火打出几发，以及相邻两发的张角。由 Main 按难度设定。
## 单发式敌人的实际输出取决于它活了多久，而玩家火力一强就会把敌机在开火前打死；
## 齐射把“总输出”改成由**首发**决定的量，因此不会被秒杀抹平。
@export var volley_count: int = 1
@export var volley_spread_degrees: float = 13.0

@onready var shoot_timer: Timer = $ShootTimer
@onready var muzzle: Marker2D = $Muzzle
@onready var hull: Polygon2D = $Visual/Hull

var dead: bool = false

func _ready() -> void:
	add_to_group("enemy")
	shoot_timer.timeout.connect(_on_shoot_timer_timeout)
	if can_shoot:
		# 三种颜色对应三种威胁：红色不还手、橙色会直射、紫色会瞄准你。
		# 不做颜色区分的话，“谁在瞄我”这件事玩家根本读不出来。
		hull.color = Color("7d3c98") if aims_at_player else Color("cc6b27")
		shoot_timer.start(first_shot_delay)

func _physics_process(delta: float) -> void:
	if dead:
		return
	position.y += speed * delta
	if global_position.y > get_viewport_rect().size.y + 64.0:
		escaped.emit()
		deactivate()
		queue_free()

func _on_shoot_timer_timeout() -> void:
	if dead or not can_shoot:
		return
	# 敌机进入画面后才开火，不在顶部 HUD 区域开火。
	if global_position.y > 105.0 and global_position.y < get_viewport_rect().size.y - 75.0:
		var base_direction: Vector2 = fire_direction()
		var shots: int = maxi(volley_count, 1)
		# 以基准方向为中心左右对称散开：单发时偏移恰好为 0，与旧行为逐值一致。
		for index in range(shots):
			var offset_degrees: float = (float(index) - float(shots - 1) * 0.5) * volley_spread_degrees
			shoot_requested.emit(
				muzzle.global_position,
				base_direction.rotated(deg_to_rad(offset_degrees)),
				bullet_speed
			)
	shoot_timer.start(shoot_interval)

func fire_direction() -> Vector2:
	# 单独抽成公开函数，是为了让“到底朝哪打”可以被直接断言，
	# 而不必靠观察弹道去猜。
	if not aims_at_player:
		return Vector2.DOWN
	# 用组查询拿玩家，而不是硬编码 /root/Main/Player 这类脆弱路径——
	# 项目本来就用组做节点间解耦（Player 在 _ready 里 add_to_group("player")）。
	var target: Node2D = get_tree().get_first_node_in_group("player")
	if target == null or not is_instance_valid(target):
		return Vector2.DOWN
	var to_target: Vector2 = target.global_position - muzzle.global_position
	if to_target.length_squared() < 0.01:
		return Vector2.DOWN
	return to_target.normalized()

func take_hit() -> bool:
	if dead:
		return false
	deactivate()
	destroyed.emit(score_value)
	queue_free()
	return true

func hit_player(target: Area2D) -> void:
	if dead or not is_instance_valid(target) or not target.has_method("take_damage"):
		return
	# 碰撞敌机不加分；即使玩家无敌，该敌机仍被消耗，避免堆叠伤害。
	deactivate()
	target.take_damage()
	queue_free()

func deactivate() -> void:
	dead = true
	visible = false
	set_physics_process(false)
	shoot_timer.stop()
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
