extends Node3D

# --- handle gun rotation via mouse wheel
func _unhandled_input(event):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_WHEEL_UP:
		$AnimationPlayer.play("rotate_gun")
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		$AnimationPlayer.play("rotate_gun")

# --- shooting params
@export var fire_rate: float = 0.2
var time_since_last_shot: float = 0.0

@export var muzzle_path: NodePath
@export var bullet_scene: PackedScene
@onready var muzzle: Node3D = null

@export var ray_origin_path: NodePath
@onready var ray_origin: Node3D = get_node_or_null(ray_origin_path) as Node3D


@export var crosshair_path: NodePath  # optional: assign your TextureRect crosshair here
@onready var crosshair_control: Control = get_node_or_null(crosshair_path)


# recoil parameters (degrees)
@export var recoil_amount: float = 4.0        # degrees added on each shot
@export var recoil_max: float = 12.0
@export var recoil_recover_speed: float = 8.0

var _current_recoil: float = 0.0
var _initial_rotation: Vector3

# muzzle fx nodes (optional)
@onready var muzzle_smoke: GPUParticles3D = null

@warning_ignore("shadowed_variable_base_class")
func _find_node_recursive(root: Node, name: String) -> Node:
	for child in root.get_children():
		if child is Node:
			if child.name == name:
				return child
			var f = _find_node_recursive(child, name)
			if f:
				return f
	return null

@onready var muzzle_flash: MeshInstance3D = $MuzzleFlash


func _ready() -> void:
	if muzzle_flash:
		muzzle_flash.visible = false
	else:
		push_warning("MuzzleFlash not found as child $MuzzleFlash")
	# try inspector-assigned first (you may already have this)
	if not crosshair_control or crosshair_control == null:
		# search the whole scene for a Control named "CrossHair"
		# (searches recursively; put your crosshair node name exactly "CrossHair")
		var scene_root := get_tree().current_scene
		if scene_root:
			crosshair_control = _find_node_recursive(scene_root, "CrossHair") as Control
			if crosshair_control:
				print("Gun: found crosshair at ", crosshair_control.get_path())
			else:
				print("Gun: crosshair not found — will use screen center")
		
	# debug
	if crosshair_control:
		print("Gun: found crosshair:", crosshair_control.get_path())
	else:
		print("Gun: no crosshair found, will use screen center")
	
	
	if muzzle_path:
		muzzle = get_node_or_null(muzzle_path)
	# cache muzzle FX nodes if present
	if muzzle:
		muzzle_flash = muzzle.get_node_or_null("MuzzleFlash")
		muzzle_smoke = muzzle.get_node_or_null("MuzzleSmoke")
	_initial_rotation = rotation_degrees

	# debug: confirm important setup
	if not muzzle:
		print("Gun.ready: WARNING - muzzle_path not set or node not found.")
	if not bullet_scene:
		print("Gun.ready: WARNING - bullet_scene not assigned in Inspector.")
	# try auto-find ray_origin if not assigned in inspector
	if not ray_origin:
		var scene_root := get_tree().current_scene
		if scene_root:
			var found := _find_node_recursive(scene_root, "RayOrigin")
			if found and found is Node3D:
				ray_origin = found
				print("Gun.ready: found RayOrigin at ", ray_origin.get_path())
			else:
				print("Gun.ready: RayOrigin not found; bullets will spawn from muzzle.")


func _process(delta: float) -> void:
	time_since_last_shot += delta
	if Input.is_action_pressed("shoot") and time_since_last_shot >= fire_rate:
		shoot()
		
	if Input.is_action_just_pressed("shoot"):
		show_muzzle_flash()
		
	# --- recoil recovery ---
	if _current_recoil > 0.001:
		_current_recoil = max(_current_recoil - recoil_recover_speed * delta, 0.0)
		var r = _initial_rotation
		r.x = r.x - _current_recoil
		rotation_degrees = r
	else:
		rotation_degrees = _initial_rotation

@warning_ignore("shadowed_variable")


func show_muzzle_flash() -> void:
	if not muzzle_flash:
		return
	muzzle_flash.visible = true
	await get_tree().create_timer(0.05).timeout
	if muzzle_flash:
		muzzle_flash.visible = false



