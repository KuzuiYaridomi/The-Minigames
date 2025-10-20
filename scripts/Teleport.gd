extends Area3D

# Inspector fields
@export var target_path: NodePath                # explicit one-way target (optional)
@export var pair_with: NodePath                  # another Teleport node to pair with (optional)
@export var two_way: bool = false                # if true and pair_with is set, auto-link both teleports
@export var cooldown: float = 0.5                # seconds to disable pair to avoid ping-pong

# runtime cached nodes
var target_area: Area3D = null
var pair_area: Area3D = null

var _enabled: bool = true

func _ready() -> void:
	# connect signal
	if not is_connected("body_entered", Callable(self, "_on_body_entered")):
		connect("body_entered", Callable(self, "_on_body_entered"))

	# try resolve target_area from target_path
	if target_path and str(target_path) != "":
		target_area = get_node_or_null(target_path) as Area3D

	# try resolve pair_area from pair_with
	if pair_with and str(pair_with) != "":
		pair_area = get_node_or_null(pair_with) as Area3D

	# if pair_with is provided but no explicit target_path, default to pair_area
	if not target_area and pair_area:
		target_area = pair_area

	# If user requested two_way and a valid pair was found, attempt to link them symmetrically.
	# We call an exported helper on the other node so this works even if both Teleports use this same script.
	if two_way and pair_area:
		# ask the pair node to set its target to us (safe: will only succeed if pair has the method)
		if pair_area.has_method("assign_pair_target"):
			pair_area.call("assign_pair_target", self.get_path())
		else:
			# fallback: try to set its exported property (works if pair is also Teleport or has target_path)
			if pair_area.has_meta("target_path") or true:
				# set property if exists; ignore runtime error otherwise
				# Use call_deferred to avoid editor-time assignment surprises
				pair_area.call_deferred("set", "target_path", self.get_path())

	# defensive info
	if not target_area:
		print_debug("Teleport: target not resolved for ", get_path(), ". Set target_path or pair_with in Inspector.")

# Helper called by partner teleport to assign its target to this teleport
func assign_pair_target(path: NodePath) -> void:
	target_path = path
	target_area = get_node_or_null(target_path) as Area3D

# Main trigger
func _on_body_entered(body: Node) -> void:
	if not _enabled:
		return
	if not body:
		return
	# only teleport players (or objects in "player" group)
	if not body.is_in_group("player"):
		return

	# resolve target on demand
	if not target_area and target_path and str(target_path) != "":
		target_area = get_node_or_null(target_path) as Area3D
	if not target_area:
		push_warning("Teleport: no target assigned. Ignoring teleport.")
		return

	# compute destination (prefer ExitMarker if present)
	var dest: Vector3
	var dest_basis: Basis = Basis.IDENTITY
	if target_area.has_node("ExitMarker"):
		var exit_marker = target_area.get_node("ExitMarker") as Node3D
		dest = exit_marker.global_transform.origin
		dest_basis = exit_marker.global_transform.basis
	else:
		dest = target_area.global_transform.origin
		dest_basis = target_area.global_transform.basis

	# disable both teleports temporarily to avoid immediate back-teleport
	_enabled = false
	monitoring = false
	if target_area:
		target_area.monitoring = false

	# move the body safely
	if body is CharacterBody3D:
		var t = body.global_transform
		t.origin = dest
		# preserve orientation? you can rotate to match target if desired:
		# t.basis = dest_basis
		body.global_transform = t
		# reset velocity if the body exposes it
		if "velocity" in body:
			body.velocity = Vector3.ZERO
	else:
		# generic fallback - set global_transform if possible
		if body.has_method("set_global_transform"):
			var tt = body.global_transform
			tt.origin = dest
			body.global_transform = tt
		else:
			# last resort: translate or move to dest
			body.global_transform = Transform3D(body.global_transform.basis, dest)

	# optional callback on teleported body
	if body.has_method("on_teleported"):
		body.call_deferred("on_teleported", self, target_area)

	# start cooldown to re-enable monitoring (non-blocking)
	_teleport_cooldown()

# cooldown re-enable (async)
func _teleport_cooldown() -> void:
	# allow a short wait then re-enable both ends
	await get_tree().create_timer(cooldown).timeout
	_enabled = true
	monitoring = true
	if target_area:
		target_area.monitoring = true
