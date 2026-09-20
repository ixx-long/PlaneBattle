extends SceneTree
## 追击基准：量"玩家**按人的方式打**时，三台战机各是什么体验"，并守住三条结论。
##
## 为什么需要它：威胁基准把玩家钉死在屏幕下方并且盲目扫射，那对**瞬间命中**的光束战机是
## 失真的——真人会看着敌机打、会往够得着的地方挪。光束加入之后，两个真实缺陷都是这条
## 基准量出来的、而威胁基准完全看不见：
##   ① **Boss 血量被上限截断**：满配光柱每秒伤害 275，公式给出 1925，被 1400 的上限砍到
##      1400，于是"按 7 秒设计"的 Boss 5.1 秒就没了，而子弹系要 9~10 秒（他们的公式默认
##      发发命中，实际只兑现约 74%）。
##   ② **光柱不需要预判也不需要靠近**：子弹必须提前约 0.5 秒打在那个位置上，光柱是
##      "现在指到谁谁就没"，而且能隔着半屏清场、站在屏幕底部把 Boss 融化。
##
## 这个玩家模型是**机器人，不是人**：它只朝最近的敌机靠过去（每 0.15 秒更新一次目标，
## 模拟反应延迟），并且**完全不闪避**。所以它量的是"武器本身能打成什么样"，不是"人能不
## 能活下来"。断言也只钉那些跨版本稳定的性质，不钉具体数值。
##
## 运行：godot --headless --path . --script res://tests/PursuitTest.gd

## 看门狗必须明显小于 validate_project 的 300 秒外层超时。
const WATCHDOG_SECONDS: float = 260.0
## 前场量 10 秒。取 6 秒时样本只有 45 架敌机，**一台之差就是 2.2 个百分点**，
## 门槛会卡在边界上偶发失败；10 秒把同样的抖动压到 1.3 个点。
const MEASURE_SECONDS: float = 10.0
const BOSS_MEASURE_SECONDS: float = 5.0
const RNG_SEED: int = 20260918
const ARRIVAL_MARGIN: float = 90.0
## 后期才有意义：前期的敌机密度与开火频率都还没起来。
const PROBE_LEVEL: int = 30
## 反应延迟：每这么多帧才重新选一次目标。人的反应约 0.15~0.25 秒。
const REACTION_FRAMES: int = 18
const DEAD_ZONE: float = 4.0
const PLAYER_Y: float = 640.0
const PURSUIT_MIN_Y: float = 220.0
const PURSUIT_MAX_Y: float = 700.0
## 击毁率下限：守住"没有任何一台被削到没法玩"。10 秒窗口下实测 80%~87%，门槛取 65%。
const MIN_KILL_RATIO: float = 0.65
## 任意两台之间的击毁率差距上限（百分点）。形态可以有强弱侧重，但不能差出一倍。
##
## **这个数是按实测分布定的**：同一份代码连跑多次，差距在 7~17 个百分点之间漂——
## 漂移来自机器人本身（它每 18 帧才换一次目标，而三台武器对"目标在哪"的敏感度不同：
## 导弹要追、光柱要覆盖、直弹幕只看车道）。上限取 25 而不是贴着 17，是因为**贴着实测值
## 定的门槛只会偶发失败**（这条教训在威胁基准上已经吃过一次）。它守的性质没有变：
## 25 个百分点对应约 1.4 倍的差距，仍然远小于"差出一倍"。
const MAX_KILL_SPREAD: float = 0.25
## Boss 击破秒数的容许区间。设计目标是 boss_target_seconds（7 秒），
## 但子弹的实际命中率、光柱的射程都会把它推到 8 秒上下；超过这个区间说明公式或形态又偏了。
const BOSS_KILL_MIN_SECONDS: float = 5.0
const BOSS_KILL_MAX_SECONDS: float = 12.0

var failures: int = 0
var checks: int = 0
var _finished: bool = false
var _enemy_shots: int = 0
var _kill_distances: Array[float] = []
var _aim := Vector2(240.0, PLAYER_Y)
var _step: int = 0

func _initialize() -> void:
	_run.call_deferred()
	create_timer(WATCHDOG_SECONDS).timeout.connect(_on_watchdog_timeout)

func _on_watchdog_timeout() -> void:
	if _finished:
		return
	push_error("PursuitTest 超过 %.0f 秒仍未结束：_run() 很可能中途因运行时错误中断了" % WATCHDOG_SECONDS)
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
	# 与压力/威胁/浸泡基准同样的满配：真人 4~5 分钟时手里就是这个强度。
	for id in ["rapid_fire", "multishot", "wing_shot", "velocity", "caliber", "pierce", "interceptor"]:
		for _index in range(game._max_stacks_of(id)):
			game.upgrade_stacks[id] = game._stacks_of(id) + 1
			game._apply_upgrade(id)

func _on_enemy_destroyed(_points: int, instance_id: int) -> void:
	var enemy = instance_from_id(instance_id)
	if enemy != null and is_instance_valid(enemy):
		_kill_distances.append(PLAYER_Y - enemy.global_position.y)

func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total: float = 0.0
	for value in values:
		total += value
	return total / float(values.size())

