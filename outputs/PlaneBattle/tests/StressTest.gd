extends SceneTree
## 最坏情况的压力基准：把所有攻击类能力叠满、按住射击打满一段时间，
## 量出峰值对象数、帧时间与清场后的残留。
##
## 它存在的意义不是玩法验收，而是给“要不要做对象池”这个决策提供**数据**，
## 并把结论固化成断言：以后若有人把弹幕密度改到远超今天的水平，这条基准会先失败，
## 提醒重新评估对象池，而不是等到玩家感觉到卡顿。
##
## 运行：godot --headless --path . --script res://tests/StressTest.gd

## 看门狗上限，必须明显小于 validate_project 的 90 秒子进程超时。
const WATCHDOG_SECONDS: float = 75.0
## 测量时长（秒）。物理频率 120 Hz，所以步数是它的 120 倍。
const MEASURE_SECONDS: float = 6.0

## 峰值并发子弹的上限。实测值远低于它——留出接近一倍余量，
## 只有弹幕密度发生数量级变化时才会触发。
const PEAK_BULLET_CAP: int = 250
## 峰值 Actors 子节点数的上限（子弹 + 敌机 + 敌弹 + 爆炸）。
const PEAK_ACTOR_CAP: int = 320

var failures: int = 0
var checks: int = 0
var _finished: bool = false

func _initialize() -> void:
	_run.call_deferred()
	create_timer(WATCHDOG_SECONDS).timeout.connect(_on_watchdog_timeout)

func _on_watchdog_timeout() -> void:
	if _finished:
		return
	push_error("StressTest 超过 %.0f 秒仍未结束：_run() 很可能中途因运行时错误中断了" % WATCHDOG_SECONDS)
	quit(1)

