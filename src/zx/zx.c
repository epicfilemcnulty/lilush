// SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
// SPDX-License-Identifier: OWL-1.0 or later
// Licensed under the Open Weights License v1.0. See LICENSE for details.

/*
 * ZX Spectrum 48K/128K Emulator Core
 *
 * This module provides:
 * - Z80 CPU emulation
 * - 64KB memory (16KB ROM + 48KB RAM), 128K memory banking
 * - ULA emulation (video, keyboard, border, beeper hook)
 *
 * The Z80 implementation aims for game compatibility rather than
 * cycle-perfect accuracy. Contended memory timing is not emulated.
 */

#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <poll.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* --------------------------------------------------------------------------
 * Z80 CPU State
 * -------------------------------------------------------------------------- */

// Flag bit positions in F register
#define FLAG_C  0x01 // Carry
#define FLAG_N  0x02 // Add/Subtract
#define FLAG_PV 0x04 // Parity/Overflow
#define FLAG_H  0x10 // Half Carry
#define FLAG_Z  0x40 // Zero
#define FLAG_S  0x80 // Sign

// ZX Spectrum memory map
#define ROM_START         0x0000
#define ROM_END           0x3FFF
#define SCREEN_START      0x4000
#define SCREEN_BITMAP_END 0x57FF
#define SCREEN_ATTR_END   0x5AFF
#define RAM_END           0xFFFF

// Timing constants
#define TSTATES_PER_FRAME_48K  69888                 // 3.5MHz / 50Hz (48k)
#define TSTATES_PER_FRAME_128K 70908                 // 128k has slightly different timing
#define TSTATES_PER_FRAME      TSTATES_PER_FRAME_48K // Default for compatibility
#define SCREEN_SIZE            6912                  // 6144 bitmap + 768 attributes
#define TSTATES_PER_LINE       224                   // T-states per scanline
#define SCANLINES_PER_FRAME    312                   // PAL: 312 scanlines per frame

// Machine types
#define MACHINE_48K   0
#define MACHINE_128K  1
#define MACHINE_PLUS2 2

// Memory bank sizes
#define RAM_BANK_SIZE  16384 // 16KB per bank
#define RAM_BANK_COUNT 8     // 8 banks for 128k (128KB total)
#define ROM_BANK_COUNT 2     // 2 ROM banks for 128k

// AY-3-8912 register indices
#define AY_REG_A_TONE_L  0
#define AY_REG_A_TONE_H  1
#define AY_REG_B_TONE_L  2
#define AY_REG_B_TONE_H  3
#define AY_REG_C_TONE_L  4
#define AY_REG_C_TONE_H  5
#define AY_REG_NOISE     6
#define AY_REG_MIXER     7
#define AY_REG_A_VOL     8
#define AY_REG_B_VOL     9
#define AY_REG_C_VOL     10
#define AY_REG_ENV_L     11
#define AY_REG_ENV_H     12
#define AY_REG_ENV_SHAPE 13
#define AY_REG_IO_A      14
#define AY_REG_IO_B      15

// AY clock divider: CPU runs at 3.5 MHz, AY at 1.7734 MHz (CPU/2)
// Then AY further divides by 8 internally for tone generation
#define AY_CLOCK_DIVIDER 16

// Audio sampling constants
#define AUDIO_SAMPLE_RATE 44100
#define CPU_CLOCK         3500000
// Size the per-frame audio buffer with headroom (covers 48k and 128k frame timings).
#define AUDIO_SAMPLES_PER_FRAME \
    ((int)(((uint64_t)TSTATES_PER_FRAME_128K * (uint64_t)AUDIO_SAMPLE_RATE) / (uint64_t)CPU_CLOCK) + 32)

// AY-3-8912 sound chip state
typedef struct {
    uint8_t regs[16];     // R0-R15
    uint8_t selected_reg; // Current register (0-15)

    // Tone generators (3 channels)
    uint16_t tone_counters[3]; // 12-bit counters
    uint8_t tone_outputs[3];   // Current output state (0/1)

    // Noise generator
    uint8_t noise_counter; // 5-bit counter
    uint32_t noise_shift;  // 17-bit LFSR
    uint8_t noise_output;  // Current output state

    // Envelope generator
    uint16_t env_counter; // 16-bit counter
    uint8_t env_step;     // 0-15 (or 0-31 for some shapes)
    uint8_t env_holding;  // Envelope in hold state
    uint8_t env_attack;   // Attack direction (1=up, 0=down)
    uint8_t env_div;      // Envelope clock divider (0-15)

    // T-states accumulator for AY clock division
    uint32_t tstates_accum;
} AYState;

typedef struct {
    // Main registers
    uint8_t a, f;
    uint8_t b, c;
    uint8_t d, e;
    uint8_t h, l;

    // Alternate register set
    uint8_t a_, f_;
    uint8_t b_, c_;
    uint8_t d_, e_;
    uint8_t h_, l_;

    // Index registers
    uint16_t ix, iy;

    // Stack pointer and program counter
    uint16_t sp, pc;

    // Interrupt vector and refresh registers
    uint8_t i, r;

    // Interrupt flip-flops and mode
    uint8_t iff1, iff2;
    uint8_t im; // Interrupt mode (0, 1, or 2)

    // EI enables interrupts after the *next* instruction
    uint8_t ei_delay;

    // Halted flag
    uint8_t halted;

    // T-states counter for current frame
    uint32_t tstates;

    // Machine type
    uint8_t machine_type; // MACHINE_48K, MACHINE_128K, MACHINE_PLUS2

    // Banked memory for 128k support
    // RAM: 8 banks of 16KB each (128KB total)
    // ROM: 2 banks of 16KB each (32KB total for 128k)
    uint8_t ram_banks[RAM_BANK_COUNT][RAM_BANK_SIZE];
    uint8_t rom_banks[ROM_BANK_COUNT][RAM_BANK_SIZE];

    // Memory mapping pointers (for fast access)
    // 4 regions of 16KB each: 0x0000, 0x4000, 0x8000, 0xC000
    uint8_t *mem_map[4];
    uint8_t mem_writable[4]; // 1 = writable (RAM), 0 = read-only (ROM)

    // Memory banking state (port 0x7FFD)
    uint8_t port_7ffd;       // Last value written to 0x7FFD
    uint8_t paging_disabled; // Bit 5 of 0x7FFD locks paging until reset

    // Active screen buffer (0 = bank 5 @ 0x4000, 1 = bank 7 @ 0xC000)
    uint8_t active_screen;

    // Debug counters for banking
    uint32_t screen_switch_count;   // Times active_screen changed
    uint32_t port_7ffd_write_count; // Times port 0x7FFD was written

    // Frame timing (varies between 48k/128k)
    uint32_t tstates_per_frame;

    // ROM loaded flags (one per bank)
    uint8_t rom_loaded;

    // ULA state
    uint8_t border_color;
    uint8_t keyboard_rows[8]; // 8 half-rows of keyboard matrix

    // Border scanline history (for tape loading visualization)
    // Only populated when tape_active is set
    uint8_t border_scanlines[SCANLINES_PER_FRAME];

    // Screen dirty flag (set when VRAM written)
    uint8_t screen_dirty;

    // Audio state
    uint8_t beeper_state;
    int16_t audio_buffer[AUDIO_SAMPLES_PER_FRAME];
    uint32_t audio_sample_idx;

    // Audio sampling accumulator (fixed-point):
    // audio_phase_accum += tstates * AUDIO_SAMPLE_RATE
    // while (audio_phase_accum >= CPU_CLOCK) emit one sample
    uint64_t audio_phase_accum;

    // Tape loading sound monitor (mixes EAR pulses into output)
    uint8_t tape_audio_enabled;
    int16_t tape_audio_amp;

    // AY-3-8912 sound chip (128k only)
    AYState ay;

    // Tape (TAP) playback state (EAR bit)
    // Cached flag: (loaded && playing) - updated when tape state changes
    uint8_t tape_active;
    struct {
        int loaded;
        int playing;
        int autostarted;

        // Parsed TAP blocks
        struct {
            uint8_t *data;
            uint16_t len;
            // Timing parameters (T-states)
            // If has_pilot_sync=0, block starts directly with data pulses.
            uint8_t has_pilot_sync;
            uint8_t is_turbo;
            uint8_t used_bits_last; // 1..8
            uint8_t pause_defined;  // 0=treat pause_ms==0 as TAP default gap, 1=honor pause_ms (0=none)
            uint16_t pause_ms;      // pause after this block (ms)
            uint16_t pilot_len;
            uint16_t sync1_len;
            uint16_t sync2_len;
            uint16_t bit0_len;
            uint16_t bit1_len;
            uint16_t pilot_pulses; // used when is_turbo=1

            // Optional starting level (used with TZX 0x2B)
            uint8_t start_level_set;
            uint8_t start_level;
        } *blocks;
        int block_count;
        int block_idx;

        // Bitstream position within current block
        int byte_idx;
        int bit_idx; // 0..7 (MSB first)

        // Signal generation
        uint8_t ear_level;    // 0/1 reflected on ULA bit 6
        int32_t tstates_rem;  // time remaining in current phase/pulse
        int pilot_rem;        // remaining pilot pulses
        uint8_t phase;        // internal phase state
        uint8_t pulse_in_bit; // 0/1 (two pulses per bit)
    } tape;

    // Debug/diagnostic state
    uint16_t last_in_port;   // Last port read
    uint8_t last_in_result;  // Last IN result
    uint32_t keyboard_reads; // Counter for keyboard port reads

    // Interrupt vector byte (IM2 data bus). Real Spectrum behavior depends on
    // floating bus/ULA; keeping it configurable helps game compatibility.
    uint8_t int_vector;

    // If set, use int_vector as a fixed data bus byte for IM2.
    // If clear, emulate a "floating bus" value based on ULA timing.
    uint8_t int_vector_fixed;

    // Debug: track writes to the IM2 vector page (I:00..FF)
    uint32_t im2_page_write_count;
    uint16_t im2_last_write_addr;
    uint8_t im2_last_write_val;

    // Floating bus last value (approximation)
    uint8_t floating_bus_last;

    // PC history for debugging
    uint16_t pc_history[16];
    uint8_t pc_history_idx;

    // Last executed opcode (for EI delay optimization)
    uint8_t last_opcode;

} ZXState;

// Metatable name for ZX emulator userdata
#define ZX_EMU_MT "zx.emulator"

/* --------------------------------------------------------------------------
 * Z80 snapshot (.z80) helpers
 * -------------------------------------------------------------------------- */

