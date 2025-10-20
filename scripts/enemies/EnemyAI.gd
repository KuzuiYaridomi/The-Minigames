# EnemyAI.gd
# Attach to Enemy (CharacterBody3D)
@tool
extends CharacterBody3D

@export_group("Tuning")
@export var speed: float = 3.5
@export var chase_speed: float = 4.5
@export var turn_speed: float = 8.0

@export var sight_range: float = 30.0
@export var fov_degrees: float = 90.0           # field of view cone
@export var sight_mask: int = 1                 # physics layer mask for sight rays (set in inspector)
@export var attack_range: float = 10.0
@export var fire_rate: float = 0.8
@export var damage_base: float = 1.0

@export var head_multiplier: float = 2.5
@export var torso_multiplier: float = 1.0
@export var limb_multiplier: float = 0.6

@export var chase_memory_time: float = 2.5

@export_group("Patrol")
# Array of Vector3 points (you can set in inspector or fill programmatically)
@export var patrol_points: Array = []
@export var patrol_wait_time: float = 1.0
# NEW: container path - set this to a Node3D in the level whose children are Marker3D patrol points
@export var patrol_container_path: NodePath = NodePath("")

# Optional nodepaths
@export var nav_agent_path: NodePath
@export var muzzle_path: NodePath
@export var anim_player_path: NodePath

# Internals
@onready var nav_agent: NavigationAgent3D = get_node_or_null(nav_agent_path) if nav_agent_path != NodePath("") else ( $NavigationAgent3D if has_node("NavigationAgent3D") else null )
@onready var muzzle: Node3D = get_node_or_null(muzzle_path) if muzzle_path != NodePath("") else ( $Muzzle if has_node("Muzzle") else null )
@onready var anim_player: AnimationPlayer = get_node_or_null(anim_player_path) if anim_player_path != NodePath("") else ( $AnimationPlayer if has_node("AnimationPlayer") else null )

# find vision rays named VisionRay* under this node (optional). Each Ray is a Node3D used to originate sight rays.
var vision_roots: Array = []

var player: Node = null
var last_seen_pos: Vector3 = Vector3.ZERO
var last_seen_time: float = -9999.0

# patrol state
var _patrol_index: int = 0
var _patrol_wait_timer: float = 0.0

var _fire_timer: float = 0.0

enum State { IDLE, PATROL, CHASE, ATTACK }
var state: int = State.PATROL

func _refresh_patrol_points():
	patrol_points.clear()
	for m in get_tree().get_nodes_in_group("patrol_point"):
		patrol_points.append(m.global_transform.origin)


func _ready() -> void:
	# collect vision nodes (optional)
	for child in get_children():
		if child is Node and String(child.name).begins_with("VisionRay"):
			vision_roots.append(child as Node3D)

	# fallback single vision source if none provided: use muzzle or head
	if vision_roots.is_empty():
		if muzzle:
			vision_roots.append(muzzle)
		else:
			vision_roots.append(self)

	# nav agent sanity
	if nav_agent:
		# optional tuning: set agent tuning param(s) here
		# nav_agent.velocity_computed_max = speed  # keep if your agent exposes this
		pass

	# NEW: collect patrol points from a container if assigned
	_collect_patrol_points_from_container()

	# start patrol if points exist
	if patrol_points.size() > 0:
		state = State.PATROL
		_set_nav_target(patrol_points[_patrol_index])
	else:
		state = State.IDLE
	
	if Engine.is_editor_hint():
		_refresh_patrol_points()

func _collect_patrol_points_from_container() -> void:
	# If user assigned a container NodePath in the inspector, read its Marker3D children
	if patrol_container_path == NodePath(""):
		return
	var cont := get_node_or_null(patrol_container_path)
	if not cont:
		return
	# clear existing explicit points and populate from Marker3D children (in order)
	patrol_points.clear()
	for c in cont.get_children():
		if c is Marker3D:
			patrol_points.append((c as Marker3D).global_transform.origin)
	# if you prefer to keep any existing patrol_points that were manually added, remove .clear() above

func _physics_process(delta: float) -> void:
	@warning_ignore("incompatible_ternary")
	print_debug("Enemy pos:", global_transform.origin, " velocity:", velocity, " nav_next:", nav_agent.get_next_path_position() if nav_agent and not nav_agent.is_navigation_finished() else "none")
	
	_fire_timer = max(0.0, _fire_timer - delta)

	# update chasing memory expiry
	var now = Time.get_ticks_msec() / 1000.0
	var chasing = false
	if player:
		last_seen_pos = player.global_transform.origin
		last_seen_time = now
		chasing = true
	elif now - last_seen_time <= chase_memory_time:
		chasing = true

	# state logic
	match state:
		State.IDLE:
			_play_anim("RifleIdle0")
			velocity = Vector3.ZERO
			if patrol_points.size() > 0:
				state = State.PATROL
				_set_nav_target(patrol_points[_patrol_index])

		State.PATROL:
			_play_anim("WalkWithRifle0")
			_handle_patrol(delta)
			# check vision for player
			_scan_for_player()

		State.CHASE:
			_play_anim("RifleRun(1)0")
			_chase_update(delta)
			_scan_for_player()

		State.ATTACK:
			_play_anim("FiringRifle0")
			_attack_update(delta)
			_scan_for_player()

	# if no player & not patrolling, fallback to idle
	if not chasing and patrol_points.size() == 0 and state != State.IDLE:
		state = State.IDLE

