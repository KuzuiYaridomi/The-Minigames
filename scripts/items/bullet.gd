extends RigidBody3D

@export var lifetime: float = 5.0       # seconds
@export var damage: int = 1
@export var impact_scene: PackedScene   # optional: small impact VFX scene (Particles/CPUParticles or Mesh)
@export var impact_impulse_scale: float = 0.1

var shooter: Node = null
@onready var hitbox: Area3D = $Hitbox if has_node("Hitbox") else null

func _ready() -> void:
	# schedule despawn after lifetime
	get_tree().create_timer(lifetime).timeout.connect(Callable(self, "queue_free"))
	# ensure awake
	if has_method("set_sleeping"):
		set_sleeping(false)
	# disable gravity for straight bullet behaviour (optional)
	if "gravity_scale" in self:
		self.gravity_scale = 0.0

	# connect Area3D hit if present
	if hitbox:
		if not hitbox.is_connected("body_entered", Callable(self, "_on_hitbox_body_entered")):
			hitbox.connect("body_entered", Callable(self, "_on_hitbox_body_entered"))
	else:
		# fallback: connect RigidBody body_entered (may not always fire reliably)
		if not is_connected("body_entered", Callable(self, "_on_body_entered")):
			connect("body_entered", Callable(self, "_on_body_entered"))


# Area3D hit handler (preferred)
func _on_hitbox_body_entered(body: Node) -> void:
	_handle_hit(body)

# Fallback RigidBody contact handler
func _on_body_entered(body: Node) -> void:
	_handle_hit(body)


# helper: search upward for node that can take damage (checks self/parents)
func _find_damage_target(start_node: Node) -> Node:
	var n := start_node
	while n:
		# prefer node that exposes damage API
		if n.has_method("apply_damage") or n.has_method("take_damage"):
			return n
		# or child named "Health"
		if n.has_node("Health"):
			var hc = n.get_node_or_null("Health")
			if hc:
				return hc
		n = n.get_parent()
	return null


# robust damage application helper (use from bullet collision)
func _apply_damage_to_body(body: Node, amount: int, shooter: Node = null, hit_force: Vector3 = Vector3.ZERO) -> bool:
	var applied := false

	# Step up to a damage-capable node (body might be a CollisionShape3D)
	var target := _find_damage_target(body)
	if not target:
		return false

	# 1) If the target itself exposes an explicit API, prefer it
	if target.has_method("apply_damage"):
		target.call_deferred("apply_damage", amount, shooter, hit_force)
		applied = true
	elif target.has_method("take_damage"):
		# enemy.take_damage(amount, instigator, hit_force) style
		target.call_deferred("take_damage", amount, shooter, hit_force)
		applied = true
	else:
		# nothing found - no damage applied
		applied = false

	# 2) Optionally: if the hit body (or parent) is a RigidBody3D, apply physical impulse for knockback
	if applied and hit_force != Vector3.ZERO:
		# locate the nearest RigidBody3D to apply impulse (prefer the exact physics body)
		var rb = null
		# prefer the immediate physics body (body may be the RigidBody)
		if body is RigidBody3D:
			rb = body
		else:
			# try walking up to find a RigidBody3D parent
			var p := body
			while p:
				if p is RigidBody3D:
					rb = p
					break
				p = p.get_parent()
		if rb:
			# apply impulse at center (use small scale)
			var impulse := hit_force * impact_impulse_scale
			# apply_impulse(offset, impulse)
			if rb.has_method("apply_impulse"):
				rb.apply_impulse(Vector3.ZERO, impulse)
			elif rb.has_method("apply_central_impulse"):
				rb.apply_central_impulse(impulse)

	return applied


func _handle_hit(body: Node) -> void:
	if body == self:
		return
	if shooter and body == shooter:
		# ignore shooter
		return

	# compute hit force from bullet velocity (if applicable)
	var hit_force := Vector3.ZERO
	if "linear_velocity" in self:
		hit_force = linear_velocity

	# 1) Try autoload Damagesystem first (if you have an autoload named exactly "Damagesystem")
	var applied: bool = false
	var ds = get_node_or_null("/root/Damagesystem")
	if ds:
		# call the autoload API; expected signature: deal_damage(target, amount, instigator, force)
		# use call_deferred for safety
		if ds.has_method("deal_damage"):
			ds.call_deferred("deal_damage", body, damage, shooter, hit_force)
			applied = true
	else:
		# fallback: robust local damage helper which climbs parents and calls found API
		applied = _apply_damage_to_body(body, damage, shooter, hit_force)

	# 2) Apply physics impulse if the hit body is a rigidbody (also done inside _apply_damage_to_body)
	if body and body is RigidBody3D and hit_force != Vector3.ZERO:
		var impulse = hit_force * impact_impulse_scale
		if body.has_method("apply_impulse"):
			body.apply_impulse(Vector3.ZERO, impulse)
		elif body.has_method("apply_central_impulse"):
			body.apply_central_impulse(impulse)

	# 3) Spawn impact VFX
	if impact_scene:
		var vfx = impact_scene.instantiate()
		var root = get_tree().get_current_scene() if get_tree().get_current_scene() != null else get_tree().get_root()
		if root == null:
			root = get_tree().get_root()
		root.add_child(vfx)
		# place at bullet position
		var pos = global_transform.origin
		vfx.global_transform = Transform3D(vfx.global_transform.basis, pos)
		# auto-free after a short time if VFX doesn't self-clean
		if not vfx.has_method("queue_free_later"):
			get_tree().create_timer(1.0).timeout.connect(Callable(vfx, "queue_free"))

	# finally destroy the bullet
	queue_free()
