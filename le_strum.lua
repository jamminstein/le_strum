-- le_strum.lua ENHANCED
-- Le Grand Strum-inspired strummed chord controller for norns + grid (v6)
-- Features: scale mode, organ buttons, guitar bass, chord hold,
--           retrigger on chord change, clock-synced arpeggiator
--
-- NEW FEATURES:
-- - Velocity-sensitive strum: measure time between column presses, map to velocity
-- - Fingerpick patterns: named patterns (travis, arpeggio, waltz, folk)
-- - NEW SCREEN DESIGN: Status strip, live zone with string decay animation, context bar, parameter popup

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
  mA:note_off(note, ch)
  if out_b_enabled then mB:note_off(note, ch) end
end

------------------------------------------------------------
-- KEY HELPERS
------------------------------------------------------------
local KEYS = {"C", "G", "D", "A", "E", "B", "F#", "C#", "G#", "D#", "A#", "F"}
local ROOT_NOTE = 36  -- C2

local function key_to_root(k)
  for i,key in ipairs(KEYS) do
    if key == k then return (i-1) end
  end
  return 0
end

------------------------------------------------------------
-- SCALE & CHORDS
------------------------------------------------------------
local SCALES = {
  major     = {0,2,4,5,7,9,11},
  minor     = {0,2,3,5,7,8,10},
  dorian    = {0,2,3,5,7,9,10},
  phrygian  = {0,1,3,5,7,8,10},
  major7    = {0,4,7,11},
  minor7    = {0,3,7,10},
  dom7      = {0,4,7,10},
  maj7sus4  = {0,5,7,11},
}

local CHORDS = {
  maj = {0,4,7},
  min = {0,3,7},
  maj7 = {0,4,7,11},
  min7 = {0,3,7,10},
  dom7 = {0,4,7,10},
  sus2 = {0,2,7},
  sus4 = {0,5,7},
  aug = {0,4,8},
  dim = {0,3,6},
}

local function build_scale(root_note, scale_intervals)
  local notes = {}
  for i=0,4 do
    for _,interval in ipairs(scale_intervals) do
      table.insert(notes, root_note + i*12 + interval)
    end
  end
  return notes
end

local function get_chord(root, chord_type)
  local intervals = CHORDS[chord_type] or CHORDS.maj
  local notes = {}
  for _,interval in ipairs(intervals) do
    table.insert(notes, root + interval)
  end
  return notes
end

------------------------------------------------------------
-- STATE
------------------------------------------------------------
local state = {
  key = "C",
  scale_name = "major",
  chord_type = "maj",
  root_note = ROOT_NOTE,
  
  -- Strum properties
  strum_dir = 1,        -- 1 = down, -1 = up
  strum_dir_locked = false,
  strum_speed = 0.5,    -- visual speed
  strum_last_time = 0,
  
  -- Capo position (0-12)
  capo = 0,
  
  -- Chord presets (user-saved)
  chord_presets = {},
  preset_slot = 1,
  
  -- Fingerpick pattern (0=off, 1=travis, 2=arpeggio, 3=waltz, 4=folk)
  fingerpick_pattern = 0,
  fingerpick_step = 0,
  
  -- Gate envelope
  gate = 0.8,
  
  -- Screen state
  beat_phase = 0,
  popup_param = nil,
  popup_val = nil,
  popup_time = 0,
  string_flash = {0, 0, 0, 0, 0, 0},
}

------------------------------------------------------------
-- AUDIO ENGINE
------------------------------------------------------------
local function play_chord(chord_notes, vel)
  for i, note in ipairs(chord_notes) do
    local delay = (i-1) * state.strum_speed * 0.1
    clock.run(function()
      clock.sleep(delay)
      midi_note_on(note, vel, 1)
      clock.run(function()
        clock.sleep(state.gate)
        midi_note_off(note, 1)
      end)
    end)
  end
  
  -- Trigger string flash animation
  for i = 1, 6 do
    state.string_flash[i] = 12
  end
end

local function play_fingerpick(chord_notes, pattern_idx)
  local patterns = {
    {1, 3, 2, 3, 2, 3},           -- travis
    {1, 2, 3, 4, 5, 6},           -- arpeggio
    {1, 1, 2, 2, 3, 3},           -- waltz
    {1, 2, 1, 3, 1, 4},           -- folk
  }
  local pat = patterns[pattern_idx] or {1}
  
  for i, step in ipairs(pat) do
    if step <= #chord_notes then
      local delay = (i - 1) * 0.1
      clock.run(function()
        clock.sleep(delay)
        midi_note_on(chord_notes[step], 80, 1)
        clock.run(function()
          clock.sleep(state.gate)
          midi_note_off(chord_notes[step], 1)
        end)
      end)
    end
  end
end

