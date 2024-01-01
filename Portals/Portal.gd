@tool
class_name Portal
extends Area3D

@export var other_portal : Node3D

## The visual layer the portal is rendered on. Set this to something other than the layer your level and models are on.
## This is used to hide the destination portal from the camera's view so we can see past it.
@export var cull_layer : int = 4

@export var make_mesh_duplicates : bool = true
@export var portal_area_z_margin : = 1.0
@export var portal_area_x_margin : = 0.1
@export var portal_area_y_margin : = 0.1
@export var size : = Vector2(1,2)
@export var use_body_camera_as_teleport_origin = true

## Was getting weird behavior with the near cull plane,
## only solution I found was to lower near cull plane on camera
@export var enable_camera_near_plane_fix: bool = true

const CAM_NEAR_NEEDED_TO_PREVENT_GLITCH = 0.001

# If a body moved further than this while passing through the portal, consider it a teleport.
# Disables portal movement in cases where the player teleports via some ability, but moved
# over the portal border in the process. Should only activate portal when walking through.
const MOVE_WAS_TELEPORT_THRESHOLD = 5.0

var _tracked_phys_bodies = []

# Edge case but possible. Adding this to prevent teleporting twice if body lands exactly on portal plane
func _nonzero_sign(value):
	var s = sign(value)
	if s == 0:
		s = 1
	return s

func _ready():
	if Engine.is_editor_hint():
		return
	$PortalVisual.set_layer_mask_value(1, false)
	$PortalVisual.set_layer_mask_value(cull_layer, true)
	$CameraViewport/Camera3D.set_cull_mask_value(other_portal.cull_layer, false)
	# Godot normally does order _process/_phys_process -> internal physics step moving bodies -> draw immediately
	# We must call do_updates on the frame_pre_draw signal or there will be 1 frame where the body has not actually teleported
	# This will mess up the view and cause flicker for 1 frame on  player controllers
	#RenderingServer.frame_pre_draw.connect(do_updates)
	# Or so I would think. It only works with this + _process + _physics_process all calling do_updates.
	# Otherwise there is flicker. I'm not sure why just frame_pre_draw doesn't work.
	_update_portal_area_size()
	_set_portal_camera_environment_to_world3d_environment_no_tonemap()

func _set_portal_camera_environment_to_world3d_environment_no_tonemap():
	var world_3d = get_viewport().world_3d
	if not world_3d or not world_3d.environment:
		return
	# The tonemap must be disabled/set to linear.
	# This is so the tonemap won't be applied twice in the main camera render.
	$CameraViewport/Camera3D.environment = world_3d.environment.duplicate()
	$CameraViewport/Camera3D.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR

func _update_portal_area_size():
	$PortalVisual.size.x = self.size.x
	$PortalVisual.size.y = self.size.y
	$CollisionShape3D.shape.size = Vector3(
		self.size.x + self.portal_area_x_margin * 2,
		self.size.y + self.portal_area_y_margin * 2,
		self.portal_area_z_margin * 2)

# Copied from https://github.com/V-Sekai/avatar_vr_demo/blob/master/addons/V-Sekai.xr-mirror/mirror.gd
func set_projection_oblique_near_plane(matrix: Projection, clip_plane: Plane):
	# Based on the paper
	# Lengyel, Eric. “Oblique View Frustum Depth Projection and Clipping”.
	# Journal of Game Development, Vol. 1, No. 2 (2005), Charles River Media, pp. 5–16.

	# Calculate the clip-space corner point opposite the clipping plane
	# as (sgn(clipPlane.x), sgn(clipPlane.y), 1, 1) and
	# transform it into camera space by multiplying it
	# by the inverse of the projection matrix
	var q = Vector4(
		(sign(clip_plane.x) + matrix.z.x) / matrix.x.x,
		(sign(clip_plane.y) + matrix.z.y) / matrix.y.y,
		-1.0,
		(1.0 + matrix.z.z) / matrix.w.z)

	var clip_plane4 = Vector4(clip_plane.x, clip_plane.y, clip_plane.z, clip_plane.d)

	# Calculate the scaled plane vector
	var c: Vector4 = clip_plane4 * (2.0 / clip_plane4.dot(q))

	# Replace the third row of the projection matrix
	matrix.x.z = c.x - matrix.x.w
	matrix.y.z = c.y - matrix.y.w
	matrix.z.z = c.z - matrix.z.w
	matrix.w.z = c.w - matrix.w.w
	return matrix

