extends Area2D
## 一颗子弹按 direction 直线飞行，最多击毁 pierce_left + 1 个敌机，
## 开启 intercepts 时还能击落敌弹；计分最终经 Enemy.destroyed 传给 Main。

@export var speed: float = 640.0
## 飞行方向。当前 Main 的弹道一律竖直向上，因此这里始终是默认值，图形旋转量恒为 0；
## 保留该属性是因为“能朝任意方向飞”是子弹本身的能力，改成斜射不必动这个脚本。
@export var direction: Vector2 = Vector2.UP
## 还能穿透几个敌机。0 表示命中即消耗，也就是未强化时的行为。
@export var pierce_left: int = 0
## 是否拦截敌弹。需要碰撞遮罩包含敌弹所在层（见 PlayerBullet.tscn 的 mask）。
@export var intercepts: bool = false
## 可视战斗区域的顶边：子弹升过这条线就销毁，因此打不到还没露头的敌机。
## 由 Main 统一赋值（规则归 Main），默认值等于顶部 HUD 色块的下沿。
@export var play_area_top: float = 90.0
## 追踪弹：为真时每帧朝"目标指示器"转向（游隼型）。由 Main 按当前战机设定。
@export var homing: bool = false
## 每秒最多转多少弧度。留上限是为了让追踪**不是瞬间锁定**：没有上限的话子弹出膛当帧
## 就会折成一条指向目标的直线，看起来像瞬移，也丢掉了"慢速弹"这个代价。
@export var homing_turn_rate: float = 5.0
## 弹体颜色。主弹幕是青色；追踪导弹由 Main 设成暖色，好让玩家一眼认出来。
## **用颜色属性而不是 modulate**：modulate 是乘法，青色弹体乘橙色只会得到浑浊的绿，
## 第一版就是这么写的，结果导弹在截图里几乎看不见——"看得见"这件事得用真的颜色去保证。
@export var body_color: Color = Color(0.02, 0.55, 0.67, 1)

var spent: bool = false

func _ready() -> void:
	add_to_group("player_bullet")
	area_entered.connect(_on_area_entered)
	# 颜色在 _ready 里应用：Main 按项目约定在 add_child 之前写好导出值。
	($Visual as Polygon2D).color = body_color
	# 机身图形朝上，所以按飞行方向旋转；direction 为正上方时旋转量恰好为 0。
	rotation = direction.angle() + PI * 0.5

func _physics_process(delta: float) -> void:
	if spent:
		return
	if homing:
		_steer_toward_target(delta)
	position += direction * speed * delta
	# 子弹只在**玩家看得见的战斗区域**内有效，离开就销毁。
	# 顶边取 play_area_top（顶部 HUD 的下沿）而不是 y=0：顶部栏盖住 0~90 这一段，
	# 敌机从 y=-48 出生后要在栏下走一段才会被玩家看见。早先子弹一直有效到 y=-48，
	# 于是能在“玩家根本看不见”的区域里把敌机打死，表现为**敌人刚露头就没了**。
	# 左右仍按屏幕边界处理；保留三个方向而不是只判上方，是因为子弹本身支持朝任意方向
	# 飞，只判 y 会留下永不销毁的子弹。
	var bounds: Vector2 = get_viewport_rect().size
	if global_position.y < play_area_top or global_position.x < -48.0 or global_position.x > bounds.x + 48.0:
		deactivate()
		queue_free()

func _steer_toward_target(delta: float) -> void:
	# 目标由一个共享的指示器提供（Main 每帧只算一次"最近的敌机"），子弹只做一次
	# O(1) 的组查询。若让每颗子弹各自遍历敌机，满配每秒 148 发会变成每秒几千次全表搜索。
	var marker: Node2D = get_tree().get_first_node_in_group("player_target")
	if marker == null or not is_instance_valid(marker):
		return
	var to_target: Vector2 = marker.global_position - global_position
	if to_target.length_squared() < 1.0:
		return
	var desired: Vector2 = to_target.normalized()
	var max_step: float = homing_turn_rate * delta
	var turn: float = clampf(direction.angle_to(desired), -max_step, max_step)
	direction = direction.rotated(turn)
	# 图形跟着弹道转，玩家才看得出"这发在拐弯"。平行弹幕时 direction 恒为正上方，
	# 旋转量因此恒为 0，与旧行为逐值一致。
	rotation = direction.angle() + PI * 0.5

func _on_area_entered(area: Area2D) -> void:
	if spent or not is_instance_valid(area) or area.is_queued_for_deletion():
		return
	# 拦截弹：一发换一发——击落敌弹的同时自己也消失。
	# 早先这里是“击落敌弹后本弹继续飞”，当时还把它当成优点写进了文档；但满配玩家每秒
	# 打出 148 发、铺成 11 条弹道时，那条规则等于给玩家一面**无限次拦截的盾**：
	# 敌方火力在到达玩家之前就被扫光，这是“后期一点威胁都没有”的成因之一。
	# 改成对等消耗后拦截依然有用（保住当前这条弹道），但不再是免费的。
	if intercepts and area.is_in_group("enemy_bullet") and area.has_method("intercept"):
		area.intercept()
		deactivate()
		queue_free()
		return
	if not area.is_in_group("enemy") or not area.has_method("take_hit"):
		return
	# Enemy.take_hit 的 dead 锁保证同一敌机只被击毁一次；如果这一击没打中
	# （敌机已被别的子弹击毁），就不消耗穿透，让本弹继续飞。
	if not area.take_hit():
		return
	if pierce_left > 0:
		pierce_left -= 1
		return
	deactivate()
	queue_free()

func deactivate() -> void:
	spent = true
	visible = false
	set_physics_process(false)
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
