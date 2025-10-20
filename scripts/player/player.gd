extends CharacterBody3D

# ───────────── CAMERA ─────────────
@export var mouse_sensitivity: float = 0.2
@export var mouse_smooth_speed: float = 12.0  # unused for direct look but kept
var pitch := 0.0

# health hud stuff



#momentum switch up
@export var slide_momentum_transfer: float = 1.0  # 1.0 = instant transfer, 0.0 = no transfer
@export var min_speed_for_transfer: float = 2.0   # minimum horiz speed required to transfer

# small initial boost on starting a ground slide
@export var slide_start_boost: float = 1.0  # 8% instant boost when you start ground slide

#slide hop stuff:
@export var slidehop_cooldown: float = 0.25   # seconds; prevents rapid repeated boosts
var _last_slidehop_time: float = -10.0
var last_crouch_press_time: float = -10.0
@export var landing_crouch_window: float = 0.15  # seconds: allow press just before/at landing to count

@export var max_slide_speed: float = 80.0   # clamp horizontal speed to avoid explosions



# camera tilt on wall-jump
@export var camera_tilt_amount: float = 0.0
@export var camera_tilt_duration: float = 0.45
var camera_tilt_timer: float = 0.0
var camera_tilt_target: float = 0.0

# ───────────── MOVEMENT VARIABLES ─────────────
@export var base_speed: float = 10.0
@export var jump_velocity: float = 6.5
@export var acceleration: float = 18
@export var gravity: float = 15.0 # faster falling

# Strafing & crouch
@export var strafe_multiplier := 1.6
@export var crouch_multiplier := 0.6

# Sliding / Slide Hopping
@export var slide_duration := 0.6
@export var slide_boost := 1.0           # additional multiplier applied while sliding (kept 1.0)
@export var slidehop_increase: float = 0.03
var queued_slidehop: bool = false    # true when player pressed crouch while airborne
var was_on_floor: bool = true        # tracks previous physics step floor state
@export var max_slidehop_multiplier: float = 2.0

# speed multiplier is multiplicative and compounds on chained landings
var speed_multiplier: float = 1.0
var is_sliding := false
var slide_timer := 0.0

# Wall jump / glide
@export var wall_glide_speed: float = 4.0
@export var wall_jump_force: float = 8.0
@export var wall_check_distance: float = 0.6
# wall jump forces (separate horizontal and vertical so you can tune both)
@export var wall_jump_force_horizontal: float = 10.0
@export var wall_jump_force_vertical: float = 7.0

# momentum tuning
@export var braking_multiplier: float = 3.5    # stronger decel when input opposes velocity
@export var ground_stop_damping: float = 14.0  # how fast to stop when no input on ground

var input_dir: Vector3 = Vector3.ZERO
var is_crouching := false
var can_wall_jump := false

# speed debug print timer
var _speed_print_timer: float = 0.0
@export var speed_print_interval: float = 0.2  # seconds

#Health stuff first
# Health + UI (automatic lookup)
@export var max_health: int = 3
var health: int
var spawn_position: Vector3

# UI cached nodes (filled in _ready)
var _healthbar = null
var _deathpopup = null


# UI NodePaths (set in Inspector to your UI nodes)
@export var healthbar_path: NodePath
@export var deathpopup_path: NodePath
@export var player_controls_node_path: NodePath  # optional: node to disable when dead

@onready var healthbar = get_node_or_null(healthbar_path)
@onready var deathpopup = get_node_or_null(deathpopup_path)
@onready var controls_node = get_node_or_null(player_controls_node_path)


func take_damage(amount: int = 1) -> void:
	health = max(0, health - amount)
	_update_health_ui()
	if health <= 0:
		_die()

func _update_health_ui() -> void:
	if healthbar:
		# if using TextureProgress, set max/min appropriately in Inspector
		# If the control is a Range (ProgressBar/TextureProgress) set its max
		if healthbar is Range:
			healthbar.max_value = max_health
			healthbar.min_value = 0
		healthbar.value = health

func _die() -> void:
	# disable player controls (if any) by disabling a specific node if provided
	if controls_node:
		controls_node.set_process(false)
		controls_node.set_physics_process(false)
	# show death popup UI
	if deathpopup:
		deathpopup.visible = true
		# optionally pause the game logic (but we want UI still interactive)
		# get_tree().paused = true

