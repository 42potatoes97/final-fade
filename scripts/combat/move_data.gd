extends Resource

# Data-driven attack definition — each move is an instance of this

@export var move_name: String = ""
@export var input_command: String = ""  # "1", "2", "3", "4", "d+3", "d+1"

@export_group("Frame Data")
@export var startup_frames: int = 10
@export var active_frames: int = 3
@export var recovery_frames: int = 12

@export_group("Damage")
@export var damage: int = 10
@export var hit_level: String = "mid"  # "high", "mid", "low"

@export_group("On Hit/Block")
@export var hitstun_frames: int = 14
@export var blockstun_frames: int = 8
@export var knockback: float = 1.0
@export var pushback_block: float = 1.0  # Block pushback (decoupled from hit knockback)

@export_group("Hit Feel")
@export var hitstop_frames: int = 8  # Freeze frames on hit (both fighters)

@export_group("Properties")
@export var is_homing: bool = false
@export var high_crush: bool = false
@export var wall_splat: bool = false
@export var causes_knockdown: bool = false
@export var soft_knockdown: bool = false  # Fast recovery KD — opponent gets up quickly, no oki
@export var hits_grounded: bool = false  # Can hit opponents on the ground (e.g. d+3,3 rising)

@export_group("String")
@export var string_followup_command: String = ""  # e.g. "1" for d+3,1
@export var string_window_frames: int = 12

@export_group("Movement")
@export var forward_lunge: float = 0.0  # Forward movement during startup+active (units/frame)

@export_group("Animation")
@export var pose_name: String = "jab"  # Which pose function to call


func get_total_frames() -> int:
	return startup_frames + active_frames + recovery_frames
