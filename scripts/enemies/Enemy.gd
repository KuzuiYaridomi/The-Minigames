extends CharacterBody3D

# Tuning
@export var speed: float = 3.5
@export var attack_range: float = 2.2
@export var attack_cooldown: float = 1.0
@export var damage: int = 1
@export var max_health: int = 1
@export var chase_memory_time: float = 3.0  # seconds to keep chasing after losing sight
@export var turn_speed: float = 6.0         # how fast the enemy yaw rotates (higher = snappier)

# Node references (must exist)
@onready var anim_player: AnimationPlayer = $AnimationPlayer
@onready var detection_area: Area3D = $DetectionArea
@onready var attack_ray: RayCast3D = $AttackRay
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D if has_node("NavigationAgent3D") else null

# Optional external health component script path (if you use a separate Health.gd)
const HealthScript = preload("res://scripts/Health.gd")
var health_comp: Node = null

# Runtime
var player: Node = null
var last_seen_pos: Vector3 = Vector3.ZERO
var last_seen_time: float = -9999.0
var attack_timer: float = 0.0
var state: String = ""
# internal health value used by this enemy
var hp: int = 1

func _ready() -> void:
	add_to_group("enemies")
	_play_anim("tpose")

	# initialize health
	hp = max_health

	# attempt to find or create a Health component for compatibility (optional)
	if has_node("Health"):
		health_comp = get_node("Health")
	else:
		# try to instantiate HealthScript safely (optional compatibility)
		var safe_health = null
		if HealthScript:
			safe_health = HealthScript.new()
		if safe_health:
			health_comp = safe_health
			health_comp.name = "Health"
			# attempt to initialize via common init functions (deferred to avoid immediate call timing)
			if health_comp.has_method("set_max_health"):
				health_comp.call_deferred("set_max_health", max_health)
			elif health_comp.has_method("init"):
				health_comp.call_deferred("init", max_health)
			add_child(health_comp)
		else:
			health_comp = null

	# connect signals from external health_comp if they exist
	if health_comp:
		if health_comp.has_signal("died") and not health_comp.is_connected("died", Callable(self, "die")):
			health_comp.connect("died", Callable(self, "die"))
		if health_comp.has_signal("damaged") and not health_comp.is_connected("damaged", Callable(self, "_on_damaged")):
			health_comp.connect("damaged", Callable(self, "_on_damaged"))

	# connect detection signals
	if not detection_area.is_connected("body_entered", Callable(self, "_on_DetectionArea_body_entered")):
		detection_area.connect("body_entered", Callable(self, "_on_DetectionArea_body_entered"))
	if not detection_area.is_connected("body_exited", Callable(self, "_on_DetectionArea_body_exited")):
		detection_area.connect("body_exited", Callable(self, "_on_DetectionArea_body_exited"))
	attack_ray.enabled = false
	
	if collision_shape:
		collision_shape.disabled = true
		call_deferred("_enable_collision")
		
func _enable_collision() -> void:
	if collision_shape:
		collision_shape.disabled = false
		


func _on_damaged(amount: int, instigator: Node) -> void:
	# play a hit animation if available
	if anim_player and anim_player.has_animation("hit"):
		anim_player.play("hit")
	# visual feedback only (internal hp adjustment is handled in take_damage)


