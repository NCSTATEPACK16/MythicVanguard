extends CPUParticles2D

func _ready():
	emitting = true
	# Give it a little buffer time to finish the particles before deleting
	await get_tree().create_timer(lifetime + 0.1).timeout
	queue_free()