static inline uint16_t rd16le(const uint8_t *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static inline void wr16le(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
}

// Forward decls (tape code is defined later)
static void tape_rewind(ZXState *zx);

// Decompress Z80 RLE blocks into a fixed-size output.
// If v1_stream is set, stop on 00 ED ED 00 end marker.
static int z80_rle_decompress(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_len, int v1_stream) {
    size_t i = 0;
    size_t o = 0;

    while (i < in_len && o < out_len) {
        if (v1_stream && in[i] == 0x00 && (i + 3) < in_len && in[i + 1] == 0xED && in[i + 2] == 0xED &&
            in[i + 3] == 0x00) {
            break;
        }

        if (in[i] == 0xED && (i + 3) < in_len && in[i + 1] == 0xED) {
            uint8_t count = in[i + 2];
            uint8_t val   = in[i + 3];
            i += 4;
            for (uint32_t k = 0; k < count && o < out_len; k++)
                out[o++] = val;
            continue;
        }

        out[o++] = in[i++];
    }

    return (o == out_len) ? 1 : 0;
}

static void zx_snapshot_cleanup_runtime(ZXState *zx) {
    zx->tstates           = 0;
    zx->screen_dirty      = 1;
    zx->audio_sample_idx  = 0;
    zx->audio_phase_accum = 0;
    zx->beeper_state      = 0;
    zx->floating_bus_last = 0xFF;

    // AY chip internal state (keep regs, reset generator state)
    zx->ay.tstates_accum = 0;
    zx->ay.noise_shift   = 1;
    memset(zx->ay.tone_counters, 0, sizeof(zx->ay.tone_counters));
    memset(zx->ay.tone_outputs, 0, sizeof(zx->ay.tone_outputs));
    zx->ay.noise_counter = 0;
    zx->ay.noise_output  = 0;
    zx->ay.env_counter   = 0;
    zx->ay.env_step      = 0;
    zx->ay.env_holding   = 0;
    zx->ay.env_attack    = 0;
    zx->ay.env_div       = 0;

    // Stop tape playback, keep blocks loaded.
    tape_rewind(zx);
    zx->tape.loaded      = (zx->tape.block_count > 0);
    zx->tape.playing     = 0;
    zx->tape_active      = 0;
    zx->tape.phase       = 0; // TAPE_PHASE_STOP
    zx->tape.ear_level   = 1;
    zx->tape.autostarted = 0;
}

// Helper to extract and validate ZX state from userdata
static ZXState *check_zx(lua_State *L) {
    return (ZXState *)luaL_checkudata(L, 1, ZX_EMU_MT);
}

/* --------------------------------------------------------------------------
 * Floating bus approximation (IM2)
 *
 * On real Spectrum hardware, the data bus during interrupt acknowledge is not
 * driven by a peripheral; the returned byte is influenced by the ULA's current
 * memory fetch ("floating bus"). Many games rely on this behavior.
 *
 * We approximate it using current tstates within the frame and the active
 * display screen. This is not cycle-perfect, but it is much closer than a
 * constant 0x00/0xFF.
 * -------------------------------------------------------------------------- */

static inline uint8_t floating_bus_read(ZXState *zx) {
    // Approximate timing:
    // - 312 lines per frame
    // - 224 tstates per line (69888/312)
    // - Display area: 192 lines starting at line 64
    // - Each display line fetches 32 bitmap bytes (256 pixels / 8)
    // - Approximate 1 byte every 4 tstates in the left part of the line
    const uint32_t DISPLAY_START_LINE = 64;
    const uint32_t DISPLAY_LINES      = 192;

    uint32_t t         = zx->tstates % zx->tstates_per_frame;
    uint32_t line      = t / TSTATES_PER_LINE;
    uint32_t t_in_line = t - (line * TSTATES_PER_LINE);

    if (line < DISPLAY_START_LINE || line >= (DISPLAY_START_LINE + DISPLAY_LINES))
        return zx->floating_bus_last;

    uint32_t y = line - DISPLAY_START_LINE; // 0..191

    // Map t_in_line to byte position 0..31.
    // Keep the window small: if outside, behave like border (0xFF).
    uint32_t byte_x = t_in_line / 4;
    if (byte_x >= 32)
        return zx->floating_bus_last;

    // Compute bitmap offset (ZX screen memory is non-linear)
    uint32_t third         = y / 64;
    uint32_t line_in_third = y % 64;
    uint32_t char_row      = line_in_third / 8;
    uint32_t pixel_row     = line_in_third % 8;
    uint32_t offset        = third * 2048 + pixel_row * 256 + char_row * 32 + byte_x;

    // Read from the currently displayed screen bank
    uint8_t *screen_base = zx->ram_banks[5];
    if (zx->machine_type != MACHINE_48K && zx->active_screen)
        screen_base = zx->ram_banks[7];

    zx->floating_bus_last = screen_base[offset];
    return zx->floating_bus_last;
}

// Wrapper that models Z80 EI delayed enable.
static int execute_one(ZXState *zx);
static int execute_one_core(ZXState *zx);

/* --------------------------------------------------------------------------
 * Helper macros for register pairs
 * -------------------------------------------------------------------------- */

#define BC() ((zx->b << 8) | zx->c)
#define DE() ((zx->d << 8) | zx->e)
#define HL() ((zx->h << 8) | zx->l)
#define AF() ((zx->a << 8) | zx->f)
#define IX() (zx->ix)
#define IY() (zx->iy)

#define SET_BC(v)                \
    do {                         \
        uint16_t _v = (v);       \
        zx->b       = _v >> 8;   \
        zx->c       = _v & 0xFF; \
    } while (0)
#define SET_DE(v)                \
    do {                         \
        uint16_t _v = (v);       \
        zx->d       = _v >> 8;   \
        zx->e       = _v & 0xFF; \
    } while (0)
#define SET_HL(v)                \
    do {                         \
        uint16_t _v = (v);       \
        zx->h       = _v >> 8;   \
        zx->l       = _v & 0xFF; \
    } while (0)
#define SET_AF(v)                \
    do {                         \
        uint16_t _v = (v);       \
        zx->a       = _v >> 8;   \
        zx->f       = _v & 0xFF; \
    } while (0)

/* --------------------------------------------------------------------------
 * Memory access (banked for 128k support)
 * -------------------------------------------------------------------------- */

// Update memory mapping based on machine type and port 0x7FFD state
static void update_memory_mapping(ZXState *zx) {
    if (zx->machine_type == MACHINE_48K) {
        // 48k mode: fixed mapping
        // 0x0000-0x3FFF: ROM bank 0
        // 0x4000-0x7FFF: RAM bank 5 (screen)
        // 0x8000-0xBFFF: RAM bank 2
        // 0xC000-0xFFFF: RAM bank 0
        zx->mem_map[0]      = zx->rom_banks[0];
        zx->mem_map[1]      = zx->ram_banks[5];
        zx->mem_map[2]      = zx->ram_banks[2];
        zx->mem_map[3]      = zx->ram_banks[0];
        zx->mem_writable[0] = 0; // ROM is read-only
        zx->mem_writable[1] = 1;
        zx->mem_writable[2] = 1;
        zx->mem_writable[3] = 1;
        zx->active_screen   = 0; // Always bank 5
        return;
    }

    // 128k/+2 memory mapping from port 0x7FFD
    uint8_t ram_page   = zx->port_7ffd & 0x07;     // Bits 0-2: RAM page at 0xC000
    uint8_t screen_sel = (zx->port_7ffd >> 3) & 1; // Bit 3: screen select
    uint8_t rom_sel    = (zx->port_7ffd >> 4) & 1; // Bit 4: ROM select

    // Region 0 (0x0000-0x3FFF): ROM (switchable)
    zx->mem_map[0]      = zx->rom_banks[rom_sel];
    zx->mem_writable[0] = 0; // ROM is read-only

    // Region 1 (0x4000-0x7FFF): Always RAM bank 5 (normal screen)
    zx->mem_map[1]      = zx->ram_banks[5];
    zx->mem_writable[1] = 1;

    // Region 2 (0x8000-0xBFFF): Always RAM bank 2
    zx->mem_map[2]      = zx->ram_banks[2];
    zx->mem_writable[2] = 1;

    // Region 3 (0xC000-0xFFFF): Switchable RAM bank (0-7)
    zx->mem_map[3]      = zx->ram_banks[ram_page];
    zx->mem_writable[3] = 1;

    // Active screen (0 = bank 5, 1 = bank 7)
    // Mark screen dirty when switching display buffer
    if (zx->active_screen != screen_sel) {
        zx->screen_dirty = 1;
        zx->screen_switch_count++;
    }
    zx->active_screen = screen_sel;
}

static inline uint8_t mem_read(ZXState *zx, uint16_t addr) {
    uint8_t region  = addr >> 14; // 0-3 (16KB regions)
    uint16_t offset = addr & 0x3FFF;
    return zx->mem_map[region][offset];
}

static inline void mem_write(ZXState *zx, uint16_t addr, uint8_t value) {
    uint8_t region = addr >> 14; // 0-3 (16KB regions)

    // Check write protection (ROM regions)
    if (__builtin_expect(!zx->mem_writable[region], 0)) {
        return;
    }

    uint16_t offset             = addr & 0x3FFF;
    zx->mem_map[region][offset] = value;

    // Debug: track writes to the current IM2 vector page (I:00..FF).
    // This helps identify cases where the IM2 table is never initialized or
    // gets overwritten.
    if (zx->im == 2 && ((addr >> 8) == zx->i)) {
        zx->im2_page_write_count++;
        zx->im2_last_write_addr = addr;
        zx->im2_last_write_val  = value;
    }

    // Mark screen dirty if writing to screen memory area
    // Bank 5 (normal screen) is always at region 1 (0x4000-0x7FFF)
    if (region == 1 && offset < SCREEN_SIZE) {
        zx->screen_dirty = 1;
    }
    // Bank 7 (shadow screen) can be at region 3 (0xC000-0xFFFF) when paged in
    if (region == 3 && offset < SCREEN_SIZE && zx->machine_type != MACHINE_48K && (zx->port_7ffd & 0x07) == 7) {
        zx->screen_dirty = 1;
    }
}

static inline uint16_t mem_read16(ZXState *zx, uint16_t addr) {
    return (uint16_t)(mem_read(zx, addr) | ((uint16_t)mem_read(zx, (uint16_t)(addr + 1)) << 8));
}

static inline void mem_write16(ZXState *zx, uint16_t addr, uint16_t value) {
    mem_write(zx, addr, (uint8_t)(value & 0xFF));
    mem_write(zx, (uint16_t)(addr + 1), (uint8_t)(value >> 8));
}

// Fetch next byte at PC and increment PC
static inline uint8_t fetch8(ZXState *zx) {
    return mem_read(zx, zx->pc++);
}

// Fetch next word at PC and increment PC by 2
static inline uint16_t fetch16(ZXState *zx) {
    uint16_t val = mem_read16(zx, zx->pc);
    zx->pc += 2;
    return val;
}

/* --------------------------------------------------------------------------
 * Stack operations
 * -------------------------------------------------------------------------- */

static inline void push16(ZXState *zx, uint16_t value) {
    zx->sp -= 2;
    mem_write16(zx, zx->sp, value);
}

static inline uint16_t pop16(ZXState *zx) {
    uint16_t val = mem_read16(zx, zx->sp);
    zx->sp += 2;
    return val;
}

/* --------------------------------------------------------------------------
 * Flag helpers
 * -------------------------------------------------------------------------- */

// Parity lookup table (even parity = 1)
static const uint8_t parity_table[256] = {
    1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1,
    0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 1, 0,
    0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0,
    1, 0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1,
    0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 1,
    0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1,
    1, 0, 0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1};

static inline uint8_t sz_flags(uint8_t value) {
    return (value & FLAG_S) | (value == 0 ? FLAG_Z : 0);
}

static inline uint8_t szp_flags(uint8_t value) {
    return sz_flags(value) | (parity_table[value] ? FLAG_PV : 0);
}

/* --------------------------------------------------------------------------
 * Tape (TAP) playback (EAR input)
 *
 * We emulate the EAR line as a simple pulse stream derived from TAP blocks.
 * The Spectrum ROM loader measures pulse widths, so timing matters.
 * -------------------------------------------------------------------------- */

enum {
    TAPE_PHASE_STOP = 0,
    TAPE_PHASE_PILOT,
    TAPE_PHASE_SYNC1,
    TAPE_PHASE_SYNC2,
    TAPE_PHASE_DATA,
    TAPE_PHASE_PAUSE,
};

static void tape_free_state(ZXState *zx) {
    if (!zx)
        return;
    if (zx->tape.blocks) {
        for (int i = 0; i < zx->tape.block_count; i++) {
            free(zx->tape.blocks[i].data);
        }
        free(zx->tape.blocks);
    }
    zx->tape.blocks      = NULL;
    zx->tape.block_count = 0;
    zx->tape.loaded      = 0;
    zx->tape_active      = 0;
}

static void tape_rewind(ZXState *zx) {
    if (!zx)
        return;
    zx->tape.block_idx    = 0;
    zx->tape.byte_idx     = 0;
    zx->tape.bit_idx      = 0;
    zx->tape.ear_level    = 1;
    zx->tape.tstates_rem  = 0;
    zx->tape.pilot_rem    = 0;
    zx->tape.phase        = TAPE_PHASE_STOP;
    zx->tape.pulse_in_bit = 0;
    zx->tape.autostarted  = 0;
}

static inline int tape_current_bit(ZXState *zx);

static inline int tape_block_at_end(ZXState *zx) {
    if (zx->tape.block_idx >= zx->tape.block_count)
        return 1;
    uint16_t len = zx->tape.blocks[zx->tape.block_idx].len;
    uint8_t used = zx->tape.blocks[zx->tape.block_idx].used_bits_last;
    if (used == 0)
        used = 8;
    if (len == 0)
        return 1;
    if (zx->tape.byte_idx > (int)(len - 1))
        return 1;
    if (zx->tape.byte_idx == (int)(len - 1) && zx->tape.bit_idx >= (int)used)
        return 1;
    return 0;
}

static inline void tape_start_block(ZXState *zx) {
    if (zx->tape.block_idx >= zx->tape.block_count) {
        zx->tape.playing   = 0;
        zx->tape_active    = 0;
        zx->tape.phase     = TAPE_PHASE_STOP;
        // No active tape signal; real machines read EAR high by default.
        zx->tape.ear_level = 1;
        return;
    }

    zx->tape.byte_idx     = 0;
    zx->tape.bit_idx      = 0;
    zx->tape.pulse_in_bit = 0;

    // Set starting level for this block; first pulse toggles it.
    if (zx->tape.blocks[zx->tape.block_idx].start_level_set)
        zx->tape.ear_level = zx->tape.blocks[zx->tape.block_idx].start_level ? 1 : 0;
    else
        zx->tape.ear_level = 1;

    uint16_t blen          = zx->tape.blocks[zx->tape.block_idx].len;
    uint16_t pause_ms      = zx->tape.blocks[zx->tape.block_idx].pause_ms;
    uint8_t has_pilot_sync = zx->tape.blocks[zx->tape.block_idx].has_pilot_sync;

    // Pause-only block
    if (blen == 0 && pause_ms > 0) {
        zx->tape.phase       = TAPE_PHASE_PAUSE;
        zx->tape.ear_level   = 0;
        zx->tape.tstates_rem = (int32_t)pause_ms * 3500;
        return;
    }

    // Pause=0 in a pause-only block means "stop the tape".
    if (blen == 0 && pause_ms == 0) {
        zx->tape.playing   = 0;
        zx->tape_active    = 0;
        zx->tape.phase     = TAPE_PHASE_STOP;
        zx->tape.ear_level = 1;
        return;
    }

    if (!has_pilot_sync) {
        // Pure data block (no pilot/sync)
        zx->tape.phase        = TAPE_PHASE_DATA;
        zx->tape.pulse_in_bit = 0;
        int bit               = tape_current_bit(zx);
        uint16_t p0 = zx->tape.blocks[zx->tape.block_idx].bit0_len ? zx->tape.blocks[zx->tape.block_idx].bit0_len : 855;
        uint16_t p1 =
            zx->tape.blocks[zx->tape.block_idx].bit1_len ? zx->tape.blocks[zx->tape.block_idx].bit1_len : 1710;
        zx->tape.tstates_rem = bit ? p1 : p0;
        return;
    }

    // Pilot pulse count depends on block type (header vs data) unless turbo block specifies it.
    if (zx->tape.blocks[zx->tape.block_idx].is_turbo) {
        zx->tape.pilot_rem = zx->tape.blocks[zx->tape.block_idx].pilot_pulses;
    } else {
        uint8_t flag       = blen ? zx->tape.blocks[zx->tape.block_idx].data[0] : 0xFF;
        zx->tape.pilot_rem = (flag < 0x80) ? 8063 : 3223;
    }

    uint16_t pilot_len = zx->tape.blocks[zx->tape.block_idx].pilot_len;
    if (!pilot_len)
        pilot_len = 2168;

    if (zx->tape.pilot_rem <= 0) {
        zx->tape.phase       = TAPE_PHASE_SYNC1;
        uint16_t s1          = zx->tape.blocks[zx->tape.block_idx].sync1_len;
        zx->tape.tstates_rem = s1 ? s1 : 667;
        return;
    }

    zx->tape.phase       = TAPE_PHASE_PILOT;
    zx->tape.tstates_rem = pilot_len;
}

static inline int tape_current_bit(ZXState *zx) {
    if (zx->tape.block_idx >= zx->tape.block_count)
        return 0;
    if (tape_block_at_end(zx))
        return 0;
    uint16_t len = zx->tape.blocks[zx->tape.block_idx].len;
    uint8_t b    = zx->tape.blocks[zx->tape.block_idx].data[zx->tape.byte_idx];
    return (b >> (7 - zx->tape.bit_idx)) & 1;
}

static void tape_advance_after_pulse(ZXState *zx) {
    switch (zx->tape.phase) {
    case TAPE_PHASE_PILOT:
        zx->tape.pilot_rem--;
        if (zx->tape.pilot_rem <= 0) {
            zx->tape.phase       = TAPE_PHASE_SYNC1;
            uint16_t s1          = zx->tape.blocks[zx->tape.block_idx].sync1_len;
            zx->tape.tstates_rem = s1 ? s1 : 667;
        } else {
            uint16_t pl          = zx->tape.blocks[zx->tape.block_idx].pilot_len;
            zx->tape.tstates_rem = pl ? pl : 2168;
        }
        break;

    case TAPE_PHASE_SYNC1:
        zx->tape.phase = TAPE_PHASE_SYNC2;
        {
            uint16_t s2          = zx->tape.blocks[zx->tape.block_idx].sync2_len;
            zx->tape.tstates_rem = s2 ? s2 : 735;
        }
        break;

    case TAPE_PHASE_SYNC2:
        zx->tape.phase        = TAPE_PHASE_DATA;
        zx->tape.pulse_in_bit = 0;
        {
            uint16_t p0 = zx->tape.blocks[zx->tape.block_idx].bit0_len;
            uint16_t p1 = zx->tape.blocks[zx->tape.block_idx].bit1_len;
            if (!p0)
                p0 = 855;
            if (!p1)
                p1 = 1710;
            zx->tape.tstates_rem = tape_current_bit(zx) ? p1 : p0;
        }
        break;

    case TAPE_PHASE_DATA: {
        // Two pulses per bit
        if (zx->tape.pulse_in_bit == 0) {
            zx->tape.pulse_in_bit = 1;
            uint16_t p0           = zx->tape.blocks[zx->tape.block_idx].bit0_len;
            uint16_t p1           = zx->tape.blocks[zx->tape.block_idx].bit1_len;
            if (!p0)
                p0 = 855;
            if (!p1)
                p1 = 1710;
            zx->tape.tstates_rem = tape_current_bit(zx) ? p1 : p0;
            break;
        }

        // Move to next bit
        zx->tape.pulse_in_bit = 0;
        zx->tape.bit_idx++;
        uint8_t used = zx->tape.blocks[zx->tape.block_idx].used_bits_last;
        if (used == 0)
            used = 8;
        if (zx->tape.byte_idx == (int)(zx->tape.blocks[zx->tape.block_idx].len - 1)) {
            if (zx->tape.bit_idx >= used) {
                zx->tape.bit_idx = used;
                zx->tape.byte_idx++;
            }
        } else {
            if (zx->tape.bit_idx >= 8) {
                zx->tape.bit_idx = 0;
                zx->tape.byte_idx++;
            }
        }

        // End of block -> pause then next block
        if (zx->tape.byte_idx >= zx->tape.blocks[zx->tape.block_idx].len) {
            zx->tape.phase = TAPE_PHASE_PAUSE;

            uint16_t pause_ms = zx->tape.blocks[zx->tape.block_idx].pause_ms;
            uint8_t pause_def = zx->tape.blocks[zx->tape.block_idx].pause_defined;

            if (pause_def) {
                // TZX blocks define pause explicitly; 0 means no pause.
                if (pause_ms > 0)
                    zx->tape.ear_level = 0;
                zx->tape.tstates_rem = (int32_t)pause_ms * 3500;
            } else {
                // TAP does not encode an explicit pause duration.
                // A long 1s pause is realistic, but it makes the loader feel stuck
                // (especially between header+data). Use a short inter-block gap.
                zx->tape.ear_level = 0;
                if (zx->tape.block_idx + 1 < zx->tape.block_count)
                    zx->tape.tstates_rem = 200000; // ~57ms
                else
                    zx->tape.tstates_rem = 3500000; // ~1s after final block
            }
        } else {
            uint16_t p0 = zx->tape.blocks[zx->tape.block_idx].bit0_len;
            uint16_t p1 = zx->tape.blocks[zx->tape.block_idx].bit1_len;
            if (!p0)
                p0 = 855;
            if (!p1)
                p1 = 1710;
            zx->tape.tstates_rem = tape_current_bit(zx) ? p1 : p0;
        }
    } break;

    default:
        break;
    }
}

/* --------------------------------------------------------------------------
 * Audio sampling
 * -------------------------------------------------------------------------- */

// Forward declarations for AY chip
static void ay_tick(ZXState *zx, int tstates);
static int16_t ay_generate_sample(ZXState *zx);

// Sample audio at ~44100 Hz (beeper + AY + optional tape monitor)
static inline void audio_tick(ZXState *zx, int tstates) {
    // Update AY chip state first
    ay_tick(zx, tstates);

    zx->audio_phase_accum += (uint64_t)tstates * (uint64_t)AUDIO_SAMPLE_RATE;

    // Emit one sample for each CPU_CLOCK / AUDIO_SAMPLE_RATE t-states (exact on average)
    while (zx->audio_phase_accum >= (uint64_t)CPU_CLOCK) {
        zx->audio_phase_accum -= (uint64_t)CPU_CLOCK;

        if (zx->audio_sample_idx < AUDIO_SAMPLES_PER_FRAME) {
            // Beeper sample (ULA bit 4)
            int16_t beeper = zx->beeper_state ? 8192 : -8192;

            // AY sample (128k only, returns 0 for 48k)
            int16_t ay = ay_generate_sample(zx);

            // Tape monitor (EAR pulses) for loading sound
            int16_t tape = 0;
            if (zx->tape_audio_enabled && zx->tape_active)
                tape = zx->tape.ear_level ? zx->tape_audio_amp : (int16_t)-zx->tape_audio_amp;

            int32_t mixed = (int32_t)beeper + (int32_t)ay + (int32_t)tape;

            // Soft clip to prevent harsh distortion
            if (mixed > 24000)
                mixed = 24000;
            if (mixed < -24000)
                mixed = -24000;

            zx->audio_buffer[zx->audio_sample_idx++] = (int16_t)mixed;
        }
    }
}

static inline void tape_tick(ZXState *zx, int tstates) {
    // Use cached flag instead of checking two fields every instruction
    if (!zx->tape_active)
        return;

    // The ROM loader expects the tape stream to begin at the start of a block.
    // If playback started while we were already running, ensure we've kicked
    // the state machine once.
    if (!zx->tape.autostarted) {
        zx->tape.autostarted = 1;
        if (zx->tape.phase == TAPE_PHASE_STOP)
            tape_start_block(zx);
    }

    while (tstates > 0) {
        if (zx->tape.phase == TAPE_PHASE_STOP) {
            tape_start_block(zx);
            if (zx->tape.phase == TAPE_PHASE_STOP)
                return;
        }

        if (zx->tape.phase == TAPE_PHASE_PAUSE) {
            if (tstates < zx->tape.tstates_rem) {
                zx->tape.tstates_rem -= tstates;
                return;
            }
            tstates -= zx->tape.tstates_rem;
            zx->tape.tstates_rem = 0;
            zx->tape.block_idx++;
            tape_start_block(zx);
            continue;
        }

        if (zx->tape.tstates_rem <= 0) {
            // Shouldn't happen, but recover.
            zx->tape.tstates_rem = 1;
        }

        if (tstates < zx->tape.tstates_rem) {
            zx->tape.tstates_rem -= tstates;
            return;
        }

        tstates -= zx->tape.tstates_rem;
        zx->tape.tstates_rem = 0;

        // Toggle EAR level on each pulse edge.
        zx->tape.ear_level ^= 1;

        tape_advance_after_pulse(zx);
    }
}

/* --------------------------------------------------------------------------
 * AY-3-8912 Sound Chip Emulation
 * -------------------------------------------------------------------------- */

// AY volume table (approximates the non-linear DAC response)
static const uint8_t ay_vol_table[16] = {0, 1, 2, 3, 5, 7, 10, 15, 22, 31, 44, 63, 90, 127, 180, 255};

static uint8_t ay_read_register(ZXState *zx) {
    if (zx->ay.selected_reg > 15)
        return 0xFF;
    return zx->ay.regs[zx->ay.selected_reg];
}

static void ay_write_register(ZXState *zx, uint8_t value) {
    uint8_t reg = zx->ay.selected_reg;
    if (reg > 15)
        return;

    // Apply register masks (some registers use fewer bits)
    switch (reg) {
    case AY_REG_A_TONE_H:
    case AY_REG_B_TONE_H:
    case AY_REG_C_TONE_H:
        value &= 0x0F; // 4-bit tone high
        break;
    case AY_REG_NOISE:
        value &= 0x1F; // 5-bit noise period
        break;
    case AY_REG_MIXER:
        // All 8 bits used (6 for mixer, 2 for I/O direction)
        break;
    case AY_REG_A_VOL:
    case AY_REG_B_VOL:
    case AY_REG_C_VOL:
        value &= 0x1F; // 5-bit (bit 4 = envelope mode)
        break;
    case AY_REG_ENV_SHAPE:
        value &= 0x0F; // 4-bit envelope shape
        // Writing to envelope shape restarts the envelope
        zx->ay.env_counter = 0;
        zx->ay.env_step    = 0;
        zx->ay.env_holding = 0;
        // Decode attack direction from shape
        zx->ay.env_attack  = (value & 0x04) ? 1 : 0;
        break;
    }

    zx->ay.regs[reg] = value;
}

static uint8_t ay_get_envelope_volume(ZXState *zx) {
    uint8_t vol = zx->ay.env_step;
    if (!zx->ay.env_attack)
        vol = 15 - vol;
    return vol;
}

static void ay_update_envelope(ZXState *zx) {
    if (zx->ay.env_holding)
        return;

    uint16_t period = zx->ay.regs[AY_REG_ENV_L] | (zx->ay.regs[AY_REG_ENV_H] << 8);
    if (period == 0)
        period = 1;

    if (++zx->ay.env_counter >= period) {
        zx->ay.env_counter = 0;
        zx->ay.env_step++;

        if (zx->ay.env_step >= 16) {
            // End of envelope cycle
            uint8_t shape = zx->ay.regs[AY_REG_ENV_SHAPE];

            if (!(shape & 0x08)) {
                // Shapes 0-7: single decay/attack then hold at 0
                zx->ay.env_holding = 1;
                zx->ay.env_step    = 0;
            } else if (shape & 0x01) {
                // Hold at final level
                zx->ay.env_holding = 1;
                zx->ay.env_step    = (shape & 0x02) ? (zx->ay.env_attack ? 15 : 0) : (zx->ay.env_attack ? 0 : 15);
            } else {
                // Repeat
                zx->ay.env_step = 0;
                if (shape & 0x02) {
                    // Alternate direction
                    zx->ay.env_attack ^= 1;
                }
            }
        }
    }
}

// AY clock tick: updates tone, noise, and envelope generators
static void ay_tick(ZXState *zx, int tstates) {
    if (zx->machine_type == MACHINE_48K)
        return;

    zx->ay.tstates_accum += tstates;

    while (zx->ay.tstates_accum >= AY_CLOCK_DIVIDER) {
        zx->ay.tstates_accum -= AY_CLOCK_DIVIDER;

        // Update tone counters (3 channels)
        for (int ch = 0; ch < 3; ch++) {
            uint16_t period = zx->ay.regs[ch * 2] | ((zx->ay.regs[ch * 2 + 1] & 0x0F) << 8);
            if (period == 0)
                period = 1;

            if (++zx->ay.tone_counters[ch] >= period) {
                zx->ay.tone_counters[ch] = 0;
                zx->ay.tone_outputs[ch] ^= 1;
            }
        }

        // Update noise counter
        uint8_t noise_period = zx->ay.regs[AY_REG_NOISE] & 0x1F;
        if (noise_period == 0)
            noise_period = 1;

        if (++zx->ay.noise_counter >= noise_period) {
            zx->ay.noise_counter = 0;
            // 17-bit LFSR: feedback from bits 0 and 3
            uint8_t feedback     = ((zx->ay.noise_shift & 1) ^ ((zx->ay.noise_shift >> 3) & 1));
            zx->ay.noise_shift   = (zx->ay.noise_shift >> 1) | (feedback << 16);
            zx->ay.noise_output  = zx->ay.noise_shift & 1;
        }

        // Update envelope (runs at 1/16 of tone rate)
        if (++zx->ay.env_div >= 16) {
            zx->ay.env_div = 0;
            ay_update_envelope(zx);
        }
    }
}

// Generate one AY audio sample
static int16_t ay_generate_sample(ZXState *zx) {
    if (zx->machine_type == MACHINE_48K)
        return 0;

    uint8_t mixer  = zx->ay.regs[AY_REG_MIXER];
    int32_t output = 0;

    for (int ch = 0; ch < 3; ch++) {
        // Check if tone and noise are enabled for this channel
        // Note: In mixer register, 0 = enabled, 1 = disabled
        uint8_t tone_enable  = !((mixer >> ch) & 1);
        uint8_t noise_enable = !((mixer >> (ch + 3)) & 1);

        // Channel is audible when (tone OR disabled) AND (noise OR disabled)
        // This matches real AY behavior where disabled acts as "always high"
        uint8_t tone_out  = tone_enable ? zx->ay.tone_outputs[ch] : 1;
        uint8_t noise_out = noise_enable ? zx->ay.noise_output : 1;
        uint8_t audible   = tone_out & noise_out;

        if (audible) {
            // Get volume (fixed or envelope)
            uint8_t vol_reg = zx->ay.regs[AY_REG_A_VOL + ch];
            uint8_t vol;

            if (vol_reg & 0x10) {
                // Envelope mode
                vol = ay_get_envelope_volume(zx);
            } else {
                // Fixed volume (0-15)
                vol = vol_reg & 0x0F;
            }

            output += ay_vol_table[vol];
        }
    }

    // Scale to 16-bit range (3 channels max ~765)
    // Normalize to ~6000 to leave headroom for beeper mixing
    return (int16_t)((output * 6000) / 765);
}

/* --------------------------------------------------------------------------
 * I/O Port handling
 * -------------------------------------------------------------------------- */

static uint8_t port_read(ZXState *zx, uint16_t port) {
    // ULA port (active low on A0)
    if ((port & 0x01) == 0) {
        // Bits 0-4: keyboard (active low)
        // Bit 6: EAR input
        // Other bits typically read high.
        uint8_t result = 0xFF;

        // Keyboard: each bit in high byte selects a half-row
        for (int row = 0; row < 8; row++) {
            if (!(port & (1 << (row + 8)))) {
                result &= zx->keyboard_rows[row];
            }
        }
        // On real hardware bits 5 and 7 typically read high.
        // Bit 6 is EAR input (must reflect the tape level, not forced high).
        result |= 0xA0; // bits 7 and 5

        if (zx->tape.ear_level)
            result |= 0x40;
        else
            result &= (uint8_t)~0x40;

        zx->keyboard_reads++;
        return result;
    }

    // Kempston joystick (port 0x1F) - return 0 (no buttons pressed)
    if ((port & 0xFF) == 0x1F) {
        return 0x00;
    }

    // AY-3-8912 register read (128k only)
    // Port 0xFFFD: Read selected register (A15=1, A14=1, A1=0)
    if (zx->machine_type != MACHINE_48K && (port & 0xC002) == 0xC000) {
        return ay_read_register(zx);
    }

    // Unhandled ports: return floating bus value
    // On real hardware, unhandled port reads return whatever the ULA is
    // currently reading from video RAM. Many games use this for timing
    // synchronization (e.g., waiting for a specific scan line).
    return floating_bus_read(zx);
}

static void port_write(ZXState *zx, uint16_t port, uint8_t value) {
    // ULA port (active low on A0)
    if ((port & 0x01) == 0) {
        uint8_t new_border = value & 0x07;

        // Track border changes per-scanline during tape playback
        // This enables the characteristic loading stripe visualization
        if (zx->tape_active && new_border != zx->border_color) {
            uint32_t line = zx->tstates / TSTATES_PER_LINE;
            if (line < SCANLINES_PER_FRAME) {
                // Fill from current line to end of frame with new color
                // (subsequent changes will overwrite as needed)
                memset(&zx->border_scanlines[line], new_border, SCANLINES_PER_FRAME - line);
            }
        }

        zx->border_color = new_border;
        zx->beeper_state = (value >> 4) & 0x01;
        // MIC output is bit 3, we ignore it
        return;
    }

    // 128k memory paging port (0x7FFD)
    // Real hardware is partially decoded, but the key property is low byte 0xFD
    // with A15=0 and A1=0. Using an overly broad decode here can accidentally
    // treat unrelated OUTs as paging writes and permanently lock paging (bit 5).
    if (zx->machine_type != MACHINE_48K && (port & 0x8002) == 0x0000 && (port & 0x00FF) == 0x00FD) {
        if (!zx->paging_disabled) {
            zx->port_7ffd       = value;
            zx->paging_disabled = (value >> 5) & 1; // Bit 5 locks paging
            zx->port_7ffd_write_count++;
            update_memory_mapping(zx);
        }
        return;
    }

    // AY-3-8912 sound chip ports (128k only)
    // Decoding: A15=1, A1=0 (matches 0xFFFD, 0xBFFD, etc.)
    if (zx->machine_type != MACHINE_48K && (port & 0x8002) == 0x8000) {
        if ((port & 0x4000) == 0x4000) {
            // Port 0xFFFD: Register select (A14=1)
            zx->ay.selected_reg = value & 0x0F;
        } else {
            // Port 0xBFFD: Data write (A14=0)
            ay_write_register(zx, value);
        }
        return;
    }
}

/* --------------------------------------------------------------------------
 * Z80 Instructions
 *
 * Comprehensive Z80 CPU implementation including all documented opcodes and
 * commonly-used undocumented opcodes (IXH/IXL/IYH/IYL operations, ED 70/71,
 * SLL, etc.). Opcodes are organized by prefix:
 *   - Unprefixed (main table)
 *   - CB prefix (bit operations)
 *   - DD prefix (IX operations)
 *   - FD prefix (IY operations)
 *   - ED prefix (extended operations)
 * -------------------------------------------------------------------------- */

// Forward declarations for prefixed instruction handlers
static int execute_cb(ZXState *zx);
static int execute_dd(ZXState *zx);
static int execute_fd(ZXState *zx);
static int execute_ed(ZXState *zx);

// ALU operations
//
// Most instruction code reads more naturally when it can just call `alu_add(a,b,0)`
// without explicitly threading the current emulator instance. We keep the
// per-instance state in a local variable named `zx` in all opcode handlers, so
// we implement the ALU helpers as *_impl() functions and provide macros that
// implicitly pass that `zx`.
static inline uint8_t alu_add_impl(ZXState *zx, uint8_t a, uint8_t b, uint8_t carry) {
    uint16_t result = a + b + carry;
    uint8_t r8      = result & 0xFF;

    zx->f = sz_flags(r8);
    if (result > 0xFF)
        zx->f |= FLAG_C;
    if ((a ^ b ^ r8) & 0x10)
        zx->f |= FLAG_H;
    if (((a ^ ~b) & (a ^ r8)) & 0x80)
        zx->f |= FLAG_PV;

    return r8;
}

static inline uint8_t alu_sub_impl(ZXState *zx, uint8_t a, uint8_t b, uint8_t carry) {
    uint16_t result = a - b - carry;
    uint8_t r8      = result & 0xFF;

    zx->f = sz_flags(r8) | FLAG_N;
    if (result > 0xFF)
        zx->f |= FLAG_C;
    if ((a ^ b ^ r8) & 0x10)
        zx->f |= FLAG_H;
    if (((a ^ b) & (a ^ r8)) & 0x80)
        zx->f |= FLAG_PV;

    return r8;
}

static inline void alu_cp_impl(ZXState *zx, uint8_t a, uint8_t b) {
    alu_sub_impl(zx, a, b, 0); // CP is SUB without storing result
}

static inline uint8_t alu_and_impl(ZXState *zx, uint8_t a, uint8_t b) {
    uint8_t result = a & b;
    zx->f          = szp_flags(result) | FLAG_H;
    return result;
}

static inline uint8_t alu_or_impl(ZXState *zx, uint8_t a, uint8_t b) {
    uint8_t result = a | b;
    zx->f          = szp_flags(result);
    return result;
}

static inline uint8_t alu_xor_impl(ZXState *zx, uint8_t a, uint8_t b) {
    uint8_t result = a ^ b;
    zx->f          = szp_flags(result);
    return result;
}

static inline uint8_t alu_inc_impl(ZXState *zx, uint8_t val) {
    uint8_t result = val + 1;
    zx->f          = (zx->f & FLAG_C) | sz_flags(result);
    if ((val & 0x0F) == 0x0F)
        zx->f |= FLAG_H;
    if (val == 0x7F)
        zx->f |= FLAG_PV;
    return result;
}

static inline uint8_t alu_dec_impl(ZXState *zx, uint8_t val) {
    uint8_t result = val - 1;
    zx->f          = (zx->f & FLAG_C) | sz_flags(result) | FLAG_N;
    if ((val & 0x0F) == 0x00)
        zx->f |= FLAG_H;
    if (val == 0x80)
        zx->f |= FLAG_PV;
    return result;
}

// 16-bit ADD HL, rr
static inline void alu_add16_impl(ZXState *zx, uint16_t *dest, uint16_t val) {
    uint32_t result = *dest + val;
    zx->f           = (zx->f & (FLAG_S | FLAG_Z | FLAG_PV));
    if (result > 0xFFFF)
        zx->f |= FLAG_C;
    if (((*dest ^ val ^ result) >> 8) & 0x10)
        zx->f |= FLAG_H;
    *dest = result & 0xFFFF;
}

static inline void alu_sbc_hl_impl(ZXState *zx, uint16_t val) {
    uint16_t hl   = HL();
    uint8_t carry = (zx->f & FLAG_C) ? 1 : 0;
    uint32_t full = (uint32_t)hl - (uint32_t)val - carry;
    uint16_t res  = (uint16_t)full;

    uint8_t f = FLAG_N;

    // Carry flag acts as borrow for SBC (borrow if result underflowed).
    if (full & 0xFFFF0000)
        f |= FLAG_C;

    // Half-borrow from bit 11 (use 32-bit to avoid overflow).
    if ((uint32_t)(hl & 0x0FFF) < (uint32_t)(val & 0x0FFF) + carry)
        f |= FLAG_H;

    // Signed overflow.
    if (((hl ^ val) & (hl ^ res) & 0x8000) != 0)
        f |= FLAG_PV;

    if (res == 0)
        f |= FLAG_Z;
    if (res & 0x8000)
        f |= FLAG_S;

    // Undocumented flags: copy bits 3 and 5 from high byte.
    f |= (uint8_t)((res >> 8) & 0x28);

    SET_HL(res);
    zx->f = f;
}

static inline void alu_adc_hl_impl(ZXState *zx, uint16_t val) {
    uint16_t hl   = HL();
    uint8_t carry = (zx->f & FLAG_C) ? 1 : 0;
    uint32_t full = (uint32_t)hl + (uint32_t)val + carry;
    uint16_t res  = (uint16_t)full;

    uint8_t f = 0;

    if (full > 0xFFFF)
        f |= FLAG_C;

    if (((hl & 0x0FFF) + (val & 0x0FFF) + carry) > 0x0FFF)
        f |= FLAG_H;

    if (((~(hl ^ val)) & (hl ^ res) & 0x8000) != 0)
        f |= FLAG_PV;

    if (res == 0)
        f |= FLAG_Z;
    if (res & 0x8000)
        f |= FLAG_S;

    f |= (uint8_t)((res >> 8) & 0x28);

    SET_HL(res);
    zx->f = f;
}

#define alu_add(a, b, c) alu_add_impl(zx, (a), (b), (c))
#define alu_sub(a, b, c) alu_sub_impl(zx, (a), (b), (c))
#define alu_cp(a, b)     alu_cp_impl(zx, (a), (b))
#define alu_and(a, b)    alu_and_impl(zx, (a), (b))
#define alu_or(a, b)     alu_or_impl(zx, (a), (b))
#define alu_xor(a, b)    alu_xor_impl(zx, (a), (b))
#define alu_inc(v)       alu_inc_impl(zx, (v))
#define alu_dec(v)       alu_dec_impl(zx, (v))
#define alu_add16(d, v)  alu_add16_impl(zx, (d), (v))
#define alu_sbc_hl(v)    alu_sbc_hl_impl(zx, (v))
#define alu_adc_hl(v)    alu_adc_hl_impl(zx, (v))

// Execute one instruction, return T-states consumed
static int execute_one_core(ZXState *zx) {
    // If CPU is halted, it keeps consuming cycles until an interrupt arrives.
    // PC stays pointing at the next instruction.
    if (zx->halted) {
        zx->pc_history[zx->pc_history_idx] = zx->pc;
        zx->pc_history_idx                 = (zx->pc_history_idx + 1) & 0x0F;
        zx->r                              = (zx->r & 0x80) | ((zx->r + 1) & 0x7F);
        return 4;
    }

    // Record PC history before fetching
    zx->pc_history[zx->pc_history_idx] = zx->pc;
    zx->pc_history_idx                 = (zx->pc_history_idx + 1) & 0x0F;

    uint8_t opcode  = fetch8(zx);
    zx->last_opcode = opcode;                                // Save for EI delay check
    zx->r           = (zx->r & 0x80) | ((zx->r + 1) & 0x7F); // Increment R register

    // DD/FD prefixes are part of the ROM hot loop (e.g. FD CB d op).
    // If we treat them as unknown opcodes, the PC won't advance correctly.
    if (opcode == 0xDD)
        return execute_dd(zx);

    if (opcode == 0xFD)
        return execute_fd(zx);

    switch (opcode) {
    // NOP
    case 0x00:
        return 4;

    // LD BC, nn
    case 0x01:
        SET_BC(fetch16(zx));
        return 10;

    // LD (BC), A
    case 0x02:
        mem_write(zx, BC(), zx->a);
        return 7;

    // INC BC
    case 0x03:
        SET_BC(BC() + 1);
        return 6;

    // INC B
    case 0x04:
        zx->b = alu_inc(zx->b);
        return 4;

    // DEC B
    case 0x05:
        zx->b = alu_dec(zx->b);
        return 4;

    // LD B, n
    case 0x06:
        zx->b = fetch8(zx);
        return 7;

    // RLCA
    case 0x07: {
        uint8_t c = zx->a >> 7;
        zx->a     = (zx->a << 1) | c;
        zx->f     = (zx->f & (FLAG_S | FLAG_Z | FLAG_PV)) | c | (zx->a & 0x28);
        return 4;
    }

    // EX AF, AF'
    case 0x08: {
        uint8_t t = zx->a;
        zx->a     = zx->a_;
        zx->a_    = t;
        t         = zx->f;
        zx->f     = zx->f_;
        zx->f_    = t;
        return 4;
    }

    // ADD HL, BC
    case 0x09: {
        uint16_t hl = HL();
        alu_add16(&hl, BC());
        SET_HL(hl);
        return 11;
    }

    // LD A, (BC)
    case 0x0A:
        zx->a = mem_read(zx, BC());
        return 7;

    // DEC BC
    case 0x0B:
        SET_BC(BC() - 1);
        return 6;

    // INC C
    case 0x0C:
        zx->c = alu_inc(zx->c);
        return 4;

    // DEC C
    case 0x0D:
        zx->c = alu_dec(zx->c);
        return 4;

    // LD C, n
    case 0x0E:
        zx->c = fetch8(zx);
        return 7;

    // RRCA
    case 0x0F: {
        uint8_t c = zx->a & 0x01;
        zx->a     = (zx->a >> 1) | (c << 7);
        zx->f     = (zx->f & (FLAG_S | FLAG_Z | FLAG_PV)) | c | (zx->a & 0x28);
        return 4;
    }

    // DJNZ d
    case 0x10: {
        int8_t offset = (int8_t)fetch8(zx);
        zx->b--;
        if (zx->b != 0) {
            zx->pc += offset;
            return 13;
        }
        return 8;
    }

    // LD DE, nn
    case 0x11:
        SET_DE(fetch16(zx));
        return 10;

    // LD (DE), A
    case 0x12:
        mem_write(zx, DE(), zx->a);
        return 7;

    // INC DE
    case 0x13:
        SET_DE(DE() + 1);
        return 6;

    // INC D
    case 0x14:
        zx->d = alu_inc(zx->d);
        return 4;

    // DEC D
    case 0x15:
        zx->d = alu_dec(zx->d);
        return 4;

    // LD D, n
    case 0x16:
        zx->d = fetch8(zx);
        return 7;

    // RLA
    case 0x17: {
        uint8_t old_c = zx->f & FLAG_C;
        uint8_t new_c = zx->a >> 7;
        zx->a         = (zx->a << 1) | old_c;
        zx->f         = (zx->f & (FLAG_S | FLAG_Z | FLAG_PV)) | new_c | (zx->a & 0x28);
        return 4;
    }

    // JR d
    case 0x18: {
        int8_t offset = (int8_t)fetch8(zx);
        zx->pc += offset;
        return 12;
    }

    // ADD HL, DE
    case 0x19: {
        uint16_t hl = HL();
        alu_add16(&hl, DE());
        SET_HL(hl);
        return 11;
    }

    // LD A, (DE)
    case 0x1A:
        zx->a = mem_read(zx, DE());
        return 7;

    // DEC DE
    case 0x1B:
        SET_DE(DE() - 1);
        return 6;

    // INC E
    case 0x1C:
        zx->e = alu_inc(zx->e);
        return 4;

    // DEC E
    case 0x1D:
        zx->e = alu_dec(zx->e);
        return 4;

    // LD E, n
    case 0x1E:
        zx->e = fetch8(zx);
        return 7;

    // RRA
    case 0x1F: {
        uint8_t old_c = zx->f & FLAG_C;
        uint8_t new_c = zx->a & 0x01;
        zx->a         = (zx->a >> 1) | (old_c << 7);
        zx->f         = (zx->f & (FLAG_S | FLAG_Z | FLAG_PV)) | new_c | (zx->a & 0x28);
        return 4;
    }

    // JR NZ, d
    case 0x20: {
        int8_t offset = (int8_t)fetch8(zx);
        if (!(zx->f & FLAG_Z)) {
            zx->pc += offset;
            return 12;
        }
        return 7;
    }

    // LD HL, nn
    case 0x21:
        SET_HL(fetch16(zx));
        return 10;

    // LD (nn), HL
    case 0x22: {
        uint16_t addr = fetch16(zx);
        mem_write16(zx, addr, HL());
        return 16;
    }

    // INC HL
    case 0x23:
        SET_HL(HL() + 1);
        return 6;

    // INC H
    case 0x24:
        zx->h = alu_inc(zx->h);
        return 4;

    // DEC H
    case 0x25:
        zx->h = alu_dec(zx->h);
        return 4;

    // LD H, n
    case 0x26:
        zx->h = fetch8(zx);
        return 7;

    // DAA - Decimal Adjust Accumulator
    // Adjusts A for BCD arithmetic after ADD/ADC/SUB/SBC
    case 0x27: {
        uint8_t a          = zx->a;
        uint8_t correction = 0;
        uint8_t carry      = 0;
        uint8_t half_carry = 0;

        // Determine the correction based on current flags and A value
        if ((a & 0x0F) > 9 || (zx->f & FLAG_H)) {
            correction |= 0x06;
        }
        if (a > 0x99 || (zx->f & FLAG_C)) {
            correction |= 0x60;
            carry = FLAG_C;
        }

        if (zx->f & FLAG_N) {
            // After subtraction: subtract the correction
            zx->a = a - correction;
            // H flag is set if there was a half-borrow from bit 4
            // This happens when the low nibble needed correction AND
            // the original low nibble was less than 6
            if ((zx->f & FLAG_H) && (a & 0x0F) < 6) {
                half_carry = FLAG_H;
            }
        } else {
            // After addition: add the correction
            zx->a = a + correction;
            // H flag is set if the low nibble correction caused a carry
            // from bit 3 to bit 4 (i.e., if adding 6 made it wrap)
            if ((a & 0x0F) > 9) {
                half_carry = FLAG_H;
            }
        }

        zx->f = (zx->f & FLAG_N) | carry | half_carry | szp_flags(zx->a);
        return 4;
    }

    // JR Z, d
    case 0x28: {
        int8_t offset = (int8_t)fetch8(zx);
        if (zx->f & FLAG_Z) {
            zx->pc += offset;
            return 12;
        }
        return 7;
    }

    // ADD HL, HL
    case 0x29: {
        uint16_t hl = HL();
        alu_add16(&hl, HL());
        SET_HL(hl);
        return 11;
    }

    // LD HL, (nn)
    case 0x2A: {
        uint16_t addr = fetch16(zx);
        SET_HL(mem_read16(zx, addr));
        return 16;
    }

    // DEC HL
    case 0x2B:
        SET_HL(HL() - 1);
        return 6;

    // INC L
    case 0x2C:
        zx->l = alu_inc(zx->l);
        return 4;

    // DEC L
    case 0x2D:
        zx->l = alu_dec(zx->l);
        return 4;

    // LD L, n
    case 0x2E:
        zx->l = fetch8(zx);
        return 7;

    // CPL
    case 0x2F:
        zx->a = ~zx->a;
        zx->f |= FLAG_H | FLAG_N;
        return 4;

    // JR NC, d
    case 0x30: {
        int8_t offset = (int8_t)fetch8(zx);
        if (!(zx->f & FLAG_C)) {
            zx->pc += offset;
            return 12;
        }
        return 7;
    }

    // LD SP, nn
    case 0x31:
        zx->sp = fetch16(zx);
        return 10;

    // LD (nn), A
    case 0x32: {
        uint16_t addr = fetch16(zx);
        mem_write(zx, addr, zx->a);
        return 13;
    }

    // INC SP
    case 0x33:
        zx->sp++;
        return 6;

    // INC (HL)
    case 0x34:
        mem_write(zx, HL(), alu_inc(mem_read(zx, HL())));
        return 11;

    // DEC (HL)
    case 0x35:
        mem_write(zx, HL(), alu_dec(mem_read(zx, HL())));
        return 11;

    // LD (HL), n
    case 0x36:
        mem_write(zx, HL(), fetch8(zx));
        return 10;

    // SCF - Set Carry Flag
    // C=1, N=0, H=0, S/Z/PV unchanged
    // Undocumented: bits 3 and 5 come from A
    case 0x37:
        zx->f = (zx->f & (FLAG_S | FLAG_Z | FLAG_PV)) | FLAG_C | (zx->a & 0x28);
        return 4;

    // JR C, d
    case 0x38: {
        int8_t offset = (int8_t)fetch8(zx);
        if (zx->f & FLAG_C) {
            zx->pc += offset;
            return 12;
        }
        return 7;
    }

    // ADD HL, SP
    case 0x39: {
        uint16_t hl = HL();
        alu_add16(&hl, zx->sp);
        SET_HL(hl);
        return 11;
    }

    // LD A, (nn)
    case 0x3A: {
        uint16_t addr = fetch16(zx);
        zx->a         = mem_read(zx, addr);
        return 13;
    }

    // DEC SP
    case 0x3B:
        zx->sp--;
        return 6;

    // INC A
    case 0x3C:
        zx->a = alu_inc(zx->a);
        return 4;

    // DEC A
    case 0x3D:
        zx->a = alu_dec(zx->a);
        return 4;

    // LD A, n
    case 0x3E:
        zx->a = fetch8(zx);
        return 7;

    // CCF - Complement Carry Flag
    // C=~C, N=0, H=previous C, S/Z/PV unchanged
    // Undocumented: bits 3 and 5 come from A
    case 0x3F: {
        uint8_t old_c = zx->f & FLAG_C;
        zx->f         = (zx->f & (FLAG_S | FLAG_Z | FLAG_PV)) | (old_c ? FLAG_H : FLAG_C) | (zx->a & 0x28);
        return 4;
    }

    // LD B, B through LD A, A (0x40-0x7F except HALT)
    // LD r, r' instructions - 8x8 matrix
    case 0x40:
        return 4; // LD B, B
    case 0x41:
        zx->b = zx->c;
        return 4;
    case 0x42:
        zx->b = zx->d;
        return 4;
    case 0x43:
        zx->b = zx->e;
        return 4;
    case 0x44:
        zx->b = zx->h;
        return 4;
    case 0x45:
        zx->b = zx->l;
        return 4;
    case 0x46:
        zx->b = mem_read(zx, HL());
        return 7;
    case 0x47:
        zx->b = zx->a;
        return 4;

    case 0x48:
        zx->c = zx->b;
        return 4;
    case 0x49:
        return 4; // LD C, C
    case 0x4A:
        zx->c = zx->d;
        return 4;
    case 0x4B:
        zx->c = zx->e;
        return 4;
    case 0x4C:
        zx->c = zx->h;
        return 4;
    case 0x4D:
        zx->c = zx->l;
        return 4;
    case 0x4E:
        zx->c = mem_read(zx, HL());
        return 7;
    case 0x4F:
        zx->c = zx->a;
        return 4;

    case 0x50:
        zx->d = zx->b;
        return 4;
    case 0x51:
        zx->d = zx->c;
        return 4;
    case 0x52:
        return 4; // LD D, D
    case 0x53:
        zx->d = zx->e;
        return 4;
    case 0x54:
        zx->d = zx->h;
        return 4;
    case 0x55:
        zx->d = zx->l;
        return 4;
    case 0x56:
        zx->d = mem_read(zx, HL());
        return 7;
    case 0x57:
        zx->d = zx->a;
        return 4;

    case 0x58:
        zx->e = zx->b;
        return 4;
    case 0x59:
        zx->e = zx->c;
        return 4;
    case 0x5A:
        zx->e = zx->d;
        return 4;
    case 0x5B:
        return 4; // LD E, E
    case 0x5C:
        zx->e = zx->h;
        return 4;
    case 0x5D:
        zx->e = zx->l;
        return 4;
    case 0x5E:
        zx->e = mem_read(zx, HL());
        return 7;
    case 0x5F:
        zx->e = zx->a;
        return 4;

    case 0x60:
        zx->h = zx->b;
        return 4;
    case 0x61:
        zx->h = zx->c;
        return 4;
    case 0x62:
        zx->h = zx->d;
        return 4;
    case 0x63:
        zx->h = zx->e;
        return 4;
    case 0x64:
        return 4; // LD H, H
    case 0x65:
        zx->h = zx->l;
        return 4;
    case 0x66:
        zx->h = mem_read(zx, HL());
        return 7;
    case 0x67:
        zx->h = zx->a;
        return 4;

    case 0x68:
        zx->l = zx->b;
        return 4;
    case 0x69:
        zx->l = zx->c;
        return 4;
    case 0x6A:
        zx->l = zx->d;
        return 4;
    case 0x6B:
        zx->l = zx->e;
        return 4;
    case 0x6C:
        zx->l = zx->h;
        return 4;
    case 0x6D:
        return 4; // LD L, L
    case 0x6E:
        zx->l = mem_read(zx, HL());
        return 7;
    case 0x6F:
        zx->l = zx->a;
        return 4;

    case 0x70:
        mem_write(zx, HL(), zx->b);
        return 7;
    case 0x71:
        mem_write(zx, HL(), zx->c);
        return 7;
    case 0x72:
        mem_write(zx, HL(), zx->d);
        return 7;
    case 0x73:
        mem_write(zx, HL(), zx->e);
        return 7;
    case 0x74:
        mem_write(zx, HL(), zx->h);
        return 7;
    case 0x75:
        mem_write(zx, HL(), zx->l);
        return 7;

    // HALT
    case 0x76:
        zx->halted = 1;
        return 4;

    case 0x77:
        mem_write(zx, HL(), zx->a);
        return 7;

    case 0x78:
        zx->a = zx->b;
        return 4;
    case 0x79:
        zx->a = zx->c;
        return 4;
    case 0x7A:
        zx->a = zx->d;
        return 4;
    case 0x7B:
        zx->a = zx->e;
        return 4;
    case 0x7C:
        zx->a = zx->h;
        return 4;
    case 0x7D:
        zx->a = zx->l;
        return 4;
    case 0x7E:
        zx->a = mem_read(zx, HL());
        return 7;
    case 0x7F:
        return 4; // LD A, A

    // ADD A, r (0x80-0x87)
    case 0x80:
        zx->a = alu_add(zx->a, zx->b, 0);
        return 4;
    case 0x81:
        zx->a = alu_add(zx->a, zx->c, 0);
        return 4;
    case 0x82:
        zx->a = alu_add(zx->a, zx->d, 0);
        return 4;
    case 0x83:
        zx->a = alu_add(zx->a, zx->e, 0);
        return 4;
    case 0x84:
        zx->a = alu_add(zx->a, zx->h, 0);
        return 4;
    case 0x85:
        zx->a = alu_add(zx->a, zx->l, 0);
        return 4;
    case 0x86:
        zx->a = alu_add(zx->a, mem_read(zx, HL()), 0);
        return 7;
    case 0x87:
        zx->a = alu_add(zx->a, zx->a, 0);
        return 4;

    // ADC A, r (0x88-0x8F)
    case 0x88:
        zx->a = alu_add(zx->a, zx->b, zx->f & FLAG_C ? 1 : 0);
        return 4;
    case 0x89:
        zx->a = alu_add(zx->a, zx->c, zx->f & FLAG_C ? 1 : 0);
        return 4;
    case 0x8A:
        zx->a = alu_add(zx->a, zx->d, zx->f & FLAG_C ? 1 : 0);
        return 4;
    case 0x8B:
        zx->a = alu_add(zx->a, zx->e, zx->f & FLAG_C ? 1 : 0);
        return 4;
    case 0x8C:
        zx->a = alu_add(zx->a, zx->h, zx->f & FLAG_C ? 1 : 0);
        return 4;
    case 0x8D:
        zx->a = alu_add(zx->a, zx->l, zx->f & FLAG_C ? 1 : 0);
        return 4;
    case 0x8E:
        zx->a = alu_add(zx->a, mem_read(zx, HL()), zx->f & FLAG_C ? 1 : 0);
        return 7;
    case 0x8F:
        zx->a = alu_add(zx->a, zx->a, zx->f & FLAG_C ? 1 : 0);
        return 4;

    // SUB r (0x90-0x97)
    case 0x90:
        zx->a = alu_sub(zx->a, zx->b, 0);
        return 4;
    case 0x91:
        zx->a = alu_sub(zx->a, zx->c, 0);
        return 4;
    case 0x92:
        zx->a = alu_sub(zx->a, zx->d, 0);
        return 4;
    case 0x93:
        zx->a = alu_sub(zx->a, zx->e, 0);
        return 4;
    case 0x94:
        zx->a = alu_sub(zx->a, zx->h, 0);
        return 4;
    case 0x95:
        zx->a = alu_sub(zx->a, zx->l, 0);
        return 4;
    case 0x96:
        zx->a = alu_sub(zx->a, mem_read(zx, HL()), 0);
        return 7;
    case 0x97:
        zx->a = alu_sub(zx->a, zx->a, 0);
        return 4;

    // SBC A, r (0x98-0x9F)
    case 0x98:
        zx->a = alu_sub(zx->a, zx->b, zx->f & FLAG_C ? 1 : 0);
        return 4;
    case 0x99:
        zx->a = alu_sub(zx->a, zx->c, zx->f & FLAG_C ? 1 : 0);
        return 4;
    case 0x9A:
        zx->a = alu_sub(zx->a, zx->d, zx->f & FLAG_C ? 1 : 0);
        return 4;
    case 0x9B:
        zx->a = alu_sub(zx->a, zx->e, zx->f & FLAG_C ? 1 : 0);
        return 4;
    case 0x9C:
        zx->a = alu_sub(zx->a, zx->h, zx->f & FLAG_C ? 1 : 0);
        return 4;
    case 0x9D:
        zx->a = alu_sub(zx->a, zx->l, zx->f & FLAG_C ? 1 : 0);
        return 4;
    case 0x9E:
        zx->a = alu_sub(zx->a, mem_read(zx, HL()), zx->f & FLAG_C ? 1 : 0);
        return 7;
    case 0x9F:
        zx->a = alu_sub(zx->a, zx->a, zx->f & FLAG_C ? 1 : 0);
        return 4;

    // AND r (0xA0-0xA7)
    case 0xA0:
        zx->a = alu_and(zx->a, zx->b);
        return 4;
    case 0xA1:
        zx->a = alu_and(zx->a, zx->c);
        return 4;
    case 0xA2:
        zx->a = alu_and(zx->a, zx->d);
        return 4;
    case 0xA3:
        zx->a = alu_and(zx->a, zx->e);
        return 4;
    case 0xA4:
        zx->a = alu_and(zx->a, zx->h);
        return 4;
    case 0xA5:
        zx->a = alu_and(zx->a, zx->l);
        return 4;
    case 0xA6:
        zx->a = alu_and(zx->a, mem_read(zx, HL()));
        return 7;
    case 0xA7:
        zx->a = alu_and(zx->a, zx->a);
        return 4;

    // XOR r (0xA8-0xAF)
    case 0xA8:
        zx->a = alu_xor(zx->a, zx->b);
        return 4;
    case 0xA9:
        zx->a = alu_xor(zx->a, zx->c);
        return 4;
    case 0xAA:
        zx->a = alu_xor(zx->a, zx->d);
        return 4;
    case 0xAB:
        zx->a = alu_xor(zx->a, zx->e);
        return 4;
    case 0xAC:
        zx->a = alu_xor(zx->a, zx->h);
        return 4;
    case 0xAD:
        zx->a = alu_xor(zx->a, zx->l);
        return 4;
    case 0xAE:
        zx->a = alu_xor(zx->a, mem_read(zx, HL()));
        return 7;
    case 0xAF:
        zx->a = alu_xor(zx->a, zx->a);
        return 4;

    // OR r (0xB0-0xB7)
    case 0xB0:
        zx->a = alu_or(zx->a, zx->b);
        return 4;
    case 0xB1:
        zx->a = alu_or(zx->a, zx->c);
        return 4;
    case 0xB2:
        zx->a = alu_or(zx->a, zx->d);
        return 4;
    case 0xB3:
        zx->a = alu_or(zx->a, zx->e);
        return 4;
    case 0xB4:
        zx->a = alu_or(zx->a, zx->h);
        return 4;
    case 0xB5:
        zx->a = alu_or(zx->a, zx->l);
        return 4;
    case 0xB6:
        zx->a = alu_or(zx->a, mem_read(zx, HL()));
        return 7;
    case 0xB7:
        zx->a = alu_or(zx->a, zx->a);
        return 4;

    // CP r (0xB8-0xBF)
    case 0xB8:
        alu_cp(zx->a, zx->b);
        return 4;
    case 0xB9:
        alu_cp(zx->a, zx->c);
        return 4;
    case 0xBA:
        alu_cp(zx->a, zx->d);
        return 4;
    case 0xBB:
        alu_cp(zx->a, zx->e);
        return 4;
    case 0xBC:
        alu_cp(zx->a, zx->h);
        return 4;
    case 0xBD:
        alu_cp(zx->a, zx->l);
        return 4;
    case 0xBE:
        alu_cp(zx->a, mem_read(zx, HL()));
        return 7;
    case 0xBF:
        alu_cp(zx->a, zx->a);
        return 4;

    // RET NZ
    case 0xC0:
        if (!(zx->f & FLAG_Z)) {
            zx->pc = pop16(zx);
            return 11;
        }
        return 5;

    // POP BC
    case 0xC1:
        SET_BC(pop16(zx));
        return 10;

    // JP NZ, nn
    case 0xC2: {
        uint16_t addr = fetch16(zx);
        if (!(zx->f & FLAG_Z)) {
            zx->pc = addr;
        }
        return 10;
    }

    // JP nn
    case 0xC3:
        zx->pc = fetch16(zx);
        return 10;

    // CALL NZ, nn
    case 0xC4: {
        uint16_t addr = fetch16(zx);
        if (!(zx->f & FLAG_Z)) {
            push16(zx, zx->pc);
            zx->pc = addr;
            return 17;
        }
        return 10;
    }

    // PUSH BC
    case 0xC5:
        push16(zx, BC());
        return 11;

    // ADD A, n
    case 0xC6:
        zx->a = alu_add(zx->a, fetch8(zx), 0);
        return 7;

    // RST 00h
    case 0xC7:
        push16(zx, zx->pc);
        zx->pc = 0x0000;
        return 11;

    // RET Z
    case 0xC8:
        if (zx->f & FLAG_Z) {
            zx->pc = pop16(zx);
            return 11;
        }
        return 5;

    // RET
    case 0xC9:
        zx->pc = pop16(zx);
        return 10;

    // JP Z, nn
    case 0xCA: {
        uint16_t addr = fetch16(zx);
        if (zx->f & FLAG_Z) {
            zx->pc = addr;
        }
        return 10;
    }

    // CB prefix
    case 0xCB:
        return execute_cb(zx);

    // CALL Z, nn
    case 0xCC: {
        uint16_t addr = fetch16(zx);
        if (zx->f & FLAG_Z) {
            push16(zx, zx->pc);
            zx->pc = addr;
            return 17;
        }
        return 10;
    }

    // CALL nn
    case 0xCD: {
        uint16_t addr = fetch16(zx);
        push16(zx, zx->pc);
        zx->pc = addr;
        return 17;
    }

    // ADC A, n
    case 0xCE:
        zx->a = alu_add(zx->a, fetch8(zx), zx->f & FLAG_C ? 1 : 0);
        return 7;

    // RST 08h
    case 0xCF:
        push16(zx, zx->pc);
        zx->pc = 0x0008;
        return 11;

    // RET NC
    case 0xD0:
        if (!(zx->f & FLAG_C)) {
            zx->pc = pop16(zx);
            return 11;
        }
        return 5;

    // POP DE
    case 0xD1:
        SET_DE(pop16(zx));
        return 10;

    // JP NC, nn
    case 0xD2: {
        uint16_t addr = fetch16(zx);
        if (!(zx->f & FLAG_C)) {
            zx->pc = addr;
        }
        return 10;
    }

    // OUT (n), A
    case 0xD3: {
        uint8_t port_low = fetch8(zx);
        port_write(zx, (zx->a << 8) | port_low, zx->a);
        return 11;
    }

    // CALL NC, nn
    case 0xD4: {
        uint16_t addr = fetch16(zx);
        if (!(zx->f & FLAG_C)) {
            push16(zx, zx->pc);
            zx->pc = addr;
            return 17;
        }
        return 10;
    }

    // PUSH DE
    case 0xD5:
        push16(zx, DE());
        return 11;

    // SUB n
    case 0xD6:
        zx->a = alu_sub(zx->a, fetch8(zx), 0);
        return 7;

    // RST 10h
    case 0xD7:
        push16(zx, zx->pc);
        zx->pc = 0x0010;
        return 11;

    // RET C
    case 0xD8:
        if (zx->f & FLAG_C) {
            zx->pc = pop16(zx);
            return 11;
        }
        return 5;

    // EXX
    case 0xD9: {
        uint8_t t;
        t      = zx->b;
        zx->b  = zx->b_;
        zx->b_ = t;
        t      = zx->c;
        zx->c  = zx->c_;
        zx->c_ = t;
        t      = zx->d;
        zx->d  = zx->d_;
        zx->d_ = t;
        t      = zx->e;
        zx->e  = zx->e_;
        zx->e_ = t;
        t      = zx->h;
        zx->h  = zx->h_;
        zx->h_ = t;
        t      = zx->l;
        zx->l  = zx->l_;
        zx->l_ = t;
        return 4;
    }

    // JP C, nn
    case 0xDA: {
        uint16_t addr = fetch16(zx);
        if (zx->f & FLAG_C) {
            zx->pc = addr;
        }
        return 10;
    }

    // IN A, (n)
    case 0xDB: {
        uint8_t port_low   = fetch8(zx);
        uint16_t port      = (zx->a << 8) | port_low;
        zx->a              = port_read(zx, port);
        zx->last_in_port   = port;
        zx->last_in_result = zx->a;
        return 11;
    }

    // CALL C, nn
    case 0xDC: {
        uint16_t addr = fetch16(zx);
        if (zx->f & FLAG_C) {
            push16(zx, zx->pc);
            zx->pc = addr;
            return 17;
        }
        return 10;
    }

    // Note: 0xDD and 0xFD are handled before the switch statement
    // to properly support multi-byte sequences like "FD CB d op"

    // SBC A, n
    case 0xDE:
        zx->a = alu_sub(zx->a, fetch8(zx), zx->f & FLAG_C ? 1 : 0);
        return 7;

    // RST 18h
    case 0xDF:
        push16(zx, zx->pc);
        zx->pc = 0x0018;
        return 11;

    // RET PO
    case 0xE0:
        if (!(zx->f & FLAG_PV)) {
            zx->pc = pop16(zx);
            return 11;
        }
        return 5;

    // POP HL
    case 0xE1:
        SET_HL(pop16(zx));
        return 10;

    // JP PO, nn
    case 0xE2: {
        uint16_t addr = fetch16(zx);
        if (!(zx->f & FLAG_PV)) {
            zx->pc = addr;
        }
        return 10;
    }

    // EX (SP), HL
    case 0xE3: {
        uint16_t tmp = mem_read16(zx, zx->sp);
        mem_write16(zx, zx->sp, HL());
        SET_HL(tmp);
        return 19;
    }

    // CALL PO, nn
    case 0xE4: {
        uint16_t addr = fetch16(zx);
        if (!(zx->f & FLAG_PV)) {
            push16(zx, zx->pc);
            zx->pc = addr;
            return 17;
        }
        return 10;
    }

    // PUSH HL
    case 0xE5:
        push16(zx, HL());
        return 11;

    // AND n
    case 0xE6:
        zx->a = alu_and(zx->a, fetch8(zx));
        return 7;

    // RST 20h
    case 0xE7:
        push16(zx, zx->pc);
        zx->pc = 0x0020;
        return 11;

    // RET PE
    case 0xE8:
        if (zx->f & FLAG_PV) {
            zx->pc = pop16(zx);
            return 11;
        }
        return 5;

    // JP (HL)
    case 0xE9:
        zx->pc = HL();
        return 4;

    // JP PE, nn
    case 0xEA: {
        uint16_t addr = fetch16(zx);
        if (zx->f & FLAG_PV) {
            zx->pc = addr;
        }
        return 10;
    }

    // EX DE, HL
    case 0xEB: {
        uint16_t tmp = DE();
        SET_DE(HL());
        SET_HL(tmp);
        return 4;
    }

    // CALL PE, nn
    case 0xEC: {
        uint16_t addr = fetch16(zx);
        if (zx->f & FLAG_PV) {
            push16(zx, zx->pc);
            zx->pc = addr;
            return 17;
        }
        return 10;
    }

    // ED prefix
    case 0xED:
        return execute_ed(zx);

    // XOR n
    case 0xEE:
        zx->a = alu_xor(zx->a, fetch8(zx));
        return 7;

    // RST 28h
    case 0xEF:
        push16(zx, zx->pc);
        zx->pc = 0x0028;
        return 11;

    // RET P
    case 0xF0:
        if (!(zx->f & FLAG_S)) {
            zx->pc = pop16(zx);
            return 11;
        }
        return 5;

    // POP AF
    case 0xF1:
        SET_AF(pop16(zx));
        return 10;

    // JP P, nn
    case 0xF2: {
        uint16_t addr = fetch16(zx);
        if (!(zx->f & FLAG_S)) {
            zx->pc = addr;
        }
        return 10;
    }

    // DI
    case 0xF3:
        zx->iff1 = zx->iff2 = 0;
        zx->ei_delay        = 0;
        return 4;

    // CALL P, nn
    case 0xF4: {
        uint16_t addr = fetch16(zx);
        if (!(zx->f & FLAG_S)) {
            push16(zx, zx->pc);
            zx->pc = addr;
            return 17;
        }
        return 10;
    }

    // PUSH AF
    case 0xF5:
        push16(zx, AF());
        return 11;

    // OR n
    case 0xF6:
        zx->a = alu_or(zx->a, fetch8(zx));
        return 7;

    // RST 30h
    case 0xF7:
        push16(zx, zx->pc);
        zx->pc = 0x0030;
        return 11;

    // RET M
    case 0xF8:
        if (zx->f & FLAG_S) {
            zx->pc = pop16(zx);
            return 11;
        }
        return 5;

    // LD SP, HL
    case 0xF9:
        zx->sp = HL();
        return 6;

    // JP M, nn
    case 0xFA: {
        uint16_t addr = fetch16(zx);
        if (zx->f & FLAG_S) {
            zx->pc = addr;
        }
        return 10;
    }

    // EI (interrupts are enabled after the *next* instruction)
    case 0xFB:
        zx->ei_delay = 1;
        return 4;

    // CALL M, nn
    case 0xFC: {
        uint16_t addr = fetch16(zx);
        if (zx->f & FLAG_S) {
            push16(zx, zx->pc);
            zx->pc = addr;
            return 17;
        }
        return 10;
    }

    // CP n
    case 0xFE:
        alu_cp(zx->a, fetch8(zx));
        return 7;

    // RST 38h
    case 0xFF:
        push16(zx, zx->pc);
        zx->pc = 0x0038;
        return 11;

    default:
        // Unknown opcode - treat as NOP
        return 4;
    }
}

/* --------------------------------------------------------------------------
 * CB-prefixed instructions (bit operations)
 * -------------------------------------------------------------------------- */

// Helper to get/set register by index (0=B, 1=C, 2=D, 3=E, 4=H, 5=L, 6=(HL), 7=A)
static uint8_t get_reg(ZXState *zx, int idx) {
    switch (idx) {
    case 0:
        return zx->b;
    case 1:
        return zx->c;
    case 2:
        return zx->d;
    case 3:
        return zx->e;
    case 4:
        return zx->h;
    case 5:
        return zx->l;
    case 6:
        return mem_read(zx, HL());
    case 7:
        return zx->a;
    default:
        return 0;
    }
}

static void set_reg(ZXState *zx, int idx, uint8_t val) {
    switch (idx) {
    case 0:
        zx->b = val;
        break;
    case 1:
        zx->c = val;
        break;
    case 2:
        zx->d = val;
        break;
    case 3:
        zx->e = val;
        break;
    case 4:
        zx->h = val;
        break;
    case 5:
        zx->l = val;
        break;
    case 6:
        mem_write(zx, HL(), val);
        break;
    case 7:
        zx->a = val;
        break;
    }
}

static int execute_cb(ZXState *zx) {
    uint8_t opcode = fetch8(zx);
    int reg        = opcode & 0x07;
    int bit        = (opcode >> 3) & 0x07;
    int tstates    = (reg == 6) ? 15 : 8;

    uint8_t val = get_reg(zx, reg);

    switch (opcode & 0xC0) {
    case 0x00: // Rotate/shift operations
        switch (bit) {
        case 0: // RLC
            zx->f = (val >> 7);
            val   = (val << 1) | (val >> 7);
            zx->f |= szp_flags(val);
            break;
        case 1: // RRC
            zx->f = val & 0x01;
            val   = (val >> 1) | (val << 7);
            zx->f |= szp_flags(val);
            break;
        case 2: // RL
        {
            uint8_t c = zx->f & FLAG_C;
            zx->f     = val >> 7;
            val       = (val << 1) | c;
            zx->f |= szp_flags(val);
        } break;
        case 3: // RR
        {
            uint8_t c = zx->f & FLAG_C;
            zx->f     = val & 0x01;
            val       = (val >> 1) | (c << 7);
            zx->f |= szp_flags(val);
        } break;
        case 4: // SLA
            zx->f = val >> 7;
            val   = val << 1;
            zx->f |= szp_flags(val);
            break;
        case 5: // SRA
            zx->f = val & 0x01;
            val   = (val >> 1) | (val & 0x80);
            zx->f |= szp_flags(val);
            break;
        case 6: // SLL (undocumented)
            zx->f = val >> 7;
            val   = (val << 1) | 0x01;
            zx->f |= szp_flags(val);
            break;
        case 7: // SRL
            zx->f = val & 0x01;
            val   = val >> 1;
            zx->f |= szp_flags(val);
            break;
        }
        set_reg(zx, reg, val);
        break;

    case 0x40: // BIT
        zx->f = (zx->f & FLAG_C) | FLAG_H;
        if (!(val & (1 << bit)))
            zx->f |= FLAG_Z | FLAG_PV;
        if (bit == 7 && (val & 0x80))
            zx->f |= FLAG_S;
        // Undocumented: bits 3 and 5 come from the tested value
        zx->f |= (val & 0x28);
        tstates = (reg == 6) ? 12 : 8;
        break;

    case 0x80: // RES
        set_reg(zx, reg, (uint8_t)(val & ~(1 << bit)));
        break;

    case 0xC0: // SET
        set_reg(zx, reg, (uint8_t)(val | (1 << bit)));
        break;
    }

    return tstates;
}

/* --------------------------------------------------------------------------
 * ED-prefixed instructions (extended operations)
 * -------------------------------------------------------------------------- */

static int execute_ed(ZXState *zx) {
    uint8_t opcode = fetch8(zx);

    switch (opcode) {
    // IN r, (C)
    case 0x40:
        zx->b = port_read(zx, BC());
        zx->f = (zx->f & FLAG_C) | szp_flags(zx->b);
        return 12;
    case 0x48:
        zx->c = port_read(zx, BC());
        zx->f = (zx->f & FLAG_C) | szp_flags(zx->c);
        return 12;
    case 0x50:
        zx->d = port_read(zx, BC());
        zx->f = (zx->f & FLAG_C) | szp_flags(zx->d);
        return 12;
    case 0x58:
        zx->e = port_read(zx, BC());
        zx->f = (zx->f & FLAG_C) | szp_flags(zx->e);
        return 12;
    case 0x60:
        zx->h = port_read(zx, BC());
        zx->f = (zx->f & FLAG_C) | szp_flags(zx->h);
        return 12;
    case 0x68:
        zx->l = port_read(zx, BC());
        zx->f = (zx->f & FLAG_C) | szp_flags(zx->l);
        return 12;
    case 0x78: {
        uint16_t port      = BC();
        zx->a              = port_read(zx, port);
        zx->f              = (zx->f & FLAG_C) | szp_flags(zx->a);
        zx->last_in_port   = port;
        zx->last_in_result = zx->a;
        return 12;
    }

    // OUT (C), r
    case 0x41:
        port_write(zx, BC(), zx->b);
        return 12;
    case 0x49:
        port_write(zx, BC(), zx->c);
        return 12;
    case 0x51:
        port_write(zx, BC(), zx->d);
        return 12;
    case 0x59:
        port_write(zx, BC(), zx->e);
        return 12;
    case 0x61:
        port_write(zx, BC(), zx->h);
        return 12;
    case 0x69:
        port_write(zx, BC(), zx->l);
        return 12;
    case 0x79:
        port_write(zx, BC(), zx->a);
        return 12;

    // SBC HL, rr
    case 0x42:
        alu_sbc_hl(BC());
        return 15;
    case 0x52:
        alu_sbc_hl(DE());
        return 15;
    case 0x62:
        alu_sbc_hl(HL());
        return 15;
    case 0x72:
        alu_sbc_hl(zx->sp);
        return 15;

    // ADC HL, rr
    case 0x4A:
        alu_adc_hl(BC());
        return 15;
    case 0x5A:
        alu_adc_hl(DE());
        return 15;
    case 0x6A:
        alu_adc_hl(HL());
        return 15;
    case 0x7A:
        alu_adc_hl(zx->sp);
        return 15;

    // LD (nn), rr
    case 0x43: {
        uint16_t addr = fetch16(zx);
        mem_write16(zx, addr, BC());
        return 20;
    }
    case 0x53: {
        uint16_t addr = fetch16(zx);
        mem_write16(zx, addr, DE());
        return 20;
    }
    case 0x63: {
        uint16_t addr = fetch16(zx);
        mem_write16(zx, addr, HL());
        return 20;
    }
    case 0x73: {
        uint16_t addr = fetch16(zx);
        mem_write16(zx, addr, zx->sp);
        return 20;
    }

    // LD rr, (nn)
    case 0x4B: {
        uint16_t addr = fetch16(zx);
        SET_BC(mem_read16(zx, addr));
        return 20;
    }
    case 0x5B: {
        uint16_t addr = fetch16(zx);
        SET_DE(mem_read16(zx, addr));
        return 20;
    }
    case 0x6B: {
        uint16_t addr = fetch16(zx);
        SET_HL(mem_read16(zx, addr));
        return 20;
    }
    case 0x7B: {
        uint16_t addr = fetch16(zx);
        zx->sp        = mem_read16(zx, addr);
        return 20;
    }

    // NEG
    case 0x44:
    case 0x4C:
    case 0x54:
    case 0x5C:
    case 0x64:
    case 0x6C:
    case 0x74:
    case 0x7C:
        zx->a = alu_sub(0, zx->a, 0);
        return 8;

    // RETN - restore IFF1 from IFF2 before returning
    case 0x45:
    case 0x55:
    case 0x5D:
    case 0x65:
    case 0x6D:
    case 0x75:
    case 0x7D:
        zx->iff1 = zx->iff2;
        zx->pc   = pop16(zx);
        return 14;

    // RETI - also restore IFF1 from IFF2
    case 0x4D:
        zx->iff1 = zx->iff2;
        zx->pc   = pop16(zx);
        return 14;

    // IM 0/1/2 (including undocumented mirrors)
    case 0x46:
    case 0x4E: // undocumented mirror
    case 0x66:
    case 0x6E: // undocumented mirror
        zx->im = 0;
        return 8;
    case 0x56:
    case 0x76:
        zx->im = 1;
        return 8;
    case 0x5E:
    case 0x7E:
        zx->im = 2;
        return 8;

    // LD I, A
    case 0x47:
        zx->i = zx->a;
        return 9;

    // LD R, A
    case 0x4F:
        zx->r = zx->a;
        return 9;

    // LD A, I
    case 0x57:
        zx->a = zx->i;
        zx->f = (zx->f & FLAG_C) | sz_flags(zx->a) | (zx->iff2 ? FLAG_PV : 0);
        return 9;

    // LD A, R
    case 0x5F:
        zx->a = zx->r;
        zx->f = (zx->f & FLAG_C) | sz_flags(zx->a) | (zx->iff2 ? FLAG_PV : 0);
        return 9;

    // RRD
    case 0x67: {
        uint8_t hl_val = mem_read(zx, HL());
        uint8_t new_hl = (zx->a << 4) | (hl_val >> 4);
        zx->a          = (zx->a & 0xF0) | (hl_val & 0x0F);
        mem_write(zx, HL(), new_hl);
        zx->f = (zx->f & FLAG_C) | szp_flags(zx->a);
        return 18;
    }

    // RLD
    case 0x6F: {
        uint8_t hl_val = mem_read(zx, HL());
        uint8_t new_hl = (hl_val << 4) | (zx->a & 0x0F);
        zx->a          = (zx->a & 0xF0) | (hl_val >> 4);
        mem_write(zx, HL(), new_hl);
        zx->f = (zx->f & FLAG_C) | szp_flags(zx->a);
        return 18;
    }

    // LDI
    case 0xA0: {
        uint8_t val = mem_read(zx, HL());
        mem_write(zx, DE(), val);
        SET_HL(HL() + 1);
        SET_DE(DE() + 1);
        SET_BC(BC() - 1);
        // Flags: H=0, N=0, PV=BC!=0, S/Z/C preserved, bits 3/5 from (A+val)
        zx->f = (zx->f & (FLAG_S | FLAG_Z | FLAG_C)) | (BC() ? FLAG_PV : 0) | ((uint8_t)(zx->a + val) & 0x28);
        return 16;
    }

    // CPI
    case 0xA1: {
        uint8_t val    = mem_read(zx, HL());
        uint8_t result = zx->a - val;
        SET_HL(HL() + 1);
        SET_BC(BC() - 1);
        zx->f = (zx->f & FLAG_C) | sz_flags(result) | FLAG_N | (BC() ? FLAG_PV : 0);
        if ((zx->a & 0x0F) < (val & 0x0F))
            zx->f |= FLAG_H;
        return 16;
    }

    // INI
    case 0xA2: {
        uint8_t val = port_read(zx, BC());
        mem_write(zx, HL(), val);
        SET_HL(HL() + 1);
        zx->b--;
        zx->f = (zx->b == 0 ? FLAG_Z : 0) | FLAG_N;
        return 16;
    }

    // OUTI
    case 0xA3: {
        uint8_t val = mem_read(zx, HL());
        zx->b--;
        port_write(zx, BC(), val);
        SET_HL(HL() + 1);
        zx->f = (zx->b == 0 ? FLAG_Z : 0) | FLAG_N;
        return 16;
    }

    // LDD
    case 0xA8: {
        uint8_t val = mem_read(zx, HL());
        mem_write(zx, DE(), val);
        SET_HL(HL() - 1);
        SET_DE(DE() - 1);
        SET_BC(BC() - 1);
        // Flags: H=0, N=0, PV=BC!=0, S/Z/C preserved, bits 3/5 from (A+val)
        zx->f = (zx->f & (FLAG_S | FLAG_Z | FLAG_C)) | (BC() ? FLAG_PV : 0) | ((uint8_t)(zx->a + val) & 0x28);
        return 16;
    }

    // CPD
    case 0xA9: {
        uint8_t val    = mem_read(zx, HL());
        uint8_t result = zx->a - val;
        SET_HL(HL() - 1);
        SET_BC(BC() - 1);
        zx->f = (zx->f & FLAG_C) | sz_flags(result) | FLAG_N | (BC() ? FLAG_PV : 0);
        if ((zx->a & 0x0F) < (val & 0x0F))
            zx->f |= FLAG_H;
        return 16;
    }

    // IND
    case 0xAA: {
        uint8_t val = port_read(zx, BC());
        mem_write(zx, HL(), val);
        SET_HL(HL() - 1);
        zx->b--;
        zx->f = (zx->b == 0 ? FLAG_Z : 0) | FLAG_N;
        return 16;
    }

    // OUTD
    case 0xAB: {
        uint8_t val = mem_read(zx, HL());
        zx->b--;
        port_write(zx, BC(), val);
        SET_HL(HL() - 1);
        zx->f = (zx->b == 0 ? FLAG_Z : 0) | FLAG_N;
        return 16;
    }

    // LDIR
    case 0xB0: {
        uint8_t val = mem_read(zx, HL());
        mem_write(zx, DE(), val);
        SET_HL(HL() + 1);
        SET_DE(DE() + 1);
        SET_BC(BC() - 1);
        // Same flags as LDI, PV reflects BC after decrement.
        zx->f = (zx->f & (FLAG_S | FLAG_Z | FLAG_C)) | (BC() ? FLAG_PV : 0) | ((uint8_t)(zx->a + val) & 0x28);
        if (BC()) {
            zx->pc -= 2; // Repeat
            return 21;
        }
        return 16;
    }

    // CPIR
    case 0xB1: {
        uint8_t val    = mem_read(zx, HL());
        uint8_t result = zx->a - val;
        SET_HL(HL() + 1);
        SET_BC(BC() - 1);
        zx->f = (zx->f & FLAG_C) | sz_flags(result) | FLAG_N | (BC() ? FLAG_PV : 0);
        if ((zx->a & 0x0F) < (val & 0x0F))
            zx->f |= FLAG_H;
        if (BC() && result != 0) {
            zx->pc -= 2;
            return 21;
        }
        return 16;
    }

    // INIR
    case 0xB2: {
        uint8_t val = port_read(zx, BC());
        mem_write(zx, HL(), val);
        SET_HL(HL() + 1);
        zx->b--;
        zx->f = FLAG_Z | FLAG_N;
        if (zx->b) {
            zx->f &= ~FLAG_Z;
            zx->pc -= 2;
            return 21;
        }
        return 16;
    }

    // OTIR
    case 0xB3: {
        uint8_t val = mem_read(zx, HL());
        zx->b--;
        port_write(zx, BC(), val);
        SET_HL(HL() + 1);
        zx->f = FLAG_Z | FLAG_N;
        if (zx->b) {
            zx->f &= ~FLAG_Z;
            zx->pc -= 2;
            return 21;
        }
        return 16;
    }

    // LDDR
    case 0xB8: {
        uint8_t val = mem_read(zx, HL());
        mem_write(zx, DE(), val);
        SET_HL(HL() - 1);
        SET_DE(DE() - 1);
        SET_BC(BC() - 1);
        // Same flags as LDD, PV reflects BC after decrement.
        zx->f = (zx->f & (FLAG_S | FLAG_Z | FLAG_C)) | (BC() ? FLAG_PV : 0) | ((uint8_t)(zx->a + val) & 0x28);
        if (BC()) {
            zx->pc -= 2;
            return 21;
        }
        return 16;
    }

    // CPDR
    case 0xB9: {
        uint8_t val    = mem_read(zx, HL());
        uint8_t result = zx->a - val;
        SET_HL(HL() - 1);
        SET_BC(BC() - 1);
        zx->f = (zx->f & FLAG_C) | sz_flags(result) | FLAG_N | (BC() ? FLAG_PV : 0);
        if ((zx->a & 0x0F) < (val & 0x0F))
            zx->f |= FLAG_H;
        if (BC() && result != 0) {
            zx->pc -= 2;
            return 21;
        }
        return 16;
    }

    // INDR
    case 0xBA: {
        uint8_t val = port_read(zx, BC());
        mem_write(zx, HL(), val);
        SET_HL(HL() - 1);
        zx->b--;
        zx->f = FLAG_Z | FLAG_N;
        if (zx->b) {
            zx->f &= ~FLAG_Z;
            zx->pc -= 2;
            return 21;
        }
        return 16;
    }

    // OTDR
    case 0xBB: {
        uint8_t val = mem_read(zx, HL());
        zx->b--;
        port_write(zx, BC(), val);
        SET_HL(HL() - 1);
        zx->f = FLAG_Z | FLAG_N;
        if (zx->b) {
            zx->f &= ~FLAG_Z;
            zx->pc -= 2;
            return 21;
        }
        return 16;
    }

    // ED 70: IN (C) - affects flags only, discards result (undocumented)
    // This instruction reads from port BC, sets S/Z/P flags based on the
    // value read, but does NOT store the result. Used by games for timing
    // and synchronization loops.
    case 0x70: {
        uint8_t val = port_read(zx, BC());
        zx->f       = (zx->f & FLAG_C) | szp_flags(val);
        return 12;
    }

    // ED 71: OUT (C), 0 (undocumented)
    // Outputs 0 to port BC.
    case 0x71:
        port_write(zx, BC(), 0);
        return 12;

    default:
        // Unknown ED opcode - treat as NOP NOP
        return 8;
    }
}

/* --------------------------------------------------------------------------
 * DD/FD-prefixed instructions (IX/IY operations)
 *
 * These are mostly the same as the main opcodes, but use IX/IY instead of HL.
 * For (IX+d)/(IY+d) addressing, we need to handle the displacement.
 * -------------------------------------------------------------------------- */

// Common implementation for DD and FD prefixes
static int execute_index(ZXState *zx, uint16_t *idx_reg) {
    uint8_t opcode = fetch8(zx);

    // DD/FD prefixes should act as NOP when applied to an instruction
    // that doesn't use HL/IX/IY. We currently don't implement that full
    // substitution behavior, but we must not consume bytes incorrectly.
    // In particular, "FD CB d op" sequences are real 4-byte opcodes.
    // Some ROM loops depend on them.

    // Many DD/FD opcodes just replace HL with IX/IY
    switch (opcode) {
    // ADD IX/IY, rr
    // Note: These must set the H flag (half-carry from bit 11), not just C.
    // Games often use the H flag after 16-bit additions for address calculations.
    case 0x09: {
        uint16_t orig   = *idx_reg;
        uint16_t val    = BC();
        uint32_t result = orig + val;
        zx->f           = (zx->f & (FLAG_S | FLAG_Z | FLAG_PV));
        if (result > 0xFFFF)
            zx->f |= FLAG_C;
        if (((orig ^ val ^ result) >> 8) & 0x10)
            zx->f |= FLAG_H;
        *idx_reg = result & 0xFFFF;
        return 15;
    }
    case 0x19: {
        uint16_t orig   = *idx_reg;
        uint16_t val    = DE();
        uint32_t result = orig + val;
        zx->f           = (zx->f & (FLAG_S | FLAG_Z | FLAG_PV));
        if (result > 0xFFFF)
            zx->f |= FLAG_C;
        if (((orig ^ val ^ result) >> 8) & 0x10)
            zx->f |= FLAG_H;
        *idx_reg = result & 0xFFFF;
        return 15;
    }
    case 0x29: {
        uint16_t orig   = *idx_reg;
        uint32_t result = orig + orig;
        zx->f           = (zx->f & (FLAG_S | FLAG_Z | FLAG_PV));
        if (result > 0xFFFF)
            zx->f |= FLAG_C;
        if (((orig ^ orig ^ result) >> 8) & 0x10)
            zx->f |= FLAG_H;
        *idx_reg = result & 0xFFFF;
        return 15;
    }
    case 0x39: {
        uint16_t orig   = *idx_reg;
        uint16_t val    = zx->sp;
        uint32_t result = orig + val;
        zx->f           = (zx->f & (FLAG_S | FLAG_Z | FLAG_PV));
        if (result > 0xFFFF)
            zx->f |= FLAG_C;
        if (((orig ^ val ^ result) >> 8) & 0x10)
            zx->f |= FLAG_H;
        *idx_reg = result & 0xFFFF;
        return 15;
    }

    // LD IX/IY, nn
    case 0x21:
        *idx_reg = fetch16(zx);
        return 14;

    // LD (nn), IX/IY
    case 0x22: {
        uint16_t addr = fetch16(zx);
        mem_write16(zx, addr, *idx_reg);
        return 20;
    }

    // INC IX/IY
    case 0x23:
        (*idx_reg)++;
        return 10;

    // ---- Undocumented IXH/IXL/IYH/IYL operations ----
    // These treat the index register as two separate 8-bit registers.
    // Many games (especially action games) use these for efficient
    // sprite coordinate manipulation.

    // INC IXH/IYH (undocumented)
    case 0x24:
        *idx_reg = (*idx_reg & 0x00FF) | ((uint16_t)alu_inc(*idx_reg >> 8) << 8);
        return 8;

    // DEC IXH/IYH (undocumented)
    case 0x25:
        *idx_reg = (*idx_reg & 0x00FF) | ((uint16_t)alu_dec(*idx_reg >> 8) << 8);
        return 8;

    // LD IXH/IYH, n (undocumented)
    case 0x26:
        *idx_reg = (*idx_reg & 0x00FF) | ((uint16_t)fetch8(zx) << 8);
        return 11;

    // DEC IX/IY
    case 0x2B:
        (*idx_reg)--;
        return 10;

    // LD IX/IY, (nn)
    case 0x2A: {
        uint16_t addr = fetch16(zx);
        *idx_reg      = mem_read16(zx, addr);
        return 20;
    }

    // INC IXL/IYL (undocumented)
    case 0x2C:
        *idx_reg = (*idx_reg & 0xFF00) | alu_inc(*idx_reg & 0xFF);
        return 8;

    // DEC IXL/IYL (undocumented)
    case 0x2D:
        *idx_reg = (*idx_reg & 0xFF00) | alu_dec(*idx_reg & 0xFF);
        return 8;

    // LD IXL/IYL, n (undocumented)
    case 0x2E:
        *idx_reg = (*idx_reg & 0xFF00) | fetch8(zx);
        return 11;

    // INC (IX/IY+d)
    case 0x34: {
        int8_t d      = (int8_t)fetch8(zx);
        uint16_t addr = *idx_reg + d;
        mem_write(zx, addr, alu_inc(mem_read(zx, addr)));
        return 23;
    }

    // DEC (IX/IY+d)
    case 0x35: {
        int8_t d      = (int8_t)fetch8(zx);
        uint16_t addr = *idx_reg + d;
        mem_write(zx, addr, alu_dec(mem_read(zx, addr)));
        return 23;
    }

    // LD (IX/IY+d), n
    case 0x36: {
        int8_t d      = (int8_t)fetch8(zx);
        uint8_t n     = fetch8(zx);
        uint16_t addr = *idx_reg + d;
        mem_write(zx, addr, n);
        return 19;
    }

    // ---- Undocumented LD operations with IXH/IXL/IYH/IYL ----

    // LD B, IXH/IYH (undocumented)
    case 0x44:
        zx->b = *idx_reg >> 8;
        return 8;

    // LD B, IXL/IYL (undocumented)
    case 0x45:
        zx->b = *idx_reg & 0xFF;
        return 8;

    // LD C, IXH/IYH (undocumented)
    case 0x4C:
        zx->c = *idx_reg >> 8;
        return 8;

    // LD C, IXL/IYL (undocumented)
    case 0x4D:
        zx->c = *idx_reg & 0xFF;
        return 8;

    // LD D, IXH/IYH (undocumented)
    case 0x54:
        zx->d = *idx_reg >> 8;
        return 8;

    // LD D, IXL/IYL (undocumented)
    case 0x55:
        zx->d = *idx_reg & 0xFF;
        return 8;

    // LD E, IXH/IYH (undocumented)
    case 0x5C:
        zx->e = *idx_reg >> 8;
        return 8;

    // LD E, IXL/IYL (undocumented)
    case 0x5D:
        zx->e = *idx_reg & 0xFF;
        return 8;

    // LD IXH, B (undocumented)
    case 0x60:
        *idx_reg = (*idx_reg & 0x00FF) | ((uint16_t)zx->b << 8);
        return 8;

    // LD IXH, C (undocumented)
    case 0x61:
        *idx_reg = (*idx_reg & 0x00FF) | ((uint16_t)zx->c << 8);
        return 8;

    // LD IXH, D (undocumented)
    case 0x62:
        *idx_reg = (*idx_reg & 0x00FF) | ((uint16_t)zx->d << 8);
        return 8;

    // LD IXH, E (undocumented)
    case 0x63:
        *idx_reg = (*idx_reg & 0x00FF) | ((uint16_t)zx->e << 8);
        return 8;

    // LD IXH, IXH (undocumented) - NOP effectively
    case 0x64:
        return 8;

    // LD IXH, IXL (undocumented)
    case 0x65:
        *idx_reg = (*idx_reg & 0x00FF) | ((*idx_reg & 0xFF) << 8);
        return 8;

    // LD IXH, A (undocumented)
    case 0x67:
        *idx_reg = (*idx_reg & 0x00FF) | ((uint16_t)zx->a << 8);
        return 8;

    // LD IXL, B (undocumented)
    case 0x68:
        *idx_reg = (*idx_reg & 0xFF00) | zx->b;
        return 8;

    // LD IXL, C (undocumented)
    case 0x69:
        *idx_reg = (*idx_reg & 0xFF00) | zx->c;
        return 8;

    // LD IXL, D (undocumented)
    case 0x6A:
        *idx_reg = (*idx_reg & 0xFF00) | zx->d;
        return 8;

    // LD IXL, E (undocumented)
    case 0x6B:
        *idx_reg = (*idx_reg & 0xFF00) | zx->e;
        return 8;

    // LD IXL, IXH (undocumented)
    case 0x6C:
        *idx_reg = (*idx_reg & 0xFF00) | (*idx_reg >> 8);
        return 8;

    // LD IXL, IXL (undocumented) - NOP effectively
    case 0x6D:
        return 8;

    // LD IXL, A (undocumented)
    case 0x6F:
        *idx_reg = (*idx_reg & 0xFF00) | zx->a;
        return 8;

    // LD A, IXH/IYH (undocumented)
    case 0x7C:
        zx->a = *idx_reg >> 8;
        return 8;

    // LD A, IXL/IYL (undocumented)
    case 0x7D:
        zx->a = *idx_reg & 0xFF;
        return 8;

    // LD r, (IX/IY+d) - various opcodes
    case 0x46: {
        int8_t d = (int8_t)fetch8(zx);
        zx->b    = mem_read(zx, *idx_reg + d);
        return 19;
    }
    case 0x4E: {
        int8_t d = (int8_t)fetch8(zx);
        zx->c    = mem_read(zx, *idx_reg + d);
        return 19;
    }
    case 0x56: {
        int8_t d = (int8_t)fetch8(zx);
        zx->d    = mem_read(zx, *idx_reg + d);
        return 19;
    }
    case 0x5E: {
        int8_t d = (int8_t)fetch8(zx);
        zx->e    = mem_read(zx, *idx_reg + d);
        return 19;
    }
    case 0x66: {
        int8_t d = (int8_t)fetch8(zx);
        zx->h    = mem_read(zx, *idx_reg + d);
        return 19;
    }
    case 0x6E: {
        int8_t d = (int8_t)fetch8(zx);
        zx->l    = mem_read(zx, *idx_reg + d);
        return 19;
    }
    case 0x7E: {
        int8_t d = (int8_t)fetch8(zx);
        zx->a    = mem_read(zx, *idx_reg + d);
        return 19;
    }

    // LD (IX/IY+d), r
    case 0x70: {
        int8_t d = (int8_t)fetch8(zx);
        mem_write(zx, *idx_reg + d, zx->b);
        return 19;
    }
    case 0x71: {
        int8_t d = (int8_t)fetch8(zx);
        mem_write(zx, *idx_reg + d, zx->c);
        return 19;
    }
    case 0x72: {
        int8_t d = (int8_t)fetch8(zx);
        mem_write(zx, *idx_reg + d, zx->d);
        return 19;
    }
    case 0x73: {
        int8_t d = (int8_t)fetch8(zx);
        mem_write(zx, *idx_reg + d, zx->e);
        return 19;
    }
    case 0x74: {
        int8_t d = (int8_t)fetch8(zx);
        mem_write(zx, *idx_reg + d, zx->h);
        return 19;
    }
    case 0x75: {
        int8_t d = (int8_t)fetch8(zx);
        mem_write(zx, *idx_reg + d, zx->l);
        return 19;
    }
    case 0x77: {
        int8_t d = (int8_t)fetch8(zx);
        mem_write(zx, *idx_reg + d, zx->a);
        return 19;
    }

    // ---- Undocumented ALU operations with IXH/IXL/IYH/IYL ----

    // ADD A, IXH/IYH (undocumented)
    case 0x84:
        zx->a = alu_add(zx->a, *idx_reg >> 8, 0);
        return 8;

    // ADD A, IXL/IYL (undocumented)
    case 0x85:
        zx->a = alu_add(zx->a, *idx_reg & 0xFF, 0);
        return 8;

    // ADC A, IXH/IYH (undocumented)
    case 0x8C:
        zx->a = alu_add(zx->a, *idx_reg >> 8, zx->f & FLAG_C ? 1 : 0);
        return 8;

    // ADC A, IXL/IYL (undocumented)
    case 0x8D:
        zx->a = alu_add(zx->a, *idx_reg & 0xFF, zx->f & FLAG_C ? 1 : 0);
        return 8;

    // SUB IXH/IYH (undocumented)
    case 0x94:
        zx->a = alu_sub(zx->a, *idx_reg >> 8, 0);
        return 8;

    // SUB IXL/IYL (undocumented)
    case 0x95:
        zx->a = alu_sub(zx->a, *idx_reg & 0xFF, 0);
        return 8;

    // SBC A, IXH/IYH (undocumented)
    case 0x9C:
        zx->a = alu_sub(zx->a, *idx_reg >> 8, zx->f & FLAG_C ? 1 : 0);
        return 8;

    // SBC A, IXL/IYL (undocumented)
    case 0x9D:
        zx->a = alu_sub(zx->a, *idx_reg & 0xFF, zx->f & FLAG_C ? 1 : 0);
        return 8;

    // AND IXH/IYH (undocumented)
    case 0xA4:
        zx->a = alu_and(zx->a, *idx_reg >> 8);
        return 8;

    // AND IXL/IYL (undocumented)
    case 0xA5:
        zx->a = alu_and(zx->a, *idx_reg & 0xFF);
        return 8;

    // XOR IXH/IYH (undocumented)
    case 0xAC:
        zx->a = alu_xor(zx->a, *idx_reg >> 8);
        return 8;

    // XOR IXL/IYL (undocumented)
    case 0xAD:
        zx->a = alu_xor(zx->a, *idx_reg & 0xFF);
        return 8;

    // OR IXH/IYH (undocumented)
    case 0xB4:
        zx->a = alu_or(zx->a, *idx_reg >> 8);
        return 8;

    // OR IXL/IYL (undocumented)
    case 0xB5:
        zx->a = alu_or(zx->a, *idx_reg & 0xFF);
        return 8;

    // CP IXH/IYH (undocumented)
    case 0xBC:
        alu_cp(zx->a, *idx_reg >> 8);
        return 8;

    // CP IXL/IYL (undocumented)
    case 0xBD:
        alu_cp(zx->a, *idx_reg & 0xFF);
        return 8;

    // ALU operations with (IX/IY+d)
    case 0x86: {
        int8_t d = (int8_t)fetch8(zx);
        zx->a    = alu_add(zx->a, mem_read(zx, *idx_reg + d), 0);
        return 19;
    }
    case 0x8E: {
        int8_t d = (int8_t)fetch8(zx);
        zx->a    = alu_add(zx->a, mem_read(zx, *idx_reg + d), zx->f & FLAG_C ? 1 : 0);
        return 19;
    }
    case 0x96: {
        int8_t d = (int8_t)fetch8(zx);
        zx->a    = alu_sub(zx->a, mem_read(zx, *idx_reg + d), 0);
        return 19;
    }
    case 0x9E: {
        int8_t d = (int8_t)fetch8(zx);
        zx->a    = alu_sub(zx->a, mem_read(zx, *idx_reg + d), zx->f & FLAG_C ? 1 : 0);
        return 19;
    }
    case 0xA6: {
        int8_t d = (int8_t)fetch8(zx);
        zx->a    = alu_and(zx->a, mem_read(zx, *idx_reg + d));
        return 19;
    }
    case 0xAE: {
        int8_t d = (int8_t)fetch8(zx);
        zx->a    = alu_xor(zx->a, mem_read(zx, *idx_reg + d));
        return 19;
    }
    case 0xB6: {
        int8_t d = (int8_t)fetch8(zx);
        zx->a    = alu_or(zx->a, mem_read(zx, *idx_reg + d));
        return 19;
    }
    case 0xBE: {
        int8_t d = (int8_t)fetch8(zx);
        alu_cp(zx->a, mem_read(zx, *idx_reg + d));
        return 19;
    }

        // DDCB/FDCB prefixed (bit operations on (IX/IY+d))
    case 0xCB: {
        int8_t d      = (int8_t)fetch8(zx);
        uint8_t op    = fetch8(zx);
        uint16_t addr = *idx_reg + d;
        uint8_t val   = mem_read(zx, addr);
        int bit       = (op >> 3) & 0x07;

        // Some of these operations also load a register with the result
        // (depending on op low bits).
        int r = op & 0x07;

        switch (op & 0xC0) {
        case 0x00: // Rotate/shift
            switch (bit) {
            case 0:
                zx->f = val >> 7;
                val   = (val << 1) | (val >> 7);
                break; // RLC
            case 1:
                zx->f = val & 0x01;
                val   = (val >> 1) | (val << 7);
                break; // RRC
            case 2: {
                uint8_t c = zx->f & FLAG_C;
                zx->f     = val >> 7;
                val       = (val << 1) | c;
            } break; // RL
            case 3: {
                uint8_t c = zx->f & FLAG_C;
                zx->f     = val & 0x01;
                val       = (val >> 1) | (c << 7);
            } break; // RR
            case 4:
                zx->f = val >> 7;
                val   = val << 1;
                break; // SLA
            case 5:
                zx->f = val & 0x01;
                val   = (val >> 1) | (val & 0x80);
                break; // SRA
            case 6:
                zx->f = val >> 7;
                val   = (val << 1) | 1;
                break; // SLL
            case 7:
                zx->f = val & 0x01;
                val   = val >> 1;
                break; // SRL
            }
            zx->f |= szp_flags(val);

            // Write back result
            mem_write(zx, addr, val);

            // And potentially load a register, except for the
            // undocumented case where r==6 (HL).
            switch (r) {
            case 0:
                zx->b = val;
                break;
            case 1:
                zx->c = val;
                break;
            case 2:
                zx->d = val;
                break;
            case 3:
                zx->e = val;
                break;
            case 4:
                zx->h = val;
                break;
            case 5:
                zx->l = val;
                break;
            case 7:
                zx->a = val;
                break;
            }
            break;

        case 0x40: // BIT
            zx->f = (zx->f & FLAG_C) | FLAG_H;
            if (!(val & (1 << bit)))
                zx->f |= FLAG_Z | FLAG_PV;
            if (bit == 7 && (val & 0x80))
                zx->f |= FLAG_S;
            return 20;

        case 0x80: // RES
            mem_write(zx, addr, val & ~(1 << bit));
            break;

        case 0xC0: // SET
            mem_write(zx, addr, val | (1 << bit));
            break;
        }
        return 23;
    }

    // POP IX/IY
    case 0xE1:
        *idx_reg = pop16(zx);
        return 14;

    // EX (SP), IX/IY
    case 0xE3: {
        uint16_t tmp = mem_read16(zx, zx->sp);
        mem_write16(zx, zx->sp, *idx_reg);
        *idx_reg = tmp;
        return 23;
    }

    // PUSH IX/IY
    case 0xE5:
        push16(zx, *idx_reg);
        return 15;

    // JP (IX/IY)
    case 0xE9:
        zx->pc = *idx_reg;
        return 8;

    // LD SP, IX/IY
    case 0xF9:
        zx->sp = *idx_reg;
        return 10;

    default:
        // Unknown DD/FD opcode - execute as main opcode
        // (effectively treating DD/FD as NOP prefix)
        zx->pc--;
        return 4;
    }
}

static int execute_dd(ZXState *zx) {
    return execute_index(zx, &zx->ix);
}

static int execute_fd(ZXState *zx) {
    return execute_index(zx, &zx->iy);
}

static inline int execute_one(ZXState *zx) {
    // Execute one instruction, then update EI-delay and tape timing.
    // If the executed opcode was EI itself, we must *not* tick the delay.
    int tstates = execute_one_core(zx);

    // Interleave audio and tape edges so tape loading sound is time-aligned.
    if (zx->tape_active && !zx->tape.autostarted)
        tape_tick(zx, 0);

    int rem = tstates;
    while (rem > 0) {
        int chunk = rem;
        if (zx->tape_active && zx->tape.tstates_rem > 0 && zx->tape.tstates_rem < chunk)
            chunk = zx->tape.tstates_rem;

        audio_tick(zx, chunk);
        tape_tick(zx, chunk);
        rem -= chunk;
    }

    if (zx->ei_delay) {
        // EI takes effect after the next instruction completes.
        // Use saved opcode instead of re-reading memory
        if (zx->last_opcode != 0xFB) {
            zx->ei_delay--;
            if (zx->ei_delay == 0) {
                zx->iff1 = zx->iff2 = 1;
            }
        }
    }

    return tstates;
}

/* --------------------------------------------------------------------------
 * Interrupt handling
 * -------------------------------------------------------------------------- */

static void handle_interrupt(ZXState *zx) {
    // Any interrupt signal ends the HALT state, even if interrupts are disabled.
    zx->halted = 0;

    if (!zx->iff1)
        return;

    // On maskable interrupt accept, only IFF1 is cleared.
    // IFF2 preserves the previous interrupt state so RETN can restore it.
    // (IFF2 is only modified by EI, DI, and LD A,I / LD A,R instructions.)
    zx->iff1 = 0;
    // Note: IFF2 is NOT cleared here - this was a critical bug!

    // Cancel any pending EI delay when an interrupt is taken.
    zx->ei_delay = 0;

    switch (zx->im) {
    case 0:
    case 1:
        // Mode 0/1: RST 38h
        push16(zx, zx->pc);
        zx->pc = 0x0038;
        zx->tstates += 13;
        break;
    case 2: {
        // Mode 2: Vector from (I * 256 + data_bus)
        // The Z80 forms a 16-bit pointer (I:vector) and reads a 16-bit address
        // from that pointer and the following byte.
        //
        // IMPORTANT: the second byte fetch wraps within the same 256-byte page
        // (high byte stays I). It is NOT a full 16-bit increment. Many IM2
        // handlers intentionally use vector 0xFF and place the 16-bit pointer
        // at (I:0xFF) and (I:0x00). Using a 16-bit increment here will read the
        // high byte from the next page (or 0x0000), sending execution into
        // garbage (often PC=0xFFFF + HALT).
        // On a real Spectrum, the vector byte comes from the floating data bus.
        // We keep it configurable (zx->int_vector).
        push16(zx, zx->pc);

        // Vector byte comes from the floating bus unless user forces a fixed
        // value via set_int_vector().
        uint8_t vec = zx->int_vector_fixed ? zx->int_vector : floating_bus_read(zx);

        uint16_t ptr    = (uint16_t)((zx->i << 8) | vec);
        uint16_t ptr_hi = (uint16_t)((zx->i << 8) | (uint8_t)(vec + 1));
        uint8_t lo      = mem_read(zx, ptr);
        uint8_t hi      = mem_read(zx, ptr_hi);
        zx->pc          = (uint16_t)(lo | (hi << 8));
        zx->tstates += 19;
        break;
    }
    }
}

/* --------------------------------------------------------------------------
 * Lua API
 * -------------------------------------------------------------------------- */

// Create a new emulator instance (userdata)
static int zx_new(lua_State *L) {
    // Get machine type from argument (default to 48k)
    const char *machine = luaL_optstring(L, 1, "48k");

    // Allocate userdata for the emulator state
    ZXState *zx = (ZXState *)lua_newuserdata(L, sizeof(ZXState));
    memset(zx, 0, sizeof(ZXState));

    // Set metatable
    luaL_getmetatable(L, ZX_EMU_MT);
    lua_setmetatable(L, -2);

    // Initialize machine type
    if (strcmp(machine, "128k") == 0) {
        zx->machine_type      = MACHINE_128K;
        zx->tstates_per_frame = TSTATES_PER_FRAME_128K;
    } else if (strcmp(machine, "plus2") == 0) {
        zx->machine_type      = MACHINE_PLUS2;
        zx->tstates_per_frame = TSTATES_PER_FRAME_128K;
    } else {
        zx->machine_type      = MACHINE_48K;
        zx->tstates_per_frame = TSTATES_PER_FRAME_48K;
    }

    // Initialize keyboard to all keys released (active low)
    for (int i = 0; i < 8; i++) {
        zx->keyboard_rows[i] = 0xFF;
    }

    // IM2: by default emulate floating bus (not a fixed byte).
    zx->int_vector           = 0xFF;
    zx->int_vector_fixed     = 0;
    zx->im2_page_write_count = 0;
    zx->im2_last_write_addr  = 0;
    zx->im2_last_write_val   = 0;

    // Initialize memory banking state
    zx->port_7ffd       = 0;
    zx->paging_disabled = 0;

    zx->floating_bus_last = 0xFF;

    // Initialize AY chip (128k only)
    zx->ay.noise_shift = 1; // LFSR must be non-zero

    // Set up memory mapping
    update_memory_mapping(zx);

    // Initialize tape state
    tape_rewind(zx);

    // Tape audio monitor defaults
    zx->tape_audio_enabled = 1;
    zx->tape_audio_amp     = 6000;

    // Return the userdata (already on stack)
    return 1;
}

// GC metamethod - cleanup tape blocks
static int zx_gc(lua_State *L) {
    ZXState *zx = (ZXState *)luaL_checkudata(L, 1, ZX_EMU_MT);
    tape_free_state(zx);
    return 0;
}

// Reset the CPU
static int zx_reset(lua_State *L) {
    ZXState *zx = check_zx(L);

    zx->pc   = 0x0000;
    zx->sp   = 0xFFFF;
    zx->a    = 0xFF;
    zx->f    = 0xFF;
    zx->iff1 = zx->iff2 = 0;
    zx->im              = 0;
    zx->ei_delay        = 0;
    zx->halted          = 0;
    zx->tstates         = 0;
    zx->screen_dirty    = 1;

    zx->beeper_state         = 0;
    zx->audio_sample_idx     = 0;
    zx->audio_phase_accum    = 0;
    zx->int_vector           = 0xFF;
    zx->int_vector_fixed     = 0;
    zx->im2_page_write_count = 0;
    zx->im2_last_write_addr  = 0;
    zx->im2_last_write_val   = 0;

    // Reset memory banking (128k mode)
    zx->port_7ffd       = 0;
    zx->paging_disabled = 0;
    update_memory_mapping(zx);

    zx->floating_bus_last = 0xFF;

    // Reset AY chip
    memset(&zx->ay, 0, sizeof(AYState));
    zx->ay.noise_shift = 1; // LFSR must be non-zero

    // Keep tape blocks loaded, but rewind playback.
    tape_rewind(zx);
    zx->tape.loaded      = (zx->tape.block_count > 0);
    zx->tape.playing     = 0; // user presses PLAY (F9) after LOAD ""
    zx->tape_active      = 0;
    zx->tape.phase       = TAPE_PHASE_STOP;
    // No active tape signal; real machines read EAR high by default.
    zx->tape.ear_level   = 1;
    zx->tape.autostarted = 0;

    lua_pushboolean(L, zx->tape.loaded);
    return 1;
}

// Load ROM data (16KB for 48k, 32KB for 128k/+2)
static int zx_load_rom(lua_State *L) {
    ZXState *zx = check_zx(L);

    size_t len;
    const char *data = luaL_checklstring(L, 2, &len);

    if (zx->machine_type == MACHINE_48K) {
        // 48k mode: expect 16KB ROM
        if (len != 16384) {
            lua_pushnil(L);
            lua_pushfstring(L, "48k ROM: expected 16384 bytes, got %d", (int)len);
            return 2;
        }
        memcpy(zx->rom_banks[0], data, 16384);
    } else {
        // 128k/+2 mode: expect 32KB ROM (two 16KB banks)
        if (len != 32768) {
            lua_pushnil(L);
            lua_pushfstring(L, "128k ROM: expected 32768 bytes, got %d", (int)len);
            return 2;
        }
        memcpy(zx->rom_banks[0], data, 16384);         // 128k editor ROM
        memcpy(zx->rom_banks[1], data + 16384, 16384); // 48k BASIC ROM
    }

    zx->rom_loaded = 1;
    update_memory_mapping(zx);

    // Rewind tape state when changing ROM.
    tape_rewind(zx);

    lua_pushboolean(L, 1);
    return 1;
}

// Poke a byte into memory
static int zx_poke(lua_State *L) {
    ZXState *zx = check_zx(L);

    uint16_t addr = (uint16_t)luaL_checkinteger(L, 2);
    uint8_t value = (uint8_t)luaL_checkinteger(L, 3);

    mem_write(zx, addr, value);

    lua_pushboolean(L, 1);
    return 1;
}

// Peek a byte from memory
static int zx_peek(lua_State *L) {
    ZXState *zx = check_zx(L);

    uint16_t addr = (uint16_t)luaL_checkinteger(L, 2);
    lua_pushinteger(L, mem_read(zx, addr));
    return 1;
}

static int zx_tape_play(lua_State *L) {
    ZXState *zx = check_zx(L);

    int play         = lua_toboolean(L, 2);
    zx->tape.playing = play ? 1 : 0;
    zx->tape_active  = (zx->tape.loaded && zx->tape.playing) ? 1 : 0;

    if (zx->tape.playing) {
        // If we're starting playback, ensure we're at a valid phase.
        if (zx->tape.phase == TAPE_PHASE_STOP)
            tape_start_block(zx);
    } else {
        // No active tape signal; real machines read EAR high by default.
        zx->tape.ear_level = 1;
    }

    lua_pushboolean(L, 1);
    return 1;
}

static int zx_set_tape_audio(lua_State *L) {
    ZXState *zx = check_zx(L);

    int en                 = lua_toboolean(L, 2);
    zx->tape_audio_enabled = en ? 1 : 0;

    lua_pushboolean(L, 1);
    return 1;
}

static int zx_set_int_vector(lua_State *L) {
    ZXState *zx = check_zx(L);

    zx->int_vector       = (uint8_t)luaL_checkinteger(L, 2);
    zx->int_vector_fixed = 1;
    lua_pushboolean(L, 1);
    return 1;
}

static int zx_tape_rewind(lua_State *L) {
    ZXState *zx = check_zx(L);

    tape_rewind(zx);
    lua_pushboolean(L, 1);
    return 1;
}

// Load a TAP file (raw bytes) into the tape drive (stopped).
static int zx_load_tap(lua_State *L) {
    ZXState *zx = check_zx(L);

    size_t len;
    const uint8_t *data = (const uint8_t *)luaL_checklstring(L, 2, &len);

    tape_free_state(zx);
    tape_rewind(zx);

    // Parse TAP: [u16 len][len bytes]...
    size_t pos     = 0;
    int blocks_cap = 0;

    while (pos + 2 <= len) {
        uint16_t blen = (uint16_t)data[pos] | ((uint16_t)data[pos + 1] << 8);
        pos += 2;
        if (pos + blen > len)
            break;

        if (zx->tape.block_count >= blocks_cap) {
            blocks_cap = blocks_cap ? blocks_cap * 2 : 16;
            void *nb   = realloc(zx->tape.blocks, (size_t)blocks_cap * sizeof(*zx->tape.blocks));
            if (!nb) {
                tape_free_state(zx);
                lua_pushnil(L);
                lua_pushstring(L, "Out of memory while parsing TAP");
                return 2;
            }
            zx->tape.blocks = nb;
        }

        uint8_t *copy = (uint8_t *)malloc(blen);
        if (!copy) {
            tape_free_state(zx);
            lua_pushnil(L);
            lua_pushstring(L, "Out of memory while copying TAP block");
            return 2;
        }
        memcpy(copy, data + pos, blen);

        zx->tape.blocks[zx->tape.block_count].data            = copy;
        zx->tape.blocks[zx->tape.block_count].len             = blen;
        zx->tape.blocks[zx->tape.block_count].has_pilot_sync  = 1;
        zx->tape.blocks[zx->tape.block_count].is_turbo        = 0;
        zx->tape.blocks[zx->tape.block_count].used_bits_last  = 8;
        zx->tape.blocks[zx->tape.block_count].pause_defined   = 0;
        zx->tape.blocks[zx->tape.block_count].pause_ms        = 0;
        zx->tape.blocks[zx->tape.block_count].pilot_len       = 2168;
        zx->tape.blocks[zx->tape.block_count].sync1_len       = 667;
        zx->tape.blocks[zx->tape.block_count].sync2_len       = 735;
        zx->tape.blocks[zx->tape.block_count].bit0_len        = 855;
        zx->tape.blocks[zx->tape.block_count].bit1_len        = 1710;
        zx->tape.blocks[zx->tape.block_count].pilot_pulses    = 0;
        zx->tape.blocks[zx->tape.block_count].start_level_set = 0;
        zx->tape.blocks[zx->tape.block_count].start_level     = 1;
        zx->tape.block_count++;

        pos += blen;
    }

    zx->tape.loaded      = (zx->tape.block_count > 0);
    zx->tape.playing     = 0;
    zx->tape_active      = 0;
    zx->tape.phase       = TAPE_PHASE_STOP;
    zx->tape.ear_level   = 0;
    zx->tape.autostarted = 0;

    lua_pushboolean(L, zx->tape.loaded);
    return 1;
}

static inline uint32_t rd24le(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16);
}

