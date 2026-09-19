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

func _ready() -> void:
	add_to_group("explosion")
	# one_shot 粒子在 emitting 置真后只播一轮，播完发 finished，这时才释放自己。
	emitting = true
	finished.connect(queue_free)
	var tween: Tween = create_tween()
	tween.tween_property(flash, "modulate:a", 0.0, flash_duration)
