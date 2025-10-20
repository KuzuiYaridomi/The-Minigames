extends Node
class_name DamageSystem

# Ensure the Health type is available by preloading the script:
@warning_ignore("shadowed_global_identifier")
const Health = preload("res://scripts/Health.gd")

# Find a Health component on the node, its children, or ancestors
func find_health_component(node: Node) -> Health:
	if node == null:
		return null
	if node is Health:
		return node
	if node.has_node("Health"):
		var c = node.get_node_or_null("Health")
		if c and c is Health:
			return c
	# shallow search children
	for child in node.get_children():
		if child is Health:
			return child
	# walk upward
	var p = node.get_parent()
	if p:
		return find_health_component(p)
	return null

# Deal damage to target (returns true if applied)
func deal_damage(target: Node, amount: int, instigator: Node = null, force: Vector3 = Vector3.ZERO, damage_type: String = "") -> bool:
	var h = find_health_component(target)
	if h:
		return h.apply_damage(amount, instigator, force, damage_type)
	return false