@warning_ignore("shadowed_variable")
func get_bullet_forward_axis(bullet: Node3D, muzzle: Node3D) -> Vector3:
	# muzzle forward in world space (use -Z as canonical forward of the muzzle)
	var muzzle_forward: Vector3 = -muzzle.global_transform.basis.z
	muzzle_forward = muzzle_forward.normalized()

	# bullet's local axes expressed in world space
	var b_basis = bullet.global_transform.basis
	var axes = {
		"X+": b_basis.x.normalized(),
		"X-": (-b_basis.x).normalized(),
		"Y+": b_basis.y.normalized(),
		"Y-": (-b_basis.y).normalized(),
		"Z+": b_basis.z.normalized(),
		"Z-": (-b_basis.z).normalized(),
	}

	# find best aligned axis by dot product
	var best_axis = Vector3.ZERO
	var best_dot = -1.0
	var best_name = ""
	@warning_ignore("shadowed_variable_base_class")
	for name in axes.keys():
		var axis = axes[name]
		var d = muzzle_forward.dot(axis)
		if d > best_dot:
			best_dot = d
			best_axis = axis
			best_name = name
	# debug: print which local axis was chosen (useful for fixing model rotation)
	print("Gun: Chosen axis:", best_name, " dot:", best_dot)
	return best_axis

# --------------------------------------------
# New robust bullet spawn/fire helpers
# --------------------------------------------
@warning_ignore("shadowed_variable")
func _spawn_bullet_at_muzzle(bullet_scene: PackedScene, muzzle_node: Node3D) -> Node:
	if not bullet_scene:
		return null
	var bullet = bullet_scene.instantiate()

	# place bullet transform at muzzle first (so it visually originates at muzzle)
	if muzzle_node:
		var muzzle_pos = muzzle_node.global_transform.origin
		# keep bullet basis as identity for now; we'll orient it later
		bullet.global_transform = Transform3D(bullet.global_transform.basis, muzzle_pos)

	# add to main scene root immediately (not deferred) so it is visible now
	var root = get_tree().get_current_scene() if get_tree().get_current_scene() != null else get_tree().get_root()
	if Engine.has_singleton("SceneTree"):
		root = get_tree().get_current_scene()
	if root == null:
		root = get_tree().get_root()
	root.add_child(bullet)

	return bullet

func _fire_projectile_at_dir(fire_dir: Vector3) -> void:
	# instantiate and add bullet (safe)
	var bullet = _spawn_bullet_at_muzzle(bullet_scene, muzzle)
	if bullet == null:
		push_warning("Gun._fire_projectile_at_dir: cannot instantiate bullet (scene missing).")
		return

	# debug: show muzzle and direction info
	var muzzle_pos = muzzle.global_transform.origin if muzzle else Vector3.ZERO
	print("Gun._fire_projectile_at_dir: muzzle_pos=", muzzle_pos, " fire_dir=", fire_dir)

	# orient the bullet visually so its -Z faces the fire_dir (Godot forward = -Z)
	var z_axis = -fire_dir.normalized()
	var up = Vector3.UP
	if abs(z_axis.dot(up)) > 0.99:
		up = Vector3(0, 0, 1)
	var x_axis = up.cross(z_axis).normalized()
	var y_axis = z_axis.cross(x_axis).normalized()
	@warning_ignore("shadowed_variable_base_class")
	var basis = Basis(x_axis, y_axis, z_axis)
	# apply transform with new basis and origin
	bullet.global_transform = Transform3D(basis, muzzle_pos)

	# debug: confirm bullet root and visible child
	var mesh_found := false
	for child in bullet.get_children():
		if child is MeshInstance3D:
			mesh_found = true
			break
	print("Gun._fire_projectile_at_dir: bullet_instanced, has_mesh:", mesh_found, " root_type:", bullet.get_class())

	# physics: set velocity and disable gravity if RigidBody3D
	var bullet_speed := 50.0  # tune as needed
	if bullet is RigidBody3D:
		# ensure awake
		bullet.set_sleeping(false)

		# disable gravity if possible
		if "gravity_scale" in bullet:
			bullet.gravity_scale = 0.0
		# set linear velocity in world space
		bullet.linear_velocity = fire_dir * bullet_speed
		print("Gun._fire_projectile_at_dir: set RigidBody3D.linear_velocity =", bullet.linear_velocity)
	elif bullet.has_method("set_linear_velocity"):
		if bullet.has_variable("gravity_scale"):
			bullet.gravity_scale = 0.0
		bullet.set_linear_velocity(fire_dir * bullet_speed)
		print("Gun._fire_projectile_at_dir: called set_linear_velocity on bullet")
	else:
		# fallback: seek a RigidBody child
		var rb := bullet.get_node_or_null("RigidBody3D")
		if rb == null:
			rb = bullet.get_node_or_null("Body")
		if rb and rb is RigidBody3D:
			rb.global_transform = bullet.global_transform
			if "gravity_scale" in rb:
				rb.gravity_scale = 0.0
			rb.linear_velocity = fire_dir * bullet_speed
			print("Gun._fire_projectile_at_dir: applied velocity to child RigidBody3D")
		else:
			push_warning("Bullet root not a RigidBody3D and no known setter found. Convert bullet root to RigidBody3D or expose set_linear_velocity().")

	# reset fire timer/recoil/muzzle fx etc
	time_since_last_shot = 0.0
	_current_recoil = clamp(_current_recoil + recoil_amount, 0.0, recoil_max)
	_trigger_muzzle_fx()

