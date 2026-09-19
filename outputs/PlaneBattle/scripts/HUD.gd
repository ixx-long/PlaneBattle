extends Control
## 只负责显示和按钮请求，不持有游戏规则。
##
## 根节点在场景里设为 PROCESS_MODE_ALWAYS：升级抉择期间整棵树暂停，但选项必须
## 仍然可以点击、可以按数字键，所以暂停只冻结游戏世界，HUD 继续接收输入。

signal start_game
signal restart_game
signal upgrade_chosen(index: int)
## 暂停面板请求。HUD 只报告“玩家按了什么”，改不改规则由 Main 决定。
signal pause_toggle_requested
signal pause_restarted
signal shake_toggled(enabled: bool)
## 音量：bus_name 取 "Music" / "SFX"，percent 为 0~100。
signal volume_changed(bus_name: String, percent: int)

## 与 Main 的选项数上限一一对应的键位，下标即卡片下标。基础 4 个，
## “幸运补给”可以让选项加到 5，所以这里准备好 5 个动作。
const CHOICE_ACTIONS: Array[String] = ["choice_1", "choice_2", "choice_3", "choice_4", "choice_5"]

## 受伤红闪与得分脉冲的时长与强度。
@export var damage_flash_duration: float = 0.30
## 受伤红闪的峰值透明度。0.38 时整屏泛红偏重，会短暂盖住敌机弹道——而受伤那一下
## 恰恰是玩家最需要看清弹幕的时刻。调到 0.26：依然一眼可见，但不再遮住画面。
@export var damage_flash_alpha: float = 0.26
@export var score_pulse_duration: float = 0.18
@export var score_pulse_scale: float = 1.18
## 升级面板底部留在最后一张卡片下面的空白。
@export var panel_bottom_padding: float = 26.0

@onready var score_label: Label = $ScoreLabel
@onready var combo_label: Label = $ComboLabel
@onready var lives_label: Label = $LivesLabel
@onready var status_label: Label = $StatusLabel
@onready var level_label: Label = $LevelLabel
@onready var best_label: Label = $BestLabel
@onready var xp_bar: ProgressBar = $XpBar
@onready var damage_flash: ColorRect = $DamageFlash
@onready var boss_label: Label = $BossLabel
@onready var boss_bar: ProgressBar = $BossBar
@onready var message_label: Label = $MessageLabel
@onready var start_button: Button = $StartButton
@onready var restart_button: Button = $RestartButton
@onready var overlay: ColorRect = $Overlay
@onready var message_panel: Panel = $MessagePanel
@onready var hint_label: Label = $HintLabel
@onready var level_up_overlay: ColorRect = $LevelUpOverlay
@onready var level_up_panel: Panel = $LevelUpPanel
@onready var level_up_title: Label = $LevelUpTitle
@onready var level_up_hint: Label = $LevelUpHint
@onready var upgrade_cards: Array[Button] = [
	$UpgradeCard0, $UpgradeCard1, $UpgradeCard2, $UpgradeCard3, $UpgradeCard4,
]
@onready var pause_overlay: ColorRect = $PauseOverlay
@onready var pause_panel: Panel = $PausePanel
@onready var pause_title: Label = $PauseTitle
@onready var shake_caption: Label = $ShakeCaption
@onready var shake_button: Button = $ShakeButton
@onready var music_caption: Label = $MusicCaption
@onready var music_slider: HSlider = $MusicSlider
@onready var sfx_caption: Label = $SfxCaption
@onready var sfx_slider: HSlider = $SfxSlider
@onready var pause_resume_button: Button = $PauseResumeButton
@onready var pause_restart_button: Button = $PauseRestartButton

var _damage_tween: Tween
var _pulse_tween: Tween

func _ready() -> void:
	start_button.pressed.connect(_on_start_pressed)
	restart_button.pressed.connect(_on_restart_pressed)
	shake_button.pressed.connect(_on_shake_pressed)
	music_slider.value_changed.connect(_on_music_changed)
	sfx_slider.value_changed.connect(_on_sfx_changed)
	pause_resume_button.pressed.connect(_on_pause_resume_pressed)
	pause_restart_button.pressed.connect(_on_pause_restart_pressed)
	for index in range(upgrade_cards.size()):
		upgrade_cards[index].pressed.connect(_on_upgrade_card_pressed.bind(index))
	hide_level_up()
	hide_pause()

func update_stats(points: int, remaining_lives: int, elapsed: float, level: int, wave: int) -> void:
	score_label.text = "分数  %06d" % points
	lives_label.text = "生命  %d" % remaining_lives
	# 用 “·” 而不是长斜杠分隔：这一行现在有三个读数，宽分隔符会把它顶出矩形。
	status_label.text = "生存 %03d · 难度 %02d · 第 %d 波" % [int(elapsed), level, wave]

func update_best(best: int) -> void:
	best_label.text = "最高  %06d" % best

