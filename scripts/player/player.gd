class_name PlayerController
extends CharacterBody3D

const Kit = preload("res://scripts/common/kit.gd")
const Weapons = preload("res://scripts/combat/weapon_catalog.gd")
const Grenades = preload("res://scripts/combat/grenade_catalog.gd")
const Visuals = preload("res://scripts/visuals/combat_visuals.gd")
var gun_models: Dictionary = {}
var knife_audio: AudioStreamPlayer
var reload_audio: AudioStreamPlayer
var inventory: Dictionary = {}
var loadout: Array[String] = ["pistol", "rifle"]
var weapon_id: String = "pistol"
var reserve: int = 24
var switch_time: float = 0
var grenade_type: String = "basic"
var grenade_inventory: Dictionary = {"basic": 3}
var grenade_audio: AudioStreamPlayer
var grenades: int:
	get:
		return int(grenade_inventory.get(grenade_type, 0))
	set(value):
		grenade_inventory[grenade_type] = clampi(value, 0, int(Grenades.DATA[grenade_type].maximum))
var grenade_wait: float = 0
var knife: Node3D
var shotgun_barrel: Node3D
var scope: Node3D
var plasma_coil: Node3D
const MAX_HEALTH: int = 100
const REGEN_DELAY: float = 4.0
const REGEN_RATE: float = 8.0
var regen_wait: float = 0.0
var regen_fraction: float = 0.0
var game: Node3D
var camera: Camera3D
var weapon: Node3D
var health: int = 100
var ammo: int = 12
var max_health: int = 100
var ammo_capacity: int = 12
var weapon_damage: int = 25
var fire_interval: float = 0.21
var reload_duration: float = 1.25
var regen_rate: float = 8.0
var shield: float = 0
var shield_max: float = 0
var shield_wait: float = 0
var armor: float = 0
var speed_multiplier: float = 1.0
var cargo_factor: float = 1.0
var melee_enabled: bool = false
var melee_wait: float = 0
var melee_flash: float = 0

var cooldown: float = 0.0
var reload_time: float = 0.0
var recoil: float = 0.0
var _event_moving := false
var _event_sprinting := false
var flash: MeshInstance3D

func _ready() -> void:
	game = get_parent()
	for id in (["basic"] if game.tutorial_mode else Campaign.available_grenades()):
		grenade_inventory[id] = int(Grenades.DATA[id].initial)
	grenade_audio = AudioStreamPlayer.new()
	grenade_audio.name = "GrenadeAudio"
	grenade_audio.bus = &"Effects"
	grenade_audio.volume_db = -13
	grenade_audio.stream = preload("res://assets/audio/grenades/throw.wav")
	add_child(grenade_audio)
	max_health = 100 + 25 * Campaign.rank_of("health")
	health = max_health
	var rifle := Campaign.rank_of("rifle") > 0
	ammo_capacity = (24 if rifle else 12) + 4 * Campaign.rank_of("magazine")
	ammo = ammo_capacity
	weapon_damage = (20 if rifle else 25) + 4 * Campaign.rank_of("damage")
	fire_interval = 0.15 if rifle else 0.21
	reload_duration = 1.25 - 0.2 * Campaign.rank_of("reload")
	regen_rate = 8.0 + 3 * Campaign.rank_of("regen")
	shield_max = 25.0 * Campaign.rank_of("shield")
	shield = shield_max
	armor = 0.08 * Campaign.rank_of("armor")
	speed_multiplier = 1.0 + 0.08 * Campaign.rank_of("speed")
	melee_enabled = true
	$Camera/Weapon/RifleExtension.visible = rifle
	camera = $Camera
	weapon = $Camera/Weapon
	weapon.position.z = -0.2
	flash = $Camera/Weapon/Flash
	loadout.assign(["pistol", "rifle"] if game.tutorial_mode else Campaign.selected_loadout(game.level_number))
	for id in (loadout if game.tutorial_mode else Campaign.available_weapons(game.level_number)):
		var data: Dictionary = Weapons.DATA[id]
		inventory[id] = {"ammo": capacity_for(id), "reserve": mini(int(data.max_reserve), int(data.reserve) + (12 * Campaign.rank_of("rifle") if id == "rifle" else 0))}
	for child in weapon.get_children():
		if child != flash:child.hide()
	for id in Weapons.DATA:
		var model := Visuals.weapon(id)
		weapon.add_child(model)
		model.hide()
		gun_models[id] = model
	knife = Visuals.weapon("knife")
	weapon.add_child(knife)
	knife.hide()
	# A soft equipment fill keeps metal readable without lighting the map.
	for mesh in weapon.find_children("*", "MeshInstance3D", true, false):
		mesh.layers = 2
	var equipment_light := OmniLight3D.new()
	equipment_light.name = "EquipmentFill"
	equipment_light.position = Vector3(-.15, .12, -.12)
	equipment_light.light_color = Color("c4d2df")
	equipment_light.light_energy = .8
	equipment_light.omni_range = 2.0
	equipment_light.light_cull_mask = 2
	camera.add_child(equipment_light)
	shotgun_barrel = gun_models.shotgun
	scope = gun_models.precision
	plasma_coil = gun_models.plasma
	knife_audio = AudioStreamPlayer.new()
	knife_audio.name = "KnifeAudio"
	knife_audio.bus = &"Effects"
	knife_audio.max_polyphony = 2
	add_child(knife_audio)
	reload_audio = AudioStreamPlayer.new()
	reload_audio.name = "ReloadAudio"
	reload_audio.bus = &"Effects"
	reload_audio.volume_db = -12
	add_child(reload_audio)
	ammo = int(inventory.pistol.ammo)
	reserve = int(inventory.pistol.reserve)
	equip(loadout[0])
	camera.current = true
	camera.fov = float(Campaign.options.fov)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	switch_time = 0