func respawn() -> void:
	# hide popup
	if deathpopup:
		deathpopup.visible = false
	# move player to spawn position
	var t = global_transform
	t.origin = spawn_position
	global_transform = t
	# reset health
	health = max_health
	_update_health_ui()
	# re-enable controls
	if controls_node:
		controls_node.set_process(true)
		controls_node.set_physics_process(true)
	# unpause if you paused
	# get_tree().paused = false

# ───────────── CAMERA LOOK ─────────────
func _ready():
		# register as player group (so enemies/bullets detect)
	add_to_group("player")
	health = max_health
	spawn_position = global_transform.origin

	# ----------------- START: HUD auto-find fallback (ADDED) -----------------
	# If inspector paths weren't set, try to find UI nodes automatically in current scene.
	if healthbar == null:
		var root = get_tree().get_current_scene()
		if root:
			# try common places: UI -> HealthBar
			var ui = root.get_node_or_null("UI")
			if ui == null:
				# fallback: find any CanvasLayer and look inside
				for c in root.get_children():
					if c is CanvasLayer:
						ui = c
						break
			if ui:
				# try named children inside UI
				var hb = ui.get_node_or_null("HealthBar")
				if hb:
					healthbar = hb
				else:
					# deep search for a node called HealthBar anywhere under root
					var found = root.find_node("HealthBar", true, false)
					if found:
						healthbar = found
	# death popup
	if deathpopup == null:
		var root2 = get_tree().get_current_scene()
		if root2:
			var dp = _find_node_recursive(root2, "DeathPopup")
			if dp:
				deathpopup = dp
	# Configure healthbar max if applicable and ensure deathpopup hidden
	if healthbar and (healthbar is Range):
		healthbar.max_value = max_health
		healthbar.min_value = 0
	if deathpopup:
		deathpopup.visible = false
	# ----------------- END: HUD auto-find fallback (ADDED) -----------------

	_update_health_ui()
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	# ensure pitch starts from current camera pivot angle
	pitch = $CameraPivot.rotation_degrees.x

# helper: recursive search for a node by name
func _find_node_recursive(node: Node, target_name: String) -> Node:
	for child in node.get_children():
		if String(child.name) == target_name:
			return child
		var found := _find_node_recursive(child, target_name)
		if found:
			return found
	return null



func _input(event):
	if event is InputEventMouseMotion:
		# immediate yaw rotation (radians)
		rotate_y(deg_to_rad(-event.relative.x * mouse_sensitivity))
		# update pitch target but don't force it here if tilt is active
		pitch = clamp(pitch - event.relative.y * mouse_sensitivity, -89, 89)
		# only set CameraPivot here if no tilt active, otherwise tilt code will control it
		if camera_tilt_timer <= 0.0:
			$CameraPivot.rotation_degrees.x = pitch

func receive_force(impulse: Vector3) -> void:
	# simple: add impulse to velocity (you already have a velocity var)
	velocity += impulse
	# optional: start a short stun or reduce control while being pushed


# ───────────── MOVEMENT ─────────────
func get_input_direction() -> Vector3:
	var dir = Vector3.ZERO
	var forward = -global_transform.basis.z
	var right = global_transform.basis.x
	
	if Input.is_action_pressed("move_forward"):
		dir += forward
	if Input.is_action_pressed("move_back"):
		dir -= forward
	if Input.is_action_pressed("move_right"):
		dir += right
	if Input.is_action_pressed("move_left"):
		dir -= right
	
	return dir.normalized()