func _handle_patrol(delta: float) -> void:
	if not nav_agent:
		# direct move between points
		if patrol_points.size() == 0:
			return
		var target = patrol_points[_patrol_index]
		var dir = (target - global_transform.origin)
		dir.y = 0
		if dir.length() < 0.4:
			_patrol_wait_timer += delta
			if _patrol_wait_timer >= patrol_wait_time:
				_patrol_wait_timer = 0
				_patrol_index = (_patrol_index + 1) % patrol_points.size()
		else:
			dir = dir.normalized()
			velocity.x = dir.x * speed
			velocity.z = dir.z * speed
			_move_and_face(dir, delta)
			move_and_slide()
	else:
		# navigation agent path-follow
		if nav_agent.is_navigation_finished():
			_patrol_wait_timer += delta
			if _patrol_wait_timer >= patrol_wait_time:
				_patrol_wait_timer = 0
				_patrol_index = (_patrol_index + 1) % patrol_points.size()
				_set_nav_target(patrol_points[_patrol_index])
		else:
			_follow_nav(delta)

func _chase_update(delta: float) -> void:
	# if we have a player reference, chase them (pathfinding)
	if player:
		var target_pos = player.global_transform.origin
		# if close enough to attack, switch
		var dist = (target_pos - global_transform.origin).length()
		if dist <= attack_range and _has_line_of_sight_to(target_pos):
			state = State.ATTACK
			return
		# else set nav target and follow
		_set_nav_target(target_pos)
		_follow_nav(delta)
	else:
		# fallback: use last_seen_pos
		if (last_seen_time > 0 and (Time.get_ticks_msec()/1000.0 - last_seen_time) <= chase_memory_time):
			_set_nav_target(last_seen_pos)
			_follow_nav(delta)
		else:
			# lost memory -> patrol
			if patrol_points.size() > 0:
				state = State.PATROL
				_set_nav_target(patrol_points[_patrol_index])
			else:
				state = State.IDLE

# Call this while the node is selected in the editor (or at runtime) to add current enemy position as a patrol point.
func add_patrol_point_here() -> void:
	var p = global_transform.origin
	patrol_points.append(p)
	print("EnemyAI: added patrol point at ", p)


func _attack_update(delta: float) -> void:
	# Face the target, fire when fire timer ready
	if not player:
		state = State.PATROL if patrol_points.size() > 0 else State.IDLE
		return
	var target_pos = player.global_transform.origin
	# ensure LOS
	if not _has_line_of_sight_to(target_pos):
		# lost direct sight -> chase toward last seen
		state = State.CHASE
		return

	# face player
	var dir = (target_pos - global_transform.origin)
	dir.y = 0
	if dir.length() > 0.01:
		_move_and_face(dir.normalized(), delta)

	# firing
	if _fire_timer <= 0.0:
		_fire_timer = fire_rate
		_fire_hitscan(target_pos)

func _scan_for_player() -> void:
	# check multiple sample targets (head, torso, center) for better detection
	var player_candidate = _find_closest_player_in_sight()
	if player_candidate:
		player = player_candidate
		state = State.CHASE
		last_seen_time = Time.get_ticks_msec() / 1000.0

func _find_closest_player_in_sight() -> Node:
	# returns player node if any ray hits a player or a player-area (Area3D) exposed
	var space = get_world_3d().direct_space_state
	for root in vision_roots:
		# sample points on the player: head, chest, pelvis (assumes player has these bones/named nodes)
		var samples = []
		# look for a 'player' in group and sample top/bottom offsets
		# We simply iterate all nodes in group player and test them — controlled scenes should mark player as "player"
		for p in get_tree().get_nodes_in_group("player"):
			# sample points relative to player origin
			var ppos = p.global_transform.origin
			samples.clear()
			samples.append(ppos + Vector3(0, 1.4, 0)) # head-ish
			samples.append(ppos + Vector3(0, 1.0, 0)) # chest
			samples.append(ppos + Vector3(0, 0.6, 0)) # pelvis

			for s in samples:
				# quick range check
				var origin = root.global_transform.origin
				if origin.distance_to(s) > sight_range:
					continue
				# FOV check
				var to_sample = (s - origin).normalized()
				var forward = -global_transform.basis.z
				var angle = rad_to_deg(acos(clamp(forward.dot(to_sample), -1.0, 1.0)))
				if angle > fov_degrees * 0.5:
					continue
				# do raycast with PhysicsRayQueryParameters3D
				var params = PhysicsRayQueryParameters3D.new()
				params.from = origin
				params.to = s
				params.exclude = [self]
				params.collision_mask = sight_mask
				var res = space.intersect_ray(params)
				if res and res.get("collider") != null:
					var collider = res.get("collider")
					# if the ray hit an Area3D bone attachment it may return that Area as collider
					# prefer player node detection (node in group "player")
					if collider.is_in_group("player"):
						return collider
					# if collider is an Area3D attached to player or child of player, return that player
					var root_node = collider
					while root_node and root_node != self and not root_node.is_in_group("player"):
						root_node = root_node.get_parent()
					if root_node and root_node.is_in_group("player"):
						return root_node
	# no player found
	return null