func check(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("PASS: ", message)
	else:
		failures += 1
		push_error("FAIL: " + message)

func settle(frames: int = 4) -> void:
	# 与 SmokeTest 一致：释放节点与放开资源引用都需要跨过若干帧才真正生效，
	# 只等一帧就退出会偶发 "resources still in use at exit"。
	for index in range(frames):
		await physics_frame
		await process_frame

func _stack_upgrades(game) -> void:
	# 只叠攻击类能力：这是本作能达到的最高弹幕密度，也是对象周转最凶的情形。
	for id in ["rapid_fire", "multishot", "wing_shot", "velocity", "caliber", "pierce", "interceptor"]:
		for _index in range(game._max_stacks_of(id)):
			game.upgrade_stacks[id] = game._stacks_of(id) + 1
			game._apply_upgrade(id)

func _run() -> void:
	var game = load("res://scenes/Main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	await physics_frame
	game.start_game()
	game.enemy_timer.stop()
	# **必须显式钉住战机**。战机的选择是写进 `user://save.cfg` 的持久设置，而威胁基准会把
	# 三台战机都跑一遍、最后停在聚焦型；不钉住的话，这条基准量的就是“上一次测试留下的
	# 那一台”，而且流程里两条基准的先后顺序会悄悄改变结论。子弹系是对象周转最快的一台
	# （满配每秒 148 发 instantiate/free），所以最坏情况取它。
	game.set_ship("parallel")
	_stack_upgrades(game)
	game.player.position = Vector2(240, 640)
	# 关掉经验：击毁敌机会累积经验并触发升级抉择，而升级会把整局暂停——
	# 一旦暂停，实体不再移动、也就永远不会出界被释放，测出来的峰值与帧时间全是假的。
	# 升级本身与对象周转无关，这里只需要它的“不干扰”。
	game.xp_multiplier = 0.0
	# 把波次推到最后一波、难度推到最高：那样才有瞄准射击（精锐波 aim_ratio 0.6 再加每级难度加成）。
	# 否则默认停在第一波、aim_ratio 为 0，量出来的根本不是最坏情况。
	game.wave_index = game.tuning.waves.size() - 1
	game.survival_time = 99999.0
	game._process(0.0)

	var bullets_per_shot: int = game._bullet_count + game._wing_pairs * 2
	var shot_interval: float = game.player.shoot_cooldown
	# 用**游戏真实的刷怪间隔**，而不是写死一个步数。原先写死 0.3 秒一架，
	# 那比真实高难度还稀疏（当时实际是 0.18 秒一架），于是"峰值 Actors 在预算内"
	# 这条结论对敌机密度并不成立——它只压住了玩家弹幕那一半。
	# 难度此刻已被推到有效上限，所以这里拿到的就是最坏情况的密度。
	var steps_per_enemy: int = maxi(1, int(round(game.get_spawn_interval() * 120.0)))
	var baseline_objects: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))

	Input.action_press("shoot")
	var steps: int = int(MEASURE_SECONDS * 120.0)
	var peak_bullets: int = 0
	var peak_actors: int = 0
	var frame_samples := PackedFloat32Array()
	var sum_frame_ms: float = 0.0
	# 用墙钟测每步耗时，而不是 Performance.TIME_PROCESS：
	# 无头模式下后者报出来的值明显偏大（实测 33ms，但整段 720 步根本不可能跑满 24 秒），
	# 拿它当“帧时间”会得出与事实相反的结论。这里量的是真实的步进间隔。
	var last_tick: int = Time.get_ticks_usec()
	for step in range(steps):
		if step % steps_per_enemy == 0:
			game._create_enemy(game.run_id)
		await physics_frame
		var now: int = Time.get_ticks_usec()
		var frame_ms: float = float(now - last_tick) / 1000.0
		last_tick = now
		sum_frame_ms += frame_ms
		frame_samples.append(frame_ms)
		peak_bullets = maxi(peak_bullets, get_nodes_in_group("player_bullet").size())
		peak_actors = maxi(peak_actors, game.actors.get_child_count())
	Input.action_release("shoot")

	# 这里刻意报 p99 而不是"最差帧"。最大值在无头 Windows 进程里被调度噪声主导：
	# 同一份代码连跑四次量到 14.21 / 17.13 / 14.21 / **78.85** ms，而平均帧稳定在
	# 8.24 ms。把最大值写进验证报告，等于用一个噪声样本去论证"仍在 60 FPS 预算内"——
	# 那是错的证据。p99 既剔除个别离群点，又能在真实性能回归时随整个分布一起上移。
	frame_samples.sort()
	var p99_frame_ms: float = 0.0
	if not frame_samples.is_empty():
		var p99_index: int = clampi(
			int(ceil(float(frame_samples.size()) * 0.99)) - 1, 0, frame_samples.size() - 1
		)
		p99_frame_ms = frame_samples[p99_index]

	# 停火后等所有实体自然出界或消失，用来判断有没有“越打越积”的泄漏。
	var drain_steps: int = 0
	while game.actors.get_child_count() > 0 and drain_steps < 2400:
		await physics_frame
		drain_steps += 1
	var residual_actors: int = game.actors.get_child_count()
	var object_growth: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - baseline_objects

	print(
		"STRESS: 弹幕=%d发/次 冷却=%.3fs 理论=%.0f发/秒 峰值子弹=%d 峰值Actors=%d 平均帧=%.2fms 帧p99=%.2fms 清场步数=%d 残留Actors=%d 对象净增=%d 战机=%s"
		% [
			bullets_per_shot, shot_interval, float(bullets_per_shot) / maxf(shot_interval, 0.001),
			peak_bullets, peak_actors, sum_frame_ms / float(steps), p99_frame_ms,
			drain_steps, residual_actors, object_growth, game.current_ship()["name"]
		]
	)

	check(peak_bullets > 0 and peak_bullets <= PEAK_BULLET_CAP, "峰值并发子弹在预算之内")
	check(peak_actors <= PEAK_ACTOR_CAP, "峰值 Actors 子节点数在预算之内")
	check(residual_actors == 0, "停火后所有实体都被释放，没有越打越积")
	# 与浸泡基准同一条守卫：战机是持久设置，被上一条基准改掉之后，这条基准量的就不再是
	# "满配子弹系"这台最坏情况，而日志里的数字看起来毫无异样。
	check(not game.ship_uses_beam(), "基准量的是子弹系满配（对象周转最快的一台，即最坏情况）")

	# 退出前必须把音频停干净并放开流引用。start_game() 会放背景音乐，
	# 若播放器还握着 AudioStream，Godot 退出时会偶发
	# "N resources still in use at exit"，把压力日志弄脏。
	game.music.stop()
	for sfx_voice in game._sfx_players:
		sfx_voice.stop()
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