static int tzx_append_block(ZXState *zx, int *blocks_cap, const uint8_t *data, uint32_t len) {
    if (len > 0xFFFF)
        return 0;
    if (zx->tape.block_count >= *blocks_cap) {
        *blocks_cap = *blocks_cap ? (*blocks_cap * 2) : 32;
        void *nb    = realloc(zx->tape.blocks, (size_t)(*blocks_cap) * sizeof(*zx->tape.blocks));
        if (!nb)
            return 0;
        zx->tape.blocks = nb;
    }

    uint8_t *copy = NULL;
    if (len > 0) {
        copy = (uint8_t *)malloc(len);
        if (!copy)
            return 0;
        memcpy(copy, data, len);
    }

    zx->tape.blocks[zx->tape.block_count].data            = copy;
    zx->tape.blocks[zx->tape.block_count].len             = (uint16_t)len;
    zx->tape.blocks[zx->tape.block_count].used_bits_last  = 8;
    zx->tape.blocks[zx->tape.block_count].pause_defined   = 1;
    zx->tape.blocks[zx->tape.block_count].pause_ms        = 0;
    zx->tape.blocks[zx->tape.block_count].has_pilot_sync  = 1;
    zx->tape.blocks[zx->tape.block_count].is_turbo        = 0;
    zx->tape.blocks[zx->tape.block_count].pilot_len       = 2168;
    zx->tape.blocks[zx->tape.block_count].sync1_len       = 667;
    zx->tape.blocks[zx->tape.block_count].sync2_len       = 735;
    zx->tape.blocks[zx->tape.block_count].bit0_len        = 855;
    zx->tape.blocks[zx->tape.block_count].bit1_len        = 1710;
    zx->tape.blocks[zx->tape.block_count].pilot_pulses    = 0;
    zx->tape.blocks[zx->tape.block_count].start_level_set = 0;
    zx->tape.blocks[zx->tape.block_count].start_level     = 1;

    zx->tape.block_count++;
    return 1;
}

