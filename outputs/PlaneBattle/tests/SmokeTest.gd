extends SceneTree
## 独立自动测试：godot --headless --path . --script res://tests/SmokeTest.gd

const SAVE_FILE: String = "user://save.cfg"
## 对局记录文件。这里独立写一份字面量，并在断言里核对它与 Main 的常量一致：
## 两处都写死但不核对的话，路径一改测试就会对着一个空文件“通过”。
const RUN_LOG_FILE: String = "user://runs.jsonl"

## 看门狗上限。整轮回归正常只要二十秒上下；这个值必须**明显小于**外层
## validate_project 的 90 秒子进程超时，否则超时先由外层触发，看门狗根本没机会
## 报出真正的原因——日志还会停留在上一次运行的内容上，非常误导。
const WATCHDOG_SECONDS: float = 55.0

var game
var failures: int = 0
var checks: int = 0
var _finished: bool = false
## 捕获 Boss 齐射方向的中转站。用一个成员变量 + 具名函数，而不是闭包捕获局部数组：
## 闭包对局部变量的捕获语义容易让人看错，具名函数在这里更直白。
var _captured_directions: Array[Vector2] = []

func capture_boss_shot(_origin: Vector2, direction: Vector2, _speed: float) -> void:
	_captured_directions.append(direction)

func _initialize() -> void:
	_run.call_deferred()
	# GDScript 没有 try/catch：_run() 里任何一处运行时错误（例如访问一个已经不存在的
	# 属性）都会让协程当场中断，末尾的 quit() 永远执行不到，进程就一直挂着——外层
	# 只能等到超时，而且报错是一条看不出原因的 TimeoutExpired。看门狗把“挂死”
	# 变成一条明确的错误信息和非零退出码。
	create_timer(WATCHDOG_SECONDS).timeout.connect(_on_watchdog_timeout)

func _on_watchdog_timeout() -> void:
	if _finished:
		return
	push_error("SmokeTest 超过 %.0f 秒仍未结束：_run() 很可能中途因运行时错误中断了" % WATCHDOG_SECONDS)
	quit(1)