func _unhandled_input(event: InputEvent) -> void:
	if game.finished or get_tree().paused:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * Campaign.sensitivity)
		camera.rotation.x = clampf(camera.rotation.x - event.relative.y * Campaign.sensitivity, -1.4, 1.4)
	if event.is_action_pressed("reload"):
		start_reload()
	if event.is_action_pressed("weapon_one"):
		equip(loadout[0])
	if event.is_action_pressed("weapon_two") and loadout.size() > 1:
		equip(loadout[1])
	if event is InputEventMouseButton and event.pressed and loadout.size() > 1 and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		equip(loadout[1] if weapon_id == loadout[0] else loadout[0])
	if event.is_action_pressed("grenade"):
		throw_grenade()
	if event.is_action_pressed("grenade_cycle"):
		cycle_grenade()
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		camera.fov = float(Campaign.options.fov) * (0.5 if event.pressed and weapon_id == "precision" else 1.0)

func _physics_process(delta: float) -> void:
	if game.finished:
		reload_audio.stop()
		# Freeze combat, while letting the last shot's feedback settle.
		cooldown = maxf(0, cooldown - delta)
		melee_flash = maxf(0, melee_flash - delta)
		recoil = move_toward(recoil, 0, delta * 0.8)
		weapon.position.z = -0.2 + recoil - melee_flash * 1.5
		flash.visible = cooldown > fire_interval - 0.06 and not Campaign.options.reduced_flashes
		return
	regenerate(delta)
	switch_time = maxf(0, switch_time - delta)
	grenade_wait = maxf(0, grenade_wait - delta)
	melee_wait = maxf(0, melee_wait - delta)
	melee_flash = maxf(0, melee_flash - delta)
	if Input.is_action_just_pressed("melee"):
		melee_attack()
	cooldown = maxf(0, cooldown - delta)
	if reload_time > 0:
		reload_time -= delta
		if reload_time <= 0:
			var transferred := mini(ammo_capacity - ammo, reserve)
			ammo += transferred
			reserve -= transferred
			_event("reload_completed",{"weapon":weapon_id,"transferred":transferred,"ammo":ammo,"reserve":reserve})
	var axis := Input.get_vector("left", "right", "forward", "back")
	var direction := transform.basis * Vector3(axis.x, 0, axis.y)
	var speed := 7.0 if Input.is_action_pressed("sprint") else 4.5
	velocity.x = direction.x * speed * speed_multiplier * cargo_factor
	velocity.z = direction.z * speed * speed_multiplier * cargo_factor
	if not is_on_floor():
		velocity.y -= 22 * delta
	elif Input.is_action_just_pressed("jump"):
		velocity.y = 7
		_event("jumped")
	var before_move := position
	move_and_slide()
	observe_movement(Vector2(position.x-before_move.x,position.z-before_move.z).length() > 0.001,Input.is_action_pressed("sprint"))
	var trigger := Input.is_action_pressed("shoot") if Weapons.DATA[weapon_id].automatic else Input.is_action_just_pressed("shoot")
	if trigger and cooldown <= 0 and reload_time <= 0 and switch_time <= 0 and melee_flash <= 0:
		shoot()
	recoil = move_toward(recoil, 0, delta * 0.8)
	weapon.position.z = -0.2 + recoil - melee_flash * 1.5
	weapon.position.y = -0.16 if reload_time > 0 else (0.0 if Campaign.options.reduced_motion else sin(Time.get_ticks_msec() * 0.012) * axis.length() * 0.012)
	flash.visible = cooldown > fire_interval - 0.06 and not Campaign.options.reduced_flashes
	knife.visible = melee_flash > 0
	for id in gun_models:
		gun_models[id].visible = id == weapon_id and melee_flash <= 0
	weapon.rotation.z = -melee_flash * 3.0
	game.update_hud()