static int tzx_skip_block(const uint8_t *buf, size_t len, size_t *pos, uint8_t id) {
    // *pos points to first byte after ID.
    size_t p = *pos;
    switch (id) {
    case 0x12: // pure tone
        if (p + 4 > len)
            return 0;
        p += 4;
        break;
    case 0x13: { // pulse sequence
        if (p + 1 > len)
            return 0;
        uint8_t n = buf[p];
        p += 1;
        if (p + (size_t)n * 2 > len)
            return 0;
        p += (size_t)n * 2;
    } break;
    case 0x15: { // direct recording
        if (p + 8 > len)
            return 0;
        uint32_t n = rd24le(buf + p + 5);
        p += 8;
        if (p + n > len)
            return 0;
        p += n;
    } break;
    case 0x18:
    case 0x19: { // blocks with 4-byte length
        if (p + 4 > len)
            return 0;
        uint32_t bl = (uint32_t)buf[p] | ((uint32_t)buf[p + 1] << 8) | ((uint32_t)buf[p + 2] << 16) |
                      ((uint32_t)buf[p + 3] << 24);
        p += 4;
        if (p + bl > len)
            return 0;
        p += bl;
    } break;
    case 0x20: // pause
        if (p + 2 > len)
            return 0;
        p += 2;
        break;
    case 0x21: { // group start
        if (p + 1 > len)
            return 0;
        uint8_t n = buf[p];
        p += 1;
        if (p + n > len)
            return 0;
        p += n;
    } break;
    case 0x22: // group end
        break;
    case 0x23: // jump
        if (p + 2 > len)
            return 0;
        p += 2;
        break;
    case 0x24: // loop start
        if (p + 2 > len)
            return 0;
        p += 2;
        break;
    case 0x25: // loop end
        break;
    case 0x26: { // call sequence
        if (p + 2 > len)
            return 0;
        uint16_t n = rd16le(buf + p);
        p += 2;
        if (p + (size_t)n * 2 > len)
            return 0;
        p += (size_t)n * 2;
    } break;
    case 0x27: // return from sequence
        break;
    case 0x28: { // select block
        if (p + 2 > len)
            return 0;
        uint16_t bl = rd16le(buf + p);
        p += 2;
        if (p + bl > len)
            return 0;
        p += bl;
    } break;
    case 0x2A: { // stop the tape if in 48k mode (extension rule, length=0)
        if (p + 4 > len)
            return 0;
        uint32_t bl = (uint32_t)buf[p] | ((uint32_t)buf[p + 1] << 8) | ((uint32_t)buf[p + 2] << 16) |
                      ((uint32_t)buf[p + 3] << 24);
        p += 4;
        if (p + bl > len)
            return 0;
        p += bl;
    } break;
    case 0x2B: // set signal level
        if (p + 4 > len)
            return 0;
        {
            uint32_t bl = (uint32_t)buf[p] | ((uint32_t)buf[p + 1] << 8) | ((uint32_t)buf[p + 2] << 16) |
                          ((uint32_t)buf[p + 3] << 24);
            p += 4;
            if (p + bl > len)
                return 0;
            p += bl;
        }
        break;
    case 0x30: { // text description
        if (p + 1 > len)
            return 0;
        uint8_t n = buf[p];
        p += 1;
        if (p + n > len)
            return 0;
        p += n;
    } break;
    case 0x31: { // message block
        if (p + 2 > len)
            return 0;
        uint8_t n = buf[p + 1];
        p += 2;
        if (p + n > len)
            return 0;
        p += n;
    } break;
    case 0x32: { // archive info
        if (p + 2 > len)
            return 0;
        uint16_t bl = rd16le(buf + p);
        p += 2;
        if (p + bl > len)
            return 0;
        p += bl;
    } break;
    case 0x33: { // hardware type
        if (p + 1 > len)
            return 0;
        uint8_t n = buf[p];
        p += 1;
        if (p + (size_t)n * 3 > len)
            return 0;
        p += (size_t)n * 3;
    } break;
    case 0x35: { // custom info
        if (p + 16 + 4 > len)
            return 0;
        p += 16;
        uint32_t bl = (uint32_t)buf[p] | ((uint32_t)buf[p + 1] << 8) | ((uint32_t)buf[p + 2] << 16) |
                      ((uint32_t)buf[p + 3] << 24);
        p += 4;
        if (p + bl > len)
            return 0;
        p += bl;
    } break;
    case 0x5A: // glue
        if (p + 9 > len)
            return 0;
        p += 9;
        break;
    default:
        return -1; // unknown
    }

    *pos = p;
    return 1;
}

