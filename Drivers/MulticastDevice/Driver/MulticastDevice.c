// Multicast output device: an AudioServerPlugIn (HAL plug-in) loaded by coreaudiod.
//
// It publishes two devices that share one clock and one loopback ring:
//   "Multicast"           output only, visible. Apps (Music, Spotify, System Settings › Sound)
//                         choose it as their output. Has volume and mute controls.
//   "Multicast Loopback"  input only, hidden. The Multicast hub opens it by UID and reads back,
//                         sample for sample, what was played to "Multicast".
//
// Format: interleaved Float32 stereo at 44.1 kHz (the hub's pipeline rate) or 48 kHz. The clock
// runs at exactly the nominal rate against host time, the same clock the hub paces with, so at
// 44.1 kHz nothing drifts. The output device reports the hub's playout delay (custom property
// 'mcLt', set by the hub) as its latency so video players keep A/V sync.
//
// All pure logic (ring, clock, volume curve, latency) is in ../Core and unit-tested there.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>

#include "MulticastDeviceCore.h"

// MARK: - Object ids

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_OutputDevice = 2,
    kObjectID_OutputStream = 3,
    kObjectID_Volume = 4,
    kObjectID_Mute = 5,
    kObjectID_LoopbackDevice = 6,
    kObjectID_InputStream = 7,
};

enum { kDeviceOutput = 0, kDeviceLoopback = 1 };

#define kManufacturer "Multicast"
#define kOutputName "Multicast"
#define kLoopbackName "Multicast Loopback"
#define kClockDomain 0x6D635F63u  // 'mc_c': both devices tick together

// MARK: - State

static AudioServerPlugInHostRef gHost = NULL;
static pthread_mutex_t gMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gRefCount = 0;

static MCLoopback *gRing = NULL;
static mach_timebase_info_data_t gTimebase;

// Changed only under gMutex while no IO runs (start or configuration change); read on IO threads.
static Float64 gSampleRate = 44100.0;
static double gTicksPerFrame = 0;
static UInt64 gAnchorTicks = 0;
static UInt32 gIORunning[2] = {0, 0};

static _Atomic float gVolume = 1.0f;
static _Atomic bool gMute = false;
static _Atomic bool gStreamActive[2] = {true, true};
static Float64 gHubLatencySeconds = 0;  // under gMutex

// MARK: - Driver interface (declarations)

static HRESULT MC_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG MC_AddRef(void *inDriver);
static ULONG MC_Release(void *inDriver);
static OSStatus MC_Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
static OSStatus MC_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo *, AudioObjectID *);
static OSStatus MC_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus MC_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *);
static OSStatus MC_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *);
static OSStatus MC_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);
static OSStatus MC_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);
static Boolean MC_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *);
static OSStatus MC_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, Boolean *);
static OSStatus MC_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *);
static OSStatus MC_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, UInt32 *, void *);
static OSStatus MC_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, const void *);
static OSStatus MC_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus MC_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus MC_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64 *, UInt64 *, UInt64 *);
static OSStatus MC_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean *, Boolean *);
static OSStatus MC_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *);
static OSStatus MC_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *, void *, void *);
static OSStatus MC_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    MC_QueryInterface, MC_AddRef, MC_Release,
    MC_Initialize, MC_CreateDevice, MC_DestroyDevice,
    MC_AddDeviceClient, MC_RemoveDeviceClient,
    MC_PerformDeviceConfigurationChange, MC_AbortDeviceConfigurationChange,
    MC_HasProperty, MC_IsPropertySettable, MC_GetPropertyDataSize, MC_GetPropertyData, MC_SetPropertyData,
    MC_StartIO, MC_StopIO, MC_GetZeroTimeStamp,
    MC_WillDoIOOperation, MC_BeginIOOperation, MC_DoIOOperation, MC_EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// MARK: - Factory (named in Info.plist)

void *MulticastDevice_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);
void *MulticastDevice_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    (void)allocator;
    if (CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}

// MARK: - IUnknown

static HRESULT MC_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriverRef || !outInterface) return kAudioHardwareIllegalOperationError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (!requested) return kAudioHardwareIllegalOperationError;
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gMutex);
        gRefCount++;
        pthread_mutex_unlock(&gMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG MC_AddRef(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gMutex);
    ULONG n = ++gRefCount;
    pthread_mutex_unlock(&gMutex);
    return n;
}

