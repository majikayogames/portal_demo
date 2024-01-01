class_name PortalMeshDuplicator
extends Node3D

var body
var dupe
var in_portal
var out_portal

func find_by_class(node: Node, className : String, exit_after_one = false, result_array = []):
	if node.is_class(className):
		result_array.push_back(node)
		if exit_after_one:
			return result_array
	for child in node.get_children():
		find_by_class(child, className, exit_after_one, result_array)
	return result_array
	
func get_child_by_name(node: Node, name):
	for c in node.get_children():
		if c.name == name:
			return c
	return null

func iterate_through_pair_and_copy_over_props(node: Node, other_node: Node, props_to_set: Array):
	for prop in props_to_set:
		other_node.set(prop, node.get(prop))
	for child in node.get_children():
		var node_child = child
		var other_node_child = get_child_by_name(other_node, child.name)
		if node_child and other_node_child:
			iterate_through_pair_and_copy_over_props(node_child, other_node_child, props_to_set)
	
func make_copy_of_node_tree(original : Node, allowed_node_types=[], external_skeleton=null):
	var cur_node
	if allowed_node_types.has(original.get_class()):
		cur_node = original.duplicate()
		for child in cur_node.get_children():
			cur_node.remove_child(child)
			child.queue_free()
	else:
		cur_node = Node3D.new()
		cur_node.name = original.name
		if original.is_class("Node3D"):
			cur_node.transform = original.transform
			cur_node.visible = original.visible
			cur_node.visibility_parent = original.visibility_parent
			
	if cur_node.is_class("BoneAttachment3D") and external_skeleton:
		cur_node.use_external_skeleton = true
		cur_node.external_skeleton = external_skeleton
	if cur_node.is_class("MeshInstance3D") and external_skeleton:
		cur_node.skeleton = external_skeleton
	
	for child in original.get_children():
		cur_node.add_child(make_copy_of_node_tree(child, allowed_node_types, external_skeleton))
	
	return cur_node

func _ready():
	var original_skeletons = find_by_class(body, "Skeleton3D")
	var external_skeleton = null
	if len(original_skeletons) > 0:
		external_skeleton = original_skeletons[0].get_path()
		
	dupe = make_copy_of_node_tree(body, ["MeshInstance3D", "CSGShape3D"], external_skeleton)
	add_child(dupe)
	synchronize_all()

func synchronize_all():
	iterate_through_pair_and_copy_over_props(body, dupe, ["transform", "visible"])
	var original_rel_to_in_portal = in_portal.global_transform.affine_inverse() * body.global_transform
	var moved_to_out_portal = out_portal.global_transform * original_rel_to_in_portal
	dupe.global_transform = moved_to_out_portal

func _process(delta):
	synchronize_all()
func _physics_process(delta):
	synchronize_all()
