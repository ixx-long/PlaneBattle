extends SceneTree
## 长时浸泡基准：满配连续打 SOAK_SECONDS 秒，看帧时间与实体数会不会**随时间漂移**。
##
## 它回答的是压力基准回答不了的那个问题——“长期局会不会越打越卡”。压力基准只测 6 秒，
## 能证明“瞬时负载在预算内”，证明不了“时间长了会不会变差”。外部评估据此提过
## “满配每秒 instantiate/free 上百节点，长期局有 GC 抖动风险”的担忧；这条基准的作用
## 就是把这个担忧从猜测变成数据：**真漂移就失败，不漂移就结案**，而不是靠再解释一遍。
##
## 运行：godot --headless --path . --script res://tests/SoakTest.gd

## 看门狗必须明显小于 validate_project 的外层超时（240 秒）。
const WATCHDOG_SECONDS: float = 150.0
## 浸泡时长。取 60 秒是压力基准（6 秒）的十倍：足以暴露“每秒都在缓慢累积”的问题，
## 又不至于让整条验证流水线变得难以忍受。**注意它仍然不是完整的一局**——
## 真人的一局是 2~5 分钟，这里没有覆盖那么长，这一点写在文档里而不是含糊过去。
const SOAK_SECONDS: float = 60.0
## 固定随机种子：不固定的话出生位置与开火判定每次都不同，前后半段的对比会被噪声淹没。
const RNG_SEED: int = 20260918

## 判定“没有退化”的门槛。帧时间与实体数天然有波动，卡得太紧就变成噪声测试、
## 只会偶发失败而抓不到真问题，所以留 25~30% 的余量。
const FRAME_DRIFT_TOLERANCE: float = 1.25
const ACTOR_DRIFT_TOLERANCE: float = 1.30
## ObjectDB 对象数的净增上限。持续创建而不释放的东西会在这里露出来。
const OBJECT_GROWTH_CAP: int = 300

var failures: int = 0
var checks: int = 0
var _finished: bool = false

func _initialize() -> void:
	_run.call_deferred()
	create_timer(WATCHDOG_SECONDS).timeout.connect(_on_watchdog_timeout)

func _on_watchdog_timeout() -> void:
	if _finished:
		return
	push_error("SoakTest 超过 %.0f 秒仍未结束：_run() 很可能中途因运行时错误中断了" % WATCHDOG_SECONDS)
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

func _stack_upgrades(game) -> void:
	# 与 StressTest 相同的满配：这是最坏情况，也是真人 4~5 分钟时接近的强度。
	for id in ["rapid_fire", "multishot", "wing_shot", "velocity", "caliber", "pierce", "interceptor"]:
		for _index in range(game._max_stacks_of(id)):
			game.upgrade_stacks[id] = game._stacks_of(id) + 1
			game._apply_upgrade(id)

## 取一段帧时间的平均值。用均值而不是最大值：单次最大值被调度噪声主导
## （同一份代码能跑出 14 ms 也能跑出 79 ms），拿它做前后对比只会得到随机结论。
func _mean(values: PackedFloat32Array, from_index: int, to_index: int) -> float:
	if to_index <= from_index:
		return 0.0
	var total: float = 0.0
	for index in range(from_index, to_index):
		total += values[index]
	return total / float(to_index - from_index)

func _run() -> void:
	var game = load("res://scenes/Main.tscn").instantiate()
	root.add_child(game)
	await settle(2)
	game.start_game()
	game.enemy_timer.stop()
	_stack_upgrades(game)
	# 与压力基准同样的三条前提：玩家不动、不会死、不会被升级抉择打断。
	game.player.position = Vector2(240, 640)
	game.lives = 999999
	game.xp_multiplier = 0.0
	game.rng.seed = RNG_SEED
	# 推到最后一套编队与最高难度，才是真正的最坏情况。
	game.wave_index = game.tuning.waves.size() - 1
	game.survival_time = 99999.0
	game._process(0.0)
	var baseline_objects: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var steps_per_enemy: int = maxi(1, int(round(game.get_spawn_interval() * 120.0)))

	var steps: int = int(SOAK_SECONDS * 120.0)
	var frames := PackedFloat32Array()
	## 每秒一个“该秒内的实体峰值”，用来对比开头与结尾。
	var actor_peaks := PackedInt32Array()
	var second_peak: int = 0
	var second_frames: float = 0.0
	var second_count: int = 0
	Input.action_press("shoot")
	var last_tick: int = Time.get_ticks_usec()
	for step in range(steps):
		if step % steps_per_enemy == 0:
			game._create_enemy(game.run_id)
		await physics_frame
		var now: int = Time.get_ticks_usec()
		var frame_ms: float = float(now - last_tick) / 1000.0
		last_tick = now
		frames.append(frame_ms)
		second_frames += frame_ms
		second_count += 1
		second_peak = maxi(second_peak, game.actors.get_child_count())
		if step % 120 == 119:
			actor_peaks.append(second_peak)
			second_peak = 0
			second_count = 0
			second_frames = 0.0
	Input.action_release("shoot")

	# 停火后等实体自然出界或被释放，用来判断有没有“越打越积”。
	var drain_steps: int = 0
	while game.actors.get_child_count() > 0 and drain_steps < 4800:
		await physics_frame
		drain_steps += 1
	var residual_actors: int = game.actors.get_child_count()
	var object_growth: int = int(Performance.get_monitor(Performance.OBJECT_COUNT)) - baseline_objects

	# 前后对比：前半段 vs 后半段。取整段的一半而不是各取 10 秒，
	# 是为了让每一边都有足够的样本，降低单次抖动的影响。
	var half: int = frames.size() / 2
	var first_half_frame: float = _mean(frames, 0, half)
	var second_half_frame: float = _mean(frames, half, frames.size())
	var seconds: int = actor_peaks.size()
	var early_window: int = mini(10, seconds / 2)
	var late_window: int = mini(10, seconds / 2)
	var early_peak: int = 0
	for index in range(early_window):
		early_peak = maxi(early_peak, actor_peaks[index])
	var late_peak: int = 0
	for index in range(seconds - late_window, seconds):
		late_peak = maxi(late_peak, actor_peaks[index])

	print(
		"SOAK: 时长=%.0fs 前半帧=%.2fms 后半帧=%.2fms 早期实体峰值=%d 后期实体峰值=%d 清场步数=%d 残留Actors=%d 对象净增=%d"
		% [SOAK_SECONDS, first_half_frame, second_half_frame,
			early_peak, late_peak, drain_steps, residual_actors, object_growth]
	)

	check(first_half_frame > 0.0 and second_half_frame > 0.0, "前后半段都取到了有效的帧时间样本")
	check(
		second_half_frame <= first_half_frame * FRAME_DRIFT_TOLERANCE,
		"后半段帧时间没有随时间退化（%.2fms → %.2fms）" % [first_half_frame, second_half_frame]
	)
	check(
		late_peak <= maxi(1, int(float(early_peak) * ACTOR_DRIFT_TOLERANCE)),
		"后期实体峰值没有持续增长（%d → %d）" % [early_peak, late_peak]
	)
	check(residual_actors == 0, "停火后所有实体都被释放，没有越打越积")
	check(
		object_growth <= OBJECT_GROWTH_CAP,
		"对象净增在预算内（%d ≤ %d），没有持续创建而不释放的东西" % [object_growth, OBJECT_GROWTH_CAP]
	)

	# 退出前把音频停干净并放开流引用，否则退出时会偶发 "resources still in use at exit"。
	# 先显式清场：浸泡结束时场上的实体比压力基准更多。
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
