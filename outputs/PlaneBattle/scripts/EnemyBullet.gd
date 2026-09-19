extends Area2D
## Player 与 EnemyBullet 都可能收到信号，spent 使双向回调幂等。

@export var speed: float = 240.0
## 飞行方向。普通敌机一律正下方，Boss 的扇形齐射会给出带角度的方向。
## 弹体图形是上下左右对称的六边形，所以按方向旋转没有视觉意义，这里不转。
@export var direction: Vector2 = Vector2.DOWN
var spent: bool = false

func _ready() -> void:
	add_to_group("enemy_bullet")
	area_entered.connect(_on_area_entered)

func _physics_process(delta: float) -> void:
	if spent:
		return
	position += direction * speed * delta
	# 斜射后左右也会出界，三个方向都要判，否则会留下永不销毁的弹。
	var bounds: Vector2 = get_viewport_rect().size
	if global_position.y > bounds.y + 48.0 or global_position.x < -48.0 or global_position.x > bounds.x + 48.0:
		deactivate()
		queue_free()

func _on_area_entered(area: Area2D) -> void:
	if area.is_in_group("player"):
		hit_player(area)

func hit_player(target: Area2D) -> void:
	if spent or not is_instance_valid(target) or not target.has_method("take_damage"):
		return
	# 无敌只阻止扣血，不阻止弹药消耗，这是本原型的明确规则。
	deactivate()
	target.take_damage()
	queue_free()

func intercept() -> bool:
	# 被玩家子弹击落：与命中玩家走同一套消耗流程，只是不扣血。
	# 返回是否真的被击落，让调用方与测试能区分“已经被消耗过”的情况。
	if spent:
		return false
	deactivate()
	queue_free()
	return true

func deactivate() -> void:
	spent = true
	visible = false
	set_physics_process(false)
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
