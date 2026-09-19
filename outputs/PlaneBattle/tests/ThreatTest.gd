extends SceneTree
## 威胁基准：量“敌方的火力有多少真的能穿过玩家弹幕、到达玩家面前”。
##
## 这个指标回答的是“后期还有没有威胁”。玩家的输出在能力叠满后会涨二十多倍，
## 而普通敌机始终是一发击毁——**如果玩家自己的弹幕就能把敌弹全部扫掉，那么无论把
## 密度、速度、开火概率调多高，玩家都感觉不到威胁**。只数“敌人有多少、打得多勤”
## 是量不出这一点的，必须量“漏过来的火力”。
##
## 之所以要把它固化成一条基准：真人明确反馈“一点威胁都没有”，而我此前几轮一直在
## 调密度、调曲线、调瞄准比例，全部是在“敌人那一侧”加码——方向就错了。
## 有了这条基准，任何一次调整都能验证“火力是否真的漏得过来了”。
##
## 运行：godot --headless --path . --script res://tests/ThreatTest.gd

## 看门狗上限，必须明显小于 validate_project 的 90 秒子进程超时。
const WATCHDOG_SECONDS: float = 110.0
## 每个难度档位的测量时长。必须小于 level_step_seconds，否则测量途中难度会跳档。
const MEASURE_SECONDS: float = 6.0
## 玩家固定在屏幕下方且全程不动：本项量的是“火力有没有漏过来”，不是“玩家会不会躲”。
## 让它一动不动，通过率才是与躲闪技术无关的客观值；同时它也是“最差情况”的命中数。
const PLAYER_POSITION: Vector2 = Vector2(240.0, 640.0)
## 敌弹越过玩家上方这么多像素，就算“已经到达玩家面前”。
const ARRIVAL_MARGIN: float = 90.0
## 要测的难度档位。覆盖真人实际会打到的区间（那两局分别死在难度 25 与 32）。
const PROBE_LEVELS: Array[int] = [10, 20, 30]
## 后期威胁的下限：最高难度那一档，每秒必须有多少发敌弹真的到达玩家面前，
## 以及每架敌机平均能打出多少发。
##
## 这两个数是本基准存在的理由，不是随手写的水位。它们防的是已经在真人身上发生过的
## 缺陷：玩家火力把敌机在开火之前就打死，于是敌方总输出被抹平——修复前实测每架只开
## **0.69** 发、每秒只有 **3.33** 发到达。补上齐射后实测为 3.7 发/架、19.8 发/秒。
##
## 门槛之所以敢定得离实测值这么近（约 35% 余量），是因为基准固定了随机种子（见 RNG_SEED）：
## 固定前“到达/秒”在 8~19 之间跳，只能把下限定到 8.0，结果偶发失败；固定后同一份代码
## 连跑三次是 19.83 / 20.33 / 19.83，只差帧时序带来的零点几。门槛贴着实测值才守得住东西。
const MIN_SHOTS_PER_ENEMY: float = 2.5
const MIN_ARRIVALS_PER_SECOND: float = 12.0

## 固定随机种子。基准里的出生横坐标、开火与瞄准判定都走 Main 的 rng：不固定的话，
## 同一份代码量出来的“到达/秒”会在 8~19 之间跳（差一倍多），下限就只能定得极松，
## 而那么松的下限守不住任何东西（曾经把下限定在 8.0，结果偶发失败——实测最小值
## 恰好是 8.17）。固定种子之后这个量变成可复现的，才能给一个有意义的门槛。
## 注意：只影响基准，游戏运行时仍然 `rng.randomize()`。
const RNG_SEED: int = 20260918

var failures: int = 0
var checks: int = 0
var _finished: bool = false
## 由敌机的 shoot_requested 信号累加：这才是“敌方一共打出了多少发”的真实分母。
## 不能只靠每帧去数场上的敌弹——被立刻拦截掉的弹一帧都活不到，会被漏掉，
## 通过率就会算得偏高，得出的结论正好与事实相反。
var _enemy_shots: int = 0

func _initialize() -> void:
	_run.call_deferred()
	create_timer(WATCHDOG_SECONDS).timeout.connect(_on_watchdog_timeout)

func _on_watchdog_timeout() -> void:
	if _finished:
		return
	push_error("ThreatTest 超过 %.0f 秒仍未结束：_run() 很可能中途因运行时错误中断了" % WATCHDOG_SECONDS)
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

func _count_enemy_shot(_origin: Vector2, _direction: Vector2, _speed: float) -> void:
	_enemy_shots += 1