func _physics_process(delta: float) -> void:
	# stop processing if dead
	if hp <= 0:
		return

	var now = Time.get_ticks_msec() / 1000.0
	var chasing_target: Vector3
	var chasing = false

	# --- Detect Player or Memory Chase ---
	if player != null:
		chasing = true
		chasing_target = player.global_transform.origin
		last_seen_pos = chasing_target
		last_seen_time = now
	elif now - last_seen_time <= chase_memory_time:
		chasing = true
		chasing_target = last_seen_pos

	# --- If no target to chase ---
	if not chasing:
		velocity = Vector3.ZERO
		_play_anim("tpose")
		move_and_slide()
		return

	# --- Movement & Rotation ---
	var dir = chasing_target - global_transform.origin
	dir.y = 0
	var dist = dir.length()

	# Check if player is in attack ray (line-of-sight)
	var player_in_ray = false
	if player:
		var local_target = attack_ray.to_local(player.global_transform.origin)
		# RayCast3D uses target_position (local) in Godot 4
		attack_ray.target_position = local_target
		attack_ray.force_raycast_update()
		attack_ray.enabled = true
		if attack_ray.is_colliding() and attack_ray.get_collider() == player:
			player_in_ray = true
	else:
		attack_ray.enabled = false

	# --- Chase or Attack ---
	if dist > attack_range or not player_in_ray:
		# Walk toward target
		dir = dir.normalized()
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
		_play_anim("walk")
	else:
		# In attack range + ray hit → stop & attack
		velocity = Vector3.ZERO
		_play_anim("attack")
		if attack_timer <= 0:
			attack_timer = attack_cooldown
			if player and player.has_method("take_damage"):
				player.take_damage(damage)

	# Smooth rotation toward target
	if dir.length() > 0.01:
		var desired_yaw = atan2(dir.x, dir.z)
		rotation.y = lerp_angle(rotation.y, desired_yaw, clamp(turn_speed * delta, 0, 1))

	# --- Attack cooldown ---
	if attack_timer > 0:
		attack_timer -= delta

	move_and_slide()


func _on_DetectionArea_body_entered(body: Node) -> void:
	# only react to nodes in "player" group
	if body and body.is_in_group("player"):
		player = body
		last_seen_pos = player.global_transform.origin
		last_seen_time = Time.get_ticks_msec() / 1000.0


func _on_DetectionArea_body_exited(body: Node) -> void:
	if body == player:
		player = null  # memory chasing takes over


# compatibility wrapper: allow direct take_damage calls (keeps old code working)
# instigator and hit_force are optional and can be used by caller (e.g., bullet)
func take_damage(amount: int, instigator: Node = null, hit_force: Vector3 = Vector3.ZERO) -> void:
	# If you have an external health component that provides apply_damage or take_damage,
	# prefer calling it (for bookkeeping). Otherwise, apply damage to local hp.
	var handled_by_comp: bool = false

	if health_comp:
		# try common method names in order (safe calls)
		if health_comp.has_method("apply_damage"):
			health_comp.call_deferred("apply_damage", amount, instigator, hit_force)
			handled_by_comp = true
		elif health_comp.has_method("take_damage"):
			health_comp.call_deferred("take_damage", amount)
			handled_by_comp = true

	# If external component didn't handle damage, reduce our local hp
	if not handled_by_comp:
		hp -= amount

	# If external component exists, try to sync hp from a couple common getters (safe checks)
	if health_comp:
		if health_comp.has_method("get_current_health"):
			hp = int(health_comp.call("get_current_health"))
		elif health_comp.has_method("get_health"):
			hp = int(health_comp.call("get_health"))
		# otherwise keep local hp as authoritative

	# play hit animation (visual)
	if anim_player and anim_player.has_animation("hit"):
		anim_player.play("hit")

	# Check death
	if hp <= 0:
		# ensure only one die() call
		if is_inside_tree():
			die()


func die() -> void:
	# stop logic & play death animation
	hp = 0
	velocity = Vector3.ZERO
	_play_anim("death")
	set_physics_process(false)
	if collision_shape:
		collision_shape.disabled = true
	remove_from_group("enemies")
	# stop attack, disable detection
	if detection_area:
		detection_area.monitoring = false
	attack_ray.enabled = false

	# Wait exactly 2 seconds then free (as requested)
	await get_tree().create_timer(2.0).timeout
	queue_free()


@warning_ignore("shadowed_variable_base_class")
func _play_anim(name: String) -> void:
	if anim_player.current_animation != name:
		anim_player.play(name)