func shoot() -> void:
	if game.finished or get_tree().paused or cooldown > 0 or reload_time > 0 or switch_time > 0 or melee_flash > 0:
		return
	if ammo <= 0:
		start_reload()
		return
	ammo -= 1
	_event("shot_fired",{"weapon":weapon_id,"ammo":ammo,"reserve":reserve,"pellets":int(Weapons.DATA[weapon_id].pellets)})
	$Shot.pitch_scale = 1.0
	$Shot.play()
	cooldown = fire_interval
	recoil = 0.085
	flash.visible = not Campaign.options.reduced_flashes
	var start := camera.global_position
	var data: Dictionary = Weapons.DATA[weapon_id]
	for pellet in range(int(data.pellets)):
		var spread: float = data.spread
		var direction := (-camera.global_basis.z + camera.global_basis.x * randf_range(-spread, spread) + camera.global_basis.y * randf_range(-spread, spread)).normalized()
		var end: Vector3 = start + direction * float(data.range)
		var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(start, end, 1, [get_rid()]))
		if not hit.is_empty():
			end = hit.position
			if hit.collider.has_method("take_damage"):
				var damage := weapon_damage
				if weapon_id == "shotgun":
					damage = roundi(damage * clampf(1.0 - start.distance_to(end) / 28.0, 0.2, 1.0))
				_damage_target(hit.collider,damage,"shot",weapon_id)
				game.hit_time = 0.12
			if weapon_id == "plasma":
				plasma_blast(end, hit.collider)
		game.beam(flash.global_position, end, Color("e482ff") if weapon_id == "plasma" else Color("64efff"))
	if not Campaign.options.reduced_motion:
		camera.rotation.x = clampf(camera.rotation.x + (0.035 if weapon_id == "shotgun" else 0.009), -1.4, 1.4)

func regenerate(delta: float) -> void:
	if game.finished or get_tree().paused or health <= 0:
		return
	var shield_delta := maxf(0, delta - shield_wait)
	shield_wait = maxf(0, shield_wait - delta)
	shield = minf(shield_max, shield + shield_delta * 10.0)
	var healing_delta := maxf(0, delta - regen_wait)
	regen_wait = maxf(0, regen_wait - delta)
	if health >= max_health:
		regen_fraction = 0
		return
	regen_fraction += healing_delta * regen_rate
	var points := floori(regen_fraction)
	health = mini(max_health, health + points)
	regen_fraction -= points

func take_damage(amount: int) -> void:
	if game.finished or amount <= 0:
		return
	regen_wait = REGEN_DELAY
	regen_fraction = 0
	shield_wait = 3.5
	var incoming := float(amount) * (1.0 - armor)
	var absorbed := minf(shield, incoming)
	shield -= absorbed
	var previous_health := health
	health = maxi(0, health - ceili(incoming - absorbed))
	_event("player_damaged",{"incoming":amount,"health_damage":previous_health-health,"shield_damage":absorbed,"health":health,"shield":shield})
	game.damage_time = 0.3
	game.update_hud()
	if health == 0:
		game.end_game(false)

func melee_attack() -> void:
	if not melee_enabled or melee_wait > 0 or game.finished or get_tree().paused:
		return
	_event("melee_used",{"weapon":"knife"})
	cancel_reload_event("melee")
	melee_wait = 0.65 if Campaign.rank_of("melee") > 0 else 0.9
	reload_audio.stop()
	reload_time = 0
	melee_flash = 0.2
	knife_audio.stream = load("res://assets/audio/weapons/knife_swing.wav")
	knife_audio.volume_db = -18
	knife_audio.play()
	var start := camera.global_position
	var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(start, start - camera.global_basis.z * 2.2, 1, [get_rid()]))
	if not hit.is_empty() and hit.collider.has_method("take_damage"):
		_damage_target(hit.collider,100 if Campaign.rank_of("melee") > 0 else 65,"melee","knife")
		game.hit_time = 0.12
		knife_audio.stream = load("res://assets/audio/weapons/knife_hit.wav")
		knife_audio.volume_db = -14
		knife_audio.play()