func _release_inputs() -> void:
	for action in ["move_left", "move_right", "move_up", "move_down", "shoot"]:
		Input.action_release(action)

## 朝最近的敌机靠过去（横向 + 纵向），每 REACTION_FRAMES 帧才换一次目标。
##
## 纵向也允许移动是有意的：射程被限制之后，"够不着的敌人要不要上去打"正是这台战机
## 的核心取舍。只让它横向跟踪会**低估**它——机器人会一直追一个自己根本打不到的目标。
## 代价那一侧由"击毁距离"体现：三台战机分别在多远的地方结束战斗。
func _pursue(game) -> void:
	if _step % REACTION_FRAMES == 0:
		var target := Vector2.ZERO
		var best: float = 1e9
		var found: bool = false
		for enemy in get_nodes_in_group("enemy"):
			if not is_instance_valid(enemy) or enemy.is_queued_for_deletion():
				continue
			var spot: Vector2 = enemy.global_position
			var distance: float = game.player.global_position.distance_to(spot)
			if distance < best:
				best = distance
				target = spot
				found = true
		if found:
			# 停在敌机下方一点点：贴太近会撞上，离太远又打不到。
			_aim = Vector2(target.x, clampf(target.y + 40.0, PURSUIT_MIN_Y, PURSUIT_MAX_Y))
	var delta: Vector2 = _aim - game.player.global_position
	if delta.x > DEAD_ZONE:
		Input.action_press("move_right")
		Input.action_release("move_left")
	elif delta.x < -DEAD_ZONE:
		Input.action_press("move_left")
		Input.action_release("move_right")
	else:
		Input.action_release("move_left")
		Input.action_release("move_right")
	if delta.y > DEAD_ZONE:
		Input.action_press("move_down")
		Input.action_release("move_up")
	elif delta.y < -DEAD_ZONE:
		Input.action_press("move_up")
		Input.action_release("move_down")
	else:
		Input.action_release("move_up")
		Input.action_release("move_down")

func _prepare(game, target_difficulty: int) -> void:
	game.enemy_timer.stop()
	game._clear_entities()
	game.escape_pressure = 0.0
	game.survival_time = float(target_difficulty - 1) * maxf(game.tuning.level_step_seconds, 1.0)
	game._process(0.0)
	game.player.position = Vector2(240.0, PLAYER_Y)
	_aim = Vector2(240.0, PLAYER_Y)
	await settle(2)

func _measure_field(game) -> Dictionary:
	await _prepare(game, PROBE_LEVEL)
	var arrival_y: float = PLAYER_Y - ARRIVAL_MARGIN
	var kills_before: int = game.kills
	var spawned_count: int = 0
	_enemy_shots = 0
	_kill_distances.clear()
	var seen := {}
	var arrived := {}
	var steps_per_enemy: int = maxi(1, int(round(game.get_spawn_interval() * 120.0)))

	Input.action_press("shoot")
	for step in range(int(MEASURE_SECONDS * 120.0)):
		_step = step
		_pursue(game)
		if step % steps_per_enemy == 0:
			game._create_enemy(game.run_id)
			var spawned = game.actors.get_child(game.actors.get_child_count() - 1)
			if spawned != null and spawned.has_signal("shoot_requested"):
				spawned.shoot_requested.connect(_count_enemy_shot)
				spawned_count += 1
				spawned.destroyed.connect(_on_enemy_destroyed.bind(spawned.get_instance_id()))
		await physics_frame
		for bullet in get_nodes_in_group("enemy_bullet"):
			var bullet_id: int = bullet.get_instance_id()
			seen[bullet_id] = true
			if bullet.global_position.y >= arrival_y:
				arrived[bullet_id] = true
	_release_inputs()
	await settle(2)

	return {
		"difficulty": game.difficulty_level,
		"spawned": spawned_count,
		"kills": game.kills - kills_before,
		"shots": _enemy_shots,
		"arrived": arrived.size(),
		"kill_distance": _mean(_kill_distances),
	}

## Boss 战：走真实登场路径把 Boss 推到位，量实际每秒扣血与击破秒数。
## pursue = true 时用追击模型；false 时玩家**站在屏幕底部完全不动**。
func _measure_boss(game, pursue: bool) -> Dictionary:
	game._clear_entities()
	game.boss_pending = false
	game._start_boss()
	await settle(2)
	if not is_instance_valid(game.boss):
		return {"ok": false}
	for _step in range(80):
		game.boss._physics_process(0.05)
	var max_hp: int = game.boss.max_hp
	var hp_before: int = game.boss.hp
	game.player.position = Vector2(240.0, PLAYER_Y)
	_aim = Vector2(240.0, PLAYER_Y)
	Input.action_press("shoot")
	var elapsed: int = 0
	for step in range(int(BOSS_MEASURE_SECONDS * 120.0)):
		_step = step
		if pursue:
			_pursue(game)
		await physics_frame
		elapsed += 1
		if not is_instance_valid(game.boss):
			break
	_release_inputs()
	var dealt: int = hp_before - (game.boss.hp if is_instance_valid(game.boss) else 0)
	var seconds: float = float(elapsed) / 120.0
	var dps: float = 0.0 if seconds <= 0.0 else float(dealt) / seconds
	var killed: bool = not is_instance_valid(game.boss)
	return {
		"ok": true,
		"max_hp": max_hp,
		"dealt": dealt,
		"dps": dps,
		# 打死了就报实际用时；没打死就按当前输出外推，两种情况下都能比较。
		"kill_seconds": seconds if killed else (0.0 if dps <= 0.0 else float(max_hp) / dps),
	}