// Load a TZX file into the tape drive.
// Supports ID 10 (standard), ID 11 (turbo), ID 14 (pure data), ID 20 (pause).
static int zx_load_tzx(lua_State *L) {
    ZXState *zx = check_zx(L);

    size_t len;
    const uint8_t *buf = (const uint8_t *)luaL_checklstring(L, 2, &len);

    if (len < 10 || memcmp(buf, "ZXTape!", 7) != 0 || buf[7] != 0x1A) {
        lua_pushnil(L);
        lua_pushstring(L, "Invalid TZX header");
        return 2;
    }

    tape_free_state(zx);
    tape_rewind(zx);

    size_t pos     = 10;
    int blocks_cap = 0;

    // Track pending pre-data blocks (common in some TZX files):
    // 0x12 (pure tone) + 0x13 (pulse sequence) + 0x14 (pure data)
    int pending_have_pilot        = 0;
    uint16_t pending_pilot_len    = 0;
    uint16_t pending_pilot_pulses = 0;

    int pending_have_sync  = 0;
    uint16_t pending_sync1 = 0;
    uint16_t pending_sync2 = 0;

    // TZX 0x2B (set signal level) -> apply to next tape segment we generate.
    int pending_level_set = 0;
    uint8_t pending_level = 1;

    while (pos < len) {
        uint8_t id = buf[pos++];
        if (id == 0x10) {
            if (pos + 4 > len)
                break;
            uint16_t pause_ms = rd16le(buf + pos);
            uint16_t blen     = rd16le(buf + pos + 2);
            pos += 4;
            if (pos + blen > len)
                break;
            if (!tzx_append_block(zx, &blocks_cap, buf + pos, blen)) {
                tape_free_state(zx);
                lua_pushnil(L);
                lua_pushstring(L, "Out of memory while parsing TZX");
                return 2;
            }
            zx->tape.blocks[zx->tape.block_count - 1].pause_ms       = pause_ms;
            zx->tape.blocks[zx->tape.block_count - 1].has_pilot_sync = 1;
            zx->tape.blocks[zx->tape.block_count - 1].is_turbo       = 0;
            if (pending_level_set) {
                zx->tape.blocks[zx->tape.block_count - 1].start_level_set = 1;
                zx->tape.blocks[zx->tape.block_count - 1].start_level     = pending_level;
                pending_level_set                                         = 0;
            }
            pos += blen;

            pending_have_pilot = 0;
            pending_have_sync  = 0;
        } else if (id == 0x11) {
            if (pos + 0x12 > len)
                break;

            uint16_t pilot_len    = rd16le(buf + pos + 0);
            uint16_t sync1_len    = rd16le(buf + pos + 2);
            uint16_t sync2_len    = rd16le(buf + pos + 4);
            uint16_t bit0_len     = rd16le(buf + pos + 6);
            uint16_t bit1_len     = rd16le(buf + pos + 8);
            uint16_t pilot_pulses = rd16le(buf + pos + 0x0A);
            uint8_t used_bits     = buf[pos + 0x0C];
            uint16_t pause_ms     = rd16le(buf + pos + 0x0D);
            uint32_t blen         = rd24le(buf + pos + 0x0F);
            pos += 0x12;

            if (pos + blen > len)
                break;
            if (!tzx_append_block(zx, &blocks_cap, buf + pos, blen)) {
                tape_free_state(zx);
                lua_pushnil(L);
                lua_pushstring(L, "Out of memory while parsing TZX");
                return 2;
            }
            if (used_bits == 0)
                used_bits = 8;
            zx->tape.blocks[zx->tape.block_count - 1].pause_ms       = pause_ms;
            zx->tape.blocks[zx->tape.block_count - 1].has_pilot_sync = 1;
            zx->tape.blocks[zx->tape.block_count - 1].is_turbo       = 1;
            zx->tape.blocks[zx->tape.block_count - 1].used_bits_last = used_bits;
            zx->tape.blocks[zx->tape.block_count - 1].pilot_len      = pilot_len;
            zx->tape.blocks[zx->tape.block_count - 1].sync1_len      = sync1_len;
            zx->tape.blocks[zx->tape.block_count - 1].sync2_len      = sync2_len;
            zx->tape.blocks[zx->tape.block_count - 1].bit0_len       = bit0_len;
            zx->tape.blocks[zx->tape.block_count - 1].bit1_len       = bit1_len;
            zx->tape.blocks[zx->tape.block_count - 1].pilot_pulses   = pilot_pulses;
            if (pending_level_set) {
                zx->tape.blocks[zx->tape.block_count - 1].start_level_set = 1;
                zx->tape.blocks[zx->tape.block_count - 1].start_level     = pending_level;
                pending_level_set                                         = 0;
            }
            pos += blen;

            pending_have_pilot = 0;
            pending_have_sync  = 0;
        } else if (id == 0x14) {
            if (pos + 0x0A > len)
                break;
            uint16_t bit0_len = rd16le(buf + pos + 0);
            uint16_t bit1_len = rd16le(buf + pos + 2);
            uint8_t used_bits = buf[pos + 4];
            uint16_t pause_ms = rd16le(buf + pos + 5);
            uint32_t blen     = rd24le(buf + pos + 7);
            pos += 0x0A;
            if (pos + blen > len)
                break;
            if (!tzx_append_block(zx, &blocks_cap, buf + pos, blen)) {
                tape_free_state(zx);
                lua_pushnil(L);
                lua_pushstring(L, "Out of memory while parsing TZX");
                return 2;
            }
            if (used_bits == 0)
                used_bits = 8;
            zx->tape.blocks[zx->tape.block_count - 1].pause_ms       = pause_ms;
            zx->tape.blocks[zx->tape.block_count - 1].has_pilot_sync = 0;
            zx->tape.blocks[zx->tape.block_count - 1].is_turbo       = 1;
            zx->tape.blocks[zx->tape.block_count - 1].used_bits_last = used_bits;
            zx->tape.blocks[zx->tape.block_count - 1].bit0_len       = bit0_len;
            zx->tape.blocks[zx->tape.block_count - 1].bit1_len       = bit1_len;

            // If there were preceding 0x12/0x13 blocks, treat this as a full
            // pilot+sync+data sequence.
            if (pending_have_pilot || pending_have_sync) {
                zx->tape.blocks[zx->tape.block_count - 1].has_pilot_sync = 1;
                if (pending_have_pilot) {
                    zx->tape.blocks[zx->tape.block_count - 1].pilot_len    = pending_pilot_len;
                    zx->tape.blocks[zx->tape.block_count - 1].pilot_pulses = pending_pilot_pulses;
                    zx->tape.blocks[zx->tape.block_count - 1].is_turbo     = 1;
                }
                if (pending_have_sync) {
                    zx->tape.blocks[zx->tape.block_count - 1].sync1_len = pending_sync1;
                    zx->tape.blocks[zx->tape.block_count - 1].sync2_len = pending_sync2;
                }
                pending_have_pilot = 0;
                pending_have_sync  = 0;
            }

            if (pending_level_set) {
                zx->tape.blocks[zx->tape.block_count - 1].start_level_set = 1;
                zx->tape.blocks[zx->tape.block_count - 1].start_level     = pending_level;
                pending_level_set                                         = 0;
            }
            pos += blen;
        } else if (id == 0x20) {
            if (pos + 2 > len)
                break;
            uint16_t pause_ms = rd16le(buf + pos);
            pos += 2;
            // Represent pause as an empty block.
            if (!tzx_append_block(zx, &blocks_cap, NULL, 0)) {
                tape_free_state(zx);
                lua_pushnil(L);
                lua_pushstring(L, "Out of memory while parsing TZX");
                return 2;
            }
            zx->tape.blocks[zx->tape.block_count - 1].pause_ms       = pause_ms;
            zx->tape.blocks[zx->tape.block_count - 1].has_pilot_sync = 0;
            zx->tape.blocks[zx->tape.block_count - 1].is_turbo       = 0;
            pending_have_pilot                                       = 0;
            pending_have_sync                                        = 0;
            pending_level_set                                        = 0;
        } else if (id == 0x12) {
            // Pure tone (often pilot tone for a following 0x14 block)
            if (pos + 4 > len)
                break;
            pending_pilot_len    = rd16le(buf + pos);
            pending_pilot_pulses = rd16le(buf + pos + 2);
            pending_have_pilot   = 1;
            pos += 4;
        } else if (id == 0x13) {
            // Pulse sequence (often sync pulses for a following 0x14 block)
            if (pos + 1 > len)
                break;
            uint8_t n = buf[pos++];
            if (pos + (size_t)n * 2 > len)
                break;
            if (n >= 1)
                pending_sync1 = rd16le(buf + pos);
            if (n >= 2)
                pending_sync2 = rd16le(buf + pos + 2);
            else
                pending_sync2 = pending_sync1;
            pending_have_sync = (n > 0) ? 1 : 0;
            pos += (size_t)n * 2;
        } else if (id == 0x2B) {
            // Set signal level (extension rule)
            if (pos + 4 > len)
                break;
            uint32_t bl = (uint32_t)buf[pos] | ((uint32_t)buf[pos + 1] << 8) | ((uint32_t)buf[pos + 2] << 16) |
                          ((uint32_t)buf[pos + 3] << 24);
            pos += 4;
            if (pos + bl > len)
                break;
            if (bl >= 1) {
                pending_level_set = 1;
                pending_level     = buf[pos] ? 1 : 0;
            }
            pos += bl;
        } else {
            int sk = tzx_skip_block(buf, len, &pos, id);
            if (sk == -1) {
                tape_free_state(zx);
                lua_pushnil(L);
                lua_pushfstring(L, "Unsupported TZX block id 0x%02X", (int)id);
                return 2;
            }
            if (sk == 0)
                break;
        }
    }

    zx->tape.loaded      = (zx->tape.block_count > 0);
    zx->tape.playing     = 0;
    zx->tape_active      = 0;
    zx->tape.phase       = TAPE_PHASE_STOP;
    zx->tape.ear_level   = 0;
    zx->tape.autostarted = 0;

    lua_pushboolean(L, zx->tape.loaded);
    return 1;
}

