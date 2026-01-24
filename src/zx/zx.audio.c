// SPDX-FileCopyrightText: © 2026 Vladimir Zorin <vladimir@deviant.guru>
// SPDX-License-Identifier: OWL-1.0 or later
// Licensed under the Open Weights License v1.0. See LICENSE for details.

/*
 * ZX Spectrum Audio Output (Direct PCM via kernel ioctls)
 *
 * Bypasses ALSA userspace library entirely, using raw kernel interface.
 * No external dependencies required.
 */

#include <errno.h>
#include <fcntl.h>
#include <lauxlib.h>
#include <limits.h>
#include <lua.h>
#include <sound/asound.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static int pcm_fd                    = -1;
static int sample_rate               = 44100;
static int initialized               = 0;
static unsigned int hw_period_frames = 0;

/*
 * Userspace ring buffer to decouple emulation from audio device writes.
 *
 * Goal: stable audio without ever blocking the emulator. We keep the PCM fd
 * non-blocking and buffer a small amount of audio here (~100-150ms target,
 * ~180ms capacity).
 */
#define ZX_AUDIO_CHANNELS    2
#define ZX_AUDIO_RING_FRAMES 8192 /* ~186ms @ 44100 Hz */

static int16_t audio_ring[ZX_AUDIO_RING_FRAMES * ZX_AUDIO_CHANNELS];
static unsigned int ring_rpos  = 0; /* frames */
static unsigned int ring_wpos  = 0; /* frames */
static unsigned int ring_count = 0; /* frames */

static void ring_reset(void) {
    ring_rpos  = 0;
    ring_wpos  = 0;
    ring_count = 0;
}

static void ring_drop_oldest(unsigned int frames) {
    if (frames >= ring_count) {
        ring_reset();
        return;
    }
    ring_rpos = (ring_rpos + frames) % ZX_AUDIO_RING_FRAMES;
    ring_count -= frames;
}

static void ring_write_stereo_frames(const int16_t *stereo, unsigned int frames) {
    if (frames == 0)
        return;

    /* Keep latency bounded: if overflow, drop oldest samples. */
    unsigned int free_frames = ZX_AUDIO_RING_FRAMES - ring_count;
    if (frames > free_frames)
        ring_drop_oldest(frames - free_frames);

    while (frames > 0) {
        unsigned int chunk      = frames;
        unsigned int until_wrap = ZX_AUDIO_RING_FRAMES - ring_wpos;
        if (chunk > until_wrap)
            chunk = until_wrap;

        memcpy(&audio_ring[ring_wpos * ZX_AUDIO_CHANNELS], stereo, chunk * ZX_AUDIO_CHANNELS * sizeof(int16_t));

        ring_wpos = (ring_wpos + chunk) % ZX_AUDIO_RING_FRAMES;
        ring_count += chunk;
        stereo += chunk * ZX_AUDIO_CHANNELS;
        frames -= chunk;
    }
}

static unsigned int ring_read_contiguous_ptr(const int16_t **out_ptr) {
    if (ring_count == 0) {
        *out_ptr = NULL;
        return 0;
    }

    *out_ptr                = &audio_ring[ring_rpos * ZX_AUDIO_CHANNELS];
    unsigned int until_wrap = ZX_AUDIO_RING_FRAMES - ring_rpos;
    return ring_count < until_wrap ? ring_count : until_wrap;
}

static void param_set_mask(struct snd_pcm_hw_params *p, int param, unsigned int val) {
    struct snd_mask *m = &p->masks[param - SNDRV_PCM_HW_PARAM_FIRST_MASK];
    memset(m, 0, sizeof(*m));
    m->bits[val >> 5] |= (1U << (val & 31));
}

static void param_set_int(struct snd_pcm_hw_params *p, int param, unsigned int val) {
    struct snd_interval *i = &p->intervals[param - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL];
    i->min = i->max = val;
    i->openmin = i->openmax = 0;
    i->integer              = 1;
    i->empty                = 0;
}

static void param_set_range(struct snd_pcm_hw_params *p, int param, unsigned int min, unsigned int max) {
    struct snd_interval *i = &p->intervals[param - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL];
    i->min                 = min;
    i->max                 = max;
    i->openmin = i->openmax = 0;
    i->integer              = 1;
    i->empty                = 0;
}

static unsigned int param_get_int(struct snd_pcm_hw_params *p, int param) {
    struct snd_interval *i = &p->intervals[param - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL];
    return i->min;
}

