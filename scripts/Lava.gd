extends Area3D

@export var instant_kill: bool = true
@export var damage_amount: int = 999
@export var hit_sound: AudioStream = null
@export var respawn_delay: float = 1.0

@onready var vfx: GPUParticles3D = $GPUParticles3D if has_node("GPUParticles3D") else null
@onready var sfx: AudioStreamPlayer3D = $AudioStreamPlayer3D if has_node("AudioStreamPlayer3D") else null

func _ready() -> void:
	if not is_connected("body_entered", Callable(self, "_on_body_entered")):
		connect("body_entered", Callable(self, "_on_body_entered"))

func _on_body_entered(body: Node) -> void:
	if not body:
		return
	if not body.is_in_group("player"):
		return

	# play VFX / SFX
	if vfx:
		vfx.emitting = true
	if sfx:
		if hit_sound:
			sfx.stream = hit_sound
		sfx.play()

	# apply damage or kill
	if body.has_method("take_damage"):
		if instant_kill:
			# big damage
			body.take_damage(damage_amount)
		else:
			body.take_damage(1)
	elif body.has_method("die"):
		body.die()
	else:
		# fallback: try trigger UI death popup or move to spawn
		var dp = get_tree().get_current_scene().get_node_or_null("CanvasLayer/DeathPopup")
		if dp:
			dp.visible = true
