-- le_strum.lua
-- Le Grand Strum-inspired strummed chord controller for norns + grid (v6)
-- Features: scale mode, organ buttons, guitar bass, chord hold,
--           retrigger on chord change, clock-synced arpeggiator

-- midi and grid are norns globals, no require needed

------------------------------------------------------------
-- helpers
------------------------------------------------------------
local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

local function pc(n) return (n % 12 + 12) % 12 end

local function contains(tbl, v)
  for i=1,#tbl do if tbl[i] == v then return true end end
  return false
end

local function uniq_sorted(t)
  table.sort(t)
  local out, last = {}, nil
  for _,v in ipairs(t) do
    if last == nil or v ~= last then
      out[#out+1] = v
      last = v
    end
  end
  return out
end

local function sign(x) if x < 0 then return -1 elseif x > 0 then return 1 else return 0 end end

local function note_name(pc_)
  local names = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
  return names[pc_+1]
end

local function clamp_vel(v) return clamp(math.floor(v + 0.5), 1, 127) end

------------------------------------------------------------
-- MIDI outputs (dual)
------------------------------------------------------------
local out_a_port = 1
local out_b_port = 2
local out_b_enabled = false

local mA = nil
local mB = nil

local function reconnect_midi()
  mA = midi.connect(out_a_port)
  mB = midi.connect(out_b_port)
end

local function midi_note_on(note, vel, ch)
  mA:note_on(note, vel, ch)
  if out_b_enabled then mB:note_on(note, vel, ch) end
end

local function midi_note_off(note, ch)
  mA:note_off(note, 0, ch)
  if out_b_enabled then mB:note_off(note, 0, ch) end
end

local function midi_cc(cc, val, ch)
  mA:cc(cc, val, ch)
  if out_b_enabled then mB:cc(cc, val, ch) end
end

------------------------------------------------------------
-- state
------------------------------------------------------------
local g = nil
local grid_dirty = true
local shift = false

-- chord selection
local root_pc = 0
local quality = "maj"
local add_mode = "none"   -- none/add6/add9/add11
local voicing = "close"   -- close/guitar/spread/power

-- performance
local octave = 4
local transpose = 0
local velocity = 100
local midi_ch = 1

-- direction + velocity shaping
local STRINGS = 16
local last_strum_idx = nil
local last_strum_time = -1
local last_dir = 0
local dir_window = 0.20

local vel_curve = "flat" -- flat/ramp_up/ramp_down/bell
local dir_accent = 12    -- accent magnitude

-- ratcheting
local ratchet_count = 1
local ratchet_div = 1/16

-- pluck / decay (auto note-off)
local pluck_mode = "latch_break"
local pluck_time = 0.12
local pluck_times = {0.03,0.06,0.09,0.12,0.18,0.24,0.35,0.50}

-- drone
local drone_enabled = false
local drone_common_only = true
local drone_latched_notes = {}
local drone_ch = 2
local drone_vel = 80

-- === NEW: scale mode ===
-- "chord" = map strings to chord tones (original behavior)
-- "chromatic" / "diatonic" / "pentatonic" = map to scale
local string_mode = "chord"
local scale_intervals = {
  chromatic   = {0,1,2,3,4,5,6,7,8,9,10,11},
  diatonic    = {0,2,4,5,7,9,11},
  pentatonic  = {0,2,4,7,9},
}

-- === NEW: organ buttons ===
local organ_enabled = false
local organ_ch = 2
local organ_active_notes = {}

-- === NEW: guitar bass note ===
local guitar_bass = false

-- === NEW: chord hold ===
-- true = chord persists after button release (default, original behavior)
-- false = releasing chord button damps all strings + organ
local chord_hold = true
local chord_held_count = 0

-- === NEW: arpeggiator (circular strum simulation) ===
local arp_enabled = false
local arp_div_idx = 2
local arp_divs = {1/4, 1/8, 1/16, 1/32}
local arp_div_labels = {"1/4", "1/8", "1/16", "1/32"}
local arp_gen = 0
local arp_step = 1
local arp_current_note = nil

-- strings runtime
local held_string, latched_string, active_note_for_string = {}, {}, {}
for i=1,STRINGS do
  held_string[i] = false
  latched_string[i] = false
  active_note_for_string[i] = nil
end

------------------------------------------------------------
-- chord pages
------------------------------------------------------------
local chord_page = 1
local pages = {
  [1] = { "maj",  "min",  "7"    },
  [2] = { "maj7", "min7", "m7b5" },
  [3] = { "sus2", "sus4", "dim7" },
  [4] = { "6",    "m6",   "9"    },
}

------------------------------------------------------------
-- behavior flags
------------------------------------------------------------
local mode = "momentary"

local behavior = {
  play_on_make = true,
  play_on_break = false,
  stop_on_make = false,
  stop_on_break = true,

  sustain_common = true,
  follow_held = true,
  retrigger_on_chord_change = false,
  kill_all_on_chord_change = false,

  latch_mode = false,
}

local function apply_mode()
  if mode == "momentary" then
    behavior.latch_mode = false
    behavior.play_on_make = true
    behavior.play_on_break = false
    behavior.stop_on_make = false
    behavior.stop_on_break = true
  elseif mode == "break" then
    behavior.latch_mode = false
    behavior.play_on_make = false
    behavior.play_on_break = true
    behavior.stop_on_make = true
    behavior.stop_on_break = false
  elseif mode == "latch" then
    behavior.latch_mode = true
    behavior.play_on_make = true
    behavior.play_on_break = false
    behavior.stop_on_make = false
    behavior.stop_on_break = false
  elseif mode == "free" then
    -- user toggles raw flags
  end
end

------------------------------------------------------------
-- chord generation
------------------------------------------------------------
local function chord_intervals(q)
  if q == "maj"   then return {0,4,7} end
  if q == "min"   then return {0,3,7} end
  if q == "dim"   then return {0,3,6} end
  if q == "aug"   then return {0,4,8} end

  if q == "7"     then return {0,4,7,10} end
  if q == "maj7"  then return {0,4,7,11} end
  if q == "min7"  then return {0,3,7,10} end
  if q == "m7b5"  then return {0,3,6,10} end
  if q == "dim7"  then return {0,3,6,9} end

  if q == "sus2"  then return {0,2,7} end
  if q == "sus4"  then return {0,5,7} end

  if q == "6"     then return {0,4,7,9} end
  if q == "m6"    then return {0,3,7,9} end

  if q == "9"     then return {0,4,7,10,14} end

  return {0,4,7}
end

local function apply_add(intervals)
  if voicing == "power" then return intervals end
  if add_mode == "none" then return intervals end
  local out = {}
  for i=1,#intervals do out[#out+1] = intervals[i] end
  if add_mode == "add6" then out[#out+1] = 9 end
  if add_mode == "add9" then out[#out+1] = 14 end
  if add_mode == "add11" then out[#out+1] = 17 end
  return uniq_sorted(out)
end

local function build_chord_tones(root_note)
  local ints
  if voicing == "power" then
    ints = {0,7,12}
  else
    ints = apply_add(chord_intervals(quality))
  end
  local tones = {}
  for i=1,#ints do tones[#tones+1] = root_note + ints[i] end
  return tones
end

local function current_chord_pcs()
  local root_note = (octave * 12) + root_pc + transpose
  local tones = build_chord_tones(root_note)
  local pcs = {}
  for i=1,#tones do pcs[#pcs+1] = pc(tones[i]) end
  return uniq_sorted(pcs)
end

------------------------------------------------------------
-- voicings
------------------------------------------------------------
local function build_string_notes_close_spread(spread)
  local root_note = (octave * 12) + root_pc + transpose
  local chord = build_chord_tones(root_note)
  local out = {}
  for s=1,STRINGS do
    local base = chord[((s-1) % #chord) + 1]
    local oct = math.floor((s-1) / #chord)
    local extra = 0
    if spread then extra = (oct % 2 == 1) and 12 or 0 end
    out[s] = base + (12 * oct) + extra
  end
  return out
end

local function build_string_notes_guitar()
  local chord_pcs = current_chord_pcs()
  local base_anchor = (octave-2) * 12
  local open = {40,45,50,55,59,64} -- E2 A2 D3 G3 B3 E4
  local targets = {}
  for i=1,6 do targets[i] = open[i] + (base_anchor - 24) end

  local six = {}
  for i=1,6 do
    local t = targets[i]
    local found = nil
    for k=0,24 do
      local cand = t + k
      if contains(chord_pcs, pc(cand)) then found = cand; break end
    end
    six[i] = found or t
  end

  local out = {}
  local offset = 0

  -- NEW: guitar bass — string 1 is root below the voicing
  if guitar_bass then
    local root_note = (octave * 12) + root_pc + transpose
    out[1] = root_note - 12
    offset = 1
  end

  for s=(1+offset),STRINGS do
    local idx = (((s-1-offset) % 6) + 1)
    local oct = math.floor((s-1-offset) / 6)
    out[s] = six[idx] + (12 * oct)
  end
  return out
end

-- NEW: scale mode voicing
local function build_string_notes_scale(intervals)
  local root_note = (octave * 12) + root_pc + transpose
  local num = #intervals
  local out = {}
  for s=1,STRINGS do
    local idx = ((s-1) % num)
    local oct = math.floor((s-1) / num)
    out[s] = root_note + intervals[idx + 1] + (12 * oct)
  end
  return out
end

local function build_string_notes()
  -- scale modes override voicing
  if string_mode ~= "chord" and scale_intervals[string_mode] then
    return build_string_notes_scale(scale_intervals[string_mode])
  end

  if voicing == "close" then
    return build_string_notes_close_spread(false)
  elseif voicing == "spread" then
    return build_string_notes_close_spread(true)
  elseif voicing == "guitar" then
    return build_string_notes_guitar()
  elseif voicing == "power" then
    return build_string_notes_close_spread(false)
  end
  return build_string_notes_close_spread(false)
end

------------------------------------------------------------
-- direction & velocity shaping
------------------------------------------------------------
local function infer_direction(i)
  local now = util.time()
  local d = 0
  if last_strum_idx ~= nil and (now - last_strum_time) <= dir_window then
    d = sign(i - last_strum_idx)
  end
  last_strum_idx = i
  last_strum_time = now
  if d ~= 0 then last_dir = d end
  return (d ~= 0) and d or last_dir
end

local function vel_for_string(i, inferred_dir)
  local base = velocity
  local t = (i-1) / (STRINGS-1)

  local curve = 0
  if vel_curve == "flat" then
    curve = 0
  elseif vel_curve == "ramp_up" then
    curve = math.floor(20 * t)
  elseif vel_curve == "ramp_down" then
    curve = math.floor(20 * (1 - t))
  elseif vel_curve == "bell" then
    local x = (t - 0.5) / 0.5
    local bell = 1 - (x*x)
    curve = math.floor(22 * bell)
  end

  local accent = 0
  if inferred_dir ~= 0 then
    if inferred_dir == 1 then accent = dir_accent
    else accent = -math.floor(dir_accent / 2) end
  end

  return clamp_vel(base + curve + accent)
end

------------------------------------------------------------
-- note lifecycle + ratchet + pluck
------------------------------------------------------------
local function turn_off_string(i)
  local n = active_note_for_string[i]
  if n ~= nil then
    midi_note_off(n, midi_ch)
    active_note_for_string[i] = nil
  end
end

local function turn_on_string(i, note, vel)
  if active_note_for_string[i] ~= nil and active_note_for_string[i] ~= note then
    midi_note_off(active_note_for_string[i], midi_ch)
  end
  active_note_for_string[i] = note
  midi_note_on(note, vel, midi_ch)
end

local function all_notes_off_strings()
  for i=1,STRINGS do turn_off_string(i) end
end

local function ratchet_fire(note, vel)
  local count = clamp(ratchet_count, 1, 8)
  if count <= 1 then return end
  local div = ratchet_div
  clock.run(function()
    for _=2,count do
      clock.sync(div)
      midi_note_off(note, midi_ch)
      midi_note_on(note, vel, midi_ch)
    end
  end)
end

local function should_pluck()
  if pluck_mode == "off" then return false end
  if pluck_mode == "always" then return true end
  if behavior.latch_mode then return true end
  if mode == "break" then return true end
  if behavior.play_on_break then return true end
  return false
end

local function schedule_pluck_off(i, note)
  if not should_pluck() then return end
  local t = pluck_time
  clock.run(function()
    clock.sleep(t)
    if active_note_for_string[i] == note then
      midi_note_off(note, midi_ch)
      active_note_for_string[i] = nil
      grid_dirty = true
    end
  end)
end

------------------------------------------------------------
-- drone
------------------------------------------------------------
local function drone_off()
  for _,n in ipairs(drone_latched_notes) do
    midi_note_off(n, drone_ch)
  end
  drone_latched_notes = {}
  drone_enabled = false
end

local function drone_on()
  drone_off()
  local root_note = (octave * 12) + root_pc + transpose
  local tones = build_chord_tones(root_note)
  for i=1,#tones do
    local n = tones[i] - 12
    drone_latched_notes[#drone_latched_notes+1] = n
    midi_note_on(n, drone_vel, drone_ch)
  end
  drone_enabled = true
end

local function drone_toggle()
  if drone_enabled then drone_off() else drone_on() end
end

local function drone_on_chord_change(new_pcs)
  if not drone_enabled then return end
  if not drone_common_only then
    drone_on()
    return
  end
  local keep = {}
  for _,n in ipairs(drone_latched_notes) do
    if contains(new_pcs, pc(n)) then keep[#keep+1] = n end
  end
  drone_off()
  for _,n in ipairs(keep) do
    drone_latched_notes[#drone_latched_notes+1] = n
    midi_note_on(n, drone_vel, drone_ch)
  end
  if #drone_latched_notes == 0 then
    local root_note = (octave * 12) + root_pc + transpose
    local n = root_note - 12
    drone_latched_notes = {n}
    midi_note_on(n, drone_vel, drone_ch)
    drone_enabled = true
  else
    drone_enabled = true
  end
end

------------------------------------------------------------
-- NEW: organ buttons
------------------------------------------------------------
local function organ_notes_off()
  for _, n in ipairs(organ_active_notes) do
    midi_note_off(n, organ_ch)
  end
  organ_active_notes = {}
end

local function organ_notes_on()
  if not organ_enabled then return end
  organ_notes_off()
  local root_note = (octave * 12) + root_pc + transpose
  local tones = build_chord_tones(root_note)
  for _, n in ipairs(tones) do
    organ_active_notes[#organ_active_notes+1] = n
    midi_note_on(n, velocity, organ_ch)
  end
end

------------------------------------------------------------
-- NEW: arpeggiator (circular strum simulation)
------------------------------------------------------------
local function arp_stop()
  arp_gen = arp_gen + 1
  arp_enabled = false
  -- coroutine will clean up via generation check
end

local function arp_start()
  -- kill any lingering note from previous generation
  if arp_current_note then
    midi_note_off(arp_current_note, midi_ch)
    arp_current_note = nil
  end
  arp_gen = arp_gen + 1
  local my_gen = arp_gen
  arp_step = 1
  arp_enabled = true

  clock.run(function()
    while arp_enabled and my_gen == arp_gen do
      local root_note = (octave * 12) + root_pc + transpose
      local tones = build_chord_tones(root_note)
      if #tones > 0 then
        if arp_step > #tones then arp_step = 1 end
        local note = tones[arp_step]

        -- turn off previous arp note
        if arp_current_note then
          midi_note_off(arp_current_note, midi_ch)
        end

        arp_current_note = note
        midi_note_on(note, velocity, midi_ch)
        arp_step = arp_step + 1
      end

      clock.sync(arp_divs[arp_div_idx])
    end

    -- cleanup when coroutine exits
    -- only clean up if we're still the active generation
    -- (if a new gen started, it owns arp_current_note now)
    if my_gen == arp_gen and arp_current_note then
      midi_note_off(arp_current_note, midi_ch)
      arp_current_note = nil
    end
    grid_dirty = true
  end)
end

local function arp_toggle()
  if arp_enabled then
    arp_stop()
  else
    arp_start()
  end
  grid_dirty = true
end

------------------------------------------------------------
-- chord change behavior
------------------------------------------------------------
local function apply_chord_change(old_pcs)
  local new_pcs = current_chord_pcs()

  if behavior.kill_all_on_chord_change then
    all_notes_off_strings()
  end

  if behavior.follow_held then
    local new_notes = build_string_notes()
    for i=1,STRINGS do
      local old = active_note_for_string[i]
      if old ~= nil then
        local newn = new_notes[i]
        if behavior.sustain_common and contains(new_pcs, pc(old)) then
          -- keep common tones
        else
          midi_note_off(old, midi_ch)
          local d = infer_direction(i)
          local vel = vel_for_string(i, d)
          midi_note_on(newn, vel, midi_ch)
          active_note_for_string[i] = newn
          if behavior.retrigger_on_chord_change then
            ratchet_fire(newn, vel)
            schedule_pluck_off(i, newn)
          end
        end
      end
    end
  end

  drone_on_chord_change(new_pcs)

  -- organ buttons: retrigger on chord change (if any chord cell is held)
  if organ_enabled and chord_held_count > 0 then
    organ_notes_on()
  end
end

------------------------------------------------------------
-- PANIC
------------------------------------------------------------
local function panic()
  for ch=1,16 do midi_cc(123, 0, ch) end
  all_notes_off_strings()
  drone_off()
  organ_notes_off()
  if arp_enabled then arp_stop() end
  if arp_current_note then
    midi_note_off(arp_current_note, midi_ch)
    arp_current_note = nil
  end
  grid_dirty = true
end

------------------------------------------------------------
-- input handling
------------------------------------------------------------
local function is_chord_cell(x,y)
  return x>=1 and x<=12 and y>=1 and y<=3
end

local function chord_from_cell(x,y)
  local old_pcs = current_chord_pcs()
  root_pc = (x-1) % 12
  quality = pages[chord_page][y]
  apply_chord_change(old_pcs)
  -- organ: fire chord on ch2 when button is pressed
  organ_notes_on()
  grid_dirty = true
end

local function chord_release()
  -- organ always stops on chord button release
  organ_notes_off()
  -- if chord_hold is off, damp all strings too
  if not chord_hold then
    all_notes_off_strings()
  end
  grid_dirty = true
end

local function is_string_cell(x,y)
  return y==8 and x>=1 and x<=16
end

local function do_play(i, note, vel)
  turn_on_string(i, note, vel)
  ratchet_fire(note, vel)
  schedule_pluck_off(i, note)
end

local function handle_string(i, z)
  local notes = build_string_notes()
  local note = notes[i]
  local d = infer_direction(i)
  local vel = vel_for_string(i, d)

  local is_make = (z==1)
  local is_break = (z==0)

  if behavior.latch_mode then
    if is_make then
      latched_string[i] = not latched_string[i]
      if latched_string[i] then
        do_play(i, note, vel)
      else
        turn_off_string(i)
      end
    end
    held_string[i] = false
    grid_dirty = true
    return
  end

  held_string[i] = is_make

  if is_make then
    if behavior.stop_on_make and active_note_for_string[i] ~= nil then
      turn_off_string(i)
    end
    if behavior.play_on_make then
      do_play(i, note, vel)
    end
  else
    if behavior.stop_on_break and active_note_for_string[i] ~= nil then
      turn_off_string(i)
    end
    if behavior.play_on_break then
      do_play(i, note, vel)
    end
  end

  grid_dirty = true
end

------------------------------------------------------------
-- patches (updated with new features)
------------------------------------------------------------
local patch = 1
local function load_patch(p)
  patch = clamp(p,1,4)
  if patch == 1 then
    -- Classic strum
    mode = "momentary"; apply_mode()
    voicing = "close"
    string_mode = "chord"
    vel_curve = "flat"
    ratchet_count = 1
    pluck_mode = "latch_break"
    organ_enabled = false
    guitar_bass = false
    chord_hold = true
    behavior.retrigger_on_chord_change = false
    if arp_enabled then arp_stop() end
  elseif patch == 2 then
    -- Guitar strum with bass
    mode = "momentary"; apply_mode()
    voicing = "guitar"
    string_mode = "chord"
    vel_curve = "ramp_up"
    ratchet_count = 1
    pluck_mode = "latch_break"
    organ_enabled = false; organ_notes_off()
    guitar_bass = true
    chord_hold = true
    behavior.retrigger_on_chord_change = false
    if arp_enabled then arp_stop() end
  elseif patch == 3 then
    -- Organ pad
    mode = "momentary"; apply_mode()
    voicing = "spread"
    string_mode = "chord"
    vel_curve = "flat"
    ratchet_count = 1
    pluck_mode = "off"
    organ_enabled = true
    guitar_bass = false
    chord_hold = false
    behavior.retrigger_on_chord_change = true
    if arp_enabled then arp_stop() end
  elseif patch == 4 then
    -- Scale arp
    mode = "latch"; apply_mode()
    voicing = "close"
    string_mode = "pentatonic"
    vel_curve = "bell"
    ratchet_count = 1
    pluck_mode = "always"
    organ_enabled = false
    guitar_bass = false
    chord_hold = true
    behavior.retrigger_on_chord_change = false
    arp_div_idx = 2
    if not arp_enabled then arp_start() end
  end
  grid_dirty = true
end

------------------------------------------------------------
-- grid controls
------------------------------------------------------------
local function normal_press(x,y)
  local old_pcs = current_chord_pcs()

  -- pages: x13..15,y1 (x16 is shift)
  if y==1 and x>=13 and x<=15 then
    chord_page = x-12
    grid_dirty = true
    return
  end

  -- patches: x13..16,y2
  if y==2 and x>=13 and x<=16 then
    load_patch(x-12)
    apply_chord_change(old_pcs)
    return
  end

  -- row 4: add modes + voicing + drone
  if y==4 then
    if x==1 then add_mode="none"
    elseif x==2 then add_mode="add6"
    elseif x==3 then add_mode="add9"
    elseif x==4 then add_mode="add11"
    elseif x==13 then drone_toggle()
    elseif x==14 then voicing="close"
    elseif x==15 then voicing="guitar"
    elseif x==16 then voicing="spread"
    end
    apply_chord_change(old_pcs)
    grid_dirty = true
    return
  end

  -- row 5: NEW FEATURES
  if y==5 then
    -- x1-4: string mode
    if x==1 then string_mode="chord"
    elseif x==2 then string_mode="chromatic"
    elseif x==3 then string_mode="diatonic"
    elseif x==4 then string_mode="pentatonic"
    -- x6: guitar bass
    elseif x==6 then guitar_bass = not guitar_bass
    -- x7: organ buttons
    elseif x==7 then
      organ_enabled = not organ_enabled
      if not organ_enabled then organ_notes_off() end
    -- x8: retrigger on chord change
    elseif x==8 then
      behavior.retrigger_on_chord_change = not behavior.retrigger_on_chord_change
    -- x9: chord hold
    elseif x==9 then chord_hold = not chord_hold
    -- x11: arp toggle
    elseif x==11 then arp_toggle()
    -- x13-16: arp division
    elseif x>=13 and x<=16 then
      arp_div_idx = x - 12
      -- if arp is running, restart to pick up new division immediately
      if arp_enabled then arp_start() end
    end
    apply_chord_change(old_pcs)
    grid_dirty = true
    return
  end
end

local function shift_press(x,y)
  local old_pcs = current_chord_pcs()

  -- PANIC: (16,8)
  if x==16 and y==8 then panic(); return end

  -- Out A port: y1 x1..8
  if y==1 and x>=1 and x<=8 then
    out_a_port = x
    reconnect_midi()
    grid_dirty = true
    return
  end

  -- MIDI channel: y1 x9..16 => 1..8 ; y2 x9..16 => 9..16
  if (y==1 or y==2) and x>=9 and x<=16 then
    local base = (y==1) and 0 or 8
    midi_ch = clamp(base + (x-8), 1, 16)
    grid_dirty = true
    return
  end

  -- Out B port: y2 x1..8
  if y==2 and x>=1 and x<=8 then
    out_b_port = x
    reconnect_midi()
    grid_dirty = true
    return
  end
  if y==2 and x==9 then
    out_b_enabled = not out_b_enabled
    grid_dirty = true
    return
  end

  -- Octave: y3 x1..8
  if y==3 and x>=1 and x<=8 then
    octave = x-1
    apply_chord_change(old_pcs)
    grid_dirty = true
    return
  end

  -- Velocity: y3 x9..16
  if y==3 and x>=9 and x<=16 then
    local step = (x-9)
    velocity = clamp(20 + step*15, 1, 127)
    grid_dirty = true
    return
  end

  -- Pluck time: y4 x1..8
  if y==4 and x>=1 and x<=8 then
    pluck_time = pluck_times[x] or pluck_time
    grid_dirty = true
    return
  end

  -- Pluck mode: y4 x9..11
  if y==4 and x>=9 and x<=11 then
    if x==9 then pluck_mode="off"
    elseif x==10 then pluck_mode="latch_break"
    elseif x==11 then pluck_mode="always"
    end
    grid_dirty = true
    return
  end

  -- Power voicing toggle: y4 x12
  if y==4 and x==12 then
    voicing = (voicing=="power") and "close" or "power"
    apply_chord_change(old_pcs)
    grid_dirty = true
    return
  end

  -- Ratchet: y5 x1..8
  if y==5 and x>=1 and x<=8 then
    ratchet_count = x
    grid_dirty = true
    return
  end

  -- Vel curve: y5 x9..12
  if y==5 and x>=9 and x<=12 then
    if x==9 then vel_curve="flat"
    elseif x==10 then vel_curve="ramp_up"
    elseif x==11 then vel_curve="ramp_down"
    elseif x==12 then vel_curve="bell"
    end
    grid_dirty = true
    return
  end

  -- Direction accent: y5 x13..16
  if y==5 and x>=13 and x<=16 then
    local step = x-13
    local vals = {0, 8, 16, 24}
    dir_accent = vals[step+1]
    grid_dirty = true
    return
  end

  -- Mode: y6 x9..12
  if y==6 and x>=9 and x<=12 then
    if x==9 then mode="momentary"
    elseif x==10 then mode="break"
    elseif x==11 then mode="latch"
    elseif x==12 then mode="free"
    end
    apply_mode()
    grid_dirty = true
    return
  end

  -- Free raw toggles: y6 x1..4
  if y==6 and x>=1 and x<=4 then
    if mode=="free" then
      if x==1 then behavior.play_on_make = not behavior.play_on_make
      elseif x==2 then behavior.play_on_break = not behavior.play_on_break
      elseif x==3 then behavior.stop_on_make = not behavior.stop_on_make
      elseif x==4 then behavior.stop_on_break = not behavior.stop_on_break
      end
      grid_dirty = true
    end
    return
  end

  -- Transpose: y7 x1..16 => -8..+7
  if y==7 and x>=1 and x<=16 then
    transpose = (x-1) - 8
    apply_chord_change(old_pcs)
    grid_dirty = true
    return
  end

  -- Drone: y8 x14 common-only, x15 toggle
  if y==8 and x==14 then
    drone_common_only = not drone_common_only
    grid_dirty = true
    return
  end
  if y==8 and x==15 then
    drone_toggle()
    grid_dirty = true
    return
  end
end

------------------------------------------------------------
-- redraw (grid + screen)
------------------------------------------------------------
local function grid_redraw()
  if not g then return end
  g:all(0)

  -- SHIFT key always visible
  g:led(16,1, shift and 15 or 3)

  -- chord page buttons (x13-15, x16 is shift)
  for x=13,15 do
    local p = x-12
    g:led(x,1, (p==chord_page) and 12 or 2)
  end

  -- patch buttons
  for x=13,16 do
    local p = x-12
    g:led(x,2, (p==patch) and 12 or 2)
  end

  -- chord matrix
  for x=1,12 do
    for y=1,3 do
      local cell_q = pages[chord_page][y]
      local lvl = 3
      if root_pc == (x-1) and quality == cell_q then lvl = 15
      elseif root_pc == (x-1) then lvl = 6 end
      g:led(x,y,lvl)
    end
  end

  if shift then
    -- === SHIFT LAYER ===
    -- Out A ports
    for x=1,8 do g:led(x,1, (x==out_a_port) and 15 or 3) end

    -- MIDI channels
    for x=9,16 do
      local ch = x-8
      g:led(x,1, (midi_ch==ch) and 15 or 2)
      g:led(x,2, (midi_ch==(ch+8)) and 15 or 2)
    end

    -- Out B ports + enable
    for x=1,8 do g:led(x,2, (x==out_b_port) and 12 or 2) end
    g:led(9,2, out_b_enabled and 15 or 3)

    -- Octave
    for x=1,8 do g:led(x,3, (octave==(x-1)) and 15 or 3) end

    -- Velocity
    local vel_step = clamp(math.floor((velocity-20)/15), 0, 7)
    for x=9,16 do g:led(x,3, ((x-9)==vel_step) and 12 or 2) end

    -- Pluck time
    for x=1,8 do
      local on = math.abs((pluck_times[x] or 0) - pluck_time) < 1e-6
      g:led(x,4, on and 15 or 2)
    end
    -- Pluck mode
    g:led(9,4,  pluck_mode=="off" and 15 or 3)
    g:led(10,4, pluck_mode=="latch_break" and 15 or 3)
    g:led(11,4, pluck_mode=="always" and 15 or 3)
    -- Power toggle
    g:led(12,4, voicing=="power" and 15 or 3)

    -- Ratchet
    for x=1,8 do g:led(x,5, (ratchet_count==x) and 15 or 3) end
    -- Vel curve
    g:led(9,5,  vel_curve=="flat" and 15 or 3)
    g:led(10,5, vel_curve=="ramp_up" and 15 or 3)
    g:led(11,5, vel_curve=="ramp_down" and 15 or 3)
    g:led(12,5, vel_curve=="bell" and 15 or 3)
    -- Accent
    local vals = {0,8,16,24}
    for x=13,16 do g:led(x,5, (dir_accent==vals[x-12]) and 12 or 2) end

    -- Mode
    g:led(9,6,  mode=="momentary" and 15 or 3)
    g:led(10,6, mode=="break" and 15 or 3)
    g:led(11,6, mode=="latch" and 15 or 3)
    g:led(12,6, mode=="free" and 15 or 3)
    -- Free flags
    g:led(1,6, behavior.play_on_make and 12 or 2)
    g:led(2,6, behavior.play_on_break and 12 or 2)
    g:led(3,6, behavior.stop_on_make and 12 or 2)
    g:led(4,6, behavior.stop_on_break and 12 or 2)

    -- Transpose
    for x=1,16 do
      local tr = (x-1)-8
      g:led(x,7, (transpose==tr) and 12 or 1)
    end

    -- Drone + panic
    g:led(14,8, drone_common_only and 15 or 3)
    g:led(15,8, drone_enabled and 15 or 3)
    g:led(16,8, 15)

  else
    -- === NORMAL LAYER ===

    -- Row 4: add modes + voicing + drone
    g:led(1,4, add_mode=="none" and 12 or 2)
    g:led(2,4, add_mode=="add6" and 12 or 2)
    g:led(3,4, add_mode=="add9" and 12 or 2)
    g:led(4,4, add_mode=="add11" and 12 or 2)

    g:led(13,4, drone_enabled and 15 or 3)
    g:led(14,4, voicing=="close" and 15 or 3)
    g:led(15,4, voicing=="guitar" and 15 or 3)
    g:led(16,4, voicing=="spread" and 15 or 3)

    -- Row 5: NEW FEATURES
    -- x1-4: string mode
    g:led(1,5, string_mode=="chord" and 12 or 2)
    g:led(2,5, string_mode=="chromatic" and 12 or 2)
    g:led(3,5, string_mode=="diatonic" and 12 or 2)
    g:led(4,5, string_mode=="pentatonic" and 12 or 2)
    -- x6: guitar bass
    g:led(6,5, guitar_bass and 15 or 3)
    -- x7: organ
    g:led(7,5, organ_enabled and 15 or 3)
    -- x8: retrigger
    g:led(8,5, behavior.retrigger_on_chord_change and 15 or 3)
    -- x9: chord hold
    g:led(9,5, chord_hold and 15 or 3)
    -- x11: arp
    g:led(11,5, arp_enabled and 15 or 3)
    -- x13-16: arp division
    for x=13,16 do
      g:led(x,5, (arp_div_idx==(x-12)) and 12 or 2)
    end

    -- Row 8: strings
    for x=1,16 do
      local i = x
      local lvl = 2
      if active_note_for_string[i] ~= nil then lvl = 12 end
      if behavior.latch_mode and latched_string[i] then lvl = 15 end
      if held_string[i] then lvl = 15 end
      g:led(x,8,lvl)
    end
  end

  g:refresh()
end

local function screen_redraw()
  screen.clear()
  screen.level(15)

  screen.move(10,12)
  screen.text("le_strum v6 "..(shift and "[SET]" or "[PLAY]"))

  screen.move(10,24)
  screen.text(note_name(root_pc).." "..quality.." +"..add_mode.." pg:"..chord_page.." p:"..patch)

  screen.move(10,36)
  local voi_str = voicing
  if string_mode ~= "chord" then voi_str = string_mode end
  screen.text("Voi:"..voi_str.." mode:"..mode.." vel:"..vel_curve)

  screen.move(10,48)
  screen.text("Oct:"..octave.." Tr:"..transpose.." Ch:"..midi_ch.." Rat:"..ratchet_count)

  screen.move(10,60)
  local flags = {}
  if organ_enabled then flags[#flags+1] = "Org" end
  if guitar_bass then flags[#flags+1] = "Bass" end
  if not chord_hold then flags[#flags+1] = "Rel" end
  if behavior.retrigger_on_chord_change then flags[#flags+1] = "Rtg" end
  if arp_enabled then flags[#flags+1] = "Arp:"..arp_div_labels[arp_div_idx] end
  if drone_enabled then flags[#flags+1] = "Drn" end
  local flag_str = #flags > 0 and table.concat(flags, " ") or "---"
  screen.text(flag_str)

  screen.update()
end

------------------------------------------------------------
-- norns lifecycle
------------------------------------------------------------
function init()
  mA = midi.connect(out_a_port)
  mB = midi.connect(out_b_port)

  apply_mode()
  load_patch(1)

  g = grid.connect()
  g.key = function(x,y,z)
    -- SHIFT hold (grid key 16,1)
    if x==16 and y==1 then
      shift = (z==1)
      grid_dirty = true
      return
    end

    -- === RELEASE EVENTS ===
    if z==0 then
      -- chord cell release: organ off + optional damp
      if is_chord_cell(x,y) then
        chord_held_count = math.max(0, chord_held_count - 1)
        if chord_held_count == 0 then
          chord_release()
        end
      end
      -- string release
      if not shift and is_string_cell(x,y) then
        handle_string(x, 0)
      end
      return
    end

    -- === PRESS EVENTS ===

    -- shift layer gets priority
    if shift then
      shift_press(x,y)
      return
    end

    -- chord cells
    if is_chord_cell(x,y) then
      chord_held_count = chord_held_count + 1
      chord_from_cell(x,y)
      return
    end

    -- strings
    if is_string_cell(x,y) then
      handle_string(x, 1)
      return
    end

    -- normal controls (rows 4, 5, etc.)
    normal_press(x,y)
  end

  -- refresh loop
  clock.run(function()
    while true do
      if grid_dirty then
        grid_redraw()
        grid_dirty = false
      end
      screen_redraw()
      clock.sleep(1/20)
    end
  end)
end

function redraw()
  screen_redraw()
end

function cleanup()
  panic()
end

function enc(n, d)
  local old_pcs = current_chord_pcs()
  if n == 2 then
    transpose = clamp(transpose + d, -24, 24)
    apply_chord_change(old_pcs)
  elseif n == 3 then
    octave = clamp(octave + d, 0, 8)
    apply_chord_change(old_pcs)
  end
  grid_dirty = true
end

function key(n, z)
  if n == 2 then
    shift = (z==1)
    grid_dirty = true
    return
  end
  if n == 3 and z == 1 then
    panic()
  end
end