func update_combo(multiplier: int) -> void:
	# 只在有倍率时出现：×1 是常态，常驻显示反而会盖住“现在有加成”这件事。
	combo_label.visible = multiplier > 1
	combo_label.text = "×%d" % multiplier

func update_progress(current_level: int, current_xp: int, xp_to_next: int) -> void:
	level_label.text = "Lv %02d" % current_level
	# 上限至少为 1，避免除以零把进度条变成 NaN。
	xp_bar.max_value = maxf(1.0, float(xp_to_next))
	xp_bar.value = float(current_xp)

func show_boss(hp: int, max_hp: int) -> void:
	# 血条与标签只在这段时间出现：Boss 战期间不刷普通敌机，屏幕上方就这一条信息。
	boss_label.show()
	boss_bar.show()
	update_boss(hp, max_hp)

func update_boss(hp: int, max_hp: int) -> void:
	boss_bar.max_value = maxf(1.0, float(max_hp))
	boss_bar.value = float(maxi(hp, 0))
	boss_label.text = "BOSS %d/%d" % [maxi(hp, 0), max_hp]

func hide_boss() -> void:
	boss_label.hide()
	boss_bar.hide()

func flash_damage() -> void:
	# 立刻把透明度抬起来再淡出：受伤反馈必须当帧可见，也让断言不必等一个帧才成立。
	# 两个 Tween 都持引用并按需 kill，避免连续受伤时叠出多条互相打架的补间。
	if _damage_tween != null and _damage_tween.is_valid():
		_damage_tween.kill()
	damage_flash.color.a = damage_flash_alpha
	_damage_tween = create_tween()
	_damage_tween.tween_property(damage_flash, "color:a", 0.0, damage_flash_duration)