# New helper which accepts an explicit spawn origin (RayOrigin)
func _fire_projectile_at_dir_and_origin(fire_dir: Vector3, spawn_origin: Vector3) -> void:
	# instantiate and add bullet (safe)
	var bullet = bullet_scene.instantiate()
	if bullet == null:
		push_warning("Gun._fire_projectile_at_dir_and_origin: cannot instantiate bullet (scene missing).")
		return

	# place bullet at spawn_origin
	bullet.global_transform = Transform3D(bullet.global_transform.basis, spawn_origin)

	# add to main scene root
	var root = get_tree().get_current_scene() if get_tree().get_current_scene() != null else get_tree().get_root()
	if root == null:
		root = get_tree().get_root()
	root.add_child(bullet)

	# debug output
	print("Gun._fire_projectile_at_dir_and_origin: spawn_origin=", spawn_origin, " fire_dir=", fire_dir, " bullet_root_type=", bullet.get_class())

	# orient bullet visually so its -Z faces the fire_dir (Godot forward = -Z)
	var z_axis = -fire_dir.normalized()
	var up = Vector3.UP
	if abs(z_axis.dot(up)) > 0.99:
		up = Vector3(0, 0, 1)
	var x_axis = up.cross(z_axis).normalized()
	var y_axis = z_axis.cross(x_axis).normalized()
	@warning_ignore("shadowed_variable_base_class")
	var basis = Basis(x_axis, y_axis, z_axis)
	bullet.global_transform = Transform3D(basis, spawn_origin)

	# physics: set velocity and disable gravity if RigidBody3D
	var bullet_speed := 50.0
	if bullet is RigidBody3D:
		bullet.set_sleeping(false)
		if "gravity_scale" in bullet:
			bullet.gravity_scale = 0.0
		bullet.linear_velocity = fire_dir * bullet_speed
		print("Gun._fire_projectile_at_dir_and_origin: set RigidBody3D.linear_velocity =", bullet.linear_velocity)
	elif bullet.has_method("set_linear_velocity"):
		if bullet.has_variable("gravity_scale"):
			bullet.gravity_scale = 0.0
		bullet.set_linear_velocity(fire_dir * bullet_speed)
	else:
		var rb := bullet.get_node_or_null("RigidBody3D")
		if rb == null:
			rb = bullet.get_node_or_null("Body")
		if rb and rb is RigidBody3D:
			rb.global_transform = bullet.global_transform
			if "gravity_scale" in rb:
				rb.gravity_scale = 0.0
			rb.linear_velocity = fire_dir * bullet_speed

	# reset fire timer/recoil/muzzle fx etc
	time_since_last_shot = 0.0
	_current_recoil = clamp(_current_recoil + recoil_amount, 0.0, recoil_max)
	_trigger_muzzle_fx()

# ---------- helper: find camera ----------
func _get_active_camera() -> Camera3D:
	# prefer the viewport's camera
	var cam := get_viewport().get_camera_3d()
	if cam:
		return cam
	# fallback: search recursively for a Camera3D in current scene
	var root = get_tree().get_current_scene()
	if root:
		var found: Node = root.find_node("Camera3D", true, false)

		if found and found is Camera3D:
			return found
	return null


# ---------- helper: find shooter (player) from gun node ----------
func _find_shooter() -> Node:
	var node = self.get_parent()
	while node:
		# assumes your player scene is in group "player" (recommended)
		if node.is_in_group("player"):
			return node
		node = node.get_parent()
	return null