# This function is based on https://github.com/SebLague/Portals/blob/master/Assets/Scripts/Core/Portal.cs
func _update_portal_camera_near_clip_plane(camera):
	if not camera.has_method("set_override_projection"):
		return # Needs https://github.com/V-Sekai/godot/tree/override_projection_4.2 branch
	
	const NEAR_CLIP_OFFSET = 0.05
	const NEAR_CLIP_LIMIT = 0.1
	
	# Calculate the near clip plane in camera space
	var clip_plane = other_portal.global_transform
	var clip_plane_forward: Vector3 = -clip_plane.basis.z
	var portal_side = _nonzero_sign(clip_plane_forward.dot(other_portal.global_transform.origin - camera.global_transform.origin))
 
	var cam_space_pos = camera.get_camera_transform().affine_inverse() * clip_plane.origin
	var cam_space_normal = (camera.get_camera_transform().affine_inverse().basis * clip_plane_forward) * portal_side
	var cam_space_dst = - cam_space_pos.dot(cam_space_normal) + NEAR_CLIP_OFFSET;
	
	# Oblique plane when very close to portal causes glitching/visual artifacts, so only enable if a small distance away
	if abs(cam_space_dst) > NEAR_CLIP_LIMIT:
		var proj : Projection = camera.get_camera_projection()
		var near_clip_plane = Plane(cam_space_normal, cam_space_dst)
		proj = set_projection_oblique_near_plane(proj, near_clip_plane)
		camera.set_override_projection(proj)
	else:
		# Set back to unmodified frustum if camera is very close to portal
		camera.set_override_projection(Projection(Vector4.ZERO, Vector4.ZERO, Vector4.ZERO, Vector4.ZERO))
	
func _update_camera_to_other_portal():
	var cur_camera = get_viewport().get_camera_3d()
	if not cur_camera:
		return
		
	# first, get the relative position/rotation of the camera to this portal
	var cur_camera_transform_rel_to_this_portal = self.global_transform.affine_inverse() * cur_camera.global_transform
	var moved_to_other_portal = other_portal.global_transform * cur_camera_transform_rel_to_this_portal
	# then, set the portal camera's transform to that relative position/rotation, but relative to other_portal
	$CameraViewport/Camera3D.global_transform = moved_to_other_portal
	$CameraViewport/Camera3D.fov = cur_camera.fov
	
	$CameraViewport/Camera3D.cull_mask = cur_camera.cull_mask
	$CameraViewport/Camera3D.set_cull_mask_value(other_portal.cull_layer, false)
	
	$CameraViewport.size = get_viewport().get_visible_rect().size
	$CameraViewport.msaa_3d = get_viewport().msaa_3d
	$CameraViewport.screen_space_aa = get_viewport().screen_space_aa
	$CameraViewport.use_taa = get_viewport().use_taa
	$CameraViewport.use_debanding = get_viewport().use_debanding
	$CameraViewport.use_occlusion_culling = get_viewport().use_occlusion_culling
	$CameraViewport.mesh_lod_threshold = get_viewport().mesh_lod_threshold
	
	_update_portal_camera_near_clip_plane($CameraViewport/Camera3D)
	
