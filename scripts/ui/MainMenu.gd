extends Control

@onready var level_popup = $LevelSelectPopup
@onready var level_list = $LevelSelectPopup/LevelList

func _ready():
	# Populate the level list — you can update this list anytime
	# Add new levels here later
	level_list.clear()
	level_list.add_item("Tutorial of Lax rush")
	
	
	# Optional: double-click to play
	level_list.item_activated.connect(_on_level_activated)

func _on_PlayButton_pressed():
	level_popup.show()

func _on_QuitButton_pressed():
	get_tree().quit()

func _on_PlayLevelButton_pressed():
	_load_selected_level()

func _on_CancelButton_pressed():
	level_popup.hide()

func _on_level_activated(index: int):
	_load_selected_level()

func _load_selected_level():
	var selected = level_list.get_selected_items()
	if selected.size() == 0:
		return
	var level_name = level_list.get_item_text(selected[0])
	match level_name:
		"Tutorial of Lax rush":
			get_tree().change_scene_to_file("res://scenes/levels/Tutorial of Lax rush.tscn")
	level_popup.hide()