func _stack_upgrades(game) -> void:
	# 与 StressTest 同样的满配。这不是“理论极限”而已——真人 4~5 分钟时手里就是
	# 10~11 项能力，接近这个强度，所以它同时是“后期实际强度”的代表。
	for id in ["rapid_fire", "multishot", "wing_shot", "velocity", "caliber", "pierce", "interceptor"]:
		for _index in range(game._max_stacks_of(id)):
			game.upgrade_stacks[id] = game._stacks_of(id) + 1
			game._apply_upgrade(id)

func _measure(game, target_difficulty: int) -> Dictionary:
	# 难度是 _process 每帧从 survival_time 推出来的派生值，所以要从时间倒推着设，
	# 不能直接赋值（下一帧就会被覆盖）。escape_pressure 保持 0，避免混入第二个来源。
	game.enemy_timer.stop()
	game._clear_entities()
	game.escape_pressure = 0.0
	game.survival_time = float(target_difficulty - 1) * maxf(game.tuning.level_step_seconds, 1.0)
	game._process(0.0)
	var start_difficulty: int = game.difficulty_level
	await settle(2)

	var arrival_y: float = PLAYER_POSITION.y - ARRIVAL_MARGIN
	var hits_before: int = game.hits_taken
	var kills_before: int = game.kills
	var spawned_count: int = 0
	_enemy_shots = 0
	var seen := {}
	var arrived := {}
	var steps_per_enemy: int = maxi(1, int(round(game.get_spawn_interval() * 120.0)))

	Input.action_press("shoot")
	for step in range(int(MEASURE_SECONDS * 120.0)):
		if step % steps_per_enemy == 0:
			game._create_enemy(game.run_id)
			var spawned = game.actors.get_child(game.actors.get_child_count() - 1)
			# 接在 Main 之后再加一条连接：只用来计数，不影响子弹的生成。
			if spawned != null and spawned.has_signal("shoot_requested"):
				spawned.shoot_requested.connect(_count_enemy_shot)
				spawned_count += 1
		await physics_frame
		for bullet in get_nodes_in_group("enemy_bullet"):
			var bullet_id: int = bullet.get_instance_id()
			seen[bullet_id] = true
			if bullet.global_position.y >= arrival_y:
				arrived[bullet_id] = true
	Input.action_release("shoot")
	await settle(2)
	return {
		"difficulty": start_difficulty,
		"end_difficulty": game.difficulty_level,
		"spawned": spawned_count,
		"kills": game.kills - kills_before,
		"shots": _enemy_shots,
		"lived": seen.size(),
		"arrived": arrived.size(),
		"hits": game.hits_taken - hits_before,
	}

