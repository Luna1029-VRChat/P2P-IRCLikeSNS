@tool
extends EditorPlugin

const AutoloadName := "NostrGD"
const ClientScriptPath := "res://addons/nostr_godot/nostr_gd_client.gd"

func _enter_tree() -> void:
	add_autoload_singleton(AutoloadName, ClientScriptPath)
	print("NostrGD: Autoload '", AutoloadName, "' has been registered.")

func _exit_tree() -> void:
	remove_autoload_singleton(AutoloadName)
	print("NostrGD: Autoload '", AutoloadName, "' has been removed.")
