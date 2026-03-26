class_name FighterStateMachine
extends Node

# Hierarchical state machine for fighter behavior
# States are child nodes with scripts extending FighterState

var current_state: FighterState
var states: Dictionary = {}
var fighter: CharacterBody3D


func current_state_name() -> String:
	if current_state:
		return current_state.name
	return ""


func initialize(fighter_node: CharacterBody3D) -> void:
	fighter = fighter_node
	for child in get_children():
		if child is FighterState:
			states[child.name] = child
			child.fighter = fighter
			child.state_machine = self

	# Start in Idle
	if states.has("Idle"):
		current_state = states["Idle"]
		current_state.enter("")


func process_tick(input_bits: int, delta: float) -> void:
	if current_state == null:
		return

	# Let current state handle input — may request transition
	var next_state_name = current_state.handle_input(input_bits)
	if next_state_name != "":
		_transition_to(next_state_name)
		return

	# Let current state run its tick logic — may also request transition
	next_state_name = current_state.tick(delta)
	if next_state_name != "":
		_transition_to(next_state_name)


func _transition_to(state_name: String) -> void:
	if not states.has(state_name):
		push_warning("FighterStateMachine: state '%s' not found" % state_name)
		return

	var prev_name = current_state.get_state_name() if current_state else ""
	current_state.exit()
	current_state = states[state_name]
	current_state.enter(prev_name)


func force_transition(state_name: String) -> void:
	_transition_to(state_name)


func get_current_state_name() -> String:
	return current_state.get_state_name() if current_state else ""


func enter_hitstun(frames: int) -> void:
	if states.has("Hitstun"):
		var hs = states["Hitstun"]
		hs.stun_frames = frames
		_transition_to("Hitstun")


func enter_blockstun(frames: int) -> void:
	if states.has("Blockstun"):
		var bs = states["Blockstun"]
		bs.stun_frames = frames
		_transition_to("Blockstun")


func enter_knockdown(soft: bool = false) -> void:
	if states.has("Knockdown"):
		var kd = states["Knockdown"]
		kd.is_soft = soft
		_transition_to("Knockdown")


# --- Rollback serialization ---
func save_state() -> Dictionary:
	return {
		"state_name": current_state.name if current_state else "Idle",
		"state_data": current_state.save_state() if current_state else {},
	}

func load_state(s: Dictionary) -> void:
	var target_name = s.get("state_name", "Idle")
	var target_data = s.get("state_data", {})
	# Set state pointer directly without calling enter/exit (avoids side effects)
	if states.has(target_name):
		current_state = states[target_name]
		current_state.load_state(target_data)
