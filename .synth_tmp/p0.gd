extends SceneTree

var p: AudioStreamPlayer

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("HEADLESS=", DisplayServer.get_name(), " inside=", root.is_inside_tree())
	p = AudioStreamPlayer.new()
	var g := AudioStreamGenerator.new()
	g.mix_rate = 44100.0
	g.buffer_length = 0.5
	p.stream = g
	p.bus = "Master"
	root.add_child(p)
	print("inside2=", p.is_inside_tree())
	p.play()
	print("PLAYING=", p.playing)
	var pb := p.get_stream_playback()
	print("PB=", pb)
	if pb != null:
		var gp := pb as AudioStreamGeneratorPlayback
		print("GP_NULL=", gp == null, " avail=", gp.get_frames_available() if gp != null else -2)
		if gp != null:
			var frames := PackedVector2Array()
			for i in 1000:
				frames.append(Vector2(sin(i * 0.05) * 0.3, sin(i * 0.05) * 0.3))
			var ok := gp.push_buffer(frames)
			print("PUSH=", ok, " avail2=", gp.get_frames_available())
	await create_timer(0.15).timeout
	print("AFTER playing=", p.playing)
	quit(0)