static ULONG MC_Release(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG n = gRefCount;
    pthread_mutex_unlock(&gMutex);
    return n;
}

// MARK: - Basic operations

static void UpdateClockLocked(void) {
    gTicksPerFrame = MCHostTicksPerFrame(gSampleRate, gTimebase.numer, gTimebase.denom);
}

static OSStatus MC_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    mach_timebase_info(&gTimebase);
    pthread_mutex_lock(&gMutex);
    if (!gRing) gRing = MCLoopbackCreate(MC_PERIOD_FRAMES);
    UpdateClockLocked();
    pthread_mutex_unlock(&gMutex);
    return gRing ? kAudioHardwareNoError : kAudioHardwareUnspecifiedError;
}

static OSStatus MC_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *c, AudioObjectID *o) {
    (void)d; (void)desc; (void)c; (void)o;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus MC_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID o) {
    (void)d; (void)o;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus MC_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo *c) {
    (void)d; (void)o; (void)c;
    return kAudioHardwareNoError;
}

static OSStatus MC_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo *c) {
    (void)d; (void)o; (void)c;
    return kAudioHardwareNoError;
}

static int DeviceIndex(AudioObjectID device) {
    if (device == kObjectID_OutputDevice) return kDeviceOutput;
    if (device == kObjectID_LoopbackDevice) return kDeviceLoopback;
    return -1;
}

static OSStatus MC_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID device, UInt64 action, void *info) {
    (void)info;
    if (inDriver != gDriverRef || DeviceIndex(device) < 0) return kAudioHardwareBadObjectError;
    Float64 rate = (Float64)action;
    if (!MCIsSupportedSampleRate(rate)) return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&gMutex);
    if (gSampleRate != rate) {
        gSampleRate = rate;
        UpdateClockLocked();
        MCLoopbackReset(gRing);
        // The anchor stays: it only has to be consistent between the two devices, and a running
        // device re-reads its zero time stamps after a configuration change anyway.
        if (gIORunning[0] + gIORunning[1] > 0) gAnchorTicks = mach_absolute_time();
    }
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}

static OSStatus MC_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void *i) {
    (void)d; (void)o; (void)a; (void)i;
    return kAudioHardwareNoError;
}

/// Both devices change rate together: the ring is shared, sample time for sample time.
static void RequestSampleRate(Float64 rate) {
    AudioServerPlugInHostRef host = gHost;
    UInt64 action = (UInt64)rate;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        host->RequestDeviceConfigurationChange(host, kObjectID_OutputDevice, action, NULL);
        host->RequestDeviceConfigurationChange(host, kObjectID_LoopbackDevice, action, NULL);
    });
}

// MARK: - Property helpers

// out == NULL: size query only. Every handler sets *outSize.
#define PUT(T, value)                                                                \
    do {                                                                             \
        if (out) {                                                                   \
            if (inSize < sizeof(T)) return kAudioHardwareBadPropertySizeError;       \
            *(T *)out = (value);                                                     \
        }                                                                            \
        *outSize = (UInt32)sizeof(T);                                                \
        return kAudioHardwareNoError;                                                \
    } while (0)

#define PUT_STRING(cstr) PUT(CFStringRef, CFStringCreateWithCString(NULL, (cstr), kCFStringEncodingUTF8))

static OSStatus PutObjectList(const AudioObjectID *ids, UInt32 count, UInt32 inSize, UInt32 *outSize, void *out) {
    if (out) {
        UInt32 fit = inSize / (UInt32)sizeof(AudioObjectID);
        if (fit < count) count = fit;
        memcpy(out, ids, count * sizeof(AudioObjectID));
    }
    *outSize = count * (UInt32)sizeof(AudioObjectID);
    return kAudioHardwareNoError;
}

static AudioStreamBasicDescription FormatAt(Float64 rate) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof(f));
    f.mSampleRate = rate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = 4 * MC_CHANNELS;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = 4 * MC_CHANNELS;
    f.mChannelsPerFrame = MC_CHANNELS;
    f.mBitsPerChannel = 32;
    return f;
}

static Float64 CurrentRate(void) {
    pthread_mutex_lock(&gMutex);
    Float64 r = gSampleRate;
    pthread_mutex_unlock(&gMutex);
    return r;
}

// MARK: - Plug-in properties