func _thicken_portal_if_necessary_to_prevent_camera_near_cull():
	var cur_camera = get_viewport().get_camera_3d()
	if not cur_camera:
		return
	
	# is this correct for case when portal is rotated? i think so but not sure since we use self.global_position
	var forward : Vector3 = self.global_transform.basis.z
	var right : Vector3 = self.global_transform.basis.x
	var up : Vector3 = self.global_transform.basis.y
	var camera_offset_from_portal = cur_camera.global_position - self.global_position
	var dist_from_portal_plane_forward = camera_offset_from_portal.dot(forward)
	var dist_from_portal_plane_to_right = camera_offset_from_portal.dot(right)
	var dist_from_portal_plane_up = camera_offset_from_portal.dot(up)
	var portal_side = _nonzero_sign(dist_from_portal_plane_forward)
	
	var half_portal_width = $PortalVisual.size.x / 2.0
	var half_portal_height = $PortalVisual.size.y / 2.0
	# Only thicken portal if we are very close to it
	if (abs(dist_from_portal_plane_forward) > 1.0
		or abs(dist_from_portal_plane_to_right) > half_portal_width + 0.3
		or dist_from_portal_plane_up > half_portal_height + 0.3):
		$PortalVisual.size.z = 0.0
		$PortalVisual.position.z = 0.0
		return
		
	# Maybe could calculate the necessary thickness based on camera near cull plane
	# 0.3 isn't always enough had to up it to 0.5 to prevent occasional glitching
	var thickness = 0.3
	
	$PortalVisual.size.z = thickness
	
	# Check if the camera is facing the portal and is within a certain distance
	if portal_side == 1:
		$PortalVisual.position.z = -thickness/2.0
	else:
		$PortalVisual.position.z = thickness/2.0

func do_updates():
	$CollisionShape3D.disabled = not self.visible
	
	for body in _get_bodies_which_passed_through_this_frame():
		if body.is_multiplayer_authority():
			_move_to_other_portal(body)
	for tracked_body in _tracked_phys_bodies:
		if (not tracked_body.body.is_multiplayer_authority()
			and _try_detect_portal_pass_through_on_multiplayer_peer(tracked_body)):
			# Added to prevent visual glitching for multiplayer peers.
			# Try to detect when peer has swapped places with their mesh duplicate and then
			# move it to the appropriate position.
			_remove_tracked_phys_body(tracked_body.body)
			other_portal._add_tracked_phys_body(tracked_body.body)
			
	# Note: placing these after above so portal thickening/camera update happen same frame as move
	_clear_mesh_duplicate_cache()
	_update_camera_to_other_portal()
	_thicken_portal_if_necessary_to_prevent_camera_near_cull()
	_remove_hanging_body_check()
	_update_portal_area_size()

# For some reason need to call both of these to prevent flicker
func _process(_delta):
	if Engine.is_editor_hint():
		_update_portal_area_size()
		return
	do_updates()
	
func _physics_process(_delta):
	do_updates()

func _try_detect_portal_pass_through_on_multiplayer_peer(tracked_body):
	if not tracked_body.mesh_duplicator:
		return false
	const DISTANCE_THRESHOLD_FROM_DUPLICATE = 2.5
	var dist_from_dupe = (tracked_body.body.global_position - tracked_body.mesh_duplicator.dupe.global_position).length()
	#if dist_from_dupe < DISTANCE_THRESHOLD_FROM_DUPLICATE:
	#	print("DETECTED OTHER PEER TELEPORT, dist was "+str(dist_from_dupe))
	return dist_from_dupe < DISTANCE_THRESHOLD_FROM_DUPLICATE

func _remove_hanging_body_check():
	# Code to prevent edge case, mostly for multiplayer
	# It's possible you can skip the Area3D on the other side of portal if moving too fast/teleporting
	# Since we need to hand object off to other portal same frame we remove it from this on port,
	# do this check to prevent handing off an object that is outside of the area3d, leaving it lingering
	var i = len(_tracked_phys_bodies) - 1
	while i >= 0:
		var tracked_body = _tracked_phys_bodies[i].body
		var track_duration = Time.get_ticks_msec() - _tracked_phys_bodies[i].track_start_time
		if track_duration > 250.0 and not overlaps_body(tracked_body):
			_remove_tracked_phys_body(tracked_body)
			print("Removed tracked body for edge case")
		i -= 1
	