func equip(id: String) -> void:
	if not Weapons.DATA.has(id) or not loadout.has(id) or not inventory.has(id):
		return
	cancel_reload_event("weapon_switch")
	if weapon_id != id:
		_event("weapon_switched",{"from":weapon_id,"weapon":id})
	reload_audio.stop()
	if inventory.has(weapon_id):
		inventory[weapon_id] = {"ammo": ammo, "reserve": reserve}
	weapon_id = id
	var data: Dictionary = Weapons.DATA[id]
	ammo_capacity = capacity_for(id)
	weapon_damage = int(data.damage) + (1 if id == "shotgun" else (8 if id == "precision" else 4)) * Campaign.rank_of("damage")
	fire_interval = float(data.interval)
	reload_duration = maxf(0.5, float(data.reload) - 0.2 * Campaign.rank_of("reload"))
	ammo = int(inventory[id].ammo)
	reserve = int(inventory[id].reserve)
	reload_time = 0
	switch_time = 0.3
	for model_id in gun_models:
		gun_models[model_id].visible = model_id == id
	$Shot.stream = load("res://assets/audio/weapons/%s.wav" % id)
	flash.position.z = {"pistol":-1.1,"rifle":-1.34,"shotgun":-1.37,"precision":-1.55,"plasma":-1.33}[id]
	flash.material_override = Kit.material(Visuals.ACCENTS[id].lightened(.2),true)
	camera.fov = float(Campaign.options.fov)

func capacity_for(id: String) -> int:
	return int(Weapons.DATA[id].capacity) + (1 if id in ["shotgun", "precision"] else (2 if id == "plasma" else 4)) * Campaign.rank_of("magazine")

func set_loadout(ids: Array) -> bool:
	if ids.size() != 2 or ids[0] == ids[1]:
		return false
	var available := Campaign.available_weapons(game.level_number)
	for id in game.run_weapons:
		if not available.has(id):
			available.append(id)
	for id in ids:
		if not available.has(str(id)):
			return false
	loadout.assign(ids)
	equip(loadout[0])
	_event("loadout_selected",{"weapons":loadout.duplicate()})
	return true

func discover_weapon(id: String) -> void:
	if not Weapons.DATA.has(id):
		return
	var data: Dictionary = Weapons.DATA[id]
	if not inventory.has(id):
		inventory[id] = {"ammo": capacity_for(id), "reserve": int(data.reserve)}
	if not game.run_weapons.has(id):
		game.run_weapons.append(id)
	if loadout.size() < 2:
		loadout.append(id)
	else:
		loadout[1] = id
	equip(id)

func start_reload() -> void:
	if not game.finished and not get_tree().paused and melee_flash <= 0 and ammo < ammo_capacity and reserve > 0 and reload_time <= 0 and switch_time <= 0:
		reload_time = reload_duration
		_event("reload_started",{"weapon":weapon_id,"ammo":ammo,"reserve":reserve,"duration_seconds":reload_duration})
		reload_audio.stream = load("res://assets/audio/weapons/%s_reload.wav" % weapon_id)
		# Keep the latch at the end synchronized with reload-speed upgrades.
		reload_audio.pitch_scale = reload_audio.stream.get_length() / reload_duration
		reload_audio.play()

func resupply() -> String:
	var resources_before := {"health":health,"grenades":grenades,"inventory":inventory.duplicate(true)}
	resources_before.inventory[weapon_id] = {"ammo":ammo,"reserve":reserve}
	inventory[weapon_id] = {"ammo": ammo, "reserve": reserve}
	var receipt: Array[String] = []
	for id in loadout:
		var data: Dictionary = Weapons.DATA[id]
		var before: int = inventory[id].reserve
		inventory[id].reserve = mini(before + int(data.pickup), int(data.max_reserve))
		receipt.append("%s +%d" % [data.title, int(inventory[id].reserve) - before])
	reserve = int(inventory[weapon_id].reserve)
	grenades += 1
	health = mini(max_health, health + 30)
	_event("supply_received",{"health_gained":health-int(resources_before.health),"grenade":grenade_type,"grenades_gained":grenades-int(resources_before.grenades),"inventory_before":resources_before.inventory,"inventory_after":inventory.duplicate(true)})
	return " · ".join(receipt)

func plasma_blast(point: Vector3, primary: Object) -> void:
	var origin := point + camera.global_basis.z * 0.1
	for target in game.get_children():
		if not target is EnemyController or target == primary or target.health <= 0:
			continue
		var end: Vector3 = target.position + Vector3.UP
		var distance := origin.distance_to(end)
		if distance > 3:
			continue
		var excluded: Array[RID] = [get_rid()]
		if primary is EnemyController:
			excluded.append(primary.get_rid())
		var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(origin, end, 1, excluded))
		if hit.is_empty() or hit.collider == target:
			_damage_target(target,roundi(weapon_damage * 0.65 * (1.0 - distance / 4.0)),"plasma_blast",weapon_id)