static OSStatus PlugInProperty(const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q,
                               UInt32 inSize, UInt32 *outSize, void *out) {
    static const AudioObjectID devices[] = {kObjectID_OutputDevice, kObjectID_LoopbackDevice};
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioPlugInClassID);
    case kAudioObjectPropertyOwner: PUT(AudioObjectID, kAudioObjectUnknown);
    case kAudioObjectPropertyManufacturer: PUT_STRING(kManufacturer);
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList:
        return PutObjectList(devices, 2, inSize, outSize, out);
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        AudioObjectID found = kAudioObjectUnknown;
        if (out) {
            if (qSize < sizeof(CFStringRef) || !q) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *(const CFStringRef *)q;
            if (uid && CFStringCompare(uid, CFSTR(MC_OUTPUT_DEVICE_UID), 0) == kCFCompareEqualTo) found = kObjectID_OutputDevice;
            if (uid && CFStringCompare(uid, CFSTR(MC_LOOPBACK_DEVICE_UID), 0) == kCFCompareEqualTo) found = kObjectID_LoopbackDevice;
        }
        PUT(AudioObjectID, found);
    }
    case kAudioPlugInPropertyResourceBundle: PUT_STRING("");
    default: return kAudioHardwareUnknownPropertyError;
    }
}

// MARK: - Device properties

