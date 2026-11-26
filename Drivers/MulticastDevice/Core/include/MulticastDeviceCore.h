// The pure, testable parts of the Multicast output device driver: the loopback ring that
// carries the output mix to the hidden input device, the clock (zero time stamps), volume
// curves and latency arithmetic. No Core Audio types: the driver and the Swift tests share it.
//
// Real-time rules: everything except MCLoopbackCreate / MCLoopbackDestroy is lock-free and
// allocation-free, so it may run on the HAL IO threads.

#ifndef MULTICAST_DEVICE_CORE_H
#define MULTICAST_DEVICE_CORE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: Shared constants

/// Channels of both devices (interleaved Float32).
#define MC_CHANNELS 2u
/// Frames between two zero time stamps, and the loopback ring's capacity.
#define MC_PERIOD_FRAMES 16384u
/// Lowest volume the control reports, in dB (scalar 0 is silence).
#define MC_VOLUME_MIN_DB (-64.0f)

/// UIDs of the two devices. The hub finds the hidden one by its UID.
#define MC_OUTPUT_DEVICE_UID "io.github.longtimeno-c.multicast.device.output"
#define MC_LOOPBACK_DEVICE_UID "io.github.longtimeno-c.multicast.device.loopback"
#define MC_MODEL_UID "io.github.longtimeno-c.multicast.device.model"
/// Custom property on the output device: the hub's playout delay in seconds (CFNumber).
/// Four-char code 'mcLt'.
#define MC_PROPERTY_HUB_LATENCY 0x6D634C74u

/// Sample rates both devices offer. 44.1 kHz is the pipeline rate (no resampling in the hub).
bool MCIsSupportedSampleRate(double rate);
uint32_t MCSupportedSampleRateCount(void);
double MCSupportedSampleRate(uint32_t index);

// MARK: Loopback ring

/// Interleaved stereo Float32 ring indexed by absolute sample time. One writer (the output
/// device's WriteMix) and any number of readers (the loopback device's ReadInput).
typedef struct MCLoopback MCLoopback;

/// `capacityFrames` is rounded up to a power of two. Not real-time safe.
MCLoopback *MCLoopbackCreate(uint32_t capacityFrames);
void MCLoopbackDestroy(MCLoopback *ring);
uint32_t MCLoopbackCapacity(const MCLoopback *ring);

/// Forgets everything written (sample rate change, IO restart). Reads return silence until
/// the next write.
void MCLoopbackReset(MCLoopback *ring);

/// Stores `frames` frames for sample times [sampleTime, sampleTime + frames), multiplied by
/// `gain`. A write that does not continue the previous one starts a new run: older frames are
/// no longer readable, so a reader never gets audio from an earlier lap of the ring.
void MCLoopbackWrite(MCLoopback *ring, int64_t sampleTime, const float *interleaved,
                     uint32_t frames, float gain);

/// Fills `frames` frames for [sampleTime, sampleTime + frames). Frames that were written in the
/// current run and not yet overwritten are copied; the rest are zeros. Returns how many frames
/// were real audio.
uint32_t MCLoopbackRead(const MCLoopback *ring, int64_t sampleTime, float *interleaved, uint32_t frames);

/// Sample time just past the last frame written (0 before any write).
int64_t MCLoopbackWriteEnd(const MCLoopback *ring);

// MARK: Clock

/// Host ticks (mach_absolute_time units) per frame at `sampleRate`, given the timebase.
double MCHostTicksPerFrame(double sampleRate, uint32_t timebaseNumer, uint32_t timebaseDenom);

/// The most recent zero time stamp at or before `nowTicks`, for a clock anchored at
/// `anchorTicks` (sample time 0) that steps every `periodFrames` frames. Stateless, so both
/// devices, sharing one anchor, agree on every sample time.
void MCClockZeroTimeStamp(uint64_t anchorTicks, double hostTicksPerFrame, uint32_t periodFrames,
                          uint64_t nowTicks, double *outSampleTime, uint64_t *outHostTicks,
                          uint64_t *outSeed);

// MARK: Volume

/// Volume control curve: scalar 0…1 <-> dB in [MC_VOLUME_MIN_DB, 0], cubic-ish (dB linear in
/// the scalar), the shape macOS's own volume keys feel right with.
float MCVolumeScalarToDecibels(float scalar);
float MCVolumeDecibelsToScalar(float decibels);
/// Linear gain applied to the mix: 0 when muted or at scalar 0.
float MCVolumeGain(float scalar, bool muted);

// MARK: Latency

/// Frames of latency the output device reports for a hub playout delay of `seconds`
/// (clamped to 0…10 s) at `sampleRate`.
uint32_t MCLatencyFrames(double seconds, double sampleRate);

#ifdef __cplusplus
}
#endif

#endif