# ---------- spawn + orient bullet at a given origin and direction ----------
func _spawn_bullet_and_fire(spawn_origin: Vector3, fire_dir: Vector3) -> void:
	if not bullet_scene:
		push_warning("Gun: no bullet_scene set")
		return

	# instantiate bullet
	var bullet = bullet_scene.instantiate()
	if bullet == null:
		push_warning("Gun: failed to instantiate bullet_scene")
		return

	# ensure bullet is added to main scene root
	var root = get_tree().get_current_scene() if get_tree().get_current_scene() != null else get_tree().get_root()
	if root == null:
		root = get_tree().get_root()
	root.add_child(bullet)

	# orient bullet so -Z faces the fire_dir (Godot forward: -Z)
	var z_axis = -fire_dir.normalized()
	var up = Vector3.UP
	if abs(z_axis.dot(up)) > 0.99:
		up = Vector3(0,0,1)
	var x_axis = up.cross(z_axis).normalized()
	var y_axis = z_axis.cross(x_axis).normalized()
	var basis = Basis(x_axis, y_axis, z_axis)

	# set transform and a small forward offset to avoid immediate collision with shooter
	var spawn_transform = Transform3D(basis, spawn_origin + fire_dir.normalized() * 0.2)
	bullet.global_transform = spawn_transform

	# set shooter if we can find owner
	var shooter = _find_shooter()
	if shooter:
		# store a reference on bullet for attribution / friendly-fire checks
		if "shooter" in bullet:
			bullet.shooter = shooter
		else:
			# create field dynamically (works in GDScript)
			bullet.set("shooter", shooter)

	# set physics velocity (RigidBody3D expected)
	var bullet_speed := 50.0
	if bullet is RigidBody3D:
		# disable bullet gravity if present
		if "gravity_scale" in bullet:
			bullet.gravity_scale = 0.0
		# wake up
		bullet.set_sleeping(false)
		bullet.linear_velocity = fire_dir.normalized() * bullet_speed
	elif bullet.has_method("set_linear_velocity"):
		if bullet.has_variable("gravity_scale"):
			bullet.gravity_scale = 0.0
		bullet.set_linear_velocity(fire_dir.normalized() * bullet_speed)
	else:
		# try child rigidbody fallback
		var rb := bullet.get_node_or_null("RigidBody3D")
		if rb and rb is RigidBody3D:
			rb.global_transform = bullet.global_transform
			if "gravity_scale" in rb:
				rb.gravity_scale = 0.0
			rb.linear_velocity = fire_dir.normalized() * bullet_speed
		else:
			push_warning("Gun: bullet root not RigidBody3D and no setter found. Convert the bullet scene accordingly.")

	# reset fire timer & recoil
	time_since_last_shot = 0.0
	_current_recoil = clamp(_current_recoil + recoil_amount, 0.0, recoil_max)
	_trigger_muzzle_fx()




# --- main shoot() using camera center ray for aim
func shoot() -> void:
	if not bullet_scene:
		print("Gun: bullet_scene not assigned.")
		return

	# find camera
	var cam := _get_active_camera()
	# fallback: if no camera, spawn from muzzle forward
	if cam == null:
		var fallback_forward = muzzle.global_transform.basis.z * -1.0 if muzzle else Vector3.FORWARD
		_fire_projectile_at_dir(fallback_forward) # your existing fallback helper
		return

	# compute screen point (use crosshair control center if present else exact screen center)
	var screen_point: Vector2
	if crosshair_control and crosshair_control.is_inside_tree():
		# get global position of crosshair control in screen coords
		# prefer using get_global_position() + rect_size/2 only if it's a Control and in the current canvas
		var gp = crosshair_control.get_global_position()
		var rs = Vector2.ZERO
		if "rect_size" in crosshair_control:
			rs = crosshair_control.rect_size
		screen_point = gp + rs * 0.5
	else:
		screen_point = get_viewport().get_visible_rect().size * 0.5

	# build a long camera ray through screen_point
	var cam_origin := cam.project_ray_origin(screen_point)
	var cam_dir := cam.project_ray_normal(screen_point)
	var aim_point := cam_origin + cam_dir * 2000.0

	# choose spawn origin:
	# - prefer ray_origin Marker3D if assigned and found
	# - else use muzzle if assigned
	var spawn_origin: Vector3 = muzzle.global_transform.origin if muzzle else cam_origin + cam_dir * 0.5
	if ray_origin and ray_origin is Node3D and ray_origin.is_inside_tree():
		spawn_origin = ray_origin.global_transform.origin
	# if no ray_origin, you can project the muzzle position onto the camera ray distance, to reduce mismatch:
	elif muzzle:
		var muzzle_to_cam_dist = (muzzle.global_transform.origin - cam_origin).length()
		spawn_origin = cam_origin + cam_dir * muzzle_to_cam_dist

	# compute final firing direction from spawn origin to aim_point so bullet goes through crosshair
	var fire_dir := (aim_point - spawn_origin).normalized()

	# debug (remove or comment out when satisfied)
	# print("Gun.shoot => cam_origin=", cam_origin, " spawn_origin=", spawn_origin, " aim_point=", aim_point, " fire_dir=", fire_dir)

	# spawn and fire
	_spawn_bullet_and_fire(spawn_origin, fire_dir)



func _trigger_muzzle_fx() -> void:
	# start muzzle flash (short) and smoke (longer)
	if muzzle_flash:
		muzzle_flash.visible = true
	if muzzle_smoke:
		muzzle_smoke.emitting = true

	# flash duration ~0.12s
	await get_tree().create_timer(0.12).timeout
	if muzzle_flash:
		muzzle_flash.visible = false

	# let smoke run ~1s then stop
	await get_tree().create_timer(1.0).timeout
	if muzzle_smoke:
		muzzle_smoke.emitting = false


		