static OSStatus DeviceProperty(int dev, const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q,
                               UInt32 inSize, UInt32 *outSize, void *out) {
    (void)qSize; (void)q;
    bool isOutput = dev == kDeviceOutput;
    AudioObjectID stream = isOutput ? kObjectID_OutputStream : kObjectID_InputStream;
    AudioObjectPropertyScope myScope = isOutput ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput;
    bool scopeMatches = a->mScope == kAudioObjectPropertyScopeGlobal || a->mScope == myScope;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioDeviceClassID);
    case kAudioObjectPropertyOwner: PUT(AudioObjectID, kObjectID_PlugIn);
    case kAudioObjectPropertyName: PUT_STRING(isOutput ? kOutputName : kLoopbackName);
    case kAudioObjectPropertyManufacturer: PUT_STRING(kManufacturer);
    case kAudioDevicePropertyDeviceUID: PUT_STRING(isOutput ? MC_OUTPUT_DEVICE_UID : MC_LOOPBACK_DEVICE_UID);
    case kAudioDevicePropertyModelUID: PUT_STRING(MC_MODEL_UID);
    case kAudioDevicePropertyConfigurationApplication: PUT_STRING("com.apple.audio.AudioMIDISetup");
    case kAudioDevicePropertyTransportType: PUT(UInt32, kAudioDeviceTransportTypeVirtual);
    case kAudioDevicePropertyClockDomain: PUT(UInt32, kClockDomain);
    case kAudioDevicePropertyDeviceIsAlive: PUT(UInt32, 1);
    case kAudioDevicePropertyDeviceIsRunning: {
        pthread_mutex_lock(&gMutex);
        UInt32 running = gIORunning[dev] > 0;
        pthread_mutex_unlock(&gMutex);
        PUT(UInt32, running);
    }
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        PUT(UInt32, isOutput && a->mScope != kAudioObjectPropertyScopeInput ? 1 : 0);
    case kAudioDevicePropertyIsHidden: PUT(UInt32, isOutput ? 0 : 1);
    case kAudioDevicePropertyClockIsStable: PUT(UInt32, 1);
    case kAudioDevicePropertyZeroTimeStampPeriod: PUT(UInt32, MC_PERIOD_FRAMES);
    case kAudioDevicePropertySafetyOffset: PUT(UInt32, 0);
    case kAudioDevicePropertyLatency: {
        UInt32 frames = 0;
        if (isOutput) {
            pthread_mutex_lock(&gMutex);
            frames = MCLatencyFrames(gHubLatencySeconds, gSampleRate);
            pthread_mutex_unlock(&gMutex);
        }
        PUT(UInt32, frames);
    }
    case kAudioDevicePropertyNominalSampleRate: PUT(Float64, CurrentRate());
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        UInt32 n = MCSupportedSampleRateCount();
        if (out) {
            UInt32 fit = inSize / (UInt32)sizeof(AudioValueRange);
            if (fit < n) n = fit;
            AudioValueRange *r = out;
            for (UInt32 i = 0; i < n; i++) r[i].mMinimum = r[i].mMaximum = MCSupportedSampleRate(i);
        }
        *outSize = n * (UInt32)sizeof(AudioValueRange);
        return kAudioHardwareNoError;
    }
    case kAudioObjectPropertyOwnedObjects: {
        AudioObjectID owned[3] = {stream, kObjectID_Volume, kObjectID_Mute};
        return PutObjectList(owned, isOutput ? 3 : 1, inSize, outSize, out);
    }
    case kAudioDevicePropertyStreams:
        return PutObjectList(&stream, scopeMatches ? 1 : 0, inSize, outSize, out);
    case kAudioObjectPropertyControlList: {
        AudioObjectID controls[2] = {kObjectID_Volume, kObjectID_Mute};
        return PutObjectList(controls, isOutput ? 2 : 0, inSize, outSize, out);
    }
    case kAudioDevicePropertyRelatedDevices: {
        AudioObjectID me = isOutput ? kObjectID_OutputDevice : kObjectID_LoopbackDevice;
        return PutObjectList(&me, 1, inSize, outSize, out);
    }
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        if (out) {
            if (inSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32 *)out)[0] = 1;
            ((UInt32 *)out)[1] = 2;
        }
        *outSize = 2 * sizeof(UInt32);
        return kAudioHardwareNoError;
    }
    case kAudioDevicePropertyPreferredChannelLayout: {
        UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + MC_CHANNELS * sizeof(AudioChannelDescription));
        if (out) {
            if (inSize < size) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout *l = out;
            memset(l, 0, size);
            l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            l->mNumberChannelDescriptions = MC_CHANNELS;
            l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            l->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
        }
        *outSize = size;
        return kAudioHardwareNoError;
    }
    case kAudioObjectPropertyCustomPropertyInfoList: {
        if (!isOutput) { *outSize = 0; return kAudioHardwareNoError; }
        AudioServerPlugInCustomPropertyInfo info = {
            MC_PROPERTY_HUB_LATENCY,
            kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
            kAudioServerPlugInCustomPropertyDataTypeNone,
        };
        PUT(AudioServerPlugInCustomPropertyInfo, info);
    }
    case MC_PROPERTY_HUB_LATENCY: {
        if (!isOutput) return kAudioHardwareUnknownPropertyError;
        CFPropertyListRef value = NULL;
        if (out) {
            pthread_mutex_lock(&gMutex);
            Float64 seconds = gHubLatencySeconds;
            pthread_mutex_unlock(&gMutex);
            value = CFNumberCreate(NULL, kCFNumberFloat64Type, &seconds);
        }
        PUT(CFPropertyListRef, value);
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

// MARK: - Stream properties

static OSStatus StreamProperty(bool isOutput, const AudioObjectPropertyAddress *a,
                               UInt32 inSize, UInt32 *outSize, void *out) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioStreamClassID);
    case kAudioObjectPropertyOwner: PUT(AudioObjectID, isOutput ? kObjectID_OutputDevice : kObjectID_LoopbackDevice);
    case kAudioObjectPropertyOwnedObjects: *outSize = 0; return kAudioHardwareNoError;
    case kAudioStreamPropertyIsActive: PUT(UInt32, atomic_load(&gStreamActive[isOutput ? 0 : 1]) ? 1 : 0);
    case kAudioStreamPropertyDirection: PUT(UInt32, isOutput ? 0 : 1);
    case kAudioStreamPropertyTerminalType: PUT(UInt32, kAudioStreamTerminalTypeLine);
    case kAudioStreamPropertyStartingChannel: PUT(UInt32, 1);
    case kAudioStreamPropertyLatency: PUT(UInt32, 0);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
        PUT(AudioStreamBasicDescription, FormatAt(CurrentRate()));
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        UInt32 n = MCSupportedSampleRateCount();
        if (out) {
            UInt32 fit = inSize / (UInt32)sizeof(AudioStreamRangedDescription);
            if (fit < n) n = fit;
            AudioStreamRangedDescription *d = out;
            for (UInt32 i = 0; i < n; i++) {
                Float64 r = MCSupportedSampleRate(i);
                d[i].mFormat = FormatAt(r);
                d[i].mSampleRateRange.mMinimum = d[i].mSampleRateRange.mMaximum = r;
            }
        }
        *outSize = n * (UInt32)sizeof(AudioStreamRangedDescription);
        return kAudioHardwareNoError;
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

// MARK: - Control properties

