# `zxkitty` -- ZX80 emulator for terminal

`zxkitty` is a ZX80 emulator which uses 
kitty's graphic protocol for video output.

## Configuration

Use environment variables to specify path to a ROM file
and ZX Spectrum variant:

```bash
export ZX80_MACHINE_TYPE="128k"
export ZX80_ROM_PATH=/zx80/roms/128k.rom
```

You can enable turbo tape loading with `-t` flag, and
set scale with `-s`:

```bash
zxkitty -s 4 -t /path/to/game.TAP
```

## Supported formats

TAP, TZX (more or less), Z80

## Usage

* `F1` to reset the emulator
* `F2` to pause/unpause the emulation
* `F3` to take a screenshot (saved in SCR format in current dir)
* `F4` to save a snapshot in Z80 format
* `F8` to toggle turbo tape mode
* `F9` to start/stop tape
* `F10` to rewind tape