func _move_to_other_portal(body: PhysicsBody3D):
	print("moved to other portal")
	
	var transform_rel_to_this_portal = self.global_transform.affine_inverse() * body.global_transform
	var moved_to_other_portal = other_portal.global_transform * transform_rel_to_this_portal
	body.global_transform = moved_to_other_portal

	var r = other_portal.global_transform.basis.get_euler() - global_transform.basis.get_euler()
	body.velocity = body.velocity \
		.rotated(Vector3(1, 0, 0), r.x) \
		.rotated(Vector3(0, 1, 0), r.y) \
		.rotated(Vector3(0, 0, 1), r.z)
	
	_remove_tracked_phys_body(body)
	var newly_tracked_body = other_portal._add_tracked_phys_body(body)
	# We just moved the body. If it was a player, the camera may have been moved.
	# So we must do updates on the other portal. The camera and thickening will need to be updated.
	# No guarantee other portal has done updates for this frame already or not.
	if newly_tracked_body.camera:
		other_portal.do_updates()

func _get_bodies_which_passed_through_this_frame():
	var bodies_that_passed_through = []
	for tracked_body in _tracked_phys_bodies:
		var pos_node = tracked_body.camera if tracked_body.camera else tracked_body.body
		var dist_moved = pos_node.global_position - tracked_body.position_last_frame
		# Use dot product to check if side of portal we're on changed
		var forward : Vector3 = self.global_transform.basis.z
		var offset_from_portal = pos_node.global_position - self.global_position
		var prev_offset_from_portal = tracked_body.position_last_frame - self.global_position
		var portal_side = _nonzero_sign(offset_from_portal.dot(forward))
		var prev_portal_side = _nonzero_sign(prev_offset_from_portal.dot(forward))
		if portal_side != prev_portal_side and dist_moved.length() < MOVE_WAS_TELEPORT_THRESHOLD:
			bodies_that_passed_through.push_back(tracked_body.body)
		# Once we're done set position_last_frame again
		tracked_body.position_last_frame = pos_node.global_position
	return bodies_that_passed_through
	
# Mesh duplicate cache
# Helps performance and seems to make the transition from portal to portal slightly smoother
var mesh_duplicate_cache = [] #[body, mesh_duplicate, store_time]
const MESH_DUPLICATE_RETAIN_TIME_MS = 5000

func _clear_mesh_duplicate_cache():
	var mesh_duplicate_cache_to_remove = []
	for i in range(len(mesh_duplicate_cache)):
		var reverse_idx = mesh_duplicate_cache.size() - 1 - i
		var item = mesh_duplicate_cache[reverse_idx]
		if Time.get_ticks_msec() - item[2] > MESH_DUPLICATE_RETAIN_TIME_MS:
			mesh_duplicate_cache_to_remove.push_back(item)
			mesh_duplicate_cache.remove_at(reverse_idx)
	for item in mesh_duplicate_cache_to_remove:
		item[1].queue_free()

func _store_mesh_duplicate_in_cache(body, mesh_duplicate):
	mesh_duplicate_cache.push_back([body, mesh_duplicate, Time.get_ticks_msec()])

func _get_mesh_duplicate_from_cache(body, ask_other_portal = false):
	if ask_other_portal:
		var other_result = other_portal._get_mesh_duplicate_from_cache(body)
		if other_result != null:
			return other_result
	for i in range(len(mesh_duplicate_cache)):
		var item = mesh_duplicate_cache[i]
		if item[0] == body:
			mesh_duplicate_cache.remove_at(i)
			return item[1]
	return null
			
func _make_or_get_mesh_duplicate(body):
	var cache_result = _get_mesh_duplicate_from_cache(body, true)
	if cache_result:
		cache_result.in_portal = self
		cache_result.out_portal = other_portal
		return cache_result
	else:
		var new_mesh_duplicator = PortalMeshDuplicator.new()
		new_mesh_duplicator.body = body
		new_mesh_duplicator.in_portal = self
		new_mesh_duplicator.out_portal = other_portal
		return new_mesh_duplicator