static OSStatus ControlProperty(AudioObjectID control, const AudioObjectPropertyAddress *a,
                                UInt32 inSize, UInt32 *outSize, void *out) {
    bool isVolume = control == kObjectID_Volume;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: PUT(AudioClassID, isVolume ? kAudioLevelControlClassID : kAudioBooleanControlClassID);
    case kAudioObjectPropertyClass: PUT(AudioClassID, isVolume ? kAudioVolumeControlClassID : kAudioMuteControlClassID);
    case kAudioObjectPropertyOwner: PUT(AudioObjectID, kObjectID_OutputDevice);
    case kAudioObjectPropertyOwnedObjects: *outSize = 0; return kAudioHardwareNoError;
    case kAudioControlPropertyScope: PUT(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
    case kAudioControlPropertyElement: PUT(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
    default: break;
    }
    if (isVolume) {
        switch (a->mSelector) {
        case kAudioLevelControlPropertyScalarValue: PUT(Float32, atomic_load(&gVolume));
        case kAudioLevelControlPropertyDecibelValue: PUT(Float32, MCVolumeScalarToDecibels(atomic_load(&gVolume)));
        case kAudioLevelControlPropertyDecibelRange: {
            AudioValueRange r = {MC_VOLUME_MIN_DB, 0};
            PUT(AudioValueRange, r);
        }
        case kAudioLevelControlPropertyConvertScalarToDecibels:
            if (out) {
                if (inSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                *(Float32 *)out = MCVolumeScalarToDecibels(*(Float32 *)out);
            }
            *outSize = sizeof(Float32);
            return kAudioHardwareNoError;
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            if (out) {
                if (inSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                *(Float32 *)out = MCVolumeDecibelsToScalar(*(Float32 *)out);
            }
            *outSize = sizeof(Float32);
            return kAudioHardwareNoError;
        default: return kAudioHardwareUnknownPropertyError;
        }
    }
    if (a->mSelector == kAudioBooleanControlPropertyValue) PUT(UInt32, atomic_load(&gMute) ? 1 : 0);
    return kAudioHardwareUnknownPropertyError;
}

// MARK: - Property dispatch

static OSStatus Property(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q,
                         UInt32 inSize, UInt32 *outSize, void *out) {
    if (!a || !outSize) return kAudioHardwareIllegalOperationError;
    switch (obj) {
    case kObjectID_PlugIn: return PlugInProperty(a, qSize, q, inSize, outSize, out);
    case kObjectID_OutputDevice: return DeviceProperty(kDeviceOutput, a, qSize, q, inSize, outSize, out);
    case kObjectID_LoopbackDevice: return DeviceProperty(kDeviceLoopback, a, qSize, q, inSize, outSize, out);
    case kObjectID_OutputStream: return StreamProperty(true, a, inSize, outSize, out);
    case kObjectID_InputStream: return StreamProperty(false, a, inSize, outSize, out);
    case kObjectID_Volume:
    case kObjectID_Mute: return ControlProperty(obj, a, inSize, outSize, out);
    default: return kAudioHardwareBadObjectError;
    }
}

static Boolean MC_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a) {
    (void)pid;
    if (inDriver != gDriverRef) return false;
    UInt32 size = 0;
    // TranslateUIDToDevice needs a qualifier only for the value, not to answer "has".
    return Property(obj, a, 0, NULL, 0, &size, NULL) == kAudioHardwareNoError;
}

static OSStatus MC_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID obj, pid_t pid,
                                      const AudioObjectPropertyAddress *a, Boolean *outSettable) {
    (void)pid;
    if (inDriver != gDriverRef || !outSettable) return kAudioHardwareIllegalOperationError;
    UInt32 size = 0;
    OSStatus err = Property(obj, a, 0, NULL, 0, &size, NULL);
    if (err) return err;
    switch (obj) {
    case kObjectID_OutputDevice:
        *outSettable = a->mSelector == kAudioDevicePropertyNominalSampleRate || a->mSelector == MC_PROPERTY_HUB_LATENCY;
        break;
    case kObjectID_LoopbackDevice:
        *outSettable = a->mSelector == kAudioDevicePropertyNominalSampleRate;
        break;
    case kObjectID_OutputStream:
    case kObjectID_InputStream:
        *outSettable = a->mSelector == kAudioStreamPropertyIsActive || a->mSelector == kAudioStreamPropertyVirtualFormat ||
                       a->mSelector == kAudioStreamPropertyPhysicalFormat;
        break;
    case kObjectID_Volume:
        *outSettable = a->mSelector == kAudioLevelControlPropertyScalarValue || a->mSelector == kAudioLevelControlPropertyDecibelValue;
        break;
    case kObjectID_Mute:
        *outSettable = a->mSelector == kAudioBooleanControlPropertyValue;
        break;
    default:
        *outSettable = false;
    }
    return kAudioHardwareNoError;
}

static OSStatus MC_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID obj, pid_t pid,
                                       const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q, UInt32 *outSize) {
    (void)pid;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    return Property(obj, a, qSize, q, 0, outSize, NULL);
}