// Load a binary blob into memory at a given address
static int zx_load_memory(lua_State *L) {
    ZXState *zx = check_zx(L);

    uint16_t addr = (uint16_t)luaL_checkinteger(L, 2);
    size_t len;
    const char *data = luaL_checklstring(L, 3, &len);

    for (size_t i = 0; i < len && (addr + i) <= 0xFFFF; i++) {
        mem_write(zx, addr + i, (uint8_t)data[i]);
    }

    lua_pushboolean(L, 1);
    return 1;
}

static int z80_apply_page(ZXState *zx, uint8_t page, const uint8_t *data16k) {
    if (zx->machine_type == MACHINE_48K) {
        if (page == 8) {
            memcpy(zx->ram_banks[5], data16k, RAM_BANK_SIZE);
            return 1;
        } else if (page == 4) {
            memcpy(zx->ram_banks[2], data16k, RAM_BANK_SIZE);
            return 1;
        } else if (page == 5) {
            memcpy(zx->ram_banks[0], data16k, RAM_BANK_SIZE);
            return 1;
        }
        return 0;
    }

    if (page >= 3 && page <= 10) {
        memcpy(zx->ram_banks[page - 3], data16k, RAM_BANK_SIZE);
        return 1;
    }

    return 0;
}

// Save snapshot in .z80 (v3, uncompressed blocks)
static int zx_save_z80(lua_State *L) {
    ZXState *zx = check_zx(L);

    uint8_t hdr[30];
    memset(hdr, 0, sizeof(hdr));

    hdr[0]  = zx->a;
    hdr[1]  = zx->f;
    hdr[2]  = zx->c;
    hdr[3]  = zx->b;
    hdr[4]  = zx->l;
    hdr[5]  = zx->h;
    hdr[6]  = 0;
    hdr[7]  = 0; // PC=0 => v2/v3 format
    hdr[8]  = (uint8_t)(zx->sp & 0xFF);
    hdr[9]  = (uint8_t)((zx->sp >> 8) & 0xFF);
    hdr[10] = zx->i;
    hdr[11] = (uint8_t)(zx->r & 0x7F);

    uint8_t flags12 = 0;
    if (zx->r & 0x80)
        flags12 |= 0x01;
    flags12 |= (uint8_t)((zx->border_color & 0x07) << 1);
    hdr[12] = flags12;

    hdr[13] = zx->e;
    hdr[14] = zx->d;
    hdr[15] = zx->c_;
    hdr[16] = zx->b_;
    hdr[17] = zx->e_;
    hdr[18] = zx->d_;
    hdr[19] = zx->l_;
    hdr[20] = zx->h_;
    hdr[21] = zx->a_;
    hdr[22] = zx->f_;
    hdr[23] = (uint8_t)(zx->iy & 0xFF);
    hdr[24] = (uint8_t)((zx->iy >> 8) & 0xFF);
    hdr[25] = (uint8_t)(zx->ix & 0xFF);
    hdr[26] = (uint8_t)((zx->ix >> 8) & 0xFF);
    hdr[27] = zx->iff1 ? 1 : 0;
    hdr[28] = zx->iff2 ? 1 : 0;
    hdr[29] = (uint8_t)(zx->im & 0x03);

    uint16_t ext_len = 54; // v3
    uint8_t ext[54];
    memset(ext, 0, sizeof(ext));

    wr16le(&ext[0], zx->pc);

    uint8_t hw = 0;
    if (zx->machine_type == MACHINE_128K)
        hw = 4;
    else if (zx->machine_type == MACHINE_PLUS2)
        hw = 12;
    ext[2] = hw;

    if (zx->machine_type != MACHINE_48K)
        ext[3] = zx->port_7ffd;

    // Flags: bit2 => AY regs are present/used
    if (zx->machine_type != MACHINE_48K)
        ext[5] |= 0x04;

    ext[6] = zx->ay.selected_reg;
    for (int i = 0; i < 16; i++)
        ext[7 + i] = zx->ay.regs[i];

    luaL_Buffer b;
    luaL_buffinit(L, &b);
    luaL_addlstring(&b, (const char *)hdr, sizeof(hdr));

    uint8_t extlen2[2];
    wr16le(extlen2, ext_len);
    luaL_addlstring(&b, (const char *)extlen2, sizeof(extlen2));
    luaL_addlstring(&b, (const char *)ext, ext_len);

    uint8_t bhdr[3] = {0xFF, 0xFF, 0};

    if (zx->machine_type == MACHINE_48K) {
        // 48k: pages 8 (bank5), 4 (bank2), 5 (bank0)
        bhdr[2] = 8;
        luaL_addlstring(&b, (const char *)bhdr, sizeof(bhdr));
        luaL_addlstring(&b, (const char *)zx->ram_banks[5], RAM_BANK_SIZE);

        bhdr[2] = 4;
        luaL_addlstring(&b, (const char *)bhdr, sizeof(bhdr));
        luaL_addlstring(&b, (const char *)zx->ram_banks[2], RAM_BANK_SIZE);

        bhdr[2] = 5;
        luaL_addlstring(&b, (const char *)bhdr, sizeof(bhdr));
        luaL_addlstring(&b, (const char *)zx->ram_banks[0], RAM_BANK_SIZE);
    } else {
        // 128k/+2: pages 3..10 map to banks 0..7
        for (uint8_t bank = 0; bank < RAM_BANK_COUNT; bank++) {
            bhdr[2] = (uint8_t)(3 + bank);
            luaL_addlstring(&b, (const char *)bhdr, sizeof(bhdr));
            luaL_addlstring(&b, (const char *)zx->ram_banks[bank], RAM_BANK_SIZE);
        }
    }

    luaL_pushresult(&b);
    return 1;
}

