extends Area2D
## Player 不直接改生命/分数，只发送命中与发射请求。

signal player_hit
signal shoot_requested(origin: Vector2)

@export var speed: float = 340.0
@export var shoot_cooldown: float = 0.16
@export var invulnerability_duration: float = 1.2
@export var screen_margin: Vector2 = Vector2(30.0, 36.0)
## 按住“低速模式”时的移速倍率。这是弹幕游戏的公平感基础之一：
## 需要精确走位时能主动降速，而不是只能靠微操键盘。
@export var focus_speed_scale: float = 0.5
## 触屏：指尖上方留这么多像素当飞机位置。少了手指会把飞机和它正前方那条弹道盖住。
@export var touch_lift: float = 64.0
## 触屏跟手的速度倍率。跟手速度 = max(移速, 距离 × 这个值)，因此是一条**指数逼近**：
##   · 手指离得远时跟得快（不会追不上），离得近时退回移速（"引擎强化"在手机上照样有意义）；
##   · 代价是**稳态滞后 = 手指速度 ÷ 倍率**——手指匀速划 500 像素/秒时，飞机会落后
##     500/14 ≈ 36 像素。这个数就是"跟手跟不跟得上"的全部秘密，调它就等于调手感。
@export var touch_follow_scale: float = 14.0

@onready var muzzle: Marker2D = $Muzzle
@onready var visual: Node2D = $Visual
@onready var hull: Polygon2D = $Visual/Hull
@onready var cockpit: Polygon2D = $Visual/Cockpit
@onready var engine: Polygon2D = $Visual/Engine
@onready var hitbox_hint: Node2D = $Visual/HitboxHint
@onready var hitbox_area: Polygon2D = $Visual/HitboxHint/Area

var active: bool = false
var invulnerable: bool = false
var cooldown_left: float = 0.0
var life_epoch: int = 0
var blink_tween: Tween
## 本帧是否按住低速键。仅用于显示与移动，不参与任何规则判定。
var focusing: bool = false
## 触屏状态：手指按住时飞机跟到指尖上方，并**自动持续射击**。
##
## 为什么要有触屏：本作原本只有键盘操作，而它要作为作品集链接发出去——面试官很可能
## 直接用手机点开（招聘方是手游公司）。三条约束都是踩过的常识，写在这里免得被改坏：
##   ① **只认 InputEventScreenTouch/Drag**。Godot 默认把触摸模拟成鼠标事件（反过来不会），
##      所以只处理触摸事件，桌面端用鼠标点界面时绝不会误拖飞机。
##   ② **跟手而不是瞬移**：直接赋坐标会让“引擎强化”这条能力在手机上彻底失效。
##   ③ 抬手必须立刻停火并清状态——否则游戏结束后手指一松，状态会留在上一局。
var touching: bool = false
## 触屏的目标位置（游戏内坐标）。公开而不是下划线私有：回归测试要能读它，
## 用来把“事件有没有换算对坐标”与“跟手逻辑本身对不对”分开验。
var touch_target: Vector2 = Vector2.ZERO

func _ready() -> void:
	add_to_group("player")
	area_entered.connect(_on_area_entered)
	_sync_hitbox_hint()

func _sync_hitbox_hint() -> void:
	# 判定范围的尺寸**直接从碰撞形状读**，不在场景里另写一份。
	# 一个与真实判定不符的提示比没有提示更糟——玩家会按错误的边界去躲。
	var shape: Shape2D = $CollisionShape2D.shape
	if shape is RectangleShape2D:
		var half: Vector2 = (shape as RectangleShape2D).size * 0.5
		hitbox_area.polygon = PackedVector2Array([
			Vector2(-half.x, -half.y), Vector2(half.x, -half.y),
			Vector2(half.x, half.y), Vector2(-half.x, half.y),
		])

func apply_ship(data: Dictionary) -> void:
	# 战机只决定**外形与配色**（武器行为由 Main 在生成子弹时设定，因为那属于规则）。
	# 数据整体来自 Main 的 SHIPS 表，Player 不自己养一份，避免两处各写一套然后不一致。
	if data.has("hull"):
		# 表里存的是 Vector2 数组字面量（const 里不能构造 PackedVector2Array），
		# 这里转一次即可。
		hull.polygon = PackedVector2Array(data["hull"])
	if data.has("hull_color"):
		hull.color = data["hull_color"]
	if data.has("cockpit_color"):
		cockpit.color = data["cockpit_color"]
	if data.has("engine_color"):
		engine.color = data["engine_color"]

func reset_for_game(spawn_position: Vector2) -> void:
	life_epoch += 1
	_stop_blink()
	global_position = spawn_position
	cooldown_left = 0.0
	invulnerable = false
	active = true
	visible = true
	# 跨局边界：上一局残留的触屏状态不能带进新一局（会变成“没碰屏幕却在开火”）。
	touching = false
	touch_target = spawn_position
	set_physics_process(true)
	set_deferred("monitoring", true)
	set_deferred("monitorable", true)

func deactivate() -> void:
	active = false
	invulnerable = false
	focusing = false
	touching = false
	hitbox_hint.visible = false
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
	# 低速模式：按住时移速乘 focus_speed_scale，并显示真实判定范围。
	# 显示的是**碰撞形状本身**（比机身轮廓小一圈），所以玩家看到的就是会被打中的边界，
	# 而不是一个更小的“判定点”——后者会让人以为自己比实际更难被击中。
	focusing = Input.is_action_pressed("focus")
	hitbox_hint.visible = focusing
	if touching:
		# 触屏优先于键盘方向：手指按着的时候，跟手就是玩家唯一的意图。
		var gap: Vector2 = touch_target - position
		var follow_speed: float = maxf(speed, gap.length() * touch_follow_scale)
		position = position.move_toward(touch_target, follow_speed * delta)
	else:
		position += direction * speed * (focus_speed_scale if focusing else 1.0) * delta
	var size: Vector2 = get_viewport_rect().size
	position.x = clampf(position.x, screen_margin.x, size.x - screen_margin.x)
	position.y = clampf(position.y, screen_margin.y + 82.0, size.y - screen_margin.y)
	cooldown_left = maxf(0.0, cooldown_left - delta)
	# 触屏按住 = 一直开火：手机上再单开一个开火键只会占掉本来就小的屏幕。
	if (Input.is_action_pressed("shoot") or touching) and cooldown_left <= 0.0:
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

func _unhandled_input(event: InputEvent) -> void:
	# 只处理**触摸**事件。Godot 默认把触摸模拟成鼠标事件（emulate_mouse_from_touch），
	# 反过来不会，所以桌面端用鼠标点按钮不会误拖飞机——这是能“只认触摸”的前提。
	if event is InputEventScreenTouch:
		var touch: InputEventScreenTouch = event
		touching = touch.pressed
		if touch.pressed:
			set_touch_target(touch.position)
	elif event is InputEventScreenDrag:
		set_touch_target((event as InputEventScreenDrag).position)

func set_touch_target(pointer: Vector2) -> void:
	# 参数是**屏幕坐标**（事件原样给的那个）：引擎已经按屏幕变换把它换算成游戏内坐标了。
	# 指尖上方 touch_lift 像素：手指本身会盖住飞机和它正前方那条弹道。
	# 这里不做边界裁剪——越界时由 _physics_process 里那条统一的 clampf 把飞机按在战斗区内，
	# 于是“手指滑出屏幕边缘”表现为飞机贴边，而不是飞出去或抖一下。
	touch_target = pointer - Vector2(0.0, touch_lift)

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