func throw_grenade() -> void:
	if grenades <= 0 or grenade_wait > 0 or game.finished or get_tree().paused:
		return
	grenades -= 1
	_event("grenade_used",{"grenade":grenade_type,"remaining":grenades})
	grenade_wait = 1.0
	grenade_audio.play()
	var projectile := RigidBody3D.new()
	projectile.set_script(preload("res://scripts/combat/grenade.gd"))
	projectile.grenade_type = grenade_type
	projectile.position = camera.global_position - camera.global_basis.z * 0.8
	projectile.linear_velocity = -camera.global_basis.z * 15.0 + Vector3.UP * 4.0
	game.add_child(projectile)
	game.update_hud()

func available_grenades() -> Array[String]:
	var result: Array[String] = []
	for id in Grenades.DATA:
		if grenade_inventory.has(id):
			result.append(id)
	return result

func cycle_grenade() -> void:
	if game.finished or get_tree().paused:
		return
	var previous_type := grenade_type
	var types := available_grenades()
	grenade_type = types[(types.find(grenade_type) + 1) % types.size()]
	if previous_type != grenade_type:
		_event("grenade_selected",{"grenade":grenade_type})
	game.update_hud()

func grenade_label() -> String:
	return "%s · %d" % [Grenades.DATA[grenade_type].title, grenades]

func discover_grenade(id: String) -> void:
	if not Grenades.DATA.has(id):
		return
	if not grenade_inventory.has(id):
		grenade_inventory[id] = int(Grenades.DATA[id].initial)
	grenade_type = id

func capture_state() -> Dictionary:
	inventory[weapon_id] = {"ammo": ammo, "reserve": reserve}
	return {"inventory": inventory.duplicate(true), "loadout": loadout.duplicate(), "weapon": weapon_id, "health": health, "shield": shield, "grenades": grenades, "grenade_type": grenade_type, "grenade_inventory": grenade_inventory.duplicate(), "position": position, "yaw": rotation.y, "pitch": camera.rotation.x}

func restore_state(state: Dictionary) -> void:
	inventory = state.inventory.duplicate(true)
	loadout.assign(state.loadout)
	weapon_id = state.weapon
	# equip normally captures the outgoing gun: restore its current counters first.
	ammo = int(inventory[weapon_id].ammo)
	reserve = int(inventory[weapon_id].reserve)
	equip(weapon_id)
	health = int(state.health)
	shield = float(state.shield)
	# Old checkpoints carry only the original basic-grenade counter.
	grenade_inventory.clear()
	var saved_grenades: Dictionary = state.get("grenade_inventory", {"basic": int(state.get("grenades", 3))})
	for id in Grenades.DATA:
		if saved_grenades.has(id):
			grenade_inventory[id] = clampi(int(saved_grenades[id]), 0, int(Grenades.DATA[id].maximum))
	if not grenade_inventory.has("basic"):
		grenade_inventory.basic = 0
	grenade_type = str(state.get("grenade_type", "basic"))
	if not grenade_inventory.has(grenade_type):
		grenade_type = "basic"
	position = state.position
	rotation.y = float(state.yaw)
	camera.rotation.x = float(state.pitch)
	velocity = Vector3.ZERO

func _event(type: String, payload: Dictionary = {}) -> void:
	if is_instance_valid(game) and game.has_method("log_event"):
		game.log_event(type,payload)

func observe_movement(moving: bool, sprinting: bool) -> void:
	sprinting = sprinting and moving
	if moving and not _event_moving:
		_event("movement_started")
	if sprinting != _event_sprinting:
		_event("sprint_started" if sprinting else "sprint_ended")
	if not moving and _event_moving:
		_event("movement_stopped")
	_event_moving = moving
	_event_sprinting = sprinting

func stop_movement_events() -> void:
	observe_movement(false,false)

func cancel_reload_event(reason: String) -> void:
	# Observe cancellation; existing gameplay owns the reload timer.
	if reload_time > 0:
		_event("reload_cancelled",{"weapon":weapon_id,"reason":reason})

func _damage_target(target: Object, amount: int, source: String, weapon_name: String) -> void:
	if target is EnemyController:
		target.take_damage(amount,{"source":source,"weapon":weapon_name})
	else:
		target.take_damage(amount)