// Load snapshot from .z80 data
static int zx_load_z80(lua_State *L) {
    ZXState *zx = check_zx(L);

    size_t len;
    const uint8_t *buf = (const uint8_t *)luaL_checklstring(L, 2, &len);
    if (len < 30) {
        lua_pushnil(L);
        lua_pushstring(L, "Invalid Z80 snapshot: too small");
        return 2;
    }

    const uint8_t *h = buf;
    uint16_t pc_v1   = rd16le(h + 6);
    uint8_t flags12  = h[12];
    if (flags12 == 255)
        flags12 = 1;

    // Common register restore (PC handled separately)
    zx->a  = h[0];
    zx->f  = h[1];
    zx->c  = h[2];
    zx->b  = h[3];
    zx->l  = h[4];
    zx->h  = h[5];
    zx->sp = rd16le(h + 8);
    zx->i  = h[10];
    zx->r  = (uint8_t)((h[11] & 0x7F) | ((flags12 & 0x01) ? 0x80 : 0x00));

    zx->border_color = (uint8_t)((flags12 >> 1) & 0x07);

    zx->e  = h[13];
    zx->d  = h[14];
    zx->c_ = h[15];
    zx->b_ = h[16];
    zx->e_ = h[17];
    zx->d_ = h[18];
    zx->l_ = h[19];
    zx->h_ = h[20];
    zx->a_ = h[21];
    zx->f_ = h[22];
    zx->iy = rd16le(h + 23);
    zx->ix = rd16le(h + 25);

    zx->iff1     = h[27] ? 1 : 0;
    zx->iff2     = h[28] ? 1 : 0;
    zx->im       = h[29] & 0x03;
    zx->ei_delay = 0;
    zx->halted   = 0;

    // Clear fixed interrupt vector setting on snapshot load.
    zx->int_vector       = 0xFF;
    zx->int_vector_fixed = 0;

    // Default: clear AY regs unless we restore them from v2/v3 header.
    memset(&zx->ay, 0, sizeof(AYState));
    zx->ay.noise_shift = 1;

    if (pc_v1 != 0) {
        // Version 1 snapshot (48k only)
        zx->machine_type      = MACHINE_48K;
        zx->tstates_per_frame = TSTATES_PER_FRAME_48K;
        zx->port_7ffd         = 0;
        zx->paging_disabled   = 0;
        update_memory_mapping(zx);

        zx->pc = pc_v1;

        const uint8_t *mem = buf + 30;
        size_t mem_len     = len - 30;
        uint8_t ram48[49152];
        int compressed = (flags12 & 0x20) ? 1 : 0;

        if (compressed) {
            if (!z80_rle_decompress(mem, mem_len, ram48, sizeof(ram48), 1)) {
                lua_pushnil(L);
                lua_pushstring(L, "Invalid Z80 v1 snapshot: decompression failed");
                return 2;
            }
        } else {
            if (mem_len < sizeof(ram48)) {
                lua_pushnil(L);
                lua_pushstring(L, "Invalid Z80 v1 snapshot: truncated RAM image");
                return 2;
            }
            memcpy(ram48, mem, sizeof(ram48));
        }

        memcpy(zx->ram_banks[5], ram48 + 0, RAM_BANK_SIZE);
        memcpy(zx->ram_banks[2], ram48 + RAM_BANK_SIZE, RAM_BANK_SIZE);
        memcpy(zx->ram_banks[0], ram48 + (RAM_BANK_SIZE * 2), RAM_BANK_SIZE);

        zx_snapshot_cleanup_runtime(zx);

        lua_pushboolean(L, 1);
        return 1;
    }

    // Version 2/3 snapshot
    if (len < 32) {
        lua_pushnil(L);
        lua_pushstring(L, "Invalid Z80 snapshot: missing extended header");
        return 2;
    }

    uint16_t ext_len = rd16le(buf + 30);
    if (len < (size_t)(32 + ext_len)) {
        lua_pushnil(L);
        lua_pushstring(L, "Invalid Z80 snapshot: truncated extended header");
        return 2;
    }

    const uint8_t *ext = buf + 32;
    zx->pc             = rd16le(ext + 0);

    uint8_t hw = (ext_len >= 3) ? ext[2] : 0;

    // Map hardware type to our machine types
    if (hw == 0 || hw == 1) {
        zx->machine_type      = MACHINE_48K;
        zx->tstates_per_frame = TSTATES_PER_FRAME_48K;
    } else if (hw == 12) {
        zx->machine_type      = MACHINE_PLUS2;
        zx->tstates_per_frame = TSTATES_PER_FRAME_128K;
    } else {
        // Treat everything else as 128k-compatible.
        zx->machine_type      = MACHINE_128K;
        zx->tstates_per_frame = TSTATES_PER_FRAME_128K;
    }

    zx->port_7ffd       = (ext_len >= 4) ? ext[3] : 0;
    zx->paging_disabled = (zx->port_7ffd >> 5) & 1;

    if (zx->machine_type != MACHINE_48K && ext_len >= 23) {
        zx->ay.selected_reg = ext[6] & 0x0F;
        for (int i = 0; i < 16; i++)
            zx->ay.regs[i] = ext[7 + i];
        zx->ay.noise_shift = 1;
    }

    update_memory_mapping(zx);

    size_t pos = (size_t)(32 + ext_len);
    uint8_t blk[RAM_BANK_SIZE];
    int any_blocks = 0;

    while (pos + 3 <= len) {
        uint16_t blen = rd16le(buf + pos);
        uint8_t page  = buf[pos + 2];
        pos += 3;

        if (blen == 0xFFFF) {
            if (pos + RAM_BANK_SIZE > len) {
                lua_pushnil(L);
                lua_pushstring(L, "Invalid Z80 snapshot: truncated uncompressed block");
                return 2;
            }
            memcpy(blk, buf + pos, RAM_BANK_SIZE);
            pos += RAM_BANK_SIZE;
        } else {
            if (pos + blen > len) {
                lua_pushnil(L);
                lua_pushstring(L, "Invalid Z80 snapshot: truncated compressed block");
                return 2;
            }
            if (!z80_rle_decompress(buf + pos, blen, blk, RAM_BANK_SIZE, 0)) {
                lua_pushnil(L);
                lua_pushstring(L, "Invalid Z80 snapshot: block decompression failed");
                return 2;
            }
            pos += blen;
        }

        any_blocks |= z80_apply_page(zx, page, blk);
    }

    if (!any_blocks) {
        lua_pushnil(L);
        lua_pushstring(L, "Invalid Z80 snapshot: no memory blocks");
        return 2;
    }

    zx_snapshot_cleanup_runtime(zx);
    lua_pushboolean(L, 1);
    return 1;
}