static void hw_params_set_any(struct snd_pcm_hw_params *p) {
    memset(p, 0, sizeof(*p));

    for (int i = 0; i <= SNDRV_PCM_HW_PARAM_LAST_MASK - SNDRV_PCM_HW_PARAM_FIRST_MASK; i++)
        memset(&p->masks[i], 0xff, sizeof(p->masks[i]));

    for (int i = 0; i <= SNDRV_PCM_HW_PARAM_LAST_INTERVAL - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL; i++) {
        p->intervals[i].min     = 0;
        p->intervals[i].max     = UINT_MAX;
        p->intervals[i].integer = 1;
    }
}

static void hw_params_set_common(struct snd_pcm_hw_params *p, int rate) {
    param_set_mask(p, SNDRV_PCM_HW_PARAM_ACCESS, SNDRV_PCM_ACCESS_RW_INTERLEAVED);
    param_set_mask(p, SNDRV_PCM_HW_PARAM_FORMAT, SNDRV_PCM_FORMAT_S16_LE);
    param_set_mask(p, SNDRV_PCM_HW_PARAM_SUBFORMAT, SNDRV_PCM_SUBFORMAT_STD);
    param_set_int(p, SNDRV_PCM_HW_PARAM_CHANNELS, 2);
    param_set_int(p, SNDRV_PCM_HW_PARAM_RATE, (unsigned int)rate);

    p->rmask = ~0U;
    p->cmask = 0;
    p->info  = ~0U;
}

/* Try to open a PCM playback device, returns fd or -1 */
static int try_open_pcm(const char *path) {
    return open(path, O_WRONLY | O_NONBLOCK);
}

/* Find and open first available playback device */
static int find_playback_device(char *out_path, size_t out_size) {
    /* Common device paths to try, in order of preference */
    static const char *devices[] = {"/dev/snd/pcmC1D0p", /* Card 1, Device 0 (common for main audio) */
                                    "/dev/snd/pcmC0D0p", /* Card 0, Device 0 */
                                    "/dev/snd/pcmC2D0p", /* Card 2, Device 0 */
                                    "/dev/snd/pcmC0D3p", /* Card 0, Device 3 (HDMI) */
                                    "/dev/snd/pcmC0D7p", /* Card 0, Device 7 (HDMI) */
                                    NULL};

    for (int i = 0; devices[i]; i++) {
        int fd = try_open_pcm(devices[i]);
        if (fd >= 0) {
            snprintf(out_path, out_size, "%s", devices[i]);
            return fd;
        }
    }
    return -1;
}

/*
 * audio.init(sample_rate, device)
 *
 * Initialize PCM output via direct kernel interface.
 * device: "auto" (default), card number (0, 1, ...), or full path like "/dev/snd/pcmC1D0p"
 */