func check(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("PASS: ", message)
	else:
		failures += 1
		push_error("FAIL: " + message)

func settle(frames: int = 4) -> void:
	for index in range(frames):
		await physics_frame
		await process_frame

func remove_save() -> void:
	# 最高分存档会跨运行残留，不清掉的话断言就依赖上一次执行结果，测试不再可重复。
	var directory: DirAccess = DirAccess.open("user://")
	if directory == null:
		return
	if not directory.file_exists("save.cfg"):
		return
	var error: Error = directory.remove("save.cfg")
	if error != OK:
		# 清不掉存档说明测试前提不成立，必须让整次运行失败，不能带着脏状态继续断言。
		push_error("无法清除测试存档：%s" % error_string(error))

func write_save(content: String) -> bool:
	var storage: FileAccess = FileAccess.open(SAVE_FILE, FileAccess.WRITE)
	if storage == null:
		return false
	storage.store_string(content)
	storage.close()
	return true

func remove_run_log() -> void:
	# 与最高分存档同理：对局记录会跨运行残留，不清掉的话行数断言就依赖上一次的结果。
	var directory: DirAccess = DirAccess.open("user://")
	if directory == null or not directory.file_exists("runs.jsonl"):
		return
	var error: Error = directory.remove("runs.jsonl")
	if error != OK:
		push_error("无法清除对局记录：%s" % error_string(error))

func write_run_log(content: String) -> bool:
	var storage: FileAccess = FileAccess.open(RUN_LOG_FILE, FileAccess.WRITE)
	if storage == null:
		return false
	storage.store_string(content)
	storage.close()
	return true

func read_run_log() -> Array:
	# 只挑出能解析成字典的行：这正是游戏侧容错行为的镜像，
	# 用它才能断言“写坏的行确实被丢掉了”，而不是仅仅没崩。
	# 解析同样走游戏侧的 is_json_object()，免得测试自己再引入一条 JSON 报错日志。
	var records: Array = []
	if not FileAccess.file_exists(RUN_LOG_FILE):
		return records
	var reader: FileAccess = FileAccess.open(RUN_LOG_FILE, FileAccess.READ)
	if reader == null:
		return records
	while not reader.eof_reached():
		var line: String = reader.get_line().strip_edges()
		if line == "" or not game.is_json_object(line):
			continue
		records.append(JSON.parse_string(line))
	reader.close()
	return records

func force_choose(id: String) -> void:
	# 直接进入抉择状态并选定指定能力，用于逐项验证效果，避开随机选项带来的不确定性。
	game.state = game.GameState.LEVEL_UP
	var single: Array[Dictionary] = [game.upgrade_by_id(id)]
	game.offers = single
	game.choose_upgrade(0)

func silence_sfx() -> void:
	# 音效池里可能还留着上一段测试的声音，断言“这一次触发没有发声”之前必须先清干净。
	for sfx_voice in game._sfx_players:
		sfx_voice.stop()

func sfx_used(stream: AudioStream) -> bool:
	for sfx_voice in game._sfx_players:
		if sfx_voice.playing and sfx_voice.stream == stream:
			return true
	return false

func clear_arena() -> void:
	game.enemy_timer.stop()
	game._clear_entities()
	await settle()

func make_enemy(at: Vector2, points: int = 10):
	var enemy = load("res://scenes/Enemy.tscn").instantiate()
	enemy.position = at
	enemy.speed = 0.0
	enemy.score_value = points
	enemy.destroyed.connect(game.add_score)
	# 与真实生成路径保持一致：不接这一条，夹具里的敌机飞出去就不会计为逃敌。
	enemy.escaped.connect(game._on_enemy_escaped)
	game.actors.add_child(enemy)
	return enemy

func make_enemy_bullet(at: Vector2):
	var bullet = load("res://scenes/EnemyBullet.tscn").instantiate()
	bullet.position = at
	bullet.speed = 0.0
	game.actors.add_child(bullet)
	return bullet

func _run() -> void:
	# 先清掉存档，让下面的初始状态断言等价于“首次运行”。
	remove_save()
	game = load("res://scenes/Main.tscn").instantiate()
	root.add_child(game)
	await settle()
	check(game.state == game.GameState.READY, "initial READY state")
	check(game.lives == 3 and game.score == 0, "initial lives and score")
	check(game.best_score == 0, "没有存档时最高分从 0 开始")
	check(game.hud.best_label.text == "最高  000000", "没有纪录时 HUD 显示 0")

	# 固定矩形 UI 的排版回归：以后新增节点或改文案都不能溢出或互相重叠。
	var status_label: Label = game.hud.status_label
	var best_label: Label = game.hud.best_label
	var message_label: Label = game.hud.message_label
	var width_ok: bool = status_label.get_minimum_size().x > 0.0 and best_label.get_minimum_size().x > 0.0
	check(width_ok, "字体度量可用（否则下面的溢出检查会空转通过）")
	print(
		"LAYOUT: 状态 %.0f/%.0f, 最高 %.0f/%.0f, 文案高 %.0f/%.0f"
		% [
			status_label.get_minimum_size().x, status_label.size.x,
			best_label.get_minimum_size().x, best_label.size.x,
			message_label.get_minimum_size().y, message_label.size.y
		]
	)
	check(status_label.get_minimum_size().x <= status_label.size.x, "状态行文字不超出矩形宽度")
	check(best_label.get_minimum_size().x <= best_label.size.x, "最高分文字不超出矩形宽度")
	check(status_label.position.x + status_label.size.x <= best_label.position.x, "状态行与最高分不重叠")
	check(message_label.get_minimum_size().y <= message_label.size.y, "开始界面文案不超出矩形高度")

	# --- 视觉收尾的回归守卫 ---
	# 这些项原本是“看着不对但没人管”的观感问题。既然改了，就用断言钉住，
	# 否则下次动布局或改场景时很容易又退回去，而这类退化不会有任何报错。
	# 1) 升级面板必须紧贴最后一张卡。固定高度曾经让最常见的 4 选 1 底部空出约 120 像素。
	var four_offers: Array[Dictionary] = []
	var five_offers: Array[Dictionary] = []
	for index in range(game.UPGRADES.size()):
		if index < 4:
			four_offers.append(game.UPGRADES[index])
		if index < 5:
			five_offers.append(game.UPGRADES[index])
	var level_up_panel: Panel = game.hud.level_up_panel
	game.hud.show_level_up(3, four_offers)
	var gap_four: float = level_up_panel.offset_bottom - game.hud.upgrade_cards[3].offset_bottom
	check(gap_four > 0.0 and gap_four < 40.0, "4 选 1 时升级面板紧贴最后一张卡，不留大块空白")
	game.hud.show_level_up(3, five_offers)
	var gap_five: float = level_up_panel.offset_bottom - game.hud.upgrade_cards[4].offset_bottom
	check(gap_five > 0.0 and gap_five < 40.0, "5 选 1 时面板同样紧贴最后一张卡")
	check(
		game.hud.upgrade_cards[4].offset_bottom < level_up_panel.offset_bottom,
		"第 5 张卡不越出面板下沿"
	)
	game.hud.hide_level_up()

	# 2) Boss 轮廓不能是一条平顶直线，且机体顶边与顶部血条之间要留出空隙。
	# 原来的 Hull 顶边是 (44,-40) → (-44,-40) 一条 88 像素的水平线，看着像块板；
	# 而 boss_hold_y=150 时机体顶边正好顶到血条上。
	var boss_probe = load("res://scenes/Boss.tscn").instantiate()
	var hull: Polygon2D = boss_probe.get_node("Visual/Hull")
	var hull_top: float = 0.0
	var top_levels := {}
	for point in hull.polygon:
		hull_top = minf(hull_top, point.y)
		if point.y < -20.0:
			top_levels[snappedf(point.y, 0.1)] = true
	check(top_levels.size() >= 3, "Boss 顶部轮廓不是平直横线（至少有三种不同高度）")
	check(
		game.tuning.boss_hold_y + hull_top > game.hud.boss_bar.offset_bottom + 15.0,
		"Boss 机体顶边与顶部血条之间留有空隙"
	)
	boss_probe.free()

	# 3) 受伤红闪不能重到盖住画面——受伤那一下恰恰是最需要看清弹幕的时刻。
	check(
		game.hud.damage_flash_alpha <= 0.30,
		"受伤红闪峰值不超过 0.30，不至于遮住正在飞来的弹幕"
	)

	# 4) 爆炸要有存在感。
	var explosion_probe = load("res://scenes/Explosion.tscn").instantiate()
	check(explosion_probe.amount >= 18, "爆炸粒子数量足够，不会一眼看不见")
	check(explosion_probe.scale_amount_max >= 2.0, "爆炸粒子尺寸足够大")
	explosion_probe.free()

	# 5) 背景要有层次：竖向渐变 + 多级航道线，而不是一块纯色配三条线。
	# 全部由内置资源程序生成，不引入任何图片文件。
	var background = game.get_node("Background")
	check(
		background is TextureRect and background.texture != null,
		"背景是竖向渐变贴图，而不是一块纯色"
	)
	check(game.get_node("FlightLines").get_child_count() >= 5, "航道线有层次（不少于 5 条）")

	# --- 战机选择 ---
	# 战机是**开局选定**的形态，不进抽卡池：不会稀释 16 项能力的抽取，也不会出现
	# "什么都拿一点"导致覆盖形状与输出同时膨胀。
	check(game.SHIPS.size() >= 2, "至少有两台可选战机")
	var ship_ids := {}
	var ships_well_formed := true
	for entry in game.SHIPS:
		for key in ["id", "name", "detail", "seeker_interval", "seeker_speed_scale",
				"seeker_turn_rate", "seeker_lock_range", "hull",
				"hull_color", "cockpit_color", "engine_color"]:
			if not entry.has(key):
				ships_well_formed = false
		ship_ids[entry["id"]] = true
	check(ships_well_formed, "每台战机都带齐 id/名称/说明/武器行为/外形与配色")
	check(ship_ids.size() == game.SHIPS.size(), "战机 id 互不重复")
	check(game.ship_id == "parallel", "默认战机是平行弹幕")
	check(not game.ship_has_seekers(), "默认战机不发射追踪导弹")

	# 开始界面：按钮数量、选中态、说明文字都要与实际数据一致。
	check(game.hud.ship_buttons.size() >= game.SHIPS.size(), "开始界面预留了足够的战机按钮")
	var visible_ship_buttons: int = 0
	for button in game.hud.ship_buttons:
		if button.visible:
			visible_ship_buttons += 1
	check(visible_ship_buttons == game.SHIPS.size(), "只显示实际存在的战机按钮，不多不少")
	var selected_button_pressed: bool = game.hud.ship_buttons[game.selected_ship_index()].button_pressed
	check(selected_button_pressed, "当前战机的按钮处于按下状态（ButtonGroup 保证只按下一个）")
	check(
		game.hud.ship_detail.text == str(game.SHIPS[game.selected_ship_index()]["detail"]),
		"开始界面显示的是当前战机的说明"
	)
	# 按钮按实际台数动态排开：写死三档坐标的话，加第四台时新按钮会叠在旧的上面。
	var ships_laid_out := true
	for index in range(game.SHIPS.size()):
		var button: Button = game.hud.ship_buttons[index]
		if button.offset_left < game.hud.message_panel.offset_left \
				or button.offset_right > game.hud.message_panel.offset_right \
				or button.offset_top < game.hud.message_panel.offset_top \
				or button.offset_bottom > game.hud.message_panel.offset_bottom:
			ships_laid_out = false
		if index > 0:
			var previous: Button = game.hud.ship_buttons[index - 1]
			if button.offset_left < previous.offset_right:
				ships_laid_out = false
	check(ships_laid_out, "战机按钮都在面板内且互不重叠")

	# 换战机：换外形与配色、记住选择、未知 id 被拒绝。
	var default_hull_color: Color = game.player.hull.color
	check(game.set_ship("homing"), "可以切到追踪弹战机")
	check(game.ship_id == "homing" and game.ship_has_seekers(), "切换后武器行为跟着变")
	check(game.player.hull.color != default_hull_color, "切换后玩家外形配色跟着变")
	check(
		game.player.hull.polygon.size() == (game.SHIPS[1]["hull"] as Array).size(),
		"切换后玩家的机体轮廓换成了该战机的形状"
	)
	check(not game.set_ship("not_a_ship"), "未知战机 id 会被拒绝")
	check(game.ship_id == "homing", "被拒绝的切换不会改动当前战机")
	# 界面的说明文字必须跟着变。这条断言守的是一个真实发生过的缺陷：点击按钮只改了
	# 状态、`ship_detail` 纹丝不动（它只在 show_start() 里赋值过），玩家会以为没点到。
	check(
		game.hud.ship_detail.text == str(game.SHIPS[game.selected_ship_index()]["detail"]),
		"换战机后开始界面的说明文字立刻跟着更新"
	)
	check(
		game.hud.ship_buttons[game.selected_ship_index()].button_pressed,
		"换战机后选中态也立刻跟着更新"
	)
	game.select_ship(99)
	check(game.ship_id == "homing", "越界的按钮下标不会改动当前战机")
	# 选择要记住：否则每局开局都要重选一遍。
	var ship_probe = load("res://scenes/Main.tscn").instantiate()
	root.add_child(ship_probe)
	await settle()
	check(ship_probe.ship_id == "homing", "新实例从磁盘读回上次选的战机")
	ship_probe.queue_free()
	await settle()
	check(game.set_ship("parallel"), "切回默认战机")
	check(game.player.hull.color == default_hull_color, "切回后配色恢复")

	check(game.hud.start_button.visible and not game.player.active, "start menu and inactive player")
	check(game.enemy_timer.is_stopped(), "no spawns before start")
	for action in ["move_left", "move_right", "move_up", "move_down", "shoot", "restart", "focus", "pause"]:
		check(InputMap.has_action(action), "input action: " + action)
	# 键码不靠肉眼核对：拿 project.godot 里写的值与引擎常量比。
	# 这两个数字（4194325 / 4194305）是手写进 .cfg 的，写错不会有任何报错，
	# 只会表现成“按键没反应”，所以必须由测试来对。
	var focus_bound_to_shift := false
	for event in InputMap.action_get_events("focus"):
		if event is InputEventKey and (event as InputEventKey).physical_keycode == KEY_SHIFT:
			focus_bound_to_shift = true
	check(focus_bound_to_shift, "低速模式绑定在 Shift 上（与引擎的 KEY_SHIFT 常量一致）")
	var pause_bound_to_escape := false
	for event in InputMap.action_get_events("pause"):
		if event is InputEventKey and (event as InputEventKey).physical_keycode == KEY_ESCAPE:
			pause_bound_to_escape = true
	check(pause_bound_to_escape, "暂停绑定在 Esc 上（与引擎的 KEY_ESCAPE 常量一致）")
	game.hud.start_button.pressed.emit()
	await settle()
	check(game.state == game.GameState.PLAYING and game.player.active, "start button starts game")
	check(not game.hud.start_button.visible and not game.hud.overlay.visible, "playing HUD")
	check(game.player.collision_layer == 1 and game.player.collision_mask == 10, "player layer and mask")
	game.enemy_timer.stop()

	var before: Vector2 = game.player.position
	Input.action_press("move_left")
	Input.action_press("move_up")
	await create_timer(0.12).timeout
	var diagonal: Vector2 = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	check(is_equal_approx(diagonal.length(), 1.0), "input vector normalized")
	Input.action_release("move_left")
	Input.action_release("move_up")
	check(game.player.position.x < before.x and game.player.position.y < before.y, "diagonal movement")
	game.player.position = Vector2(-100, -100)
	await settle()
	check(game.player.position.x >= 30 and game.player.position.y >= 118, "left and top bounds")
	game.player.position = Vector2(1000, 1000)
	await settle()
	check(game.player.position.x <= 450 and game.player.position.y <= 764, "right and bottom bounds")
	game.player.position = Vector2(240, 650)
	# 低速模式与判定范围提示。判定提示的尺寸直接取自碰撞形状，所以这里也对着形状验，
	# 而不是对着场景里写死的数字——那两处一旦漂移，提示就会开始说谎。
	var player_shape: Shape2D = game.player.get_node("CollisionShape2D").shape
	check(player_shape is RectangleShape2D, "玩家碰撞形状是矩形（判定提示据此绘制）")
	var hint: Polygon2D = game.player.get_node("Visual/HitboxHint/Area")
	var hint_width: float = 0.0
	var hint_height: float = 0.0
	for point in hint.polygon:
		hint_width = maxf(hint_width, absf(point.x) * 2.0)
		hint_height = maxf(hint_height, absf(point.y) * 2.0)
	check(
		is_equal_approx(hint_width, (player_shape as RectangleShape2D).size.x)
			and is_equal_approx(hint_height, (player_shape as RectangleShape2D).size.y),
		"判定提示的尺寸与真实碰撞形状完全一致（不会显示一个更小的假判定点）"
	)
	check(not game.player.hitbox_hint.visible, "不按低速键时不显示判定范围")
	game.player.position = Vector2(240, 600)
	Input.action_press("move_right")
	game.player._physics_process(0.1)
	var normal_step: float = game.player.position.x - 240.0
	game.player.position = Vector2(240, 600)
	Input.action_press("focus")
	game.player._physics_process(0.1)
	var focus_step: float = game.player.position.x - 240.0
	check(game.player.hitbox_hint.visible, "按住低速键时显示判定范围")
	check(
		is_equal_approx(focus_step, normal_step * game.player.focus_speed_scale),
		"低速模式把移速按倍率减慢"
	)
	check(focus_step > 0.0 and focus_step < normal_step, "低速仍然是移动，只是更慢")
	Input.action_release("focus")
	Input.action_release("move_right")
	game.player.position = Vector2(240, 650)
	Input.action_press("shoot")
	await create_timer(0.21).timeout
	Input.action_release("shoot")
	check(get_nodes_in_group("player_bullet").size() >= 2, "hold shoot repeats after cooldown")
	await clear_arena()

	# --- 触屏操作（Web / 手机版的入口）---
	# 本作原本只有键盘。它要作为作品集链接发出去，就得能在手机上玩——招聘方是手游公司，
	# 面试官很可能直接用手机点开。这里验三条最容易做坏的性质：**跟手、按住自动开火、抬手就停**。
	#
	# 事件用 Input.parse_input_event 真注入，而不是直接调内部函数：要验的正是"触摸事件真的
	# 会走到 Player 的 _unhandled_input"这一条链路。**但坐标不能想当然**：引擎会先把窗口
	# 坐标按屏幕变换换算成游戏内坐标（480×800 的 canvas_items 拉伸），而无头模式里窗口是
	# **0×0**、这个变换会退化成 8%——实测一次触摸会被换算到一万像素以外，飞机直接被夹到
	# 右下角。所以期望值一律用引擎自己的 `get_screen_transform()` 反算，
	# 与坐标换算无关的移动逻辑则单独用游戏内坐标验。
	game.set_ship("parallel")
	game.player.position = Vector2(240.0, 650.0)
	var pointer := Vector2(120.0, 420.0)
	var lift: float = game.player.touch_lift
	var logical: Vector2 = game.get_viewport().get_screen_transform().affine_inverse() * pointer
	var press := InputEventScreenTouch.new()
	press.position = pointer
	press.pressed = true
	Input.parse_input_event(press)
	await settle(4)
	check(game.player.touching, "按下屏幕后进入触屏操作状态")
	check(
		game.player.touch_target.distance_to(logical - Vector2(0.0, lift)) < 1.0,
		"触点按引擎的屏幕变换换算成游戏内坐标，再抬高 touch_lift（手指不盖住飞机与弹道）"
	)
	var bullets_before: int = get_nodes_in_group("player_bullet").size()
	await create_timer(0.25).timeout
	check(
		get_nodes_in_group("player_bullet").size() > bullets_before,
		"按住屏幕会自动持续射击（手机上不用再单开一个开火键占屏幕）"
	)
	# 移动逻辑单独验：给一个战斗区内的目标，看飞机是否跟过去（这条与坐标换算无关）。
	# 等 0.4 秒而不是几帧：跟手是**指数逼近**（跟手速度 = 距离 × touch_follow_scale），
	# 距离按 exp(-倍率 × 时间) 衰减——0.1 秒只走完六成，指望它立刻到位是我第一版算错了。
	game.player.position = Vector2(240.0, 650.0)
	game.player.set_touch_target(Vector2(120.0, 420.0 + lift))
	await create_timer(0.4).timeout
	check(
		game.player.position.distance_to(Vector2(120.0, 420.0)) < 8.0,
		"飞机会跟到触点指的位置（是跟手，不是原地不动）"
	)
	# 越界：手指滑出屏幕，飞机应该贴边而不是跟着飞出去。
	game.player.set_touch_target(Vector2(-500.0, 420.0 + lift))
	await settle(12)
	var bounds: Vector2 = game.get_viewport_rect().size
	check(
		game.player.position.x >= game.player.screen_margin.x
			and game.player.position.x <= bounds.x - game.player.screen_margin.x,
		"手指滑出屏幕后飞机被按在战斗区内（越界的手指不会把它带出去）"
	)
	# 拖拽事件也要认：换一个触点，目标必须跟着更新。
	var drag := InputEventScreenDrag.new()
	drag.position = Vector2(360.0, 300.0)
	Input.parse_input_event(drag)
	await settle(2)
	var dragged: Vector2 = game.get_viewport().get_screen_transform().affine_inverse() * drag.position
	check(
		game.player.touch_target.distance_to(dragged - Vector2(0.0, lift)) < 1.0,
		"拖动时目标跟着手指更新（拖拽事件也认）"
	)
	var release := InputEventScreenTouch.new()
	release.position = drag.position
	release.pressed = false
	Input.parse_input_event(release)
	await settle(4)
	check(not game.player.touching, "抬手后退出触屏操作状态")
	await clear_arena()
	var quiet_before: int = get_nodes_in_group("player_bullet").size()
	await create_timer(0.3).timeout
	check(
		get_nodes_in_group("player_bullet").size() == quiet_before,
		"抬手之后不再自动开火（否则手机上会一直响个没完）"
	)
	check(not game.player.hitbox_hint.visible, "触屏不会顺带打开键盘那套低速判定提示")
	# 提示文案必须与实际输入方式一致：让触屏玩家去找 WASD 是典型的"说明书说谎"。
	# 直接改显示状态来验，而不是读当前那句提示——此刻屏幕上挂的是哪一句取决于
	# 前面跑过哪些用例（升级面板、结算面板都会改写它），那样的断言会随测试顺序漂移。
	var real_touch_device: bool = game.hud.touch_device
	game.hud.touch_device = true
	game.hud.show_start(game.SHIPS, game.selected_ship_index())
	var touch_hint: String = game.hud.hint_label.text
	game.hud.touch_device = false
	game.hud.show_start(game.SHIPS, game.selected_ship_index())
	var keyboard_hint: String = game.hud.hint_label.text
	game.hud.touch_device = real_touch_device
	check(
		not touch_hint.contains("WASD") and keyboard_hint.contains("WASD"),
		"操作提示跟着输入方式走：触屏设备上不会叫玩家去按 WASD"
	)
	check(
		game.hud.touch_device == DisplayServer.is_touchscreen_available(),
		"HUD 的触屏判定直接取引擎的能力查询，不自己猜平台"
	)
	await clear_arena()

	# --- 游隼型的追踪导弹 ---
	# **主弹幕一律照直飞，追踪是另一路武器。** 这是被数据逼出来的结构：
	# 若每发子弹都追踪，满配每秒 13.5 次射击会全部命中，实测把敌方弹幕打到 0；
	# 而"只在近距离锁定"虽然保住了威胁，却小到玩家看不见（真人试玩反馈"没有追踪效果"）。
	# 量清边界确认两者直接冲突（射程 110 → 15.33 达标、150 → 11.67 掉线），
	# 于是改成：主弹幕照直 + 少量、全屏锁定、明显可辨的导弹，用发射节奏控平衡。
	game.set_ship("homing")
	game.player.position = Vector2(240, 650)
	var target_enemy = make_enemy(Vector2(200, 300))
	game._physics_process(0.0)
	var marker: Node2D = game.get_tree().get_first_node_in_group("player_target")
	check(
		marker != null and marker.global_position.distance_to(target_enemy.global_position) < 1.0,
		"追踪导弹是全屏锁定的：远处的敌机也会被指示器锁定"
	)
	# 主弹幕必须仍然是直的，否则弹幕墙与拦截弹都会被破坏。
	# 注意追踪导弹和主弹幕在同一个组里，所以这里**按 homing 标志区分**，不能整组断言。
	game._on_player_shoot_requested(game.player.position)
	await settle(2)
	var stream_ok := true
	var stream_count: int = 0
	for entity in get_nodes_in_group("player_bullet"):
		if entity.homing:
			continue
		stream_count += 1
		if not entity.direction.is_equal_approx(Vector2.UP):
			stream_ok = false
	check(stream_ok and stream_count > 0, "游隼型的主弹幕照直飞，不追踪（弹幕墙与拦截弹因此不受影响）")

	# 追踪导弹：按节奏单独发射，带追踪标志、并且真的会拐弯。
	# 用"调用前后各数一次"而不是绝对数量：await 期间引擎自己也会推进物理帧、
	# 可能已经发过几发，写死数量会莫名其妙地失败。
	var before_seekers: int = 0
	for entity in get_nodes_in_group("player_bullet"):
		if entity.homing:
			before_seekers += 1
	game._seeker_cooldown = 0.0
	game._physics_process(0.016)
	var after_seekers: int = 0
	for entity in get_nodes_in_group("player_bullet"):
		if entity.homing:
			after_seekers += 1
	check(after_seekers == before_seekers + 1, "追踪导弹按节奏发射（一次只发一发，不是每发主弹幕都追踪）")
	var seeker = null
	for entity in get_nodes_in_group("player_bullet"):
		if entity.homing:
			seeker = entity
	if seeker != null:
		var before_angle: float = seeker.direction.angle()
		await settle(12)
		check(
			seeker.direction.angle() != before_angle,
			"追踪导弹在飞行中改变了方向（玩家能看见它在拐弯）"
		)
		check(seeker.scale.x > 1.0, "追踪导弹比主弹幕更大，玩家一眼能认出来")
	# 节奏由数据决定：冷却未走完时不再发射。
	game._seeker_cooldown = 99.0
	var guarded_before: int = get_nodes_in_group("player_bullet").size()
	game._physics_process(0.016)
	check(
		get_nodes_in_group("player_bullet").size() == guarded_before,
		"冷却没走完时不会额外发射追踪导弹（节奏就是平衡支点）"
	)
	await clear_arena()

	# 平行弹幕战机不该有任何追踪导弹。
	game.set_ship("parallel")
	check(not game.ship_has_seekers(), "标准型没有追踪导弹")
	game._seeker_cooldown = 0.0
	game._physics_process(0.016)
	var plain_seekers: int = 0
	for entity in get_nodes_in_group("player_bullet"):
		if entity.homing:
			plain_seekers += 1
	check(plain_seekers == 0, "标准型不会发射追踪导弹")
	check(
		game.get_tree().get_first_node_in_group("player_target") == null,
		"标准型会释放目标指示器（没有东西需要它）"
	)
	await clear_arena()

	# --- 聚焦型的光束 ---
	# 光束**不是子弹**：它是一条持续存在的竖直致命光柱，敌机一进入就在下一次结算时
	# 被击毁（没有飞行时间）。代价是覆盖窄，所以它反而比标准型更"有威胁"。
	game.set_ship("focus")
	check(game.ship_uses_beam(), "聚焦型使用光束")
	game._physics_process(0.016)
	check(
		game.beams.size() == game.lane_count(),
		"光束条数等于车道数（多发与侧翼炮在这台战机上含义不变）"
	)
	game.player.position = Vector2(240, 650)
	game._physics_process(0.016)
	var lane_offsets: Array[float] = game._lane_offsets()
	var beams_placed := true
	for index in range(game.beams.size()):
		var beam_node = game.beams[index]
		if not is_equal_approx(beam_node.global_position.x, 240.0 + lane_offsets[index]):
			beams_placed = false
	check(beams_placed, "光束按车道偏移排开，并且跟随玩家")
	# 光柱长度 = min(射程, 到战斗区顶边的距离)，两条边界各管一件事，所以要分别钉住。
	# 射程是真人反馈"太赖皮"之后加的代价：没有它，玩家可以永远待在屏幕底部把上半屏扫干净。
	var beam_range: float = float(game.current_ship()["beam_range"])
	var beam_top: float = game.beams[0].global_position.y - game.beams[0].beam_length
	check(
		is_equal_approx(game.beams[0].beam_length, beam_range),
		"玩家在屏幕下方时，光柱长度就是它的射程（够不到战斗区顶边）"
	)
	check(
		beam_top > game.play_area_top,
		"（对照）此时光柱上端确实在战斗区顶边之下：射程上限真的在起作用"
	)
	# 换成玩家贴近顶部：长度改由战斗区顶边决定，射程再大也不会伸到信息栏后面。
	var standing_y: float = game.player.position.y
	game.player.position = Vector2(240.0, game.play_area_top + 40.0)
	game._physics_process(0.016)
	check(
		is_equal_approx(game.beams[0].global_position.y - game.beams[0].beam_length, game.play_area_top),
		"玩家贴近顶部时，光柱止于战斗区顶边（不会伸到信息栏后面去杀还没露头的敌机）"
	)
	check(
		is_equal_approx(game.beams[0].beam_length, game.player.position.y - 34.0 - game.play_area_top),
		"（对照）此时长度由顶边而不是射程决定：两条边界互不干扰"
	)
	game.player.position = Vector2(240.0, standing_y)
	game._physics_process(0.016)
	# 看得见的"实体"必须等于真正会造成伤害的范围：亮芯宽度 = 碰撞形状宽度 = beam_width。
	# 与 Player 的判定提示是同一条纪律——一个与真实判定不符的提示比没有提示更糟。
	var core: Polygon2D = game.beams[0].get_node("Visual/Core")
	var core_width: float = absf(core.polygon[1].x - core.polygon[0].x)
	var shape_width: float = (game.beams[0].get_node("CollisionShape2D") as CollisionShape2D).shape.size.x
	check(
		is_equal_approx(core_width, game.beams[0].beam_width)
		and is_equal_approx(shape_width, game.beams[0].beam_width),
		"光柱亮芯的宽度等于真实判定宽度（不画一条比判定更宽或更窄的假光柱）"
	)
	# 瞬间命中：放进光柱的敌机会被击毁，不需要等子弹飞过去。
	# 用光柱**实测**的横坐标而不是我设定的 240：断言依赖的应该是“敌机在不在柱子里”，
	# 而不是“我以为玩家站在哪”。
	var beam_x: float = game.beams[0].global_position.x
	var in_beam = make_enemy(Vector2(beam_x, 300))
	await settle(12)
	check(not is_instance_valid(in_beam), "敌机进入光柱后被击毁（没有飞行时间）")
	# 代价：光柱之外的敌机完全不受影响。
	var outside_x: float = beam_x + 190.0 if beam_x + 190.0 <= 440.0 else beam_x - 190.0
	var out_of_beam = make_enemy(Vector2(outside_x, 300))
	await settle(12)
	check(is_instance_valid(out_of_beam), "光柱之外的敌机不受影响（覆盖窄就是这台战机的代价）")
	# 射程是这台战机的**第二项代价**，同样写成成对断言：够不着 / 上去就够得着。
	# 只断言"够不着"会漏掉另一种坏法——射程短到玩家贴上去也打不到，那样这台战机就废了。
	var high_enemy = make_enemy(Vector2(beam_x, 150.0))
	await settle(12)
	check(
		is_instance_valid(high_enemy),
		"玩家在屏幕下方时，光柱够不到屏幕顶部的敌机（射程短是真的代价，不是装饰）"
	)
	game.player.position = Vector2(240.0, 400.0)
	await settle(12)
	check(
		not is_instance_valid(high_enemy),
		"玩家主动升上去之后，同一架敌机立刻被光柱烧掉（贴近换输出，位置选择有来有回）"
	)
	game.player.position = Vector2(240.0, standing_y)
	await settle(2)
	# 敌弹在光柱里会被清掉——这是"拦截弹"在这台战机上的表现形式。
	# 拦截弹要在**光柱已经存在之后**拿到：光柱是从开局一直存在的，参数不会自己回头同步。
	game.xp = 0
	force_choose("interceptor")
	game._physics_process(0.016)
	check(game.beams[0].intercepts, "局中拿到拦截弹后，已存在的光柱立刻开始拦敌弹")
	var beam_blocked = make_enemy_bullet(Vector2(beam_x, 300))
	await settle(12)
	check(not is_instance_valid(beam_blocked), "光柱会击落柱内的敌弹（拦截弹在这台战机上仍有效）")
	# 光束战机不生成子弹。
	game._on_player_shoot_requested(game.player.position)
	await settle(3)
	var beam_ship_bullets: int = 0
	for entity in get_nodes_in_group("player_bullet"):
		beam_ship_bullets += 1
	check(beam_ship_bullets == 0, "光束战机不生成子弹（输出由光柱承担）")
	# 弹速强化映射为“充能更快”：缩短结算间隔。没有映射的话它在这台战机上就是死选项。
	var ship_base_tick: float = float(game.current_ship()["beam_tick_interval"])
	var live_beam = game.beams[0]
	var tick_before: float = live_beam.tick_interval
	game.xp = 0
	force_choose("velocity")
	game._physics_process(0.016)
	check(
		game.beam_tick_interval() < ship_base_tick,
		"弹速强化在光束战机上缩短结算间隔（充能更快），不是死选项"
	)
	check(
		live_beam.tick_interval < tick_before,
		"局中拿到弹速强化后，已存在的光柱立刻换到新节奏（不是只对新光柱生效）"
	)
	check(game.beam_tick_interval() >= 0.03, "结算间隔有下限，堆再多也不会变成 0")
	# 每秒伤害必须按光柱口径折算进 Boss 血量公式，否则 Boss 会按一个偏低的输出算血量、
	# 死得比 boss_target_seconds 快得多。
	check(
		is_equal_approx(game.player_dps_proxy(), float(game.lane_count()) / game.beam_tick_interval()),
		"光束的每秒伤害按“光柱条数 × 每秒结算次数”折算，Boss 血量才不会算低"
	)
	# 穿透弹则确实没有意义：光柱本来就穿透整列敌人。**不提供**胜过提供一个选了没变化的。
	check(not game.is_upgrade_offered("pierce"), "穿透弹对光束是死选项，因此不提供")
	# 换回非光束战机后光柱必须消失。
	check(not game.beams.is_empty(), "（前置）此时光柱确实存在，下面的清空断言才有意义")
	game.set_ship("parallel")
	game._physics_process(0.016)
	check(game.beams.is_empty(), "换回标准型后光柱消失")
	check(game.is_upgrade_offered("pierce"), "（对照）标准型仍然提供穿透弹")
	await clear_arena()

	# 前面那些敌机是夹具（为了让指示器有目标、也为了腾地方），但它们走的是真实的
	# 击毁路径、会加分。后面的计分断言要的是干净起点，所以这里显式复位——
	# 与"连击会累积得分倍率，夹具测试前必须清零"是同一类隔离。
	game.score = 0
	game.combo = 0
	game.xp = 0

	var enemy = make_enemy(Vector2(120, 250))
	var bullet = load("res://scenes/PlayerBullet.tscn").instantiate()
	bullet.position = enemy.position
	bullet.speed = 0.0
	game.actors.add_child(bullet)
	await settle(8)
	check(game.score == 10, "real Area2D bullet hit awards score")
	check(not is_instance_valid(enemy) and not is_instance_valid(bullet), "hit removes enemy and bullet")
	var elite = make_enemy(Vector2(120, 250), 20)
	check(elite.take_hit(), "enemy accepts first hit")
	check(not elite.take_hit(), "enemy ignores duplicate hit")
	check(game.score == 30, "duplicate hit does not duplicate score")
	await clear_arena()

	game.player.invulnerability_duration = 0.10
	var projectile = make_enemy_bullet(game.player.position)
	await settle(5)
	check(game.lives == 2, "enemy bullet decrements lives exactly once")
	check(not is_instance_valid(projectile), "enemy bullet consumed after contact")
	check(game.player.invulnerable, "damage starts invulnerability")
	var extra = make_enemy_bullet(Vector2(40, 200))
	extra.hit_player(game.player)
	check(game.lives == 2, "invulnerability prevents second damage")
	await create_timer(0.16).timeout
	check(not game.player.invulnerable, "invulnerability timer expires")
	await clear_arena()
	var contact = make_enemy(game.player.position)
	await settle(5)
	check(game.lives == 1, "enemy body contact decrements life")
	check(game.score == 30, "ramming does not award score")
	check(not is_instance_valid(contact), "ramming consumes enemy")
	await create_timer(0.16).timeout
	game.player.take_damage()
	check(game.lives == 0 and game.state == game.GameState.GAME_OVER, "zero lives ends game")
	check(game.enemy_timer.is_stopped() and not game.player.active, "game over stops action")
	check(game.hud.restart_button.visible, "restart button shown")
	await settle()
	check(game.actors.get_child_count() == 0, "game over clears arena")
	game.add_score(100)
	check(game.score == 30, "no scoring after game over")
	game.hud.restart_button.pressed.emit()
	await settle()
	game.enemy_timer.stop()
	check(game.score == 0 and game.lives == 3 and game.difficulty_level == 1, "restart resets score life difficulty")
	check(game.player.active and not game.player.invulnerable, "restart resets player")

	# 用真正的 InputEventKey 验证项目物理按键映射。
	var key := InputEventKey.new()
	key.physical_keycode = KEY_R
	key.pressed = true
	game.game_over()
	Input.parse_input_event(key)
	await settle()
	check(game.state == game.GameState.PLAYING, "physical R restarts game")
	key.pressed = false
	Input.parse_input_event(key)
	game.enemy_timer.stop()

	game.survival_time = 99999.0
	game._process(0.0)
	check(
		game.difficulty_level == game.effective_max_level(),
		"难度随时间上升并封顶在当前有效上限"
	)
	# --- 撞到下限之后不许再变平 ---
	# 真人第一局的数据暴露了这个缺陷：那局难度 25（21 级来自计时），但 L18→L25 的最后
	# 84 秒里所有压力参数都是常数，玩家反馈"中段像在等死"。原因是"线性 + 下限"的写法
	# 撞底即冻结。下面这组断言把这个行为锁死。
	check(
		game.get_spawn_interval() < game.tuning.spawn_interval_floor,
		"越过下限后生成间隔仍在收紧（尾段生效），而不是停在几何下限上"
	)
	check(
		game.get_spawn_interval() > game.tuning.spawn_interval_floor * 0.25,
		"尾段收紧有节制，不会把整波压进同一帧"
	)
	# 线性段必须与旧公式逐值一致：前期手感不做任何改动，改的只有撞底之后的尾段。
	var linear_segment_intact := true
	for probed_level in range(1, 13):
		game.difficulty_level = probed_level
		var linear_expected: float = game.tuning.spawn_interval_base \
			- float(probed_level - 1) * game.tuning.spawn_interval_decay
		if not is_equal_approx(game.get_spawn_interval(), linear_expected):
			linear_segment_intact = false
	check(linear_segment_intact, "难度 1~12 的生成间隔与线性公式完全一致（前期手感未被尾段影响）")
	# 关键回归：高难度之间必须持续收紧，任何两档"一样难"都是平台期复发的信号。
	game.difficulty_level = 20
	var density_at_20: float = game.get_spawn_interval()
	game.difficulty_level = 30
	var density_at_30: float = game.get_spawn_interval()
	game.difficulty_level = 40
	var density_at_40: float = game.get_spawn_interval()
	check(density_at_30 < density_at_20, "难度 30 的生成密度高于难度 20（中段不再变平）")
	check(density_at_40 < density_at_30, "难度 40 的密度仍高于难度 30（尾段不会二次冻死）")
	game.difficulty_level = 1

	# B1：难度上限随玩家等级放宽——这是根治“玩家一直在变强、敌人早就封顶”的关键。
	# 难度只是时间的函数，玩家等级一旦超前就再也追不上，中后期只剩玩家单方面变强。
	game.level = 1
	var cap_at_level_one: int = game.effective_max_level()
	game.level = 11
	var cap_at_level_eleven: int = game.effective_max_level()
	check(
		cap_at_level_eleven == cap_at_level_one + 10 * int(game.tuning.max_level_per_player_level),
		"难度上限随玩家等级同步放宽"
	)
	check(cap_at_level_eleven > int(game.tuning.max_level), "放宽后的上限高于参数表的基准上限")
	game.level = 1

	# B3：瞄准射击。比例随波次与难度上升，并有上限。
	# 第一波就已经有瞄准——此前三波之后才出现，导致开局几乎无压力。
	game.difficulty_level = 1
	game.wave_index = 0
	var first_wave_aim: float = game.aim_ratio()
	check(first_wave_aim > 0.0, "第一波就有敌机瞄准玩家")
	game.wave_index = 4
	check(game.aim_ratio() > first_wave_aim, "精锐波的瞄准比例高于第一波")
	game.difficulty_level = int(game.tuning.max_level)
	check(
		is_equal_approx(game.aim_ratio(), game.tuning.aim_ratio_cap),
		"最高难度下瞄准比例夹到上限"
	)
	game.difficulty_level = 1
	game.wave_index = 0

	# B3 的行为面：瞄准型敌机必须真的朝玩家打，而不是照样竖直向下；
	# 而且要用不同颜色标出来，否则玩家读不出“谁在瞄我”。
	game.player.position = Vector2(400, 600)
	var aiming_enemy = load("res://scenes/Enemy.tscn").instantiate()
	aiming_enemy.aims_at_player = true
	aiming_enemy.can_shoot = true
	aiming_enemy.position = Vector2(120, 200)
	game.actors.add_child(aiming_enemy)
	await settle(1)
	var aim_vector: Vector2 = aiming_enemy.fire_direction()
	check(
		aim_vector.normalized().is_equal_approx(
			(game.player.position - aiming_enemy.muzzle.global_position).normalized()
		),
		"瞄准型敌机的射击方向确实指向玩家"
	)
	check(aim_vector.dot(Vector2.DOWN) < 0.99, "瞄准型敌机不是竖直向下打")
	check(
		aiming_enemy.hull.color != Color("cc6b27"),
		"瞄准型敌机换成另一种颜色，玩家能读出威胁"
	)
	await clear_arena()
	var straight_enemy = make_enemy(Vector2(120, 200))
	check(
		straight_enemy.fire_direction().is_equal_approx(Vector2.DOWN),
		"普通敌机的弹道仍然是竖直向下，旧行为没有被改坏"
	)
	await clear_arena()

	game._create_enemy(game.run_id)
	await settle()
	var generated = get_nodes_in_group("enemy")
	check(generated.size() == 1, "enemy spawn creates instance")
	if not generated.is_empty():
		check(generated[0].position.x >= 38 and generated[0].position.x <= 442, "random spawn horizontal bounds")
	await clear_arena()
	var shooter = make_enemy(Vector2(90, 180))
	shooter.can_shoot = true
	shooter.shoot_requested.connect(game._on_enemy_shoot_requested)
	shooter._on_shoot_timer_timeout()
	await settle()
	check(get_nodes_in_group("enemy_bullet").size() == 1, "shooting enemy emits bullet")
	await clear_arena()

	# --- 齐射：玩家火力把威胁掐死在源头时的解法 ---
	# 基准实测：满配玩家每秒 148 发、11 条弹道，敌机常在开火窗口之前就被打死，
	# 每架平均只开 0.56~0.79 枪（按存活时间本该 2~4 枪）。密度、速度、开火概率乘的
	# 都是“能开几枪”，那个数已经被压到接近 0；齐射改成由**首发**决定总输出，绕开了它。
	check(game.volley_count_for(1) == 1, "难度 1 的敌机一次打 1 发")
	check(game.volley_count_for(10) == 1, "难度 10 仍是一次 1 发")
	check(game.volley_count_for(11) == 2, "难度 11 起一次打 2 发")
	check(game.volley_count_for(21) == 3, "难度 21 起一次打 3 发")
	check(
		game.volley_count_for(999) == game.tuning.volley_cap,
		"齐射发数封顶，不会无限增长"
	)

	_captured_directions.clear()
	var volley_enemy = make_enemy(Vector2(240, 300))
	volley_enemy.can_shoot = true
	volley_enemy.aims_at_player = false
	volley_enemy.volley_count = 3
	volley_enemy.volley_spread_degrees = game.tuning.volley_spread_degrees
	# 两条连接缺一不可：一条把方向记下来供断言，另一条走真实路径把子弹生成出来。
	# make_enemy 只连了 destroyed / escaped，不连 shoot_requested——只连前者的话
	# “3 发变成 3 颗敌弹”会因为根本没生成而失败（我第一版就是这么写错的）。
	volley_enemy.shoot_requested.connect(game._on_enemy_shoot_requested)
	volley_enemy.shoot_requested.connect(capture_boss_shot)
	volley_enemy._on_shoot_timer_timeout()
	await settle()
	check(_captured_directions.size() == 3, "一次齐射真的打出 3 发")
	check(get_nodes_in_group("enemy_bullet").size() == 3, "齐射的 3 发都变成了场上的敌弹")
	if _captured_directions.size() == 3:
		check(
			_captured_directions[1].is_equal_approx(Vector2.DOWN),
			"齐射的中间一发保持基准方向（直射机就是正下方）"
		)
		check(
			not _captured_directions[0].is_equal_approx(_captured_directions[2]),
			"齐射左右两发方向不同，不是三发叠在一起"
		)
		# 左右对称：两发相对基准方向的夹角大小相等、方向相反。
		check(
			is_equal_approx(
				_captured_directions[0].angle_to(Vector2.DOWN),
				-_captured_directions[2].angle_to(Vector2.DOWN)
			),
			"齐射相对基准方向左右对称散开"
		)
	_captured_directions.clear()
	await clear_arena()
	# 单发时偏移必须恰好为 0，否则“齐射”会悄悄改掉所有敌人的既有弹道。
	_captured_directions.clear()
	var single_enemy = make_enemy(Vector2(240, 300))
	single_enemy.can_shoot = true
	single_enemy.aims_at_player = false
	single_enemy.volley_count = 1
	single_enemy.shoot_requested.connect(game._on_enemy_shoot_requested)
	single_enemy.shoot_requested.connect(capture_boss_shot)
	single_enemy._on_shoot_timer_timeout()
	await settle()
	check(
		_captured_directions.size() == 1 and _captured_directions[0].is_equal_approx(Vector2.DOWN),
		"单发敌机的弹道与旧行为逐值一致（正下方，无偏移）"
	)
	_captured_directions.clear()
	await clear_arena()

	var exited = make_enemy(Vector2(80, 900))
	var exited_bullet = make_enemy_bullet(Vector2(80, 900))
	var exited_player_bullet = load("res://scenes/PlayerBullet.tscn").instantiate()
	exited_player_bullet.position = Vector2(80, -90)
	game.actors.add_child(exited_player_bullet)
	await settle()
	check(not is_instance_valid(exited) and not is_instance_valid(exited_bullet) and not is_instance_valid(exited_player_bullet), "offscreen objects are freed")

	# 延迟请求与协程在换局后必须失效。
	game.player.invulnerability_duration = 0.20
	game.player.take_damage()
	game._on_player_shoot_requested(Vector2(100, 400))
	game.game_over()
	game.restart_game()
	game.enemy_timer.stop()
	game.player.invulnerability_duration = 0.60
	game.player.take_damage()
	await create_timer(0.30).timeout
	check(game.actors.get_child_count() == 0, "stale deferred spawns discarded")
	check(game.player.invulnerable, "old timer cannot cancel new run invulnerability")
	await create_timer(0.40).timeout
	check(not game.player.invulnerable, "new run timer expires normally")

	# 最高分持久化。此时 state=PLAYING、score=0，且前面的 game_over 已把 30 分写成纪录。
	game.score = 140
	game.game_over()
	check(game.best_score == 140, "结算时用本局分数刷新纪录")
	check(FileAccess.file_exists(SAVE_FILE), "刷新纪录后存档已写入磁盘")
	check(game.hud.best_label.text == "最高  000140", "HUD 最高分跟随新纪录")
	check(game.hud.message_label.text.contains("新纪录"), "破纪录时结算界面提示新纪录")
	check(message_label.get_minimum_size().y <= message_label.size.y, "破纪录结算文案不超出矩形高度")

	game.restart_game()
	game.enemy_timer.stop()
	game.score = 40
	game.game_over()
	check(game.best_score == 140, "低分不覆盖既有纪录")
	check(not game.hud.message_label.text.contains("新纪录"), "未破纪录时结算界面不提示新纪录")
	check(message_label.get_minimum_size().y <= message_label.size.y, "普通结算文案不超出矩形高度")

	# 新实例从磁盘读回纪录，才是真正的端到端持久化验证。
	var reloaded = load("res://scenes/Main.tscn").instantiate()
	root.add_child(reloaded)
	await settle()
	check(reloaded.best_score == 140, "新实例从磁盘读回纪录")
	check(reloaded.hud.best_label.text == "最高  000140", "新实例 HUD 显示读回的纪录")
	reloaded.queue_free()
	await settle()

	# 存档被外部改坏：必须退回 0 而不是污染计分。本项会故意触发一次 WARNING。
	check(write_save("[records]\nbest_score=\"不是数字\"\n"), "测试可以写入 user:// 存档")
	var damaged = load("res://scenes/Main.tscn").instantiate()
	root.add_child(damaged)
	await settle()
	check(damaged.best_score == 0, "存档内容无效时退回 0（故意触发一次 WARNING）")
	check(damaged.state == damaged.GameState.READY, "存档损坏不影响正常开局")
	damaged.queue_free()
	await settle()
	remove_save()

	# --- 等级与能力系统 ---
	# 前面的用例结束时 state 为 GAME_OVER，先完整重开一局。
	game.restart_game()
	game.enemy_timer.stop()
	check(game.level == 1 and game.xp == 0, "开局等级 1、经验 0")
	check(game.hud.xp_bar.max_value == float(game.xp_required(1)), "经验条上限等于本级所需经验")
	check(game.hud.level_label.text == "Lv 01", "等级标签显示当前等级")

	# 击毁敌机是唯一经验来源，数值等于该敌机的分值。
	var reward_enemy = make_enemy(Vector2(120, 250))
	reward_enemy.take_hit()
	check(game.xp == 10, "击毁普通敌机获得等于其分值的经验")
	await clear_arena()

	# 经验满格进入抉择：世界必须暂停，并给出三个互不重复的选项。
	game.xp = game.xp_required(game.level) - 10
	var trigger = make_enemy(Vector2(120, 250))
	trigger.take_hit()
	check(game.state == game.GameState.LEVEL_UP, "经验满格进入升级抉择状态")
	check(game.get_tree().paused, "升级抉择期间游戏世界暂停")
	check(game.hud.level_up_panel.visible, "升级面板已显示")
	check(game.offers.size() == game.max_offers, "选项数等于当前上限")
	check(
		game.hud.level_up_hint.text.contains("1 – %d" % game.offers.size()),
		"面板提示的键位范围与实际选项数一致"
	)
	check(game.max_offers == 4, "基础选项数为 4")
	check(game.UPGRADES.size() == 16, "能力池共 16 项")
	var offer_ids: Array[String] = []
	for offer in game.offers:
		offer_ids.append(offer["id"])
	var all_unique := true
	for index in range(offer_ids.size()):
		for other in range(index + 1, offer_ids.size()):
			if offer_ids[index] == offer_ids[other]:
				all_unique = false
	check(all_unique, "所有选项互不重复")

	# 选择后：应用能力、升级、扣经验、解除暂停。
	var chosen_id: String = offer_ids[0]
	game.choose_upgrade(0)
	check(game.level == 2, "选择能力后等级 +1")
	check(game.xp == 0, "升级后扣除本级所需经验")
	check(game.upgrade_stacks.get(chosen_id, 0) == 1, "所选能力层数 +1")
	check(not game.get_tree().paused, "选择后解除暂停")
	check(not game.hud.level_up_panel.visible, "选择后升级面板收起")
	check(game.state == game.GameState.PLAYING, "选择后回到游戏进行状态")

	# 卡片文案是动态的，而且选项随机：必须逐项确认每一种文案都放得下，不能只验静态标签。
	# 同时用 5 张卡（幸运补给后的上限）验一遍下沿不越界，避免只测基础 4 张时看着没问题。
	var cards_fit := true
	var cards: Array[Button] = game.hud.upgrade_cards
	for upgrade in game.UPGRADES:
		var same_repeated: Array[Dictionary] = []
		for _slot in range(cards.size()):
			same_repeated.append(upgrade)
		game.hud.show_level_up(1, same_repeated)
		for card in cards:
			if card.visible and card.get_minimum_size().x > card.size.x:
				cards_fit = false
	check(cards_fit, "所有能力的卡片文案都不超出卡片宽度")
	var last_card: Button = cards[cards.size() - 1]
	var panel_bottom: float = game.hud.level_up_panel.position.y + game.hud.level_up_panel.size.y
	check(last_card.position.y + last_card.size.y <= panel_bottom, "第 5 张卡片不超出升级面板下沿")
	check(cards[0].position.y >= game.hud.level_up_title.position.y + game.hud.level_up_title.size.y, "首张卡片不压住标题")
	game.hud.hide_level_up()

	# 逐项验证 16 项能力真的改变了对局参数，而不是只存在于文案里。
	var cooldown_before: float = game.player.shoot_cooldown
	force_choose("rapid_fire")
	check(game.player.shoot_cooldown < cooldown_before, "射速强化：射击冷却下降")

	var speed_before: float = game.player.speed
	force_choose("thruster")
	check(game.player.speed > speed_before, "引擎强化：移动速度上升")

	var invulnerability_before: float = game.player.invulnerability_duration
	force_choose("shield")
	check(game.player.invulnerability_duration > invulnerability_before, "护盾延时：无敌时间变长")

	var count_before: int = game._bullet_count
	force_choose("multishot")
	check(game._bullet_count == count_before + 1, "火力增援：每次多射一发")

	var bullet_speed_before: float = game._bullet_speed
	force_choose("velocity")
	check(game._bullet_speed > bullet_speed_before, "弹速强化：子弹速度上升")

	var pierce_before: int = game._bullet_pierce
	force_choose("pierce")
	check(game._bullet_pierce == pierce_before + 1, "穿透弹：穿透计数 +1")

	game.lives = 3
	force_choose("repair")
	check(game.lives == 4, "应急补给：生命 +1")

	var multiplier_before: float = game.xp_multiplier
	force_choose("insight")
	check(game.xp_multiplier > multiplier_before, "战术洞察：经验倍率上升")

	var wing_before: int = game._wing_pairs
	force_choose("wing_shot")
	check(game._wing_pairs == wing_before + 1, "侧翼炮：追加平行弹道对数 +1")

	force_choose("caliber")
	check(game._bullet_scale > 1.0, "弹体增幅：子弹体积变大")

	force_choose("interceptor")
	check(game._bullet_intercepts, "拦截弹：开启拦截标志")

	game.lives = 3
	var lives_cap_before: int = game.max_lives
	force_choose("vitality")
	check(game.max_lives == lives_cap_before + 1 and game.lives == 4, "机体强化：上限与当前生命同时 +1")

	var score_multiplier_before: float = game.score_multiplier
	force_choose("bounty")
	check(game.score_multiplier > score_multiplier_before, "战果结算：得分倍率上升")

	var difficulty_step_before: float = game.level_step_seconds
	force_choose("steady")
	check(game.level_step_seconds > difficulty_step_before, "战术从容：难度上升间隔变长")

	var offers_before: int = game.max_offers
	force_choose("fortune")
	check(game.max_offers == offers_before + 1, "幸运补给：升级选项数 +1")

	# 到这里为止的比较都是相对的，所以不会被随机升级干扰。下面开始是行为夹具测试，
	# 必须先把所有能力倍率清回基线，否则随机抽到的“战果结算”“战术洞察”会让
	# 绝对数值断言漂移——这正是同一类顺序依赖缺陷的来源。
	game._reset_upgrades()

	# 经验倍率必须真的作用在获取上。
	game.xp_multiplier = 1.25
	game.xp = 0
	var boosted = make_enemy(Vector2(120, 250), 20)
	boosted.take_hit()
	check(game.xp == 25, "经验倍率 1.25 时 20 分敌机给 25 经验")
	await clear_arena()

	# 得分倍率同理，而且它不能顺带加快升级。
	game.score_multiplier = 1.5
	game.xp_multiplier = 1.0
	game.combo = 0
	game.xp = 0
	game.score = 0
	var bounty_target = make_enemy(Vector2(120, 250), 10)
	bounty_target.take_hit()
	check(game.score == 15, "得分倍率 1.5 时 10 分敌机给 15 分")
	check(game.xp == 10, "得分倍率不影响经验获取，升级速度不会被顺带拉快")
	await clear_arena()

	# 紧急清屏：只清敌弹，不动敌机与玩家自己的子弹。
	game.score_multiplier = 1.0
	var survivor = make_enemy(Vector2(120, 250))
	var threat_a = make_enemy_bullet(Vector2(80, 300))
	var threat_b = make_enemy_bullet(Vector2(400, 300))
	var friendly = load("res://scenes/PlayerBullet.tscn").instantiate()
	friendly.position = Vector2(240, 620)
	friendly.speed = 0.0
	game.actors.add_child(friendly)
	await settle()
	force_choose("purge")
	await settle()
	check(not is_instance_valid(threat_a) and not is_instance_valid(threat_b), "紧急清屏：场上敌弹被清除")
	check(is_instance_valid(survivor), "紧急清屏：敌机不受影响")
	check(is_instance_valid(friendly), "紧急清屏：自己的子弹不受影响")
	await clear_arena()

	# 多发能力必须在真实射击流程里生成对应数量的子弹，且弹道竖直、只靠水平偏移排开。
	game.xp = 0
	game._bullet_count = 3
	game._wing_pairs = 0
	var fan_origin := Vector2(240, 600)
	game.player.position = Vector2(240, 650)
	game._on_player_shoot_requested(fan_origin)
	await settle()
	var spawned := get_nodes_in_group("player_bullet")
	var offsets: Array[float] = []
	var all_vertical := true
	for fired in spawned:
		offsets.append(fired.global_position.x - fan_origin.x)
		if not fired.direction.is_equal_approx(Vector2.UP) or not is_zero_approx(fired.rotation):
			all_vertical = false
	offsets.sort()
	check(spawned.size() == 3, "多发能力真的生成 3 颗子弹")
	check(all_vertical, "多发弹全部竖直向上，不再向四周发散")
	check(
		offsets.size() == 3
		and is_equal_approx(offsets[0], -game.bullet_spacing)
		and is_zero_approx(offsets[1])
		and is_equal_approx(offsets[2], game.bullet_spacing),
		"多发弹按固定水平间距平行排开且关于中心对称（实际 %s）" % str(offsets)
	)
	await clear_arena()

	# 侧翼炮：主弹道两侧各加一条平行弹道，方向同样竖直。
	game._bullet_count = 1
	game._wing_pairs = 1
	var wing_origin := Vector2(240, 600)
	game._on_player_shoot_requested(wing_origin)
	await settle()
	var winged := get_nodes_in_group("player_bullet")
	var wing_offsets: Array[float] = []
	var wings_vertical := true
	for fired in winged:
		wing_offsets.append(fired.global_position.x - wing_origin.x)
		if not fired.direction.is_equal_approx(Vector2.UP):
			wings_vertical = false
	wing_offsets.sort()
	check(winged.size() == 3, "侧翼炮：单发基础上追加左右各一发")
	check(wings_vertical, "侧翼炮弹道同样竖直，不向外斜射")
	check(
		wing_offsets.size() == 3
		and is_equal_approx(wing_offsets[0], -game.wing_spacing)
		and is_zero_approx(wing_offsets[1])
		and is_equal_approx(wing_offsets[2], game.wing_spacing),
		"侧翼炮在主弹道外侧平行排开且左右对称（实际 %s）" % str(wing_offsets)
	)
	await clear_arena()

	# 组合：主弹幕与侧翼炮必须连成一条互不重叠的平行弹幕，而不是叠在同一个横坐标上。
	game._bullet_count = 3
	game._wing_pairs = 1
	var combo_origin := Vector2(240, 600)
	game._on_player_shoot_requested(combo_origin)
	await settle()
	var combo := get_nodes_in_group("player_bullet")
	var combo_offsets: Array[float] = []
	for fired in combo:
		combo_offsets.append(fired.global_position.x - combo_origin.x)
	combo_offsets.sort()
	var expected_offsets: Array[float] = [
		-game.bullet_spacing - game.wing_spacing,
		-game.bullet_spacing,
		0.0,
		game.bullet_spacing,
		game.bullet_spacing + game.wing_spacing,
	]
	var combo_ok: bool = combo_offsets.size() == expected_offsets.size()
	if combo_ok:
		for index in range(expected_offsets.size()):
			if not is_equal_approx(combo_offsets[index], expected_offsets[index]):
				combo_ok = false
	check(combo_ok, "多发与侧翼炮组合后仍是一条不重叠的平行弹幕（实际 %s）" % str(combo_offsets))
	await clear_arena()

	# 弹体增幅：缩放真的落到了生成的子弹上，而不是只改了内部计数。
	game._wing_pairs = 0
	game._bullet_count = 1
	game._bullet_scale = 1.15
	game._on_player_shoot_requested(Vector2(240, 600))
	await settle()
	var enlarged := get_nodes_in_group("player_bullet")
	check(
		enlarged.size() == 1 and is_equal_approx(enlarged[0].scale.x, 1.15),
		"弹体增幅：生成子弹的体积按层数放大"
	)
	await clear_arena()

	# 拦截弹：开启后玩家的子弹能击落敌弹，但**一发换一发**，自己也会消失。
	# 这里曾经断言的是相反的行为（击落后自身继续飞），后来被推翻了：满配玩家每秒
	# 148 发、11 条弹道时，“不消耗”等于一面无限次拦截的盾，敌方火力根本到不了玩家面前。
	game._bullet_scale = 1.0
	var blocked = make_enemy_bullet(Vector2(240, 400))
	var interceptor_bullet = load("res://scenes/PlayerBullet.tscn").instantiate()
	interceptor_bullet.position = Vector2(240, 400)
	interceptor_bullet.speed = 0.0
	interceptor_bullet.intercepts = true
	game.actors.add_child(interceptor_bullet)
	await settle(6)
	check(not is_instance_valid(blocked), "拦截弹：敌弹被击落")
	check(not is_instance_valid(interceptor_bullet), "拦截弹：一发换一发，击落敌弹后自身也被消耗")

	await clear_arena()
	var ignored = make_enemy_bullet(Vector2(240, 400))
	var plain_bullet = load("res://scenes/PlayerBullet.tscn").instantiate()
	plain_bullet.position = Vector2(240, 400)
	plain_bullet.speed = 0.0
	game.actors.add_child(plain_bullet)
	await settle(6)
	check(is_instance_valid(ignored) and is_instance_valid(plain_bullet), "未开启拦截时敌弹与子弹互不影响")
	await clear_arena()

	# 出屏即失效：敌机在 y=-48 出生，而顶部栏盖住 0~90，玩家要到它钻出栏下才看得见。
	# 如果子弹一直有效到 y=-48，就会在看不见的区域里把敌机打死，表现为“刚露头就没了”。
	# 下面这一对断言把边界钉死：栏下（未露头）的敌机打不到，露头的照常打得死。
	check(is_equal_approx(game.play_area_top, 90.0), "战斗区顶边取顶部栏下沿")
	var hidden_enemy = make_enemy(Vector2(240, 40))
	var early_bullet = load("res://scenes/PlayerBullet.tscn").instantiate()
	early_bullet.position = Vector2(240, 40)
	early_bullet.speed = 640.0
	game.actors.add_child(early_bullet)
	await settle(6)
	check(not is_instance_valid(early_bullet), "升到战斗区顶边之上的子弹会被销毁")
	check(is_instance_valid(hidden_enemy), "还没露头的敌机不会被子弹打死")
	await clear_arena()

	var shown_enemy = make_enemy(Vector2(240, 120))
	var killer_bullet = load("res://scenes/PlayerBullet.tscn").instantiate()
	killer_bullet.position = Vector2(240, 260)
	killer_bullet.speed = 640.0
	game.actors.add_child(killer_bullet)
	await settle(40)
	check(not is_instance_valid(shown_enemy), "（对照）已经露头的敌机照常会被击毁")
	await clear_arena()

	# 穿透弹：一颗子弹连续击毁两个敌机，并用对照组证明这不是默认行为。
	# 连击会累积得分倍率，夹具测试前必须清零才能断言绝对分数。
	game.combo = 0
	game.score = 0
	game.xp = 0
	var first_target = make_enemy(Vector2(120, 300))
	var second_target = make_enemy(Vector2(120, 300))
	var piercing = load("res://scenes/PlayerBullet.tscn").instantiate()
	piercing.position = Vector2(120, 300)
	piercing.speed = 0.0
	piercing.pierce_left = 1
	game.actors.add_child(piercing)
	await settle(8)
	check(
		game.score == 20,
		"穿透弹一发击毁两个敌机并各自计分（分数 %d，倍率 %.2f，状态 %d）"
		% [game.score, game.score_multiplier, game.state]
	)
	check(not is_instance_valid(piercing), "穿透次数用尽后子弹才被销毁")
	check(not is_instance_valid(first_target) and not is_instance_valid(second_target), "两个敌机都被击毁")

	await clear_arena()
	# 连击会累积得分倍率，夹具测试前必须清零才能断言绝对分数。
	game.combo = 0
	game.score = 0
	game.xp = 0
	var solo_a = make_enemy(Vector2(120, 300))
	var solo_b = make_enemy(Vector2(120, 300))
	var plain = load("res://scenes/PlayerBullet.tscn").instantiate()
	plain.position = Vector2(120, 300)
	plain.speed = 0.0
	game.actors.add_child(plain)
	await settle(8)
	check(game.score == 10, "无穿透时一发只击毁一个敌机，穿透确实改变了行为")
	await clear_arena()

	# 幸运补给要把选项真的加到 5 个，而不是只改了一个内部数字。
	# 这一项会走一次随机选择，所以放在夹具测试之后，避免污染上面的绝对数值断言。
	force_choose("fortune")
	game.xp = game.xp_required(game.level) - 10
	var offer_trigger = make_enemy(Vector2(120, 250))
	offer_trigger.take_hit()
	check(game.max_offers == 5, "幸运补给把选项上限抬到 5")
	check(game.offers.size() == 5, "升级真的给出 5 个选项")
	check(game.hud.level_up_hint.text.contains("1 – 5"), "5 个选项时提示也更新为 1 – 5")
	var visible_cards := 0
	for card in game.hud.upgrade_cards:
		if card.visible:
			visible_cards += 1
	check(visible_cards == 5, "5 个选项对应显示 5 张卡片")
	game.choose_upgrade(0)
	check(not game.get_tree().paused, "5 选 1 之后同样会解除暂停")

	# 能力与等级必须随重开复位，否则重开会带着上一局的强度继续打。
	game.game_over()
	game.restart_game()
	game.enemy_timer.stop()
	check(game.level == 1 and game.xp == 0, "重开后等级与经验复位")
	check(game.upgrade_stacks.is_empty(), "重开后已选能力清空")
	check(game._bullet_count == 1 and game._bullet_pierce == 0, "重开后多发与穿透复位")
	check(game._wing_pairs == 0 and is_equal_approx(game._bullet_scale, 1.0), "重开后侧翼炮与弹体增幅复位")
	check(not game._bullet_intercepts, "重开后拦截弹关闭")
	check(game.score_multiplier == 1.0 and game.xp_multiplier == 1.0, "重开后得分与经验倍率复位")
	check(game.max_lives == 6 and game.max_offers == 4, "重开后生命上限与选项数复位")
	check(
		is_equal_approx(game.level_step_seconds, game.tuning.level_step_seconds),
		"重开后难度上升间隔复位到参数表的值"
	)
	check(game.player.shoot_cooldown == game._base_shoot_cooldown, "重开后射速回到基础值")
	check(game.player.speed == game._base_speed, "重开后移速回到基础值")
	check(not game.get_tree().paused, "重开后不会停留在暂停")

	# 叠满、或对当前局面无意义的能力不能再出现，否则会出现选了没效果的死选项。
	game.upgrade_stacks["pierce"] = game._max_stacks_of("pierce")
	check(not game.is_upgrade_offered("pierce"), "叠满的能力不再出现在选项中")
	game.upgrade_stacks.erase("pierce")
	game.lives = 99
	check(not game.is_upgrade_offered("repair"), "生命已满时不再提供补给")
	game.lives = 3
	check(game.is_upgrade_offered("rapid_fire"), "未叠满的能力仍然可选")

	# 暂停只允许存在于抉择期间：结算与重开都必须解除，否则游戏会永久卡死。
	game._set_paused(true)
	game.state = game.GameState.PLAYING
	game.game_over()
	check(not game.get_tree().paused, "结算会解除暂停")
	game._set_paused(true)
	game.restart_game()
	check(not game.get_tree().paused, "重开会解除暂停")

	# 一次拿到大量经验要能连续升级，而不是升一级后把多余经验吞掉。
	game.enemy_timer.stop()
	game.xp = game.xp_required(1) + game.xp_required(2)
	var chain_trigger = make_enemy(Vector2(120, 250))
	chain_trigger.take_hit()
	check(game.state == game.GameState.LEVEL_UP, "连升时先进入第一次抉择")
	game.choose_upgrade(0)
	check(game.level == 2, "第一次抉择后等级 +1")
	check(game.state == game.GameState.LEVEL_UP, "经验仍够时立刻进入下一次抉择，而不是吞掉经验")
	game.choose_upgrade(0)
	check(game.level == 3, "第二次抉择后等级再 +1")
	check(game.state == game.GameState.PLAYING, "经验用尽后回到游戏进行状态")

	# --- 视觉反馈之一：得分脉冲 ---
	game.enemy_timer.stop()
	# 连击会累积得分倍率，夹具测试前必须清零才能断言绝对分数。
	game.combo = 0
	game.score = 0
	game.xp = 0
	var pulse_target = make_enemy(Vector2(120, 250))
	pulse_target.take_hit()
	check(game.hud.score_label.scale.x > 1.0, "得分时分数标签立刻放大")
	check(game.hud.score_label.pivot_offset != Vector2.ZERO, "脉冲围绕标签中心缩放而不是左上角")
	await create_timer(game.hud.score_pulse_duration + 0.25).timeout
	check(game.hud.score_label.scale.is_equal_approx(Vector2.ONE), "脉冲结束后回到原始大小")
	await clear_arena()

	# --- 视觉反馈之二：受伤红闪 ---
	check(is_zero_approx(game.hud.damage_flash.color.a), "未受伤时红闪层完全透明")
	game.lives = 3
	game.player.invulnerability_duration = 0.05
	game.player.take_damage()
	check(game.hud.damage_flash.color.a > 0.0, "受伤立刻闪红")
	await create_timer(game.hud.damage_flash_duration + 0.25).timeout
	check(is_zero_approx(game.hud.damage_flash.color.a), "红闪随后淡出清零")

	# --- 受伤屏幕震动 ---
	game.lives = 3
	game._stop_screen_shake()
	check(game.camera.offset.is_equal_approx(Vector2.ZERO), "震动前摄像机偏移为零")
	game.screen_shake_enabled = true
	game._start_screen_shake()
	check(not game.camera.offset.is_equal_approx(Vector2.ZERO), "开始震动时立刻产生偏移")
	await create_timer(game.screen_shake_duration + 0.25).timeout
	check(game.camera.offset.is_equal_approx(Vector2.ZERO), "震动结束后偏移自动归零")

	# 文档要求“支持关闭震动选项”，关掉后必须一动不动。
	game.screen_shake_enabled = false
	game._stop_screen_shake()
	game._start_screen_shake()
	check(game.camera.offset.is_equal_approx(Vector2.ZERO), "关闭震动选项后不再产生偏移")
	game.screen_shake_enabled = true

	# 带着震动结算时必须清零，否则结算画面会一直歪着。
	game._start_screen_shake()
	check(not game.camera.offset.is_equal_approx(Vector2.ZERO), "结算前确实处于震动中")
	game.game_over()
	check(game.camera.offset.is_equal_approx(Vector2.ZERO), "结算会把残留的震动偏移清零")
	game.restart_game()
	game.enemy_timer.stop()

	# --- 爆炸粒子 ---
	await clear_arena()
	game._create_enemy(game.run_id)
	await settle()
	var doomed := get_nodes_in_group("enemy")
	check(doomed.size() == 1, "为爆炸测试走真实生成路径造出一架敌机")
	var death_position := Vector2(240, 300)
	var doomed_enemy = doomed[0] if doomed.size() == 1 else null
	if doomed_enemy != null:
		doomed_enemy.position = death_position
		doomed_enemy.take_hit()
	await settle(2)
	var bursts := get_nodes_in_group("explosion")
	check(bursts.size() == 1, "击毁敌机后生成一个爆炸")
	var burst = bursts[0] if bursts.size() == 1 else null
	check(
		burst != null and burst.global_position.is_equal_approx(death_position),
		"爆炸出现在敌机被击毁的位置"
	)
	await create_timer(1.0).timeout
	check(burst == null or not is_instance_valid(burst), "爆炸播放完自行释放")

	# 与子弹同样的跨局规则：换局后残留的爆炸请求必须失效。
	await clear_arena()
	game._spawn_explosion(Vector2(240, 300), game.run_id + 1)
	await settle()
	check(get_nodes_in_group("explosion").is_empty(), "过期的爆炸请求被丢弃")
	game.state = game.GameState.GAME_OVER
	game._spawn_explosion(Vector2(240, 300), game.run_id)
	await settle()
	check(get_nodes_in_group("explosion").is_empty(), "非进行状态下不生成爆炸")
	game.state = game.GameState.PLAYING

	# --- 音频：总线、循环、音效池与各事件触发 ---
	# 无头模式用的是 Dummy 音频驱动，听不到声音，但 AudioStreamPlayer.playing
	# 反映的是真实的播放状态，所以这些断言在无头下依然有效。
	check(AudioServer.get_bus_index("Music") != -1, "Music 总线存在")
	check(AudioServer.get_bus_index("SFX") != -1, "SFX 总线存在")
	check(game.music.bus == "Music", "背景音乐走 Music 总线")
	check(game.music.process_mode == Node.PROCESS_MODE_ALWAYS, "背景音乐在暂停时不会哑掉")
	var bgm := game.music.stream as AudioStreamWAV
	check(bgm != null, "背景音乐已装载为 AudioStreamWAV")
	check(bgm != null and bgm.loop_mode == AudioStreamWAV.LOOP_FORWARD, "背景音乐被设为前向循环")
	# QOA 压缩后 data 不是原始 PCM，所以循环点必须按“时长 × 采样率”核对。
	check(
		bgm != null and bgm.loop_end == int(round(bgm.get_length() * float(bgm.mix_rate))),
		"循环点覆盖整段素材而不是被截断"
	)
	check(game._sfx_players.size() == game.sfx_voices, "音效池按设定路数建立")
	var pool_on_bus := true
	var pool_always := true
	for sfx_voice in game._sfx_players:
		pool_on_bus = pool_on_bus and sfx_voice.bus == "SFX"
		pool_always = pool_always and sfx_voice.process_mode == Node.PROCESS_MODE_ALWAYS
	check(pool_on_bus, "每一路音效都挂在 SFX 总线上")
	check(pool_always, "每一路音效在暂停时仍能发声")

	game.restart_game()
	game.enemy_timer.stop()
	check(game.music.playing, "开局后背景音乐开始播放")

	silence_sfx()
	game._on_player_shoot_requested(Vector2(240, 600))
	check(sfx_used(game.SFX_SHOOT), "射击触发射击音效")

	silence_sfx()
	game.lives = 3
	game.player.invulnerability_duration = 0.05
	check(game.player.take_damage(), "受伤流程可执行（为音效测试准备）")
	check(sfx_used(game.SFX_HURT), "受伤触发受伤音效")

	# 升级提示音是唯一在“整树暂停”时发声的音效，顺带验证音乐也没被暂停掐掉。
	game.xp = game.xp_required(game.level) - 10
	silence_sfx()
	game.add_score(10)
	check(game.state == game.GameState.LEVEL_UP, "已进入升级抉择（为音效测试准备）")
	check(sfx_used(game.SFX_UPGRADE), "升级触发升级音效")
	check(game.music.playing, "暂停期间背景音乐仍在播放")
	game.choose_upgrade(0)

	silence_sfx()
	game.game_over()
	check(not game.music.playing, "结算后循环音乐停止")
	check(sfx_used(game.SFX_GAMEOVER), "结算触发结算音效")

	# 击毁敌机的爆炸音效走真实生成路径：make_enemy 不接这条线。
	game.restart_game()
	game.enemy_timer.stop()
	await clear_arena()
	silence_sfx()
	game._create_enemy(game.run_id)
	await settle()
	var sfx_targets := get_nodes_in_group("enemy")
	var sfx_enemy = sfx_targets[0] if sfx_targets.size() == 1 else null
	if sfx_enemy != null:
		sfx_enemy.take_hit()
	check(sfx_used(game.SFX_EXPLOSION), "击毁敌机触发爆炸音效")
	await clear_arena()

	# --- 波次与难度参数表 ---
	check(game.tuning != null, "波次参数资源已装载")
	check(game.tuning.waves.size() == 5, "参数表里有 5 套波次编队")
	var waves_well_formed := true
	for wave in game.tuning.waves:
		if not (wave.has("name") and wave.has("count") and wave.has("formation")):
			waves_well_formed = false
	check(waves_well_formed, "每套波次都带 name / count / formation")

	# 参数资源缺失或挂错类型时必须能兜底，而不是崩在第一次生成敌机上。
	# 这一项会故意触发一次 WARNING。
	var bare_game = load("res://scenes/Main.tscn").instantiate()
	bare_game.tuning = null
	root.add_child(bare_game)
	await settle()
	check(
		bare_game.tuning != null and bare_game.tuning.get("waves") != null,
		"参数资源缺失时自动回落到默认值（故意触发一次 WARNING）"
	)
	bare_game.queue_free()
	await settle()

	game.restart_game()
	game.enemy_timer.stop()
	check(
		game.wave_index == 0 and game.wave_cycle == 0 and game.spawned_in_wave == 0,
		"开局停在第 1 波、未放出敌机"
	)

	var first_wave_count: int = game.current_wave_count()
	check(
		first_wave_count == int(game.current_wave()["count"]),
		"首轮波次数量等于参数表里的 count"
	)

	for index in range(first_wave_count):
		game._on_enemy_timer_timeout()
	check(
		game.wave_index == 0 and game.spawned_in_wave == first_wave_count,
		"本波没放满时不换波"
	)
	check(
		is_equal_approx(game.enemy_timer.wait_time, game.get_spawn_interval()),
		"波内按生成间隔逐架排队"
	)

	game._on_enemy_timer_timeout()
	check(game.wave_index == 1 and game.spawned_in_wave == 0, "放满一波后换到下一波并清零计数")
	check(
		is_equal_approx(game.enemy_timer.wait_time, game.tuning.wave_gap),
		"换波后留出一段波间停顿"
	)
	await clear_arena()

	# 编队只改出场横坐标，且必须落在可玩范围内。
	game.wave_index = 1
	var line_count: int = game.current_wave_count()
	var line_xs: Array[float] = []
	for index in range(line_count):
		line_xs.append(game._wave_spawn_x(index, line_count))
	var line_sorted := true
	for index in range(1, line_xs.size()):
		if line_xs[index] <= line_xs[index - 1]:
			line_sorted = false
	check(line_sorted, "横列编队从左到右依次出场")
	check(
		is_equal_approx(line_xs[0], 38.0) and is_equal_approx(line_xs[line_xs.size() - 1], 480.0 - 38.0),
		"横列编队铺满整幅可玩宽度"
	)

	game.wave_index = 2
	var arc_count: int = game.current_wave_count()
	var arc_in_bounds := true
	var arc_left := 0
	var arc_right := 0
	for index in range(arc_count):
		var arc_x: float = game._wave_spawn_x(index, arc_count)
		if arc_x < 38.0 or arc_x > 480.0 - 38.0:
			arc_in_bounds = false
		if arc_x < 240.0:
			arc_left += 1
		else:
			arc_right += 1
	check(arc_in_bounds, "两翼编队的出场位置都在可玩范围内")
	check(arc_left > 0 and arc_right > 0, "两翼编队左右两侧都有敌机")
	check(
		game._wave_spawn_x(0, arc_count) < 240.0 and game._wave_spawn_x(1, arc_count) > 240.0,
		"两翼编队左右交替出场"
	)

	# 波次加成必须真的生效：精锐波速度 ×1.25，任何一架都不该低于 100×1.25。
	# 单边断言——如果倍率没生效，24 次采样全部 >=125 的概率只有 2^-24。
	game.difficulty_level = 1
	game.wave_index = 4
	var scale_low: float = game.tuning.speed_min * float(game.current_wave()["speed_scale"])
	var scaled_ok := true
	for attempt in range(24):
		game._create_enemy(game.run_id)
		var probe = game.actors.get_child(game.actors.get_child_count() - 1)
		if probe.speed < scale_low - 0.01:
			scaled_ok = false
	check(scaled_ok, "精锐波的速度倍率作用在每一架敌机上")

	# 上限：难度与波次加成叠加后也不能突破。
	# 注意：difficulty_level 是 _process 每帧从 survival_time 重算出来的派生值，
	# 手动赋值只要跨过一帧就会被覆盖，所以设完必须立刻断言，中间不能 await。
	var caps_ok := true
	game.difficulty_level = int(game.tuning.max_level)
	for attempt in range(24):
		game._create_enemy(game.run_id)
		var capped = game.actors.get_child(game.actors.get_child_count() - 1)
		if capped.speed > game.tuning.speed_cap + 0.01:
			caps_ok = false
		if capped.bullet_speed > game.tuning.bullet_speed_cap + 0.01:
			caps_ok = false
		# 射击间隔的下限现在是"尾段的起点"，而不是硬地板：越过它之后仍会按 tail 逐级
		# 收紧（这是修掉中段平台期的关键）。所以这里守的不是"不低于 floor"，而是
		# "有节制、绝不会滑到 0"——滑到 0 会让同一架敌机在一帧里连射。
		if capped.shoot_interval < game.tuning.shoot_interval_floor * 0.25:
			caps_ok = false
	check(caps_ok, "速度与弹速夹在上限内，射击间隔的尾段有节制、不会滑到 0")
	# 射击间隔在难度 18 触底，之后同样必须靠尾段继续收紧——这是后期最要紧的杠杆：
	# 密度受实体数量限制，而"同一批敌机打得更勤"提高的是闪避负担，不受数量限制。
	game.difficulty_level = 18
	game._create_enemy(game.run_id)
	var shooter_at_18 = game.actors.get_child(game.actors.get_child_count() - 1)
	var shoot_interval_18: float = shooter_at_18.shoot_interval
	game.difficulty_level = int(game.tuning.max_level)
	game._create_enemy(game.run_id)
	var shooter_at_max = game.actors.get_child(game.actors.get_child_count() - 1)
	check(
		shooter_at_max.shoot_interval < shoot_interval_18,
		"越过射击间隔下限后仍在收紧（难度 18 之后射得更勤）"
	)
	check(
		shooter_at_max.shoot_interval >= game.tuning.shoot_interval_floor * 0.25,
		"射击间隔的尾段同样有节制"
	)
	check(
		is_equal_approx(game.shooter_chance(), game.tuning.shooter_chance_cap),
		"最高难度叠加精锐波后开火概率夹到上限"
	)

	await clear_arena()
	game.difficulty_level = 1
	game.wave_index = 0
	check(
		is_equal_approx(game.shooter_chance(), game.tuning.shooter_chance_base),
		"第 1 波开局的开火概率等于基础值"
	)

	# 走完一整轮后每波数量增加，但有上限。
	var base_wave_count: int = game.current_wave_count()
	game.wave_cycle = int(game.tuning.cycle_count_bonus_cap)
	var bonus_cap_count: int = game.current_wave_count()
	check(
		bonus_cap_count == base_wave_count + int(game.tuning.cycle_count_bonus_cap),
		"走完一整轮后每波敌机数量增加"
	)
	game.wave_cycle = int(game.tuning.cycle_count_bonus_cap) + 5
	check(game.current_wave_count() == bonus_cap_count, "波次数量的加成有上限，不会无限膨胀")
	game.wave_cycle = 0

	# 状态行要显示波次，而且加了这一项之后仍然不溢出。
	game.wave_index = 2
	game._refresh_hud()
	check(game.hud.status_label.text.contains("第 3 波"), "状态行显示当前波次")
	check(
		game.hud.status_label.get_minimum_size().x <= game.hud.status_label.size.x,
		"加入波次读数后状态行仍不超出矩形宽度"
	)

	# 重开必须回到第一波，不能接着上一轮的编排继续。
	game.wave_index = 3
	game.wave_cycle = 2
	game.spawned_in_wave = 4
	game.game_over()
	game.restart_game()
	game.enemy_timer.stop()
	check(
		game.wave_index == 0 and game.wave_cycle == 0 and game.spawned_in_wave == 0,
		"重开后波次回到第一波"
	)
	check(
		is_equal_approx(game.level_step_seconds, game.tuning.level_step_seconds),
		"开局难度间隔取自参数表"
	)

	# 击杀当帧触发升级时，爆炸不能被丢掉：爆炸是帧末延迟生成的，那时 state 已经是
	# LEVEL_UP，状态守卫必须放行——Boss 因为给分多必然触发升级，这条路径一定会走到。
	await clear_arena()
	game.xp = game.xp_required(game.level) - 10
	game._create_enemy(game.run_id)
	await settle()
	var boom_targets := get_nodes_in_group("enemy")
	var boom_target = boom_targets[0] if boom_targets.size() == 1 else null
	if boom_target != null:
		boom_target.take_hit()
	check(game.state == game.GameState.LEVEL_UP, "这一击确实触发了升级（为爆炸断言准备）")
	await settle(2)
	check(
		get_nodes_in_group("explosion").size() >= 1,
		"击杀触发升级时爆炸依然生成，没有被状态守卫丢掉"
	)
	var drain_guard := 0
	while game.state == game.GameState.LEVEL_UP and drain_guard < 20:
		game.choose_upgrade(0)
		drain_guard += 1
	await clear_arena()

	# --- Boss ---
	# 直接把指针推到一轮的最后一波，省去真打完五波的几十秒；推进逻辑本身与正常游玩同一条路径。
	game.restart_game()
	game.enemy_timer.stop()
	game.wave_index = game.tuning.waves.size() - 1
	game.spawned_in_wave = game.current_wave_count()
	game._on_enemy_timer_timeout()
	check(game.boss_pending, "走完一整轮波次后标记 Boss 待登场")
	check(game.boss == null, "预警停顿期间 Boss 还没有出现")
	check(not game.hud.boss_bar.visible, "Boss 登场前血条不显示")

	game._on_enemy_timer_timeout()
	await settle()
	check(game.boss != null, "预警结束后的下一拍 Boss 登场")
	check(
		game.boss != null and game.boss.get_parent() == game.actors,
		"Boss 挂在 Actors 下，会随开局/结算清场一并释放"
	)
	check(game.enemy_timer.is_stopped(), "Boss 战期间停止刷普通敌机")
	# B2：血量按玩家**当前每秒能打出多少发**反推，而不是固定值或按轮次线性增长。
	# 玩家输出跨度有二十多倍，线性曲线要么前期打不动、要么后期一碰就碎。
	var expected_boss_hp: int = clampi(
		int(round(game.player_dps_proxy() * game.tuning.boss_target_seconds)),
		int(game.tuning.boss_hp_floor),
		int(game.tuning.boss_hp_cap)
	)
	check(
		game.boss != null and game.boss.max_hp == expected_boss_hp,
		"Boss 血量按玩家当前输出反推"
	)
	check(game.boss != null and game.boss.hp == game.boss.max_hp, "登场时满血")

	# 入场：先降到设定高度，再进入横向巡航与攻击。
	check(not game.boss.entered, "刚登场时还在入场阶段")
	for step in range(80):
		game.boss._physics_process(0.05)
	check(game.boss.entered, "降到设定高度后进入攻击阶段")
	check(
		is_equal_approx(game.boss.position.y, game.tuning.boss_hold_y),
		"Boss 停在上方设定的高度，不会继续下压"
	)

	# 巡航不能越出左右边距，否则会一半身子挂在屏幕外。
	game.boss.position.x = 10.0
	for step in range(20):
		game.boss._physics_process(0.1)
	check(
		game.boss.position.x >= game.tuning.boss_margin - 0.01,
		"Boss 巡航不会越出左边距"
	)
	game.boss.position.x = 470.0
	for step in range(20):
		game.boss._physics_process(0.1)
	check(
		game.boss.position.x <= 480.0 - game.tuning.boss_margin + 0.01,
		"Boss 巡航不会越出右边距"
	)

	# 扇形齐射：信号里的方向、以及真正生成出来的敌弹，两处都要对。
	game.boss.shoot_timer.stop()
	game._purge_enemy_bullets()
	await settle()
	_captured_directions.clear()
	game.boss.shoot_requested.connect(capture_boss_shot)
	game.boss.fire_fan()
	check(
		_captured_directions.size() == game.boss.fan_count,
		"扇形齐射按设定的发数请求发弹"
	)
	var fan_sum := Vector2.ZERO
	for direction in _captured_directions:
		fan_sum += direction
	check(
		_captured_directions.size() > 0 and fan_sum.normalized().is_equal_approx(Vector2.DOWN),
		"扇形以正下方为中轴对称"
	)
	check(
		_captured_directions.size() > 0
			and not _captured_directions[0].is_equal_approx(Vector2.DOWN),
		"扇形两侧确实带角度，而不是全部垂直下落"
	)
	await settle()
	var fan_bullets := get_nodes_in_group("enemy_bullet")
	check(
		fan_bullets.size() == game.boss.fan_count,
		"齐射真的生成了对应数量的敌弹"
	)
	var angled_bullets := 0
	for boss_bullet in fan_bullets:
		if not boss_bullet.direction.is_equal_approx(Vector2.DOWN):
			angled_bullets += 1
	check(
		fan_bullets.size() > 0 and angled_bullets == fan_bullets.size() - 1,
		"扇形敌弹里只有正中一发是垂直的"
	)
	game._purge_enemy_bullets()

	# 撞机：Boss 自己不消耗，只让玩家扣命——否则拿机身去撞就能秒掉 Boss。
	game.lives = 3
	game.player.invulnerability_duration = 0.05
	var boss_hp_before_ram: int = game.boss.hp
	game.boss.hit_player(game.player)
	check(
		is_instance_valid(game.boss) and game.boss.hp == boss_hp_before_ram,
		"Boss 撞到玩家不会自我消耗"
	)
	check(game.lives == 2, "Boss 撞到玩家会让玩家扣命")

	# 玩家的普通子弹打在 Boss 上会被消耗一次，而不是穿透过去。
	var total_hp: int = game.boss.hp
	var probe_bullet = load("res://scenes/PlayerBullet.tscn").instantiate()
	probe_bullet.position = game.boss.global_position
	probe_bullet.speed = 0.0
	game.actors.add_child(probe_bullet)
	await settle(6)
	check(game.boss.hp == total_hp - 1, "玩家的子弹对 Boss 造成一点伤害")
	check(not is_instance_valid(probe_bullet), "子弹命中 Boss 后被消耗")

	# 血量见底之前不会死。
	var boss_survived := true
	for hit in range(game.boss.hp - 1):
		game.boss.take_hit()
		if not is_instance_valid(game.boss):
			boss_survived = false
			break
	check(boss_survived, "Boss 挨打只扣血，打满生命值之前不会死")

	# 连击会累积得分倍率，夹具测试前必须清零才能断言绝对分数。
	game.combo = 0
	game.score = 0
	game.xp = 0
	game.boss.take_hit()
	check(game.boss == null, "生命归零后 Boss 被击破且 Main 释放了引用")
	# Boss 也会走 add_score，因此被算进 kills——那是有意的（击毁就是击毁）。
	# 但 1 点血的敌机与上万血的 Boss 混成一个数字后，按击毁数分析时分不出普通敌机，
	# 所以另存一份 boss_kills，两者必须同时成立。
	check(game.boss_kills >= 1, "击破 Boss 会单独计入 Boss 击毁数")
	check(game.kills > game.boss_kills, "Boss 计入击毁总数，但两者分开记录")
	# 额外补的经验只有**半级**。补一整级时，单个 Boss 的总经验收益（奖励分 ×经验倍率
	# 再外加一整级）相当于约 100 架普通敌机——真人第一局里 9 个 Boss 占了约 71% 的总
	# 经验，升级于是变成"等 Boss"而不是"打得准"。这里按半级逐项算出期望值再比对：
	# 写死数字会在抽到"战术洞察"（经验倍率）时无故失败。
	var expected_boss_xp: int = int(round(float(game.tuning.boss_score) * game.xp_multiplier)) \
		+ int(round(float(game.xp_required(game.level)) * game.tuning.boss_xp_levels))
	check(game.xp == expected_boss_xp, "击破 Boss 只额外补半级经验，而不是一整级")
	check(
		game.xp < int(round(float(game.tuning.boss_score) * game.xp_multiplier))
			+ game.xp_required(game.level),
		"（对照）Boss 的经验收益确实低于“奖励分 + 一整级”的旧行为"
	)
	# 奖励分要按当前得分倍率折算：随机升级可能抽到“战果结算”，
	# 写死 500 会在某些抽取结果下无缘无故地失败。
	check(
		game.score == int(round(float(game.tuning.boss_score) * game.score_multiplier)),
		"击破 Boss 获得参数表里的奖励分（计入当前得分倍率）"
	)
	await settle(2)
	check(get_nodes_in_group("explosion").size() >= 3, "击破 Boss 会炸开多处特效，而不是只炸一下")
	check(not game.hud.boss_bar.visible, "击破后 Boss 血条收起")
	check(not game.boss_pending, "击破后不会立刻再排一个 Boss")
	check(not game.enemy_timer.is_stopped(), "击破后波次恢复正常刷怪")
	# 击破 Boss 的奖励分同时是经验，所以很可能一口气连升好几级：
	# 必须把整条抉择链收干净，否则状态会停在 LEVEL_UP，后面的断言和刷怪全都不成立。
	var upgrade_guard := 0
	while game.state == game.GameState.LEVEL_UP and upgrade_guard < 20:
		game.choose_upgrade(0)
		upgrade_guard += 1
	check(game.state == game.GameState.PLAYING, "收尾后回到游戏进行状态")
	await clear_arena()

	# 血条在 Boss 战期间显示，并跟着扣血走。
	game.boss_pending = true
	game._on_enemy_timer_timeout()
	await settle()
	var second_boss = game.boss
	check(second_boss != null, "击破一轮之后还能再次召出 Boss")
	check(game.hud.boss_bar.visible, "Boss 战时血条显示")
	check(
		second_boss != null and is_equal_approx(game.hud.boss_bar.max_value, float(second_boss.max_hp)),
		"血条上限等于 Boss 的生命上限"
	)
	check(game.hud.boss_label.text.contains("BOSS"), "血条旁标注了 BOSS")
	if second_boss != null:
		var hp_before_bar: int = second_boss.hp
		second_boss.take_hit()
		check(
			is_equal_approx(game.hud.boss_bar.value, float(hp_before_bar - 1)),
			"血条随扣血同步下降"
		)
	else:
		check(false, "血条随扣血同步下降（Boss 没召出来，无法验证）")

	# B2 的端到端证明：显式构造两套差距很大的输出，各召一次 Boss，血量必须跟着变。
	# 用固定血量或按轮次线性增长的实现，都过不了这一条。
	# （这里特意自己设定 _bullet_count / _wing_pairs，而不是拿上一只 Boss 当基准——
	#   随机升级未必给过多发与侧翼炮，那样两次血量可能一样，断言会无缘无故地飘。）
	if second_boss != null:
		second_boss.deactivate()
		second_boss.queue_free()
		game.boss = null
		game.hud.hide_boss()
	await settle()

	game._bullet_count = 5
	game._wing_pairs = 3
	game.player.shoot_cooldown = 0.074
	game.boss_pending = true
	game._on_enemy_timer_timeout()
	await settle()
	var strong_boss = game.boss
	var strong_hp: int = 0
	if strong_boss != null:
		strong_hp = strong_boss.max_hp
		strong_boss.deactivate()
		strong_boss.queue_free()
		game.boss = null
		game.hud.hide_boss()
	await settle()

	game._bullet_count = 1
	game._wing_pairs = 0
	game.player.shoot_cooldown = game._base_shoot_cooldown
	game.boss_pending = true
	game._on_enemy_timer_timeout()
	await settle()
	var weak_boss = game.boss
	check(
		weak_boss != null and strong_hp > 0 and weak_boss.max_hp < strong_hp,
		"输出越低 Boss 血量越低——血量确实随玩家强度走，而不是固定值"
	)
	if weak_boss != null:
		weak_boss.deactivate()
		weak_boss.queue_free()
		game.boss = null
		game.hud.hide_boss()
	await clear_arena()

	# 重开必须把 Boss 与待登场标记一并清掉，不能带着上一轮的半血 Boss 继续。
	game.game_over()
	game.restart_game()
	game.enemy_timer.stop()
	check(game.boss == null and not game.boss_pending, "重开清掉 Boss 与待登场标记")
	check(not game.hud.boss_bar.visible, "重开后 Boss 血条是隐藏的")

	# --- 连击与逃敌代价 ---
	# 这两条互补：连击奖励“打得凶”，逃敌惩罚“苟着不打”。没有它们时，
	# 躲着不开枪是严格最优解——既不会被扣什么，也没什么可失去的。
	game.restart_game()
	game.enemy_timer.stop()
	check(
		game.combo == 0 and game.escaped_count == 0 and is_zero_approx(game.escape_pressure),
		"开局连击、逃敌数与难度压力都归零"
	)
	check(game.combo_multiplier() == 1, "零连击时得分倍率为 ×1")
	check(not game.hud.combo_label.visible, "没有倍率时不显示连击标签")

	# 倍率阶梯：每 combo_step 次击毁升一档，并且封顶。
	game.combo = 0
	check(game.combo_multiplier() == 1, "0 连击为 ×1")
	game.combo = game.combo_step
	check(game.combo_multiplier() == 2, "满一档后升到 ×2")
	game.combo = game.combo_step * 2
	check(game.combo_multiplier() == 3, "满两档后升到 ×3")
	game.combo = game.combo_step * game.combo_max_multiplier * 4
	check(
		game.combo_multiplier() == game.combo_max_multiplier,
		"倍率封顶在参数上限，不会无限增长"
	)
	game.combo = 0

	# 击毁累积连击，而且分数真的按当时的倍率结算。
	game.score = 0
	game.xp = 0
	for index in range(game.combo_step):
		var victim = make_enemy(Vector2(120, 250))
		victim.take_hit()
	check(game.combo == game.combo_step, "连续击毁累积连击")
	check(
		game.score == 10 * (game.combo_step - 1) + 10 * game.combo_multiplier(),
		"第 N 次击毁按当时的连击倍率结算分数"
	)
	check(game.hud.combo_label.visible, "有倍率时连击标签出现")
	check(game.hud.combo_label.text == "×%d" % game.combo_multiplier(), "连击标签显示当前倍率")
	await clear_arena()

	# 受伤打断连击。
	game.combo = game.combo_step * 2
	game.lives = 3
	game.player.invulnerability_duration = 0.05
	game.player.take_damage()
	check(game.combo == 0, "受伤会把连击清零")
	check(not game.hud.combo_label.visible, "连击清零后标签收起")

	# 被击毁的敌机不能被误判成逃敌。
	game.escaped_count = 0
	var destroyed_enemy = make_enemy(Vector2(120, 250))
	destroyed_enemy.take_hit()
	await settle(2)
	check(game.escaped_count == 0, "被击毁的敌机不会计入逃敌")
	await clear_arena()

	# 漏敌：清零连击、累计逃敌数、并永久抬高本局难度。
	game.combo = game.combo_step * 2
	var pressure_before: float = game.escape_pressure
	var runaway = make_enemy(Vector2(120, 900))
	await settle(2)
	check(game.escaped_count == 1, "敌机飞出底部会计入逃敌")
	check(game.combo == 0, "漏敌会清零连击")
	check(game.escape_pressure > pressure_before, "漏敌会抬高本局的难度压力")
	check(is_instance_valid(runaway) == false, "逃走的敌机已被释放")

	for index in range(3):
		make_enemy(Vector2(120, 900))
		await settle(1)
	check(game.escaped_count >= 4, "连续漏敌会持续累计")
	game.survival_time = 0.0
	game._process(0.0)
	check(
		game.difficulty_level >= 1 + int(game.escape_pressure),
		"逃敌压力直接加到难度等级上——苟着不打会让天越来越难"
	)

	# 压力是累加到**时间轴**上再取整的，不是各自取整后相加。
	# 旧写法有个与时间无关的台阶：int(escape_pressure) 每跨过 1.0 就凭空多跳一级
	# （漏 3 架 = 1.02 正好跨过），玩家会觉得“怎么突然变难”。
	# 下面这条用分数压力把这个行为钉死：0.6 级时间 + 0.5 级压力 = 1.1，应当跨到第 2 级。
	# 分开取整的旧写法只会得到 1 + 0 + 0 = 1 级，所以它能守住回归。
	game.survival_time = game.level_step_seconds * 0.6
	game.escape_pressure = 0.5
	game._process(0.0)
	check(
		game.difficulty_level == 2,
		"时间与逃敌压力在同一条时间轴上合并取整（0.6 级 + 0.5 级正好跨到第 2 级）"
	)

	# 压力有上限，不能无限抬高。
	game.escape_pressure = game.tuning.escape_pressure_cap
	for index in range(5):
		make_enemy(Vector2(120, 900))
		await settle(1)
	check(
		is_equal_approx(game.escape_pressure, game.tuning.escape_pressure_cap),
		"逃敌压力有上限，不会无限膨胀"
	)
	await clear_arena()

	# 重开必须把这些也清干净。
	game.game_over()
	game.restart_game()
	game.enemy_timer.stop()
	check(
		game.combo == 0 and game.escaped_count == 0 and is_zero_approx(game.escape_pressure),
		"重开清空连击、逃敌数与难度压力"
	)

	# --- 暂停与设置面板 ---
	check(game.state == game.GameState.PLAYING, "（前提）暂停测试从进行中的一局开始")
	check(not game.hud.pause_panel.visible, "（前提）暂停面板初始隐藏")
	game.toggle_pause()
	check(game.get_tree().paused, "按暂停会冻结整个世界")
	check(game.hud.pause_panel.visible, "暂停面板出现")
	check(game.state == game.GameState.PLAYING, "暂停不改状态，只冻结世界")
	# 暂停中必须还能按回来：这个键由 HUD 处理（PROCESS_MODE_ALWAYS）。若交给 PAUSABLE 的
	# Main，整树一暂停它的 _unhandled_input 就不再执行，玩家会被永久卡在暂停里。
	game.toggle_pause()
	check(not game.get_tree().paused and not game.hud.pause_panel.visible, "再按一次恢复并收起面板")

	game.game_over()
	game.toggle_pause()
	check(not game.get_tree().paused, "结算状态下不接受暂停")
	game.restart_game()
	game.enemy_timer.stop()

	# 暂停面板的控件都必须落在面板内，否则会出现“按钮飘在面板外面”。
	var panel: Panel = game.hud.pause_panel
	var controls_inside := true
	for node in [
		game.hud.pause_title, game.hud.shake_caption, game.hud.shake_button,
		game.hud.music_caption, game.hud.music_slider, game.hud.sfx_caption,
		game.hud.sfx_slider, game.hud.pause_resume_button, game.hud.pause_restart_button,
	]:
		if node.offset_left < panel.offset_left or node.offset_right > panel.offset_right \
				or node.offset_top < panel.offset_top or node.offset_bottom > panel.offset_bottom:
			controls_inside = false
	check(controls_inside, "暂停面板的所有控件都在面板范围内")

	# 震动开关：按钮显示当前状态，发出的是取反后的期望值。
	var shake_before: bool = game.screen_shake_enabled
	game.toggle_pause()
	check(
		game.hud.shake_button.text == ("开" if shake_before else "关"),
		"暂停面板显示的是真实的震动开关状态"
	)
	game.hud.shake_button.pressed.emit()
	check(game.screen_shake_enabled != shake_before, "点震动按钮会切换开关")
	check(
		game.hud.shake_button.text == ("开" if game.screen_shake_enabled else "关"),
		"按钮文字跟着状态更新"
	)
	game.hud.shake_button.pressed.emit()
	check(game.screen_shake_enabled == shake_before, "再点一次切回原值")

	# 音量：滑条改的必须是音频总线的真实音量，而不是只存一个数。
	# 默认值也不是写死的 100%——总线布局里 Music 是 -6 dB，所以要能反映出约 50%。
	var music_before: int = game.music_percent
	var music_index: int = AudioServer.get_bus_index("Music")
	check(
		absf(db_to_linear(AudioServer.get_bus_volume_db(music_index)) - float(music_before) / 100.0) < 0.02,
		"初始音量来自总线实际值，而不是写死的 100%"
	)
	game.hud.music_slider.value = 0.0
	check(game.music_percent == 0, "滑条拖到 0 会更新设置")
	check(AudioServer.is_bus_mute(music_index), "0% 时真的把总线静音了")
	game.hud.music_slider.value = 60.0
	check(
		absf(db_to_linear(AudioServer.get_bus_volume_db(music_index)) - 0.6) < 0.02,
		"60% 换算到分贝再换算回来仍然是 0.6"
	)
	game.hud.music_slider.value = float(music_before)
	check(game.music_percent == music_before, "音量已还原，不影响后续断言")

	# 设置要落盘，换一个新实例必须读回同样的值。
	game.hud.shake_toggled.emit(not shake_before)
	var settings_probe = load("res://scenes/Main.tscn").instantiate()
	root.add_child(settings_probe)
	await settle()
	check(settings_probe.screen_shake_enabled != shake_before, "新实例从磁盘读回震动设置")
	check(settings_probe.music_percent == music_before, "新实例从磁盘读回音量设置")
	settings_probe.queue_free()
	await settle()
	game.hud.shake_toggled.emit(shake_before)

	# 震动与音量都是在暂停面板里改的，所以到这里游戏仍处于暂停——先显式退出，
	# 否则下面那次 toggle_pause() 会变成“恢复”而不是“暂停”，断言会莫名其妙地失败。
	game.toggle_pause()
	check(not game.get_tree().paused and not game.hud.pause_panel.visible, "（收尾）退出暂停面板")

	# 从暂停面板重开：此时 state 仍是 PLAYING，所以必须走 force 分支，
	# 否则 start_game() 会因为“进行中不许重开”而直接早退。
	game.toggle_pause()
	check(game.get_tree().paused, "（前提）已处于暂停")
	game.hud.pause_restart_button.pressed.emit()
	check(not game.get_tree().paused, "从暂停面板重开会解除暂停")
	check(not game.hud.pause_panel.visible, "重开后暂停面板收起")
	check(game.state == game.GameState.PLAYING and game.player.active, "重开后是新的进行中一局")
	check(game.score == 0 and game.lives == game.initial_lives, "重开后分数与生命复位")
	game.enemy_timer.stop()

	# --- 本局战报与对局记录 ---
	# 战报依赖三个新计数器，先确认它们确实被重开清干净了。
	check(
		game.kills == 0 and game.boss_kills == 0 and game.hits_taken == 0
			and game.peak_combo_multiplier == 1 and game.hit_times.is_empty(),
		"重开清空击毁数（含 Boss 计数）、受伤次数、最高倍率与受伤时间点"
	)
	check(game.RUN_LOG_PATH == RUN_LOG_FILE, "测试与游戏读写同一份对局记录")

	# 清掉历史记录，让后面的行数断言有确定的前提。
	remove_run_log()
	check(not FileAccess.file_exists(RUN_LOG_FILE), "测试可以清空对局记录文件")

	# 击毁计数：真击毁 +1，漏过去的不算。
	for index in range(3):
		var counted = make_enemy(Vector2(120, 250))
		counted.take_hit()
	check(game.kills == 3, "每击毁一架敌机击毁数 +1")
	make_enemy(Vector2(120, 900))
	await settle(2)
	check(game.escaped_count == 1, "（前提）漏过的敌机计入逃敌")
	check(game.kills == 3, "漏过的敌机不会计入击毁数")

	# 峰值倍率：记录本局达到过的最高档，而且受伤清零连击之后不能跟着回退。
	game.combo = game.combo_step * 2
	game.add_score(10)
	check(game.peak_combo_multiplier == 3, "峰值倍率记录本局达到过的最高档")
	game.lives = 3
	game.player.invulnerability_duration = 0.05
	game.player.take_damage()
	check(game.hits_taken == 1, "受伤次数 +1")
	# 受伤时间点是“这一局被逼死还是被主动结束”的唯一判据，必须真的记下来。
	check(
		game.hit_times.size() == 1 and is_equal_approx(game.hit_times[0], snappedf(game.survival_time, 0.1)),
		"受伤时间点记录了当时的生存时长"
	)
	check(game.combo == 0, "（前提）受伤清零连击")
	check(game.peak_combo_multiplier == 3, "受伤清零连击不会让峰值倍率回退")

	# 结算写盘：内容必须是能解析的 JSON，而且每一项都与本局对得上。
	game.survival_time = 42.5
	# 结算前特意把连击拉起来，用来验证结算是真的会把它清掉。
	game.combo = game.combo_step * 2
	game.score = game.best_score + 500
	var scored: int = game.score
	var peak: int = game.peak_combo_multiplier
	game.game_over()
	check(FileAccess.file_exists(RUN_LOG_FILE), "结算后对局记录已写入磁盘")
	var records: Array = read_run_log()
	check(records.size() == 1, "一局结算只追加一条记录")
	var entry: Dictionary = records[0] if records.size() > 0 else {}
	check(int(entry.get("score", -1)) == scored, "记录里的分数与本局一致")
	check(int(entry.get("best", -1)) == game.best_score, "记录里的最高分与当前纪录一致")
	check(int(entry.get("kills", -1)) == game.kills, "记录里的击毁数与本局一致")
	check(int(entry.get("boss_kills", -1)) == game.boss_kills, "记录里单独存了 Boss 击毁数")
	check(int(entry.get("hits", -1)) == 1, "记录里的受伤次数与本局一致")
	# 时间点序列必须单调不减，才能用来判断“最后几次受伤是不是挨得极近”。
	# 真人前两局都是主动结束，而当时的记录只有“存活 N 秒、受伤 M 次”，
	# 主动送死与被逼死长得一模一样——我据此得出了错误结论。这个字段就是补这个洞。
	var hit_series: Array = entry.get("hit_times", [])
	var hit_series_ok: bool = hit_series.size() == game.hit_times.size()
	for index in range(1, hit_series.size()):
		if float(hit_series[index]) < float(hit_series[index - 1]):
			hit_series_ok = false
	check(hit_series_ok and not hit_series.is_empty(), "记录里带单调不减的受伤时间点序列")
	check(int(entry.get("escapes", -1)) == 1, "记录里的漏敌数与本局一致")
	check(int(entry.get("peak_combo", -1)) == peak, "记录里的峰值倍率与本局一致")
	check(is_equal_approx(float(entry.get("time", -1.0)), 42.5), "记录里的存活时长与本局一致")
	check(typeof(entry.get("build")) == TYPE_DICTIONARY, "记录里带结构化的能力路线，供后续分析")
	# 规则指纹要能自证"这一局按哪套参数跑的"。上一轮真人试玩时只能靠文件时间戳去推断
	# 记录来自改前还是改后——那是会得出错误结论的证据，所以把参数写进记录本身。
	check(
		typeof(entry.get("rules")) == TYPE_STRING and String(entry["rules"]).length() > 0,
		"记录里带规则指纹，能自证是按哪套参数跑的"
	)
	# 但指纹必须真的跟着参数走，否则它只是个骗人的常量。
	var probe_main = load("res://scenes/Main.tscn").instantiate()
	var probe_tuning = load("res://scripts/WaveTuning.gd").new()
	probe_main.tuning = probe_tuning
	var fingerprint_before: String = probe_main.tuning_fingerprint()
	probe_tuning.spawn_interval_tail = 0.5
	check(
		probe_main.tuning_fingerprint() != fingerprint_before,
		"规则指纹随参数变化，不是写死的字符串"
	)
	probe_main.free()
	check(bool(entry.get("record", false)), "超过既有最高分时记录标记为破纪录")
	check(game.combo == 0 and not game.hud.combo_label.visible, "结算会清空连击并收起顶栏倍率")
	check(game.peak_combo_multiplier == peak, "结算清空连击不会影响本局峰值倍率")

	# 战报文案：该有的数字都要在，并且宽高都不能顶破固定矩形。
	var report_text: String = game.hud.message_label.text
	check(report_text.contains("本次飞行结束"), "结算界面显示战报标题")
	check(report_text.contains("击毁 %d" % game.kills), "战报显示击毁数")
	check(report_text.contains("受伤 %d 次" % game.hits_taken), "战报显示受伤次数")
	check(report_text.contains("漏敌 %d 架" % game.escaped_count), "战报显示漏敌数")
	check(report_text.contains("最高倍率 ×%d" % game.peak_combo_multiplier), "战报显示峰值倍率")
	check(report_text.contains("到达 Lv %02d" % game.level), "战报显示到达等级")
	check(report_text.contains("能力 未获得能力"), "本局没拿到能力时战报如实说明")
	check(report_text.contains("新纪录"), "破纪录时战报提示新纪录")
	check(message_label.get_minimum_size().y <= message_label.size.y, "战报文案不超出矩形高度")
	check(message_label.get_minimum_size().x <= message_label.size.x, "战报文案不超出矩形宽度")

	# 低于纪录时不标记破纪录。
	game.restart_game()
	game.enemy_timer.stop()
	game.score = 1
	game.game_over()
	var lower: Array = read_run_log()
	check(lower.size() == 2, "第二局结算再追加一条")
	check(not bool(lower[-1].get("record", true)), "低于既有最高分时记录不标记破纪录")
	check(not game.hud.message_label.text.contains("新纪录"), "未破纪录时战报不提示新纪录")

	# 上限裁剪：超过上限后只保留最近若干局，且丢掉的确实是最旧的。
	for index in range(game.RUN_LOG_LIMIT + 5):
		game.restart_game()
		game.enemy_timer.stop()
		game.score = index + 1
		game.game_over()
	var capped: Array = read_run_log()
	check(capped.size() == game.RUN_LOG_LIMIT, "对局记录只保留最近 %d 局" % game.RUN_LOG_LIMIT)
	check(int(capped[-1].get("score", -1)) == game.RUN_LOG_LIMIT + 5, "保留的是最近的记录")
	check(int(capped[0].get("score", -1)) != 1, "被裁掉的是最旧的那一局")

	# 记录文件被写坏时不能让结算失败：坏行丢掉、正常行保留、新记录照常追加。
	check(write_run_log("这不是 JSON\n\n{\"score\": 7}\n"), "测试可以写入损坏的对局记录")
	game.restart_game()
	game.enemy_timer.stop()
	game.score = 99
	game.game_over()
	var repaired: Array = read_run_log()
	check(repaired.size() == 2, "写坏的行被丢弃，正常的记录保留")
	check(int(repaired[-1].get("score", -1)) == 99, "记录损坏后仍能正常追加新的一局")
	check(game.state == game.GameState.GAME_OVER, "记录损坏不影响结算流程")

	# 主动结束的对局必须能在记录里认出来。真人前两局都是玩家自己送死的，而当时的记录里
	# 只有“存活 N 秒、受伤 M 次”，与被逼死的样子完全一样——我正是据此得出了错误结论
	# （"玩家跑得比曲线快"）。真实玩法下两次受伤至少隔一次无敌时间，所以主动送死的特征
	# 是：最后几次受伤以接近无敌时长的间隔连续出现。这里走真实受伤路径把它复现出来。
	game.restart_game()
	game.enemy_timer.stop()
	game.lives = 10
	game.player.invulnerability_duration = 0.05
	for index in range(3):
		game.player.take_damage()
		await create_timer(0.12).timeout
	var suicide_hits: Array = game.hit_times
	check(
		suicide_hits.size() == 3 and float(suicide_hits[2]) - float(suicide_hits[0]) < 1.0,
		"连续受伤的时间点挨得极近，足以与被逼死的对局区分开"
	)
	game.lives = 3
	game.game_over()
	var suicide_record: Dictionary = read_run_log()[-1]
	var suicide_series: Array = suicide_record.get("hit_times", [])
	check(suicide_series.size() == 3, "主动结束的对局在记录里保留完整的受伤时间点")

	game.game_over()
	# 退出前必须把音频停干净并放开流引用。只要有播放器还在播、还握着 AudioStream，
	# Godot 退出时就会偶发 "N resources still in use at exit"，而且时有时无——
	# 那会让流水线莫名其妙地失败，排查起来非常费劲。
	game.music.stop()
	silence_sfx()
	await settle()
	game.music.stream = null
	for sfx_voice in game._sfx_players:
		sfx_voice.stream = null
	await settle()
	game.queue_free()
	await settle()
	_finished = true
	print("RESULT: ", checks - failures, "/", checks, " checks passed; failures=", failures)
	quit(0 if failures == 0 else 1)