func _get_tracked_phys_body_entry(body):
	for entry in _tracked_phys_bodies:
		if entry.body == body:
			return entry
	return null

func _add_tracked_phys_body(body):
	# First check if we already have the body or not in our list
	var tracked_body_entry = _get_tracked_phys_body_entry(body)
	if tracked_body_entry != null:
		return tracked_body_entry
	# If not, add it
	var newly_tracked_body = {
		"body": body,
		"position_last_frame": body.global_position,
		"camera": find_by_class(body, "Camera3D") if use_body_camera_as_teleport_origin else null,
		"mesh_duplicator": null,
		"track_start_time": Time.get_ticks_msec()
	}
	if make_mesh_duplicates:
		newly_tracked_body.mesh_duplicator = _make_or_get_mesh_duplicate(body)
		add_child(newly_tracked_body.mesh_duplicator)
		newly_tracked_body.mesh_duplicator.synchronize_all()
	if newly_tracked_body.camera:
		newly_tracked_body.position_last_frame = newly_tracked_body.camera.global_position
		newly_tracked_body.prev_camera_near = newly_tracked_body.camera.near
		if enable_camera_near_plane_fix:
			newly_tracked_body.camera.near = CAM_NEAR_NEEDED_TO_PREVENT_GLITCH
	_tracked_phys_bodies.push_back(newly_tracked_body)
	
	if body.has_method("_on_portal_tracking_enter"):
		body._on_portal_tracking_enter(self)
	
	return newly_tracked_body
	
func _remove_tracked_phys_body(body):
	for i in len(_tracked_phys_bodies):
		if _tracked_phys_bodies[i].body == body:
			print("removed body")
			
			if _tracked_phys_bodies[i].mesh_duplicator:
				remove_child(_tracked_phys_bodies[i].mesh_duplicator)
				_store_mesh_duplicate_in_cache(_tracked_phys_bodies[i].body, _tracked_phys_bodies[i].mesh_duplicator)
			if _tracked_phys_bodies[i].camera:
				_tracked_phys_bodies[i].camera.near = _tracked_phys_bodies[i].prev_camera_near
			_tracked_phys_bodies.remove_at(i)
			
			if body.has_method("_on_portal_tracking_leave"):
				body._on_portal_tracking_leave(self)
			return

func find_by_class(node: Node, name_of_class : String):
	if node.is_class(name_of_class) :
		return node
	for child in node.get_children():
		var found = find_by_class(child, name_of_class)
		if found:
			return found
	return null

# This shapecast is necessary because _on_body_entered and _on_body_exited may be fired late in some
# edge cases Which could cause the conundrum of _on_body_entered being called late, after body has
# left, or _on_body_exited being called late, like firing the same frame it was added. Causing 
# incorrectly adding or removing a body. Something like that is going on. This fixes the bug of
# teleporting up to the roof when you rotate the exit velocity by PI on the y axis and it 
# rubberbands very quickly between the 2 portals. May happen rarely even without the incorrect y
# rotation set
func _check_shapecast_collision(body):
	$ShapeCast3D.force_shapecast_update()
	for i in $ShapeCast3D.get_collision_count():
		if $ShapeCast3D.get_collider(i) == body:
			return true
	return false

func _on_body_entered(body):
	# Disable non-moving static bodes from teleporting (except AnimatableBody3Ds which are considered static).
	# CSGShape3Ds are also static if you enable their use_collision property so disable them.
	if (not body.is_class("StaticBody3D") or body.is_class("AnimatableBody3D")) and not body.is_class("CSGShape3D"):
		if _check_shapecast_collision(body):
			_add_tracked_phys_body(body)

func _on_body_exited(body):
	if not _check_shapecast_collision(body) or $CollisionShape3D.disabled:
		_remove_tracked_phys_body(body)