static int zx_audio_init(lua_State *L) {
    int rate               = luaL_optinteger(L, 1, 44100);
    const char *device_arg = luaL_optstring(L, 2, "auto");

    if (initialized) {
        lua_pushboolean(L, 1);
        lua_pushinteger(L, sample_rate);
        return 2;
    }

    char device_path[64];

    if (strcmp(device_arg, "auto") == 0) {
        pcm_fd = find_playback_device(device_path, sizeof(device_path));
        if (pcm_fd < 0) {
            lua_pushnil(L);
            lua_pushstring(L, "No audio playback device found");
            return 2;
        }
    } else if (device_arg[0] == '/') {
        snprintf(device_path, sizeof(device_path), "%s", device_arg);
        pcm_fd = open(device_path, O_WRONLY | O_NONBLOCK);
    } else {
        int card = atoi(device_arg);
        snprintf(device_path, sizeof(device_path), "/dev/snd/pcmC%dD0p", card);
        pcm_fd = open(device_path, O_WRONLY | O_NONBLOCK);
    }

    if (pcm_fd < 0) {
        lua_pushnil(L);
        lua_pushfstring(L, "Cannot open audio device '%s': %s", device_path, strerror(errno));
        return 2;
    }

    /* Keep non-blocking: never stall emulation on audio. */
    {
        int flags = fcntl(pcm_fd, F_GETFL);
        if (flags >= 0)
            (void)fcntl(pcm_fd, F_SETFL, flags | O_NONBLOCK);
    }

    /* Set up hardware parameters with specific constraints */
    struct snd_pcm_hw_params hw_params;
    hw_params_set_any(&hw_params);
    hw_params_set_common(&hw_params, rate);

    /*
     * Try time-based constraints first. Many drivers accept these even when
     * they reject explicit frame-size constraints.
     */
    param_set_range(&hw_params, SNDRV_PCM_HW_PARAM_BUFFER_TIME, 100000, 150000); /* 100-150ms */
    param_set_range(&hw_params, SNDRV_PCM_HW_PARAM_PERIOD_TIME, 10000, 30000);   /* 10-30ms */

    /* Try to set parameters with requested timing */
    if (ioctl(pcm_fd, SNDRV_PCM_IOCTL_HW_PARAMS, &hw_params) < 0) {
        /* If that fails, try frame-based constraints as a fallback. */
        hw_params_set_any(&hw_params);
        hw_params_set_common(&hw_params, rate);

        param_set_range(&hw_params, SNDRV_PCM_HW_PARAM_PERIOD_SIZE, 256, 2048);
        param_set_range(&hw_params, SNDRV_PCM_HW_PARAM_BUFFER_SIZE, 2048, 16384);

        if (ioctl(pcm_fd, SNDRV_PCM_IOCTL_HW_PARAMS, &hw_params) < 0) {
            /* Last-resort: accept driver defaults (still non-blocking + ring buffer). */
            hw_params_set_any(&hw_params);
            hw_params_set_common(&hw_params, rate);

            if (ioctl(pcm_fd, SNDRV_PCM_IOCTL_HW_PARAMS, &hw_params) < 0) {
                close(pcm_fd);
                pcm_fd = -1;
                lua_pushnil(L);
                lua_pushfstring(L, "Cannot set hardware params: %s", strerror(errno));
                return 2;
            }
        }
    }

    /* Extract actual values chosen by kernel */
    unsigned int actual_buffer = param_get_int(&hw_params, SNDRV_PCM_HW_PARAM_BUFFER_SIZE);
    unsigned int actual_period = param_get_int(&hw_params, SNDRV_PCM_HW_PARAM_PERIOD_SIZE);

    /* Set software parameters - balance latency vs stability */
    struct snd_pcm_sw_params sw_params;
    memset(&sw_params, 0, sizeof(sw_params));
    /*
     * Software params: start quickly and wake writes once a period is available.
     * This keeps latency reasonable even if the driver chooses larger values.
     */
    sw_params.avail_min         = actual_period;
    sw_params.start_threshold   = actual_period; /* Start after 1 period */
    sw_params.stop_threshold    = actual_buffer;
    sw_params.silence_threshold = 0;
    sw_params.silence_size      = 0;
    sw_params.boundary          = actual_buffer;
    while (sw_params.boundary * 2 <= 0x7fffffffUL)
        sw_params.boundary *= 2;

    if (ioctl(pcm_fd, SNDRV_PCM_IOCTL_SW_PARAMS, &sw_params) < 0) {
        close(pcm_fd);
        pcm_fd = -1;
        lua_pushnil(L);
        lua_pushfstring(L, "Cannot set software params: %s", strerror(errno));
        return 2;
    }

    /* Prepare the device */
    if (ioctl(pcm_fd, SNDRV_PCM_IOCTL_PREPARE) < 0) {
        close(pcm_fd);
        pcm_fd = -1;
        lua_pushnil(L);
        lua_pushfstring(L, "Cannot prepare device: %s", strerror(errno));
        return 2;
    }

    sample_rate      = rate;
    initialized      = 1;
    hw_period_frames = actual_period;
    ring_reset();
    lua_pushboolean(L, 1);
    lua_pushinteger(L, rate);
    lua_pushinteger(L, actual_buffer); /* Return buffer size for debugging */
    lua_pushinteger(L, actual_period); /* Return period size for debugging */
    return 4;
}

/* Static buffer for mono->stereo conversion */
static int16_t stereo_buffer[4096];

static int get_pcm_delay_frames(int *out_delay) {
    if (!initialized || pcm_fd < 0)
        return -1;

    struct snd_pcm_status st;
    memset(&st, 0, sizeof(st));
    if (ioctl(pcm_fd, SNDRV_PCM_IOCTL_STATUS, &st) < 0)
        return -1;

    /* st.delay is in frames */
    if (st.delay < 0)
        *out_delay = 0;
    else if (st.delay > INT_MAX)
        *out_delay = INT_MAX;
    else
        *out_delay = (int)st.delay;
    return 0;
}

