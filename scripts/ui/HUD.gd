extends CanvasLayer

@onready var health_bar = $HealthBar

func _ready():
	health_bar.value = 100  # starting value

func set_health(value: float):
	health_bar.value = clamp(value, 0, health_bar.max_value)
