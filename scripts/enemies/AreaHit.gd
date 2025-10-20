# AreaHit.gd
extends Area3D

@export var multiplier: float = 1.0
@export var owner_node: NodePath         # optional: path to owning character (usually parent)
@export var friendly_group: String = ""  # optional: group to ignore (e.g., "enemies")

func _ready() -> void:
	if not is_connected("body_entered", Callable(self, "_on_body_entered")):
		connect("body_entered", Callable(self, "_on_body_entered"))

func _on_body_entered(body: Node) -> void:
	# this area is typically used to detect projectile collisions or overlaps
	# If the body is a projectile, try to read its damage and shooter
	if body == null:
		return
	# ignore friendly hits optionally
	if friendly_group != "" and body.is_in_group(friendly_group):
		return

	# check if body has damage info
	var ds = get_node_or_null("/root/Damagesystem")
	var dmg = 0
	var shooter = null
	var shooter_val = null
	if body.has_method("apply_damage"):
		dmg = int(body.damage)
	if body and body.has_method("get"):
		shooter_val = body.get("shooter")
	if shooter_val != null:
		shooter = shooter_val
	# fallback damage value (if projectile didn't provide)
	if dmg == 0:
		dmg = 1

	@warning_ignore("unused_variable")
	var applied = false
	if ds:
		applied = ds.deal_damage(get_parent(), int(round(dmg * multiplier)), shooter, Vector3.ZERO)
	else:
		# try direct API on parent
		@warning_ignore("shadowed_variable_base_class")
		var owner = get_parent()
		if owner and owner.has_method("apply_damage"):
			owner.call_deferred("apply_damage", int(round(dmg * multiplier)), shooter, Vector3.ZERO)
			applied = true

	# optionally queue_free projectile if it was the collider
	if body and body.get_parent() and (body.get_parent().name == "Bullets" or "Bullet" in String(body.name)):
		body.queue_free()
