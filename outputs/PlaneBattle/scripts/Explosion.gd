extends CPUParticles2D
## 敌机被击毁时的爆炸：中心一道白光闪 + 一圈向外扩散的碎片，播完自行释放。
##
## 用 CPUParticles2D 而不是 GPUParticles2D：本项目是 GL Compatibility 的 2D 原型，
## CPU 粒子不依赖 GPU 计算着色器，在低端设备与 Web 上更稳，粒子数量也很小。
## 粒子贴图用内置的 GradientTexture2D 画一个径向渐变圆点，因此不需要任何外部图片。
##
## 白光闪为什么放在这里而不是挂在敌机上：敌机是一击必毁、命中的当帧就 queue_free 的，
## 真去烫它自己的颜色根本来不及显示。把白闪做在爆炸这一侧、位置就是敌机被击毁的位置，
## 观感相同却不触碰敌机的生命周期与幂等锁。

@export var flash_duration: float = 0.08

@onready var flash: Polygon2D = $Flash

## **粒子被发射那一刻的位置**。它才是"爆炸画在哪里"的唯一依据，而不是节点当前的 position：
## `one_shot` + `explosiveness=1` 会在 `emitting` 打开的那一瞬间把整批粒子按当时的坐标
## 发射出去，之后再挪节点，粒子已经留在原地了。
## 真机上踩过一次：生成顺序写成"先 add_child、再设坐标"，于是**所有爆炸都画在左上角 (0,0)**，
## 而当时的断言查的是 `burst.global_position`——那个值是对的，所以一直绿着。
## 这个字段就是给回归测试用的：它记录的是粒子真正被发射时的位置。
var spawn_position: Vector2 = Vector2.ZERO

func _ready() -> void:
	add_to_group("explosion")
	spawn_position = global_position
	# one_shot 粒子在 emitting 置真后只播一轮，播完发 finished，这时才释放自己。
	emitting = true
	finished.connect(queue_free)
	var tween: Tween = create_tween()
	tween.tween_property(flash, "modulate:a", 0.0, flash_duration)
