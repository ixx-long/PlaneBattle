extends Area2D
## Player 不直接改生命/分数，只发送命中与发射请求。

signal player_hit
signal shoot_requested(origin: Vector2)

@export var speed: float = 340.0
@export var shoot_cooldown: float = 0.16
@export var invulnerability_duration: float = 1.2
@export var screen_margin: Vector2 = Vector2(30.0, 36.0)

@onready var muzzle: Marker2D = $Muzzle
@onready var visual: Node2D = $Visual

var active: bool = false
var invulnerable: bool = false
var cooldown_left: float = 0.0
var life_epoch: int = 0
var blink_tween: Tween

func _ready() -> void:
	add_to_group("player")
	area_entered.connect(_on_area_entered)

func reset_for_game(spawn_position: Vector2) -> void:
	life_epoch += 1
	_stop_blink()
	global_position = spawn_position
	cooldown_left = 0.0
	invulnerable = false
	active = true
	visible = true
	set_physics_process(true)
	set_deferred("monitoring", true)
	set_deferred("monitorable", true)

func deactivate() -> void:
	active = false
	invulnerable = false
	life_epoch += 1
	_stop_blink()
	visible = false
	set_physics_process(false)
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)

func _physics_process(delta: float) -> void:
	if not active:
		return
	var direction: Vector2 = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	position += direction * speed * delta
	var size: Vector2 = get_viewport_rect().size
	position.x = clampf(position.x, screen_margin.x, size.x - screen_margin.x)
	position.y = clampf(position.y, screen_margin.y + 82.0, size.y - screen_margin.y)
	cooldown_left = maxf(0.0, cooldown_left - delta)
	if Input.is_action_pressed("shoot") and cooldown_left <= 0.0:
		cooldown_left = shoot_cooldown
		shoot_requested.emit(muzzle.global_position)
	# 补充重叠检查：以后扩展持续危险区时，无敌结束仍重叠也能处理。
	# 当前原型的敌机和敌弹触碰即消耗，无敌期间接触也会消耗。
	# 重开后的第一帧 monitoring 可能仍等待 set_deferred 生效。
	if not invulnerable and monitoring:
		for area in get_overlapping_areas():
			_on_area_entered(area)
			if invulnerable or not active:
				break

func _on_area_entered(area: Area2D) -> void:
	if not active or not is_instance_valid(area) or area.is_queued_for_deletion():
		return
	if area.is_in_group("enemy") or area.is_in_group("enemy_bullet"):
		# 两种危险物统一提供 hit_player；内部负责去重和销毁。
		if area.has_method("hit_player"):
			area.hit_player(self)

func take_damage() -> bool:
	if not active or invulnerable:
		return false
	# 必须先置位再 emit，同物理帧的多个危险物只扣一次生命。
	invulnerable = true
	player_hit.emit()
	# 信号同步执行，Main 可能已经在回调中结束游戏。
	if active:
		_start_invulnerability(life_epoch)
	return true

func _start_invulnerability(ticket: int) -> void:
	_stop_blink()
	blink_tween = create_tween().set_loops()
	blink_tween.tween_property(visual, "modulate:a", 0.25, 0.08)
	blink_tween.tween_property(visual, "modulate:a", 1.0, 0.08)
	await get_tree().create_timer(invulnerability_duration, false, true).timeout
	# 防止旧局 await 恢复后篡改新局的无敌状态。
	if ticket != life_epoch or not active:
		return
	invulnerable = false
	_stop_blink()

func _stop_blink() -> void:
	if blink_tween != null and blink_tween.is_valid():
		blink_tween.kill()
	blink_tween = null
	visual.modulate.a = 1.0
