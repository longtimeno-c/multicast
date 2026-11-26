#include "MulticastDeviceCore.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// MARK: Sample rates

static const double kRates[] = {44100.0, 48000.0};

bool MCIsSupportedSampleRate(double rate) {
    for (uint32_t i = 0; i < MCSupportedSampleRateCount(); i++) {
        if (kRates[i] == rate) return true;
    }
    return false;
}

uint32_t MCSupportedSampleRateCount(void) { return (uint32_t)(sizeof(kRates) / sizeof(kRates[0])); }

double MCSupportedSampleRate(uint32_t index) {
    return index < MCSupportedSampleRateCount() ? kRates[index] : 0;
}

// MARK: Loopback ring

struct MCLoopback {
    float *samples;
    uint32_t capacity;  // frames, power of two
    int64_t mask;
    // First sample time of the current contiguous run of writes, and one past its last frame.
    // runStart <= writeEnd. Published with release after the samples, read with acquire.
    _Atomic int64_t runStart;
    _Atomic int64_t writeEnd;
};

MCLoopback *MCLoopbackCreate(uint32_t capacityFrames) {
    uint32_t cap = 1;
    while (cap < capacityFrames && cap < (1u << 30)) cap <<= 1;
    MCLoopback *ring = calloc(1, sizeof(MCLoopback));
    if (!ring) return NULL;
    ring->samples = calloc((size_t)cap * MC_CHANNELS, sizeof(float));
    if (!ring->samples) { free(ring); return NULL; }
    ring->capacity = cap;
    ring->mask = (int64_t)cap - 1;
    atomic_init(&ring->runStart, 0);
    atomic_init(&ring->writeEnd, 0);
    return ring;
}

void MCLoopbackDestroy(MCLoopback *ring) {
    if (!ring) return;
    free(ring->samples);
    free(ring);
}

uint32_t MCLoopbackCapacity(const MCLoopback *ring) { return ring->capacity; }

void MCLoopbackReset(MCLoopback *ring) {
    // An empty run: nothing is readable.
    atomic_store_explicit(&ring->runStart, 0, memory_order_release);
    atomic_store_explicit(&ring->writeEnd, 0, memory_order_release);
}

int64_t MCLoopbackWriteEnd(const MCLoopback *ring) {
    return atomic_load_explicit(&((MCLoopback *)ring)->writeEnd, memory_order_acquire);
}

void MCLoopbackWrite(MCLoopback *ring, int64_t sampleTime, const float *interleaved,
                     uint32_t frames, float gain) {
    if (frames == 0) return;
    if (frames > ring->capacity) {
        // Only the newest `capacity` frames can be kept.
        uint32_t skip = frames - ring->capacity;
        interleaved += (size_t)skip * MC_CHANNELS;
        sampleTime += skip;
        frames = ring->capacity;
    }
    int64_t end = atomic_load_explicit(&ring->writeEnd, memory_order_relaxed);
    int64_t start = atomic_load_explicit(&ring->runStart, memory_order_relaxed);
    if (sampleTime != end || end == start) {
        // A new run (first write, a gap, a rewind or an IO restart). Close the old run first,
        // so a reader can't pair the old end with frames about to be overwritten.
        atomic_store_explicit(&ring->writeEnd, sampleTime, memory_order_release);
        atomic_store_explicit(&ring->runStart, sampleTime, memory_order_release);
        start = sampleTime;
    }
    for (uint32_t i = 0; i < frames; i++) {
        size_t slot = (size_t)((sampleTime + i) & ring->mask) * MC_CHANNELS;
        const float *src = interleaved + (size_t)i * MC_CHANNELS;
        for (uint32_t c = 0; c < MC_CHANNELS; c++) ring->samples[slot + c] = src[c] * gain;
    }
    atomic_store_explicit(&ring->writeEnd, sampleTime + frames, memory_order_release);
}

uint32_t MCLoopbackRead(const MCLoopback *ring, int64_t sampleTime, float *interleaved, uint32_t frames) {
    MCLoopback *r = (MCLoopback *)ring;
    int64_t end = atomic_load_explicit(&r->writeEnd, memory_order_acquire);
    int64_t start = atomic_load_explicit(&r->runStart, memory_order_acquire);
    // Readable: inside the current run and not yet overwritten by a later lap.
    int64_t lo = start;
    if (end - (int64_t)r->capacity > lo) lo = end - (int64_t)r->capacity;
    uint32_t real = 0;
    for (uint32_t i = 0; i < frames; i++) {
        int64_t t = sampleTime + i;
        float *dst = interleaved + (size_t)i * MC_CHANNELS;
        if (t >= lo && t < end) {
            size_t slot = (size_t)(t & r->mask) * MC_CHANNELS;
            for (uint32_t c = 0; c < MC_CHANNELS; c++) dst[c] = r->samples[slot + c];
            real++;
        } else {
            for (uint32_t c = 0; c < MC_CHANNELS; c++) dst[c] = 0;
        }
    }
    return real;
}

// MARK: Clock

double MCHostTicksPerFrame(double sampleRate, uint32_t timebaseNumer, uint32_t timebaseDenom) {
    if (sampleRate <= 0 || timebaseNumer == 0) return 0;
    // ticks = nanos * denom / numer
    return (1.0e9 / sampleRate) * (double)timebaseDenom / (double)timebaseNumer;
}

void MCClockZeroTimeStamp(uint64_t anchorTicks, double hostTicksPerFrame, uint32_t periodFrames,
                          uint64_t nowTicks, double *outSampleTime, uint64_t *outHostTicks,
                          uint64_t *outSeed) {
    double ticksPerPeriod = hostTicksPerFrame * (double)periodFrames;
    uint64_t periods = 0;
    if (nowTicks > anchorTicks && ticksPerPeriod > 0) {
        periods = (uint64_t)floor((double)(nowTicks - anchorTicks) / ticksPerPeriod);
    }
    *outSampleTime = (double)periods * (double)periodFrames;
    *outHostTicks = anchorTicks + (uint64_t)llround((double)periods * ticksPerPeriod);
    *outSeed = 1;
}

// MARK: Volume

float MCVolumeScalarToDecibels(float scalar) {
    if (!(scalar > 0)) return MC_VOLUME_MIN_DB;
    if (scalar >= 1) return 0;
    return MC_VOLUME_MIN_DB * (1.0f - scalar);
}

float MCVolumeDecibelsToScalar(float decibels) {
    if (!(decibels > MC_VOLUME_MIN_DB)) return 0;
    if (decibels >= 0) return 1;
    return 1.0f - decibels / MC_VOLUME_MIN_DB;
}

float MCVolumeGain(float scalar, bool muted) {
    if (muted || !(scalar > 0)) return 0;
    if (scalar >= 1) return 1;
    return powf(10.0f, MCVolumeScalarToDecibels(scalar) / 20.0f);
}

// MARK: Latency

uint32_t MCLatencyFrames(double seconds, double sampleRate) {
    if (!(seconds > 0) || !(sampleRate > 0)) return 0;
    if (seconds > 10) seconds = 10;
    return (uint32_t)llround(seconds * sampleRate);
}