func _run() -> void:
	var game = load("res://scenes/Main.tscn").instantiate()
	root.add_child(game)
	await settle(2)
	game.start_game()
	game.enemy_timer.stop()
	_stack_upgrades(game)
	# 玩家全程不动，且不会被打死：本项量的是火力能不能漏过来，
	# 一旦游戏结束，state 离开 PLAYING，_process 与生成都会停，测量就废了。
	game.player.position = PLAYER_POSITION
	game.lives = 999999
	# 关掉经验：击毁敌机会累积经验并触发升级抉择，而抉择会把整局暂停——一旦暂停，
	# _create_enemy 会因 state != PLAYING 直接返回，场上再也没有敌机，
	# 测量出来的“通过率”就成了一个由故障伪装成的 0%。
	# （这正是 StressTest 里那句注释警告过的坑，我第一版漏了它，结果难度 20 那一档
	#   每帧都在越界取子节点。）
	game.xp_multiplier = 0.0
	# 固定随机种子：见 RNG_SEED 的说明。放在这里而不是 _ready，是因为 Main 自己会
	# 先 randomize()，必须在它之后覆盖才有效。
	game.rng.seed = RNG_SEED

	var bullets_per_shot: int = game._bullet_count + game._wing_pairs * 2
	var shot_interval: float = game.player.shoot_cooldown
	var summary_parts: Array[String] = []
	## 每台战机各跑一遍全部难度档。战机把平衡面翻了几倍，靠手调是守不住的——
	## 所以把"每台战机都必须达标"变成断言：任何一台把威胁抹平，构建就失败。
	var per_ship_late: Array[Dictionary] = []

	for ship in game.SHIPS:
		game.set_ship(ship["id"])
		var ship_results: Array[Dictionary] = []
		for target in PROBE_LEVELS:
			var result: Dictionary = await _measure(game, target)
			ship_results.append(result)
			var shots: int = int(result["shots"])
			var arrived: int = int(result["arrived"])
			var spawned: int = int(result["spawned"])
			var kills: int = int(result["kills"])
			var rate: float = 0.0 if shots <= 0 else float(arrived) / float(shots)
			# “每架敌机开了几枪”是这套测量的核心诊断量：玩家火力如果能在敌机开火之前
			# 就把它打掉，那么敌弹总量会被直接掐死在源头——这时把密度调多高都没用。
			var shots_per_enemy: float = 0.0 if spawned <= 0 else float(shots) / float(spawned)
			var kill_ratio: float = 0.0 if spawned <= 0 else float(kills) / float(spawned)
			print(
				"THREAT: 战机=%s 难度=%d 敌机=%d 击毁=%.0f%% 每架开火=%.2f 敌弹=%d 到达=%d 通过率=%.1f%% 到达/秒=%.2f 固定靶被命中=%d"
				% [ship["name"], int(result["difficulty"]), spawned, kill_ratio * 100.0, shots_per_enemy,
					shots, arrived, rate * 100.0,
					float(arrived) / MEASURE_SECONDS, int(result["hits"])]
			)
			summary_parts.append("%s@%d:%.1f%%" % [ship["id"], int(result["difficulty"]), rate * 100.0])
			# 前提断言：敌人确实开火了、也有弹真正活过一帧。少了这两条，
			# 下面的通过率会因为分母是 0 而“看起来是 0%”，把故障伪装成结论。
			check(shots > 0, "%s 在难度 %d 确实面对了敌方火力（通过率的分母有效）" % [ship["name"], target])
			check(int(result["lived"]) > 0, "%s 在难度 %d 有敌弹真正存在于场上" % [ship["name"], target])
		per_ship_late.append({"name": ship["name"], "result": ship_results[ship_results.size() - 1]})

	print(
		"THREAT-SUMMARY: 弹幕=%d发/次 冷却=%.3fs 通过率 %s"
		% [bullets_per_shot, shot_interval, " ".join(summary_parts)]
	)

	# 后期威胁的下限断言——这条断言才是本基准存在的理由。
	# 它防的是那个已经在真人身上发生过的缺陷：玩家火力把敌机在开火之前就打死，
	# 敌方总输出被抹平，于是“再怎么调密度都没有威胁”。改前实测每架 0.69 发、
	# 每秒 3.33 发到达；补上齐射后是 2.1~3.3 发/架、12.2~17.5 发/秒。
	# **每台战机都必须达标**——这是本基准在"开局选战机"之后新增的职责：
	# 形态把平衡面翻了几倍，靠手调守不住，所以把它变成构建级断言。
	for entry in per_ship_late:
		var late: Dictionary = entry["result"]
		var late_arrivals_per_second: float = float(late["arrived"]) / MEASURE_SECONDS
		var late_shots_per_enemy: float = float(late["shots"]) / maxf(float(late["spawned"]), 1.0)
		check(
			late_shots_per_enemy >= MIN_SHOTS_PER_ENEMY,
			"%s：最高难度下每架敌机的开火量不低于 %.1f 发（实测 %.2f）"
				% [entry["name"], MIN_SHOTS_PER_ENEMY, late_shots_per_enemy]
		)
		check(
			late_arrivals_per_second >= MIN_ARRIVALS_PER_SECOND,
			"%s：最高难度下每秒到达玩家面前的敌弹不低于 %.1f 发（实测 %.2f）"
				% [entry["name"], MIN_ARRIVALS_PER_SECOND, late_arrivals_per_second]
		)

	# 退出前把音频停干净并放开流引用，否则退出时会偶发 "resources still in use at exit"。
	# 先显式清场：最后一次测量留下的敌机与敌弹数量不少（满配时上百个），只靠
	# queue_free(game) 去递归释放，会让退出期的泄漏诊断时有时无。
	game.enemy_timer.stop()
	game._clear_entities()
	await settle(6)
	game.music.stop()
	for sfx_voice in game._sfx_players:
		sfx_voice.stop()
	await settle(4)
	game.music.stream = null
	for sfx_voice in game._sfx_players:
		sfx_voice.stream = null
	await settle(4)
	game.queue_free()
	await settle(6)
	_finished = true
	print("RESULT: ", checks - failures, "/", checks, " checks passed; failures=", failures)
	quit(0 if failures == 0 else 1)
