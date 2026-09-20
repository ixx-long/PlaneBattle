extends SceneTree
## 通过引擎实际渲染并保存测试截图，仅用于验收，不参与游戏。

## 看门狗上限。截图流程正常只要几秒，超过这个数基本就是 _run() 中途断了。
const WATCHDOG_SECONDS: float = 60.0

var _finished: bool = false

func _initialize() -> void:
	_run.call_deferred()
	# 与 SmokeTest 同理：运行时错误会让协程当场中断、quit() 执行不到，
	# 进程一直挂着只能等外层超时，看不出原因。看门狗把它变成明确失败。
	create_timer(WATCHDOG_SECONDS).timeout.connect(_on_watchdog_timeout)

func _on_watchdog_timeout() -> void:
	if _finished:
		return
	push_error("VisualTest 超过 %.0f 秒仍未结束：_run() 很可能中途因运行时错误中断了" % WATCHDOG_SECONDS)
	quit(1)

func capture(path: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var image: Image = root.get_texture().get_image()
	var error: Error = image.save_png(path)
	print("CAPTURE ", path, " ERROR=", error)

func _run() -> void:
	var game = load("res://scenes/Main.tscn").instantiate()
	root.add_child(game)
	await create_timer(0.3).timeout
	await capture("res://../start-preview.png")
	game.start_game()
	game.enemy_timer.stop()
	var positions: Array[Vector2] = [Vector2(100, 185), Vector2(340, 240), Vector2(185, 350), Vector2(405, 395)]
	for index in range(positions.size()):
		var enemy = load("res://scenes/Enemy.tscn").instantiate()
		enemy.position = positions[index]
		enemy.speed = 0.0
		enemy.can_shoot = index % 2 == 1
		game.actors.add_child(enemy)
	# 画三条平行弹道（与“火力增援”3 发一致）：全部竖直向上，只有水平位置不同。
	# 这是本版弹道的直接视觉证据——一旦退回扇形发散，截图里立刻能看出来。
	for lane in [-1.0, 0.0, 1.0]:
		for y in [510.0, 430.0]:
			var bullet = load("res://scenes/PlayerBullet.tscn").instantiate()
			bullet.position = Vector2(240.0 + lane * 14.0, y)
			bullet.speed = 0.0
			game.actors.add_child(bullet)
	var threat = load("res://scenes/EnemyBullet.tscn").instantiate()
	threat.position = Vector2(340, 455)
	threat.speed = 0.0
	game.actors.add_child(threat)
	game.score = 140
	# 固定一个高于本局分数的历史纪录，让截图能看出“分数”与“最高”是两个独立数值。
	game.best_score = 260
	game.survival_time = 32.0
	# 让经验条处于进行中的状态，而不是空条。
	game.level = 1
	game.xp = 34
	# 给一个进行中的连击，好让截图里能看到琥珀色的倍率标签（12 连击 = ×3）。
	# 这是“连击倍率”这一新机制唯一的视觉证据，夹具不制造连击就永远看不到它。
	game.combo = 12
	await create_timer(0.2).timeout
	await capture("res://../playing-preview.png")

	# 暂停与设置面板。走真实开关路径，截完立刻恢复——否则后面每一张截图都会停在暂停状态。
	game.toggle_pause()
	await create_timer(0.15).timeout
	await capture("res://../pause-preview.png")
	game.toggle_pause()
	await create_timer(0.1).timeout

	# 特效验收：两处爆炸 + 受伤红闪。这一张特意关掉震动，否则整幅画面会歪着，
	# 反而看不清爆炸本身；震动另有断言覆盖。
	game.screen_shake_enabled = false
	for burst_at in [Vector2(150, 300), Vector2(345, 245)]:
		var burst = load("res://scenes/Explosion.tscn").instantiate()
		burst.position = burst_at
		game.actors.add_child(burst)
	game.hud.flash_damage()
	await create_timer(0.08).timeout
	await capture("res://../effects-preview.png")
	game.screen_shake_enabled = true
	# 等特效自行消散，免得它们跟着出现在后面几张截图里。
	await create_timer(0.6).timeout

	# 追踪导弹：切到游隼型，摆几架远处的敌机，等它按节奏发几轮导弹再截图。
	# **这张的存在理由**：上一版把锁定射程压到 110 像素来保平衡，数据上完全达标，
	# 但那个距离几乎贴着玩家、**玩家根本看不见追踪**（真人试玩直接反馈"没有追踪效果"）。
	# 所以"追踪看得见"必须自己有一张图，而不是只靠平衡数字。
	game.set_ship("homing")
	for spot in [Vector2(120, 210), Vector2(360, 300), Vector2(240, 170)]:
		var target_enemy = load("res://scenes/Enemy.tscn").instantiate()
		target_enemy.position = spot
		target_enemy.speed = 0.0
		game.actors.add_child(target_enemy)
	game._seeker_cooldown = 0.0
	# 0.5 秒后截图：导弹正好在飞行途中。太晚的话它已经命中目标消失，图上什么都看不到
	# ——第一版就是这么截的，看起来像"追踪没做出来"，而其实是拍晚了。
	await create_timer(0.5).timeout
	await capture("res://../homing-preview.png")
	# 收尾：换回标准型并清场，免得这些敌机跟着出现在 Boss 截图里。
	game.set_ship("parallel")
	game._clear_entities()
	await create_timer(0.2).timeout

	# 贯穿光束：切到聚焦型，并给两条车道（等于“火力增援”拿了一级），好让光柱的
	# **平行车道**关系在图上看得明白：车道间距 14 像素、光柱判定宽 10 像素，所以两条
	# 光柱之间只留一道窄缝——图与这句话必须对得上，不能画出一条比判定更宽的光带。
	# 图上还能直接看出它的**射程**：光柱在屏幕中段就结束了，不再直达战斗区顶边，
	# 这是"太赖皮"那轮加上的代价（站桩融化 Boss 被切断），详情见 Main.gd 的 SHIPS 注释。
	# **这张的存在理由与追踪导弹那张完全相同**：光束是这台战机唯一的核心视觉标识，
	# 一旦宽度、渲染层级或几何算错，平衡数字照样全绿，只有真人看得出“东西没画出来”。
	game.set_ship("focus")
	game._bullet_count = 2
	# 敌机刻意摆在两条光柱**之外**：光柱覆盖窄正是这台战机的代价，图上要能看出来。
	for spot in [Vector2(110, 235), Vector2(375, 320)]:
		var flanking = load("res://scenes/Enemy.tscn").instantiate()
		flanking.position = spot
		flanking.speed = 0.0
		game.actors.add_child(flanking)
	await create_timer(0.3).timeout
	await capture("res://../beam-preview.png")
	game._bullet_count = 1
	game.set_ship("parallel")
	game._clear_entities()
	await create_timer(0.2).timeout

	# Boss 战：走真实登场路径，并手动把它推到位，好让截图里能看清机体与顶部血条。
	game.boss_pending = true
	game._on_enemy_timer_timeout()
	await create_timer(0.1).timeout
	for step in range(80):
		game.boss._physics_process(0.05)
	game.boss.take_hit()
	await create_timer(0.1).timeout
	await capture("res://../boss-preview.png")
	# 收尾：把 Boss 与它可能打出的弹清掉，免得出现在后面的截图里。
	game._purge_enemy_bullets()
	game.boss.deactivate()
	game.boss.queue_free()
	game.boss = null
	game.hud.hide_boss()
	game.enemy_timer.stop()
	await create_timer(0.2).timeout

	# 升级抉择界面：走真实路径——补满经验后击毁一架敌机触发升级，而不是手工摆状态。
	game.level = 3
	game.xp = game.xp_required(3) - 10
	game.add_score(10)
	await create_timer(0.2).timeout
	await capture("res://../levelup-preview.png")
	# 选第一项收尾：解除暂停，否则后面的结算截图会停在暂停状态。
	game.choose_upgrade(0)

	# 让结算战报显示一局打得有内容的数字，而不是一排 0。
	# 这些字段和上面的 score / survival_time 一样由 Main 维护，这里只是在摆一个可看的局面；
	# difficulty_level 是每帧从存活时长推出来的，必须紧挨着 game_over() 设置——
	# 中间只要过一帧，它就会被 _process 覆盖回去。
	game.kills = 61
	game.hits_taken = 2
	game.escaped_count = 4
	game.peak_combo_multiplier = 3
	game.survival_time = 128.0
	game.difficulty_level = 5
	game.game_over()
	await create_timer(0.2).timeout
	await capture("res://../gameover-preview.png")
	# 退出前先把音频停干净并放开流引用。结算音效有 0.88 秒，这里等它播完再收尾：
	# 只要还有播放对象活着，Godot 退出时就会偶发 "resources still in use at exit"，
	# 而这条诊断在日志里和真错误长得一样，会让验收时好时坏。
	await create_timer(1.0).timeout
	game.music.stop()
	for sfx_voice in game._sfx_players:
		sfx_voice.stop()
	await process_frame
	game.music.stream = null
	for sfx_voice in game._sfx_players:
		sfx_voice.stream = null
	await process_frame
	await process_frame
	game.queue_free()
	await process_frame
	await process_frame
	_finished = true
	quit()