func _physics_process(delta):
	# store previous grounded state for landing detection
	var prev_on_floor := was_on_floor
	input_dir = get_input_direction()

	# Speed debug print
	_speed_print_timer += delta
	if _speed_print_timer >= speed_print_interval:
		_speed_print_timer = 0.0
		var horiz_speed = Vector2(velocity.x, velocity.z).length()
		print("Horizontal speed: " + str(horiz_speed) + " speed_multiplier: " + str(speed_multiplier) + " sliding: " + str(is_sliding))


	# Strafing boost when moving diagonally
	var target_speed = base_speed
	if abs(input_dir.x) > 0 and abs(input_dir.z) > 0:
		target_speed *= strafe_multiplier

	is_crouching = Input.is_action_pressed("crouch")

	# --- crouch press handling: ground-slide vs queued mid-air slidehop
	if Input.is_action_just_pressed("crouch"):
		# record when crouch was pressed (used for 'press just before landing' detection)
		last_crouch_press_time = Time.get_ticks_msec() / 1000.0
		
		if not is_on_floor():
			# pressed while airborne -> queue boost for landing
			queued_slidehop = true
		else:
			# pressed on ground -> start ground slide if moving
			if input_dir.length() > 0.1:
				start_slide()
		


	# crouch handling: slowdown only applies when on ground and NOT sliding
	if is_on_floor():
		if is_crouching and not is_sliding:
			target_speed *= crouch_multiplier
			$CameraPivot.position.y = lerp($CameraPivot.position.y, 1.0, delta * 10)
		else:
			$CameraPivot.position.y = lerp($CameraPivot.position.y, 1.6, delta * 6)
	else:
		$CameraPivot.position.y = lerp($CameraPivot.position.y, 1.6, delta * 6)

	# Handle active sliding state
	if is_sliding:
		# slide_timer optional max duration (can be used), but sliding also ends on low speed or release
		slide_timer -= delta
		var horiz_speed = Vector2(velocity.x, velocity.z).length()
		# end slide when crouch released OR horizontal speed is very small OR timer runs out
		if not Input.is_action_pressed("crouch") or horiz_speed < 0.1 or slide_timer <= 0.0:
			is_sliding = false

	# Gravity (vertical)
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		if velocity.y < 0:
			velocity.y = 0

	# ---------- HORIZONTAL VELOCITY (momentum-friendly with Krunker-style sliding) ----------
	var target_velocity = input_dir * target_speed
	var current_horiz = Vector3(velocity.x, 0, velocity.z)
	var current_speed = current_horiz.length()
	
	var new_horiz: Vector3 = current_horiz
	
	# Sliding branch: preserve/boost speed, allow momentum transfer toward aim
	if is_sliding and current_speed > min_speed_for_transfer:
		# desired horizontal direction from input/aim
		var blended_dir: Vector3 = Vector3.ZERO
		if target_velocity.length() > 0.01:
			var target_dir = target_velocity.normalized()
			var from_dir = current_horiz.normalized()
			var t: float = clamp(slide_momentum_transfer, 0.0, 1.0)
			blended_dir = from_dir.lerp(target_dir, t).normalized()
		else:
			# no input direction, keep current direction
			blended_dir = current_horiz.normalized() if current_speed > 0 else Vector3.ZERO

		# compute effective speed: base current speed times speed_multiplier and slide_boost
		var effective_speed = current_speed * speed_multiplier * slide_boost
		# ensure we don't accidentally get NaN
		if blended_dir == Vector3.ZERO:
			new_horiz = Vector3.ZERO
		else:
			new_horiz = blended_dir * effective_speed
	else:
		# normal movement preservation:
		var effective_accel = acceleration if is_on_floor() else acceleration * 0.25
		if target_velocity.length() > 0 and current_horiz.length() > 0:
			var dot = current_horiz.dot(target_velocity)
			if dot < 0:
				effective_accel *= braking_multiplier
		new_horiz = current_horiz.move_toward(target_velocity, effective_accel * delta)
		
		# ground damping: skip damping while sliding so player truly slides
		if is_on_floor() and input_dir.length() < 0.01 and not is_sliding:
			new_horiz = new_horiz.move_toward(Vector3.ZERO, ground_stop_damping * delta)
			
	velocity.x = new_horiz.x
	velocity.z = new_horiz.z

	# Jump / Wall-jump (preserve momentum by adding impulse)
	if Input.is_action_just_pressed("jump") and (is_on_floor() or can_wall_jump):
		# vertical impulse (tuned)
		velocity.y = wall_jump_force_vertical
		if can_wall_jump:
			var wall_normal = detect_wall_normal()
			# add horizontal push along the wall normal using exported force
			velocity += wall_normal * wall_jump_force_horizontal
			can_wall_jump = false

	# APPLY MOVEMENT + clamp speed
	move_and_slide()
	var hv = Vector2(velocity.x, velocity.z)
	var hlen = hv.length()
	if hlen > max_slide_speed:
		var s = max_slide_speed / hlen
		velocity.x *= s
		velocity.z *= s
	
	# update ground state after physics step
	was_on_floor = is_on_floor()
	
	# detect landing -> apply queued slidehop on landing
	if not prev_on_floor and was_on_floor:
			if queued_slidehop or (Time.get_ticks_msec() / 1000.0 - last_crouch_press_time <= landing_crouch_window):
						if input_dir.length() > 0.1:
							var now = Time.get_ticks_msec() / 1000.0
							if now - _last_slidehop_time >= slidehop_cooldown:
								# multiplicative speed increase (compounding) on landing
								var boost := 1.0 + slidehop_increase
								speed_multiplier = min(speed_multiplier * boost, max_slidehop_multiplier)
								
								# immediate horizontal speed bump so player feels the chain
								var horiz_vec = Vector3(velocity.x, 0, velocity.z)
								horiz_vec *= boost
								velocity.x = horiz_vec.x
								velocity.z = horiz_vec.z
								
								# record time of this boost to prevent immediate repeats
								_last_slidehop_time = now
								
								# begin sliding on landing
								is_sliding = true
								slide_timer = slide_duration
								# camera drop on slide landing
								$CameraPivot.position.y = 1.0
			queued_slidehop = false


		
				
				
	# Slide Hop logic (keep reset on wall collision)
	handle_slide_hop()

	# Wall glide logic
	handle_wall_glide(delta)

	# ---------- CAMERA TILT HANDLING ----------
	if camera_tilt_timer > 0.0:
		# smooth toward tilt target while timer active
		camera_tilt_timer = max(camera_tilt_timer - delta, 0.0)
		$CameraPivot.rotation_degrees.x = lerp($CameraPivot.rotation_degrees.x, camera_tilt_target, clamp(12.0 * delta, 0.0, 1.0))
		# when timer finishes, ensure we return to 'pitch' next frames
		if camera_tilt_timer <= 0.0:
			$CameraPivot.rotation_degrees.x = pitch
	else:
		# keep camera exactly at pitch (direct look)
		$CameraPivot.rotation_degrees.x = pitch



