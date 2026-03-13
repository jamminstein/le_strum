# le_strum

> Strummed chord controller with grid and arpeggiator

## Controls

- **E2** — transpose
- **E3** — octave
- **K2** — toggle shift layer
- **K3** — panic / all notes off
- **K1 (hold)** — shift: access MIDI ports, octave, velocity, pluck mode, ratchet, curves, transpose, drone

## Grid

Chord matrix (1–12 × 1–3), string row (row 8, 1–16). Shift layer: MIDI routing, octave, velocity, pluck timing, ratchet, velocity curves, direction accent, mode flags, transpose, drone. Presets in row 2 (shift layer) for classic strum, guitar+bass, organ pad, and scale arp.

## Requirements

- norns
- grid (16×8, required)
- MIDI devices (port A + optional port B)
- engine: None (MIDI only)

## Install

```
;install https://github.com/jamminstein/le_strum
```