static OSStatus MC_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID obj, pid_t pid,
                                   const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q,
                                   UInt32 inSize, UInt32 *outSize, void *out) {
    (void)pid;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!out) return kAudioHardwareIllegalOperationError;
    return Property(obj, a, qSize, q, inSize, outSize, out);
}

static void Notify(AudioObjectID obj, AudioObjectPropertySelector sel) {
    AudioObjectPropertyAddress changed = {sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (gHost) gHost->PropertiesChanged(gHost, obj, 1, &changed);
}

static OSStatus SetVolume(Float32 scalar) {
    if (!(scalar >= 0)) scalar = 0;
    if (scalar > 1) scalar = 1;
    if (atomic_exchange(&gVolume, scalar) != scalar) {
        Notify(kObjectID_Volume, kAudioLevelControlPropertyScalarValue);
        Notify(kObjectID_Volume, kAudioLevelControlPropertyDecibelValue);
    }
    return kAudioHardwareNoError;
}

static OSStatus MC_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID obj, pid_t pid,
                                   const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q,
                                   UInt32 inSize, const void *in) {
    (void)pid; (void)qSize; (void)q;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!a || !in) return kAudioHardwareIllegalOperationError;
    switch (obj) {
    case kObjectID_OutputDevice:
    case kObjectID_LoopbackDevice:
        if (a->mSelector == kAudioDevicePropertyNominalSampleRate) {
            if (inSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
            Float64 rate = *(const Float64 *)in;
            if (!MCIsSupportedSampleRate(rate)) return kAudioHardwareIllegalOperationError;
            if (rate != CurrentRate()) RequestSampleRate(rate);
            return kAudioHardwareNoError;
        }
        if (obj == kObjectID_OutputDevice && a->mSelector == MC_PROPERTY_HUB_LATENCY) {
            if (inSize < sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
            CFPropertyListRef value = *(const CFPropertyListRef *)in;
            Float64 seconds = 0;
            if (!value || CFGetTypeID(value) != CFNumberGetTypeID() ||
                !CFNumberGetValue((CFNumberRef)value, kCFNumberFloat64Type, &seconds) || !(seconds >= 0) || seconds > 10) {
                return kAudioHardwareIllegalOperationError;
            }
            pthread_mutex_lock(&gMutex);
            bool changed = gHubLatencySeconds != seconds;
            gHubLatencySeconds = seconds;
            pthread_mutex_unlock(&gMutex);
            if (changed) {
                AudioObjectPropertyAddress addrs[2] = {
                    {MC_PROPERTY_HUB_LATENCY, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
                    {kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain},
                };
                if (gHost) gHost->PropertiesChanged(gHost, kObjectID_OutputDevice, 2, addrs);
            }
            return kAudioHardwareNoError;
        }
        return kAudioHardwareUnknownPropertyError;
    case kObjectID_OutputStream:
    case kObjectID_InputStream:
        if (a->mSelector == kAudioStreamPropertyIsActive) {
            if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            atomic_store(&gStreamActive[obj == kObjectID_OutputStream ? 0 : 1], *(const UInt32 *)in != 0);
            Notify(obj, kAudioStreamPropertyIsActive);
            return kAudioHardwareNoError;
        }
        if (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat) {
            if (inSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            const AudioStreamBasicDescription *f = in;
            AudioStreamBasicDescription want = FormatAt(f->mSampleRate);
            if (f->mFormatID != want.mFormatID || f->mChannelsPerFrame != want.mChannelsPerFrame ||
                f->mBitsPerChannel != want.mBitsPerChannel || !MCIsSupportedSampleRate(f->mSampleRate)) {
                return kAudioDeviceUnsupportedFormatError;
            }
            if (f->mSampleRate != CurrentRate()) RequestSampleRate(f->mSampleRate);
            return kAudioHardwareNoError;
        }
        return kAudioHardwareUnknownPropertyError;
    case kObjectID_Volume:
        if (inSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
        if (a->mSelector == kAudioLevelControlPropertyScalarValue) return SetVolume(*(const Float32 *)in);
        if (a->mSelector == kAudioLevelControlPropertyDecibelValue) return SetVolume(MCVolumeDecibelsToScalar(*(const Float32 *)in));
        return kAudioHardwareUnknownPropertyError;
    case kObjectID_Mute:
        if (a->mSelector != kAudioBooleanControlPropertyValue) return kAudioHardwareUnknownPropertyError;
        if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        if (atomic_exchange(&gMute, *(const UInt32 *)in != 0) != (*(const UInt32 *)in != 0)) {
            Notify(kObjectID_Mute, kAudioBooleanControlPropertyValue);
        }
        return kAudioHardwareNoError;
    case kObjectID_PlugIn:
        return kAudioHardwareUnknownPropertyError;
    default:
        return kAudioHardwareBadObjectError;
    }
}

// MARK: - IO

static OSStatus MC_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID device, UInt32 client) {
    (void)client;
    int dev = DeviceIndex(device);
    if (inDriver != gDriverRef || dev < 0) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    if (gIORunning[0] + gIORunning[1] == 0) {
        // The first device to start sets the shared clock; the other joins it.
        UpdateClockLocked();
        gAnchorTicks = mach_absolute_time();
        MCLoopbackReset(gRing);
    }
    gIORunning[dev]++;
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}

static OSStatus MC_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID device, UInt32 client) {
    (void)client;
    int dev = DeviceIndex(device);
    if (inDriver != gDriverRef || dev < 0) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    if (gIORunning[dev] > 0) gIORunning[dev]--;
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}

static OSStatus MC_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID device, UInt32 client,
                                    Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)client;
    if (inDriver != gDriverRef || DeviceIndex(device) < 0) return kAudioHardwareBadObjectError;
    MCClockZeroTimeStamp(gAnchorTicks, gTicksPerFrame, MC_PERIOD_FRAMES, mach_absolute_time(),
                         outSampleTime, outHostTime, outSeed);
    return kAudioHardwareNoError;
}