func _run() -> void:
	var game = load("res://scenes/Main.tscn").instantiate()
	root.add_child(game)
	await settle(2)
	game.start_game()
	game.enemy_timer.stop()
	_stack_upgrades(game)
	game.player.position = Vector2(240.0, PLAYER_Y)
	game.lives = 999999
	game.xp_multiplier = 0.0
	game.rng.seed = RNG_SEED

	var kill_ratios: Array[float] = []
	var best_kill_ratio: float = 0.0
	var boss_seconds: Array[float] = []
	var boss_parts: Array[String] = []

	for ship in game.SHIPS:
		game.set_ship(ship["id"])
		var field: Dictionary = await _measure_field(game)
		var spawned: int = int(field["spawned"])
		var kills: int = int(field["kills"])
		var kill_ratio: float = float(kills) / maxf(float(spawned), 1.0)
		kill_ratios.append(kill_ratio)
		best_kill_ratio = maxf(best_kill_ratio, kill_ratio)
		print(
			"PURSUIT: 战机=%s 难度=%d 敌机=%d 击毁=%.0f%% 每架开火=%.2f 到达/秒=%.2f 击毁距离=%.0f"
			% [ship["name"], int(field["difficulty"]), spawned, kill_ratio * 100.0,
				float(field["shots"]) / maxf(float(spawned), 1.0),
				float(field["arrived"]) / MEASURE_SECONDS, float(field["kill_distance"])]
		)
		check(
			kill_ratio >= MIN_KILL_RATIO,
			"%s：追击模型下的击毁率不低于 %.0f%%（实测 %.0f%%）"
				% [ship["name"], MIN_KILL_RATIO * 100.0, kill_ratio * 100.0]
		)
		var pursuing_boss: Dictionary = await _measure_boss(game, true)
		check(bool(pursuing_boss["ok"]), "%s：Boss 正常登场（Boss 战的数据有效）" % ship["name"])
		if bool(pursuing_boss["ok"]):
			var seconds: float = float(pursuing_boss["kill_seconds"])
			boss_seconds.append(seconds)
			boss_parts.append("%s %.1fs" % [ship["id"], seconds])
			print(
				"PURSUIT-BOSS: 战机=%s 满血=%d 每秒扣血=%.1f 击破=%.1fs"
				% [ship["name"], int(pursuing_boss["max_hp"]), float(pursuing_boss["dps"]), seconds]
			)
			check(
				seconds >= BOSS_KILL_MIN_SECONDS and seconds <= BOSS_KILL_MAX_SECONDS,
				"%s：主动上前打 Boss 的击破用时在 %.0f~%.0f 秒之间（实测 %.1f 秒）"
					% [ship["name"], BOSS_KILL_MIN_SECONDS, BOSS_KILL_MAX_SECONDS, seconds]
			)
		# 站着不动的那一侧：光柱够不着就必须真的够不着，子弹则照样能打到。
		# 这条断言把"射程是真实代价"钉死——把 beam_range 调回全屏会立刻失败。
		var standing_boss: Dictionary = await _measure_boss(game, false)
		if bool(standing_boss["ok"]):
			print(
				"PURSUIT-BOSS-STILL: 战机=%s 满血=%d 每秒扣血=%.1f"
				% [ship["name"], int(standing_boss["max_hp"]), float(standing_boss["dps"])]
			)
			if game.ship_uses_beam() or game.ship_uses_seekers():
				# 两台"远距离无效"的战机：光柱有射程，导弹有锁定射程。它们的共同代价是
				# **必须主动上前**——这也是它们高输出/必中的对价。
				check(
					int(standing_boss["dealt"]) == 0,
					"%s：站在屏幕底部不动时打不到 Boss（射程是真实代价，不是装饰）" % ship["name"]
				)
			else:
				check(
					int(standing_boss["dealt"]) > 0,
					"%s：同位置上直弹幕照样能打到 Boss（对照：射程限制是那两台战机的取舍）"
						% ship["name"]
				)

	print("PURSUIT-SUMMARY: 击毁率差距=%.0f%% Boss击破 %s"
		% [(best_kill_ratio - _min_ratio(kill_ratios)) * 100.0, " ".join(boss_parts)])
	check(
		best_kill_ratio - _min_ratio(kill_ratios) <= MAX_KILL_SPREAD,
		"三台战机的击毁率差距不超过 %.0f 个百分点（形态可以有侧重，但不能差出一倍）"
			% (MAX_KILL_SPREAD * 100.0)
	)

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

func _min_ratio(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var lowest: float = values[0]
	for value in values:
		lowest = minf(lowest, value)
	return lowest