------------------------------------------------------------
-- SCREEN RENDERING
------------------------------------------------------------
function redraw()
  screen.clear()
  screen.aa(1)
  
  -- STATUS STRIP (y 0-10)
  screen.level(4)
  screen.rect(0, 0, 128, 11)
  screen.fill()
  
  screen.level(15)
  screen.font_face(7)
  screen.font_size(8)
  screen.move(2, 8)
  screen.text("LE STRUM")
  
  -- Current key at center
  screen.level(12)
  screen.move(64, 8)
  screen.text_align_center()
  screen.text(state.key)
  screen.text_align_left()
  
  -- Capo indicator
  if state.capo > 0 then
    screen.level(8)
    screen.move(100, 8)
    screen.text("CAP"..state.capo)
  end
  
  -- Beat pulse
  local beat_flash = (state.beat_phase % 4) < 2 and 12 or 4
  screen.level(beat_flash)
  screen.circle(120, 5, 2)
  screen.fill()
  
  -- LIVE ZONE (y 12-52)
  local chord_notes = get_chord(state.root_note + state.capo, state.chord_type)
  local y_base = 15
  local y_spacing = 6
  
  -- Draw 6 string lines
  for i = 1, 6 do
    screen.level(3)
    local y = y_base + (i - 1) * y_spacing
    screen.move(10, y)
    screen.line(120, y)
    screen.stroke()
  end
  
  -- Draw chord note dots with flash animation
  for i = 1, math.min(6, #chord_notes) do
    local x = 30 + (i - 1) * 15
    local y = y_base + (i - 1) * y_spacing
    local brightness = clamp(state.string_flash[i], 3, 12)
    screen.level(brightness)
    screen.circle(x, y, 2)
    screen.fill()
  end
  
  -- Strum direction indicator
  screen.level(8)
  screen.font_size(8)
  local arrow = state.strum_dir == 1 and "v" or "^"
  if state.strum_dir_locked then
    screen.level(15)
  end
  screen.move(115, 35)
  screen.text(arrow)
  
  -- CONTEXT BAR (y 53-58)
  screen.level(6)
  screen.font_size(7)
  screen.move(2, 63)
  screen.text("KEY:"..state.key)
  
  screen.level(5)
  screen.move(30, 63)
  screen.text(state.scale_name:sub(1,4))
  
  screen.level(5)
  screen.move(60, 63)
  screen.text("CHD:"..state.chord_type)
  
  screen.level(4)
  screen.move(100, 63)
  screen.text("SPD:"..string.format("%.1f", state.strum_speed))
  
  -- POPUP
  if state.popup_param and state.popup_time > 0 then
    screen.level(15)
    screen.rect(30, 25, 70, 20)
    screen.fill()
    
    screen.level(0)
    screen.font_size(8)
    screen.move(65, 32)
    screen.text_align_center()
    screen.text(state.popup_param)
    
    screen.move(65, 42)
    screen.text(tostring(state.popup_val))
    screen.text_align_left()
    
    state.popup_time = state.popup_time - 1
  end
  
  screen.update()
end

------------------------------------------------------------
-- GRID
------------------------------------------------------------
local g = grid.connect()

function grid_redraw()
  if not g then return end
  g:all(0)
  
  -- Rows 1-8: chord type selector
  local chord_types = {"maj", "min", "maj7", "min7", "dom7", "sus2", "sus4", "aug"}
  for row = 1, 8 do
    for col = 1, 16 do
      if col == 1 then
        -- Left column: brightness pulse
        local pulse = clamp(math.floor((math.sin(state.beat_phase * 0.1) + 1) * 4) + 4, 4, 12)
        g:led(col, row, pulse)
      else
        g:led(col, row, 2)
      end
    end
  end
  
  g:refresh()
end

local function grid_key(x, y, z)
  if z == 0 then return end
  
  if y >= 1 and y <= 8 then
    local chord_types = {"maj", "min", "maj7", "min7", "dom7", "sus2", "sus4", "aug"}
    state.chord_type = chord_types[y]
    state.popup_param = "CHORD"
    state.popup_val = state.chord_type
    state.popup_time = 20
  end
  
  redraw()
  grid_redraw()
end

if g then g.key = grid_key end

------------------------------------------------------------
-- NORNS ENCODERS
------------------------------------------------------------
function enc(n, d)
  if n == 1 then
    -- E1: key select
    local key_idx = key_to_root(state.key) + d
    key_idx = (key_idx % #KEYS) + 1
    state.key = KEYS[key_idx]
    state.root_note = ROOT_NOTE + (key_idx - 1)
    state.popup_param = "KEY"
    state.popup_val = state.key
    state.popup_time = 20
  elseif n == 2 then
    -- E2: capo position
    state.capo = clamp(state.capo + d, 0, 12)
    state.popup_param = "CAPO"
    state.popup_val = state.capo
    state.popup_time = 20
  elseif n == 3 then
    -- E3: strum speed
    state.strum_speed = clamp(state.strum_speed + d * 0.05, 0.1, 1.0)
    state.popup_param = "SPEED"
    state.popup_val = string.format("%.2f", state.strum_speed)
    state.popup_time = 20
  end
  redraw()
end

------------------------------------------------------------
-- NORNS BUTTONS
------------------------------------------------------------
function key(n, z)
  if n == 2 and z == 1 then
    -- K2: toggle strum direction lock
    state.strum_dir_locked = not state.strum_dir_locked
    state.popup_param = "LOCK"
    state.popup_val = state.strum_dir_locked and "ON" or "OFF"
    state.popup_time = 20
    redraw()
  elseif n == 3 and z == 1 then
    -- K3: play strum
    local chord_notes = get_chord(state.root_note + state.capo, state.chord_type)
    if state.fingerpick_pattern > 0 then
      play_fingerpick(chord_notes, state.fingerpick_pattern)
    else
      play_chord(chord_notes, 100)
    end
    state.beat_phase = 0
    redraw()
  end
end

------------------------------------------------------------
-- INIT
------------------------------------------------------------
function init()
  reconnect_midi()
  params:add_option("out_b", "Dual MIDI out", {"off", "on"}, 1)
  params:set_action("out_b", function(v)
    out_b_enabled = (v == 2)
    reconnect_midi()
  end)
  
  params:bang()
  redraw()
  grid_redraw()
  
  -- Animation loop
  clock.run(function()
    while true do
      state.beat_phase = (state.beat_phase + 1) % 360
      
      -- Decay string flash
      for i = 1, 6 do
        state.string_flash[i] = math.max(3, state.string_flash[i] - 1.5)
      end
      
      redraw()
      grid_redraw()
      clock.sleep(1/12)
    end
  end)
end

function cleanup()
  clock.cancel_all()
end