static unsigned int audio_flush_nonblocking(void) {
    if (!initialized || pcm_fd < 0)
        return 0;

    unsigned int total_written = 0;

    /*
     * Do not get too far ahead of real-time.
     * Some drivers accept writes into very large buffers (seconds), which makes
     * audio "behind" even though emulation is correct.
     */
    int delay_frames = 0;
    (void)get_pcm_delay_frames(&delay_frames);

    /*
     * Keep a bounded amount of audio queued, but never less than one hardware
     * period, otherwise playback may not start (start_threshold) and we get
     * glitches/underruns.
     */
    int desired      = (sample_rate * 130) / 1000; /* ~130ms */
    int target_delay = desired;
    if (hw_period_frames > 0 && (int)hw_period_frames > target_delay)
        target_delay = (int)hw_period_frames;

    /* Allow a small cushion above target. */
    int max_delay = target_delay + (sample_rate * 40) / 1000; /* +40ms */

    /* If already too far queued, stop writing until it drains naturally. */
    if (delay_frames > max_delay)
        return 0;

    while (ring_count > 0) {
        if (delay_frames >= target_delay)
            break;

        const int16_t *ptr;
        unsigned int frames = ring_read_contiguous_ptr(&ptr);
        if (frames == 0 || ptr == NULL)
            break;

        /* Only write up to the target ahead. */
        int budget = target_delay - delay_frames;
        if (budget <= 0)
            break;
        if (frames > (unsigned int)budget)
            frames = (unsigned int)budget;

        struct snd_xferi xfer;
        xfer.buf    = (void *)ptr;
        xfer.frames = frames;
        xfer.result = 0;

        if (ioctl(pcm_fd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, &xfer) < 0) {
            if (errno == EPIPE) {
                /* Underrun: recover and try again on next call. */
                (void)ioctl(pcm_fd, SNDRV_PCM_IOCTL_PREPARE);
                break;
            }
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                /* Device not ready for more; never block emulation. */
                break;
            }
            /* Any other error: stop producing audio, but don't stall emulation. */
            break;
        }

        if (xfer.result <= 0)
            break;

        unsigned int written = (unsigned int)xfer.result;
        ring_rpos            = (ring_rpos + written) % ZX_AUDIO_RING_FRAMES;
        ring_count -= written;
        total_written += written;
        delay_frames += (int)written;
    }

    return total_written;
}

/*
 * audio.write(samples)
 *
 * Write PCM samples to audio device.
 * samples: string of int16_t mono values (little-endian)
 * Converts mono to stereo internally.
 */
static int zx_audio_write(lua_State *L) {
    if (!initialized || pcm_fd < 0) {
        lua_pushinteger(L, 0);
        return 1;
    }

    size_t len;
    const char *samples = luaL_checklstring(L, 1, &len);

    if (len == 0) {
        lua_pushinteger(L, 0);
        return 1;
    }

    /* Input is mono int16_t samples */
    const int16_t *mono = (const int16_t *)samples;
    size_t mono_frames  = len / 2;

    /* Convert mono to stereo in chunks, enqueue into ring buffer */
    size_t chunk_frames = sizeof(stereo_buffer) / (2 * sizeof(int16_t)); /* stereo frames per chunk */

    while (mono_frames > 0) {
        size_t frames = mono_frames < chunk_frames ? mono_frames : chunk_frames;

        /* Duplicate mono samples to stereo */
        for (size_t i = 0; i < frames; i++) {
            stereo_buffer[i * 2]     = mono[i]; /* left */
            stereo_buffer[i * 2 + 1] = mono[i]; /* right */
        }

        ring_write_stereo_frames(stereo_buffer, (unsigned int)frames);
        mono += frames;
        mono_frames -= frames;
    }

    /* Flush what we can without blocking */
    lua_pushinteger(L, (lua_Integer)audio_flush_nonblocking());
    return 1;
}

/*
 * audio.close()
 */
static int zx_audio_close(lua_State *L) {
    (void)L;

    if (pcm_fd >= 0) {
        ioctl(pcm_fd, SNDRV_PCM_IOCTL_DRAIN);
        close(pcm_fd);
        pcm_fd = -1;
    }

    initialized = 0;
    ring_reset();
    return 0;
}

/*
 * audio.get_sample_rate()
 */
static int zx_audio_get_sample_rate(lua_State *L) {
    lua_pushinteger(L, initialized ? sample_rate : 0);
    return 1;
}

/*
 * audio.is_initialized()
 */
static int zx_audio_is_initialized(lua_State *L) {
    lua_pushboolean(L, initialized);
    return 1;
}

/* Module registration */
static luaL_Reg zx_audio_funcs[] = {
    {"init",            zx_audio_init           },
    {"write",           zx_audio_write          },
    {"close",           zx_audio_close          },
    {"get_sample_rate", zx_audio_get_sample_rate},
    {"is_initialized",  zx_audio_is_initialized },
    {NULL,              NULL                    }
};

int luaopen_zx_audio(lua_State *L) {
    luaL_newlib(L, zx_audio_funcs);
    return 1;
}