static OSStatus MC_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID device, UInt32 client,
                                     UInt32 op, Boolean *outWillDo, Boolean *outInPlace) {
    (void)client;
    int dev = DeviceIndex(device);
    if (inDriver != gDriverRef || dev < 0) return kAudioHardwareBadObjectError;
    bool will = (dev == kDeviceOutput && op == kAudioServerPlugInIOOperationWriteMix) ||
                (dev == kDeviceLoopback && op == kAudioServerPlugInIOOperationReadInput);
    if (outWillDo) *outWillDo = will;
    if (outInPlace) *outInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus MC_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, UInt32 op, UInt32 n,
                                    const AudioServerPlugInIOCycleInfo *i) {
    (void)d; (void)o; (void)c; (void)op; (void)n; (void)i;
    return kAudioHardwareNoError;
}

static OSStatus MC_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID device, AudioObjectID stream,
                                 UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle,
                                 void *mainBuffer, void *secondaryBuffer) {
    (void)client; (void)secondaryBuffer; (void)stream;
    if (inDriver != gDriverRef || !cycle || !mainBuffer) return kAudioHardwareIllegalOperationError;
    if (device == kObjectID_OutputDevice && op == kAudioServerPlugInIOOperationWriteMix) {
        float gain = MCVolumeGain(atomic_load(&gVolume), atomic_load(&gMute));
        MCLoopbackWrite(gRing, (int64_t)llround(cycle->mOutputTime.mSampleTime), mainBuffer, frames, gain);
    } else if (device == kObjectID_LoopbackDevice && op == kAudioServerPlugInIOOperationReadInput) {
        MCLoopbackRead(gRing, (int64_t)llround(cycle->mInputTime.mSampleTime), mainBuffer, frames);
    }
    return kAudioHardwareNoError;
}

static OSStatus MC_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, UInt32 op, UInt32 n,
                                  const AudioServerPlugInIOCycleInfo *i) {
    (void)d; (void)o; (void)c; (void)op; (void)n; (void)i;
    return kAudioHardwareNoError;
}
