class_name FighterState
extends Node

# Base class for all fighter states
# Override these methods in subclasses

var fighter: CharacterBody3D
var state_machine: Node


func get_model():
	if fighter and fighter.model:
		return fighter.model
	return null


func enter(_prev_state: String) -> void:
	pass


func exit() -> void:
	pass


func handle_input(_input_bits: int) -> String:
	# Return the name of the next state, or "" to stay in current state
	return ""


func tick(_delta: float) -> String:
	# Called each physics tick. Return next state name or "" to stay.
	return ""


func try_attack(input_bits: int) -> String:
	var move = fighter.move_registry.get_move_for_input(input_bits, fighter.input_buffer)
	if move:
		var atk = state_machine.states.get("Attack")
		if atk:
			atk.start_move(move)
			return "Attack"
	return ""


var IM:
	get: return InputManager


var buf:
	get: return fighter.input_buffer if fighter else null


func get_state_name() -> String:
	return name


# --- Rollback serialization ---
func save_state() -> Dictionary:
	return {}

func load_state(_s: Dictionary) -> void:
	pass