# ───────────── SLIDE ─────────────
func start_slide():
	if not is_on_floor(): return
	# don't restart slide if already sliding
	if is_sliding:
		return
	is_sliding = true
	# preserve existing momentum, but give a small start boost so player actually slides
	var horiz = Vector3(velocity.x, 0, velocity.z)
	if horiz.length() > 0.1:
		horiz *= slide_start_boost
		velocity.x = horiz.x
		velocity.z = horiz.z
	# set a slide timer (optional safety cap)
	slide_timer = slide_duration
	# immediate camera crouch view
	$CameraPivot.position.y = 1.0



func handle_slide_hop():
	# When crouch is pressed mid-air, queue slidehop (apply boost on landing)
	if Input.is_action_just_pressed("crouch") and not is_on_floor():
		queued_slidehop = true  # queue instead (we apply boost on landing)

	# Reset speed multiplier on wall collision
	if is_on_wall():
		speed_multiplier = 1.0



# ───────────── WALL GLIDE ─────────────
func handle_wall_glide(_delta):
	if is_on_floor():
		can_wall_jump = false
		return

	var wall_normal = detect_wall_normal()
	if wall_normal != Vector3.ZERO:
		if velocity.y < -wall_glide_speed:
			velocity.y = -wall_glide_speed
		can_wall_jump = true
	else:
		can_wall_jump = false


# ───────────── WALL DETECTION ─────────────
func detect_wall_normal() -> Vector3:
	var space_state = get_world_3d().direct_space_state
	var directions = [
		global_transform.basis.x,   # right
		-global_transform.basis.x,  # left
		-global_transform.basis.z,  # forward
		global_transform.basis.z    # back
	]

	for dir in directions:
		var params = PhysicsRayQueryParameters3D.new()
		params.from = global_transform.origin
		params.to = global_transform.origin + dir * wall_check_distance
		params.exclude = [self]

		var result = space_state.intersect_ray(params)
		if result and result.size() > 0:
			return result.get("normal", Vector3.ZERO)

	return Vector3.ZERO









		

	
			
		
		
