extends Area2D
## 聚焦型的光束：一条持续存在、竖直向上的致命光柱。
##
## 它**不是子弹**：没有飞行时间，敌机一进入这条竖线，就会在下一次结算时被击毁——
## 这是它与标准型最本质的区别（标准型的子弹要飞 0.5~1 秒才到，敌机早就移开了）。
## 代价是覆盖：每条光柱只有 `beam_width` 像素宽。
##
## 几何与伤害都从尺寸推导，视觉、碰撞、结算共用同一组数字，不会三处各写一份。

## 伤害结算间隔。普通敌机 1 点血、一次结算即毁；对多血 Boss 它等价于
## “每秒伤害 = 1 / tick_interval”，所以这个值会直接进 `Main.player_dps_proxy()`。
@export var tick_interval: float = 0.08
## 光柱宽度与长度（长度由 Main 按战斗区顶边算出，光柱不会伸到顶部信息栏后面）。
@export var beam_width: float = 10.0
@export var beam_length: float = 600.0
## 是否拦截敌弹。与子弹的“拦截弹”是同一个能力在这台战机上的表现形式。
@export var intercepts: bool = true

var _cooldown: float = 0.0

func _ready() -> void:
	add_to_group("player_beam")
	_apply_geometry()

func refresh(new_width: float, new_length: float, new_interval: float, new_intercepts: bool) -> void:
	# 每帧由 Main 送来的是**一整套运行参数**：尺寸、结算间隔、是否拦截。
	#
	# 结算间隔与拦截标志必须每帧同步，不能只在创建时设一次：玩家是**在局中**拿到
	# “弹速强化 / 拦截弹”的，而光柱是开局就存在并一直存在的。只认创建时那份值的话，
	# 升级之后屏幕上的光柱会继续按旧节奏结算、继续不拦敌弹——玩家会认为升级没生效。
	# 这与“参数必须有唯一来源”是同一条纪律：值只有一处写，就不会分叉。
	tick_interval = maxf(new_interval, 0.01)
	intercepts = new_intercepts
	# 尺寸只在真的变了才重建多边形与形状——
	# 每帧重建碰撞形状会白白制造对象，也会在物理回调期间改动碰撞世界。
	if is_equal_approx(new_width, beam_width) and is_equal_approx(new_length, beam_length):
		return
	beam_width = maxf(new_width, 1.0)
	beam_length = maxf(new_length, 1.0)
	_apply_geometry()

func _apply_geometry() -> void:
	# **亮芯的宽度就是真实判定宽度**（碰撞形状同样是 beam_width），外面那圈更宽的
	# 半透明光是纯装饰。这条与 Player 的判定提示是同一条纪律：看得见的"实体"必须
	# 等于真正会造成伤害的范围，否则玩家会照着一条错误的宽度去瞄。
	var half_width: float = beam_width * 0.5
	($Visual/Glow as Polygon2D).polygon = PackedVector2Array([
		Vector2(-half_width * 2.0, -beam_length), Vector2(half_width * 2.0, -beam_length),
		Vector2(half_width * 2.0, 0.0), Vector2(-half_width * 2.0, 0.0),
	])
	($Visual/Core as Polygon2D).polygon = PackedVector2Array([
		Vector2(-half_width, -beam_length), Vector2(half_width, -beam_length),
		Vector2(half_width, 0.0), Vector2(-half_width, 0.0),
	])
	var shape := RectangleShape2D.new()
	shape.size = Vector2(beam_width, beam_length)
	var collider: CollisionShape2D = $CollisionShape2D
	collider.shape = shape
	collider.position = Vector2(0.0, -beam_length * 0.5)

func _physics_process(delta: float) -> void:
	_cooldown -= delta
	if _cooldown > 0.0:
		return
	_cooldown = maxf(tick_interval, 0.01)
	_strike()

func _strike() -> void:
	# 轮询重叠而不是靠 area_entered：光柱是**持续存在**的，敌机可能一直待在柱内，
	# 而 area_entered 只会在进入的那一刻触发一次。伤害本来就该按固定节奏结算。
	for area in get_overlapping_areas():
		if not is_instance_valid(area) or area.is_queued_for_deletion():
			continue
		if area.is_in_group("enemy") and area.has_method("take_hit"):
			area.take_hit()
		elif intercepts and area.is_in_group("enemy_bullet") and area.has_method("intercept"):
			area.intercept()