// Run one frame of emulation (69888 T-states)
static int zx_run_frame(lua_State *L) {
    ZXState *zx = check_zx(L);

    zx->tstates          = 0;
    zx->screen_dirty     = 0;
    zx->audio_sample_idx = 0; // Reset audio buffer for this frame

    // Initialize border scanlines with current border color (for tape loading visualization)
    if (zx->tape_active) {
        memset(zx->border_scanlines, zx->border_color, SCANLINES_PER_FRAME);
    }

    // On real Spectrum hardware, the ULA asserts INT once per frame around the
    // start of vertical blanking. Approximate it as line 64 (64*224=14336).
    // Doing this mid-frame is important for games that rely on accurate IM2
    // timing / floating bus behavior.
    const int int_tstate = 64 * 224;
    int int_fired        = 0;

    while (zx->tstates < zx->tstates_per_frame) {
        int t = execute_one(zx);
        zx->tstates += t;

        if (!int_fired && zx->tstates >= int_tstate) {
            handle_interrupt(zx);
            int_fired = 1;
        }
    }

    lua_pushboolean(L, zx->screen_dirty);
    return 1;
}

// Run a single instruction (for debugging)
static int zx_step(lua_State *L) {
    ZXState *zx = check_zx(L);

    int tstates = execute_one(zx);
    lua_pushinteger(L, tstates);
    return 1;
}

// Get the screen memory (6912 bytes in SCR format)
static int zx_get_screen(lua_State *L) {
    ZXState *zx = check_zx(L);

    // Return active screen buffer (bank 5 or bank 7)
    uint8_t *screen_base;
    if (zx->active_screen == 0) {
        screen_base = zx->ram_banks[5]; // Normal screen
    } else {
        screen_base = zx->ram_banks[7]; // Shadow screen (128k mode)
    }

    lua_pushlstring(L, (const char *)screen_base, SCREEN_SIZE);
    return 1;
}

// Set a key state (row 0-7, bit 0-4)
static int zx_key_down(lua_State *L) {
    ZXState *zx = check_zx(L);

    int row = luaL_checkinteger(L, 2);
    int bit = luaL_checkinteger(L, 3);

    if (row >= 0 && row < 8 && bit >= 0 && bit < 5) {
        zx->keyboard_rows[row] &= ~(1 << bit);
    }

    lua_pushboolean(L, 1);
    return 1;
}

static int zx_key_up(lua_State *L) {
    ZXState *zx = check_zx(L);

    int row = luaL_checkinteger(L, 2);
    int bit = luaL_checkinteger(L, 3);

    if (row >= 0 && row < 8 && bit >= 0 && bit < 5) {
        zx->keyboard_rows[row] |= (1 << bit);
    }

    lua_pushboolean(L, 1);
    return 1;
}

// Get current border color (0-7)
static int zx_get_border(lua_State *L) {
    ZXState *zx = check_zx(L);

    lua_pushinteger(L, zx->border_color);
    return 1;
}

// Get border scanlines (312 bytes, one per scanline)
// Returns nil if tape is not active (border tracking only during tape playback)
static int zx_get_border_lines(lua_State *L) {
    ZXState *zx = check_zx(L);

    if (!zx->tape_active) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushlstring(L, (const char *)zx->border_scanlines, SCANLINES_PER_FRAME);
    return 1;
}

// Get keyboard state (for debugging)
static int zx_get_keyboard(lua_State *L) {
    ZXState *zx = check_zx(L);

    lua_newtable(L);
    for (int i = 0; i < 8; i++) {
        lua_pushinteger(L, zx->keyboard_rows[i]);
        lua_rawseti(L, -2, i + 1);
    }
    return 1;
}

// Get beeper state (for audio implementation)
static int zx_get_beeper(lua_State *L) {
    ZXState *zx = check_zx(L);

    lua_pushinteger(L, zx->beeper_state);
    return 1;
}

static int zx_get_audio_samples(lua_State *L) {
    ZXState *zx = check_zx(L);

    // Return audio samples as a binary string (int16_t little-endian)
    lua_pushlstring(L, (const char *)zx->audio_buffer, zx->audio_sample_idx * sizeof(int16_t));
    return 1;
}

// Get PC history (last 16 PC values for debugging)
static int zx_get_pc_history(lua_State *L) {
    ZXState *zx = check_zx(L);

    lua_newtable(L);
    for (int i = 0; i < 16; i++) {
        // Return in order from oldest to newest
        int idx = (zx->pc_history_idx + i) & 0x0F;
        lua_pushinteger(L, zx->pc_history[idx]);
        lua_rawseti(L, -2, i + 1);
    }
    return 1;
}

// Get CPU registers (for debugging)
static int zx_get_registers(lua_State *L) {
    ZXState *zx = check_zx(L);

    lua_newtable(L);

    lua_pushinteger(L, zx->a);
    lua_setfield(L, -2, "a");
    lua_pushinteger(L, zx->f);
    lua_setfield(L, -2, "f");
    lua_pushinteger(L, zx->b);
    lua_setfield(L, -2, "b");
    lua_pushinteger(L, zx->c);
    lua_setfield(L, -2, "c");
    lua_pushinteger(L, zx->d);
    lua_setfield(L, -2, "d");
    lua_pushinteger(L, zx->e);
    lua_setfield(L, -2, "e");
    lua_pushinteger(L, zx->h);
    lua_setfield(L, -2, "h");
    lua_pushinteger(L, zx->l);
    lua_setfield(L, -2, "l");
    lua_pushinteger(L, zx->pc);
    lua_setfield(L, -2, "pc");
    lua_pushinteger(L, zx->sp);
    lua_setfield(L, -2, "sp");
    lua_pushinteger(L, zx->ix);
    lua_setfield(L, -2, "ix");
    lua_pushinteger(L, zx->iy);
    lua_setfield(L, -2, "iy");
    lua_pushinteger(L, zx->i);
    lua_setfield(L, -2, "i");
    lua_pushinteger(L, zx->r);
    lua_setfield(L, -2, "r");
    lua_pushinteger(L, zx->iff1);
    lua_setfield(L, -2, "iff1");
    lua_pushinteger(L, zx->iff2);
    lua_setfield(L, -2, "iff2");
    lua_pushinteger(L, zx->im);
    lua_setfield(L, -2, "im");
    lua_pushboolean(L, zx->halted);
    lua_setfield(L, -2, "halted");
    lua_pushinteger(L, zx->last_in_port);
    lua_setfield(L, -2, "last_in_port");
    lua_pushinteger(L, zx->last_in_result);
    lua_setfield(L, -2, "last_in_result");
    lua_pushinteger(L, zx->keyboard_reads);
    lua_setfield(L, -2, "keyboard_reads");

    lua_pushinteger(L, zx->tape.loaded);
    lua_setfield(L, -2, "tape_loaded");
    lua_pushinteger(L, zx->tape.playing);
    lua_setfield(L, -2, "tape_playing");
    lua_pushinteger(L, zx->tape.phase);
    lua_setfield(L, -2, "tape_phase");
    lua_pushinteger(L, zx->tape.block_idx);
    lua_setfield(L, -2, "tape_block_idx");
    lua_pushinteger(L, zx->tape.block_count);
    lua_setfield(L, -2, "tape_block_count");

    int cur_len = 0;
    if (zx->tape.block_idx >= 0 && zx->tape.block_idx < zx->tape.block_count)
        cur_len = zx->tape.blocks[zx->tape.block_idx].len;
    lua_pushinteger(L, cur_len);
    lua_setfield(L, -2, "tape_block_len");
    lua_pushinteger(L, zx->tape.ear_level);
    lua_setfield(L, -2, "tape_ear");
    lua_pushinteger(L, zx->tape.tstates_rem);
    lua_setfield(L, -2, "tape_tstates_rem");
    lua_pushinteger(L, zx->tape.byte_idx);
    lua_setfield(L, -2, "tape_byte_idx");
    lua_pushinteger(L, zx->tape.bit_idx);
    lua_setfield(L, -2, "tape_bit_idx");
    lua_pushinteger(L, zx->tape.pilot_rem);
    lua_setfield(L, -2, "tape_pilot_rem");
    lua_pushinteger(L, zx->tape.pulse_in_bit);
    lua_setfield(L, -2, "tape_pulse_in_bit");

    // IM2 debug: show current vector bytes + IM2 table write activity
    if (zx->im == 2) {
        uint8_t vec     = zx->int_vector_fixed ? zx->int_vector : floating_bus_read(zx);
        uint16_t ptr    = (uint16_t)((zx->i << 8) | vec);
        uint16_t ptr_hi = (uint16_t)((zx->i << 8) | (uint8_t)(vec + 1));
        uint8_t lo      = mem_read(zx, ptr);
        uint8_t hi      = mem_read(zx, ptr_hi);

        lua_pushinteger(L, zx->int_vector);
        lua_setfield(L, -2, "int_vector");
        lua_pushboolean(L, zx->int_vector_fixed);
        lua_setfield(L, -2, "int_vector_fixed");
        lua_pushinteger(L, vec);
        lua_setfield(L, -2, "im2_bus");

        lua_pushinteger(L, ptr);
        lua_setfield(L, -2, "im2_ptr");
        lua_pushinteger(L, lo);
        lua_setfield(L, -2, "im2_lo");
        lua_pushinteger(L, hi);
        lua_setfield(L, -2, "im2_hi");
        lua_pushinteger(L, (uint16_t)(lo | (hi << 8)));
        lua_setfield(L, -2, "im2_vec");

        lua_pushinteger(L, zx->im2_page_write_count);
        lua_setfield(L, -2, "im2_page_writes");
        lua_pushinteger(L, zx->im2_last_write_addr);
        lua_setfield(L, -2, "im2_last_write_addr");
        lua_pushinteger(L, zx->im2_last_write_val);
        lua_setfield(L, -2, "im2_last_write_val");
    }

    return 1;
}

// Close the emulator instance (can also use __gc)
static int zx_close(lua_State *L) {
    ZXState *zx = check_zx(L);
    tape_free_state(zx);
    // Note: userdata is freed by Lua GC
    lua_pushboolean(L, 1);
    return 1;
}

// Poll stdin for input with timeout (milliseconds)
// Returns true if input is available, false on timeout
static int zx_poll_stdin(lua_State *L) {
    int timeout_ms = luaL_optinteger(L, 1, 0);

    struct pollfd pfd;
    pfd.fd     = STDIN_FILENO;
    pfd.events = POLLIN;

    int ret = poll(&pfd, 1, timeout_ms);

    if (ret > 0 && (pfd.revents & POLLIN)) {
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

// Get current machine type
static int zx_get_machine_type(lua_State *L) {
    ZXState *zx = check_zx(L);

    switch (zx->machine_type) {
    case MACHINE_48K:
        lua_pushstring(L, "48k");
        break;
    case MACHINE_128K:
        lua_pushstring(L, "128k");
        break;
    case MACHINE_PLUS2:
        lua_pushstring(L, "plus2");
        break;
    default:
        lua_pushstring(L, "unknown");
    }
    return 1;
}

// Get AY-3-8912 register state (for debugging)
static int zx_get_ay_registers(lua_State *L) {
    ZXState *zx = check_zx(L);

    if (zx->machine_type == MACHINE_48K) {
        lua_pushnil(L);
        return 1;
    }

    lua_newtable(L);
    for (int i = 0; i < 16; i++) {
        lua_pushinteger(L, zx->ay.regs[i]);
        lua_rawseti(L, -2, i);
    }
    lua_pushinteger(L, zx->ay.selected_reg);
    lua_setfield(L, -2, "selected");
    return 1;
}

// Get memory banking state (for debugging 128k issues)
static int zx_get_banking_state(lua_State *L) {
    ZXState *zx = check_zx(L);

    lua_newtable(L);
    lua_pushinteger(L, zx->port_7ffd);
    lua_setfield(L, -2, "port_7ffd");
    lua_pushinteger(L, zx->port_7ffd & 0x07);
    lua_setfield(L, -2, "ram_page");
    lua_pushinteger(L, (zx->port_7ffd >> 3) & 1);
    lua_setfield(L, -2, "screen_select");
    lua_pushinteger(L, (zx->port_7ffd >> 4) & 1);
    lua_setfield(L, -2, "rom_select");
    lua_pushboolean(L, zx->paging_disabled);
    lua_setfield(L, -2, "paging_disabled");
    lua_pushinteger(L, zx->active_screen);
    lua_setfield(L, -2, "active_screen");
    lua_pushinteger(L, zx->screen_switch_count);
    lua_setfield(L, -2, "screen_switch_count");
    lua_pushinteger(L, zx->port_7ffd_write_count);
    lua_setfield(L, -2, "port_7ffd_write_count");

    // Sample first 16 bytes of bank 5 and bank 7 screen areas for debugging
    lua_pushlstring(L, (const char *)zx->ram_banks[5], 16);
    lua_setfield(L, -2, "bank5_sample");
    lua_pushlstring(L, (const char *)zx->ram_banks[7], 16);
    lua_setfield(L, -2, "bank7_sample");
    return 1;
}

/* --------------------------------------------------------------------------
 * Module registration
 * -------------------------------------------------------------------------- */

// Instance methods (called with : syntax, first arg is userdata)
static const luaL_Reg zx_methods[] = {
    {"reset",             zx_reset            },
    {"close",             zx_close            },
    {"load_rom",          zx_load_rom         },
    {"poke",              zx_poke             },
    {"peek",              zx_peek             },
    {"load_memory",       zx_load_memory      },
    {"save_z80",          zx_save_z80         },
    {"load_z80",          zx_load_z80         },
    {"load_tap",          zx_load_tap         },
    {"load_tzx",          zx_load_tzx         },
    {"tape_play",         zx_tape_play        },
    {"tape_rewind",       zx_tape_rewind      },
    {"set_tape_audio",    zx_set_tape_audio   },
    {"set_int_vector",    zx_set_int_vector   },
    {"run_frame",         zx_run_frame        },
    {"get_screen",        zx_get_screen       },
    {"key_down",          zx_key_down         },
    {"key_up",            zx_key_up           },
    {"get_border",        zx_get_border       },
    {"get_border_lines",  zx_get_border_lines },
    {"get_keyboard",      zx_get_keyboard     },
    {"get_beeper",        zx_get_beeper       },
    {"get_audio_samples", zx_get_audio_samples},
    {"get_pc_history",    zx_get_pc_history   },
    {"step",              zx_step             },
    {"get_registers",     zx_get_registers    },
    {"get_machine_type",  zx_get_machine_type },
    {"get_ay_registers",  zx_get_ay_registers },
    {"get_banking_state", zx_get_banking_state},
    {NULL,                NULL                }
};

// Module-level functions (no instance required)
static const luaL_Reg zx_module_funcs[] = {
    {"new",        zx_new       },
    {"poll_stdin", zx_poll_stdin},
    {NULL,         NULL         }
};

int luaopen_zx_core(lua_State *L) {
    // Create metatable for emulator instances
    luaL_newmetatable(L, ZX_EMU_MT);

    // mt.__index = methods table
    lua_newtable(L);
    luaL_register(L, NULL, zx_methods);
    lua_setfield(L, -2, "__index");

    // mt.__gc = gc function
    lua_pushcfunction(L, zx_gc);
    lua_setfield(L, -2, "__gc");

    lua_pop(L, 1); // pop metatable

    // Create and return module table
    luaL_register(L, "zx.core", zx_module_funcs);
    return 1;
}