func _has_line_of_sight_to(target_pos: Vector3) -> bool:
	var space = get_world_3d().direct_space_state
	var origin = muzzle.global_transform.origin if muzzle else global_transform.origin
	var params = PhysicsRayQueryParameters3D.new()
	params.from = origin
	params.to = target_pos
	params.exclude = [self]
	params.collision_mask = sight_mask
	var res = space.intersect_ray(params)
	if not res:
		return true # nothing blocking
	var collider = res.get("collider")
	# if collider is player or descendant of player -> LOS
	if collider and collider.is_in_group("player"):
		return true
	# if collider is Area3D attached to player
	var node = collider
	while node and node != self:
		if node.is_in_group("player"):
			return true
		node = node.get_parent()
	return false

# perform hitscan and apply damage (via Damagesystem autoload)
func _fire_hitscan(target_pos: Vector3) -> void:
	var origin = muzzle.global_transform.origin if muzzle else global_transform.origin
	var space = get_world_3d().direct_space_state
	var params = PhysicsRayQueryParameters3D.new()
	params.from = origin
	params.to = target_pos
	params.exclude = [self]
	params.collision_mask = sight_mask
	var res = space.intersect_ray(params)
	if not res:
		return
	# determine hit node and body part
	var collider = res.get("collider")
	@warning_ignore("unused_variable")
	var hit_point = res.get("position")
	var applied = false
	var ds = get_node_or_null("/root/Damagesystem")
	var multiplier = 1.0
	# if collider is Area3D bone attachment: check its name for multipliers
	if collider and collider is Area3D:
		var nm = String(collider.name).to_lower()
		if nm.find("head") >= 0:
			multiplier = head_multiplier
		elif nm.find("torso") >= 0 or nm.find("chest") >= 0:
			multiplier = torso_multiplier
		else:
			multiplier = limb_multiplier
		# parent may be the actual character
		var parent_node = collider.get_parent()
		while parent_node and not parent_node.is_in_group("player") and parent_node != self:
			parent_node = parent_node.get_parent()
		var victim = parent_node if parent_node and parent_node.is_in_group("player") else collider
		if ds:
			applied = ds.deal_damage(victim, int(round(damage_base * multiplier)), self, (target_pos-origin))
		else:
			# fallback call if victim has take_damage/apply_damage
			if victim and victim.has_method("apply_damage"):
				victim.call_deferred("apply_damage", int(round(damage_base * multiplier)), self, (target_pos-origin))
				applied = true
	elif collider:
		# hit some collider (usually the player or world)
		if ds:
			applied = ds.deal_damage(collider, damage_base, self, (target_pos-origin))
		else:
			if collider.has_method("apply_damage"):
				collider.call_deferred("apply_damage", damage_base, self, (target_pos-origin))
				applied = true

	# optional: spawn impact VFX here (call a factory or autoload)
	# debug print
	if applied:
		print("Enemy fired and applied damage to: ", collider)

# small helpers
func _set_nav_target(pos: Vector3) -> void:
	if nav_agent:
		nav_agent.target_position = pos

func _follow_nav(delta: float) -> void:
	if not nav_agent:
		return
	# ensure agent's target is set elsewhere with _set_nav_target()
	# ask nav agent for next point and move toward it
	if nav_agent.is_navigation_finished():
		velocity.x = 0
		velocity.z = 0
		return

	var next_pos = nav_agent.get_next_path_position()
	var dir = next_pos - global_transform.origin
	dir.y = 0
	if dir.length() > 0.05:
		dir = dir.normalized()
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
		_move_and_face(dir, delta)
	else:
		velocity.x = 0
		velocity.z = 0

	# actually move the CharacterBody
	move_and_slide()

func gather_patrol_points_from_container(container_node: Node):
	patrol_points.clear()
	for child in container_node.get_children():
		if child is Node3D:
			patrol_points.append(child.global_transform.origin)



func _move_and_face(dir: Vector3, delta: float) -> void:
	# rotate smoothly toward dir
	if dir.length() < 0.001:
		return
	var desired_yaw = atan2(dir.x, dir.z)
	rotation.y = lerp_angle(rotation.y, desired_yaw, clamp(turn_speed * delta, 0, 1))

func _fire_debug() -> void:
	# optional debug helper to visualize rays
	pass

@warning_ignore("shadowed_variable_base_class")
func _play_anim(name: String) -> void:
	if not anim_player:
		return
	if anim_player.has_animation(name):
		if anim_player.current_animation != name:
			anim_player.play(name)
	else:
		# helpful debug when animation missing
		print("EnemyAI: missing animation:", name)