func pulse_score() -> void:
	if _pulse_tween != null and _pulse_tween.is_valid():
		_pulse_tween.kill()
	# 固定围绕标签中心放大，否则默认轴心在左上角，字会往右下“跳”。
	score_label.pivot_offset = score_label.size * 0.5
	score_label.scale = Vector2.ONE * score_pulse_scale
	_pulse_tween = create_tween()
	_pulse_tween.tween_property(score_label, "scale", Vector2.ONE, score_pulse_duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func show_start() -> void:
	_set_message_visible(true)
	# 五行的长度都量过：MessageLabel 是固定矩形，多一行就会顶破它（有断言盯着）。
	message_label.text = "飞机大作战\n\n连续击毁提升倍率 · 受伤或漏敌清零\n紫色敌机瞄准你 · 漏敌还会抬高难度\n普通 +10 / 射击 +20 · 初始 3 命 · 短暂无敌"
	hint_label.text = "WASD / 方向键 移动   ·   空格 持续射击"
	start_button.show()
	restart_button.hide()

func show_playing() -> void:
	_set_message_visible(false)
	start_button.hide()
	restart_button.hide()
	# 不写具体数字：选项数会随“幸运补给”变化，写死迟早变成谎话
	#（升级面板顶部那行是按实际张数动态生成的，这里只说“数字键”）。
	hint_label.text = "击毁敌机升级   /   升级后按数字键选择能力"

func show_game_over(report: Dictionary) -> void:
	_set_message_visible(true)
	# 分数、最高分、等级、剩余生命都不在这里重复一遍：顶栏一直显示着，而且结算遮罩
	# 只盖住 90 像素以下的部分，顶栏本来就没被挡住。战报只补顶栏看不到的东西。
	# 行数固定为 6 行，正好卡在 MessageLabel 的固定高度里（有断言盯着溢出）。
	var closing: String = "新纪录！这一局写进了最高分。" if report["record"] else "再来一次，飞得更久。"
	message_label.text = "本次飞行结束\n生存 %d 秒 · 难度 %02d · 到达 Lv %02d\n击毁 %d · 最高倍率 ×%d\n受伤 %d 次 · 漏敌 %d 架\n能力 %s\n%s" % [
		int(report["time"]),
		int(report["difficulty"]),
		int(report["level"]),
		int(report["kills"]),
		int(report["peak_combo"]),
		int(report["hits"]),
		int(report["escapes"]),
		String(report["build_text"]),
		closing,
	]
	hint_label.text = "按 R 或点击按钮重新开始"
	start_button.hide()
	restart_button.show()

func show_level_up(current_level: int, offers: Array[Dictionary]) -> void:
	level_up_overlay.visible = true
	level_up_panel.visible = true
	level_up_title.visible = true
	level_up_hint.visible = true
	level_up_title.text = "升级！Lv %d → Lv %d" % [current_level, current_level + 1]
	# 提示与实际给出的张数一致：叠了“幸运补给”后是 5 个，写死数字会立刻变成谎话。
	level_up_hint.text = "按数字键 1 – %d 或直接点击选择" % offers.size()
	for index in range(upgrade_cards.size()):
		var card: Button = upgrade_cards[index]
		# 候选池可能不足当前的选项数，多余的卡片直接隐藏，避免出现点不动的空格子。
		var usable: bool = index < offers.size()
		card.visible = usable
		card.disabled = not usable
		if usable:
			card.text = "%d. %s　%s" % [index + 1, offers[index]["name"], offers[index]["detail"]]
	# 面板高度按**实际给到的张数**收缩。基础是 4 选 1，而面板原本固定到 y=690，
	# 于是最常见的 4 张卡下面会留下约 120 像素空白——看着像界面没画完。
	# 这里直接取最后一张可见卡片的下沿（而不是把卡片几何抄一遍），
	# 好处是以后改卡片高度或间距，面板会自动跟随，不会两处对不上。
	var shown_cards: int = clampi(offers.size(), 1, upgrade_cards.size())
	level_up_panel.offset_bottom = upgrade_cards[shown_cards - 1].offset_bottom + panel_bottom_padding

func hide_level_up() -> void:
	level_up_overlay.visible = false
	level_up_panel.visible = false
	level_up_title.visible = false
	level_up_hint.visible = false
	for card in upgrade_cards:
		card.visible = false
		card.disabled = true

## 暂停面板上震动开关**当前显示**的状态。由按钮自己维护：如果只在 show_pause() 里刷新文字，
## 玩家按下之后文字不会变，会以为没生效——第一版就是这样，被回归断言抓到了。
var _shake_shown: bool = true

func show_pause(shake_enabled: bool, music_percent: int, sfx_percent: int) -> void:
	# 一次把三项设置的真实值都摆出来。滑条用 set_value_no_signal 避免打开面板时
	# 反过来触发一轮 volume_changed——那一轮是无害的，但会让“打开面板”变成一次设置写入。
	_shake_shown = shake_enabled
	shake_button.text = "开" if shake_enabled else "关"
	music_slider.set_value_no_signal(float(music_percent))
	sfx_slider.set_value_no_signal(float(sfx_percent))
	for node in [
		pause_overlay, pause_panel, pause_title, shake_caption, shake_button,
		music_caption, music_slider, sfx_caption, sfx_slider,
		pause_resume_button, pause_restart_button,
	]:
		node.visible = true

func hide_pause() -> void:
	for node in [
		pause_overlay, pause_panel, pause_title, shake_caption, shake_button,
		music_caption, music_slider, sfx_caption, sfx_slider,
		pause_resume_button, pause_restart_button,
	]:
		node.visible = false

func _unhandled_input(event: InputEvent) -> void:
	# 暂停键必须在**暂停中也能收到**，所以由 HUD（PROCESS_MODE_ALWAYS）处理而不是 Main：
	# Main 是 PAUSABLE，整树一暂停它的 _unhandled_input 就不再执行，那样就再也按不回来了。
	if event.is_action_pressed("pause") and not event.is_echo():
		# 只在“正在游戏”或“已暂停”时接管。开始界面、结算界面、升级抉择各有自己的语义
		# （抉择期间整树已经暂停，再叠一层会让状态含糊），所以用那三个界面的可见性排除。
		var in_game: bool = not level_up_panel.visible and not start_button.visible and not restart_button.visible
		if pause_panel.visible or in_game:
			get_viewport().set_input_as_handled()
			pause_toggle_requested.emit()
			return
	# 数字键只在抉择界面可见时接管，平时 1/2/3 不占用任何操作。
	if not level_up_panel.visible or event.is_echo():
		return
	for index in range(CHOICE_ACTIONS.size()):
		if event.is_action_pressed(CHOICE_ACTIONS[index]):
			get_viewport().set_input_as_handled()
			upgrade_chosen.emit(index)
			return

func _set_message_visible(value: bool) -> void:
	overlay.visible = value
	message_panel.visible = value
	message_label.visible = value

func _on_start_pressed() -> void:
	start_button.release_focus()
	start_game.emit()

func _on_restart_pressed() -> void:
	restart_button.release_focus()
	restart_game.emit()

func _on_upgrade_card_pressed(index: int) -> void:
	# 连点保护：Main 也会校验状态，这里先挡住同一个界面上的第二次点击。
	if not level_up_panel.visible:
		return
	upgrade_cards[index].release_focus()
	upgrade_chosen.emit(index)

func _on_shake_pressed() -> void:
	shake_button.release_focus()
	# 先把显示切过去，再报告期望值——按钮的即时反馈由自己负责，
	# 而不是等 Main 回过来刷新（那会导致按下之后文字不动）。
	_shake_shown = not _shake_shown
	shake_button.text = "开" if _shake_shown else "关"
	shake_toggled.emit(_shake_shown)

func _on_music_changed(value: float) -> void:
	volume_changed.emit("Music", int(round(value)))

func _on_sfx_changed(value: float) -> void:
	volume_changed.emit("SFX", int(round(value)))

func _on_pause_resume_pressed() -> void:
	pause_resume_button.release_focus()
	pause_toggle_requested.emit()

func _on_pause_restart_pressed() -> void:
	pause_restart_button.release_focus()
	pause_restarted.emit()
