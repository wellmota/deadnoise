// Driver de áudio (AudioServerPlugIn) do DeadNoise (antes chamado VolMix; os UIDs mantêm o nome antigo).
//
// Publica dois dispositivos ligados por um buffer circular:
//   - "DeadNoise Microphone": microfone virtual que os apps de chamada escolhem (só entrada).
//   - "DeadNoise App IO": dispositivo oculto onde o DeadNoise toca o áudio já sem ruído (só saída).
// O que o DeadNoise toca no App IO aparece no Microphone. Sem o DeadNoise tocando, o microfone entrega silêncio.
//
// Formato fixo: 48 kHz, mono, Float32. Os dois dispositivos usam o relógio do host, e cada amostra
// é endereçada numa linha do tempo global (frames desde a carga do driver) para que escrita e leitura
// se encontrem mesmo com os dispositivos iniciados em momentos diferentes.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

#define kSampleRate          48000.0
#define kRingFrames          65536          // potência de 2 (~1,4 s)
#define kZeroTimeStampPeriod 16384
#define kManufacturer        CFSTR("DeadNoise")

enum {
    kObjectID_Mic         = 2,
    kObjectID_MicStream   = 3,
    kObjectID_AppIO       = 4,
    kObjectID_AppIOStream = 5,
};

typedef struct {
    AudioObjectID id;
    AudioObjectID streamID;
    bool          isInput;      // direção do único stream
    bool          hidden;
    CFStringRef   name;
    CFStringRef   uid;
    CFStringRef   modelUID;
    // Estado de IO (protegido por gStateMutex)
    UInt32        ioCount;
    UInt64        anchorHostTime;
    UInt64        numberTimeStamps;
    Float64       baseFrames;   // posição do início deste IO na linha do tempo global
    bool          streamActive;
} Device;

static Device gMic;
static Device gAppIO;

static pthread_mutex_t        gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static UInt32                 gRefCount = 0;
static Float64                gHostTicksPerFrame = 0;
static UInt64                 gEpochHostTime = 0;
static Float32                gRing[kRingFrames];
static _Atomic SInt64         gWriteEnd = 0;   // fim (global) do último bloco escrito pelo App IO

static void SetUpDevices(void) {
    gMic   = (Device){ kObjectID_Mic, kObjectID_MicStream, true, false,
                       CFSTR("DeadNoise Microphone"), CFSTR("VolMixMic_UID"), CFSTR("VolMixMic_ModelUID"),
                       0, 0, 0, 0, true };
    gAppIO = (Device){ kObjectID_AppIO, kObjectID_AppIOStream, false, true,
                       CFSTR("DeadNoise App IO"), CFSTR("VolMixAppIO_UID"), CFSTR("VolMixAppIO_ModelUID"),
                       0, 0, 0, 0, true };
}

static Device* DeviceByID(AudioObjectID id) {
    if (id == kObjectID_Mic) return &gMic;
    if (id == kObjectID_AppIO) return &gAppIO;
    return NULL;
}

static Device* DeviceByStreamID(AudioObjectID id) {
    if (id == kObjectID_MicStream) return &gMic;
    if (id == kObjectID_AppIOStream) return &gAppIO;
    return NULL;
}

static AudioStreamBasicDescription StreamFormat(void) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof(f));
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = sizeof(Float32);
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = sizeof(Float32);
    f.mChannelsPerFrame = 1;
    f.mBitsPerChannel = 32;
    return f;
}

static bool IsOurFormat(const AudioStreamBasicDescription* f) {
    return f->mSampleRate == kSampleRate && f->mFormatID == kAudioFormatLinearPCM &&
           f->mChannelsPerFrame == 1 && f->mBitsPerChannel == 32 &&
           (f->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
}

// O stream do dispositivo aparece neste escopo?
static bool StreamInScope(const Device* d, AudioObjectPropertyScope scope) {
    if (scope == kAudioObjectPropertyScopeGlobal) return true;
    return d->isInput ? scope == kAudioObjectPropertyScopeInput : scope == kAudioObjectPropertyScopeOutput;
}

#pragma mark - Propriedades

#define kLayoutSize (offsetof(AudioChannelLayout, mChannelDescriptions) + sizeof(AudioChannelDescription))

// Tamanho da propriedade, ou erro se o objeto não a tem. Base de HasProperty/GetPropertyDataSize.
static OSStatus PropertySize(AudioObjectID obj, const AudioObjectPropertyAddress* a, UInt32* outSize) {
    Device* d;
    if (obj == kAudioObjectPlugInObject) {
        switch (a->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:               *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyOwner:               *outSize = sizeof(AudioObjectID); return 0;
            case kAudioObjectPropertyManufacturer:
            case kAudioPlugInPropertyResourceBundle:      *outSize = sizeof(CFStringRef); return 0;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:          *outSize = 2 * sizeof(AudioObjectID); return 0;
            case kAudioPlugInPropertyBoxList:             *outSize = 0; return 0;
            case kAudioPlugInPropertyTranslateUIDToDevice:
            case kAudioPlugInPropertyTranslateUIDToBox:   *outSize = sizeof(AudioObjectID); return 0;
        }
        return kAudioHardwareUnknownPropertyError;
    }
    if ((d = DeviceByID(obj)) != NULL) {
        switch (a->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:               *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyOwner:
            case kAudioDevicePropertyRelatedDevices:      *outSize = sizeof(AudioObjectID); return 0;
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:            *outSize = sizeof(CFStringRef); return 0;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyStreams:
                *outSize = StreamInScope(d, a->mScope) ? sizeof(AudioObjectID) : 0; return 0;
            case kAudioObjectPropertyControlList:         *outSize = 0; return 0;
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyZeroTimeStampPeriod: *outSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyNominalSampleRate:   *outSize = sizeof(Float64); return 0;
            case kAudioDevicePropertyAvailableNominalSampleRates: *outSize = sizeof(AudioValueRange); return 0;
            case kAudioDevicePropertyPreferredChannelsForStereo:  *outSize = 2 * sizeof(UInt32); return 0;
            case kAudioDevicePropertyPreferredChannelLayout:      *outSize = (UInt32)kLayoutSize; return 0;
        }
        return kAudioHardwareUnknownPropertyError;
    }
    if (DeviceByStreamID(obj) != NULL) {
        switch (a->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:               *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyOwner:               *outSize = sizeof(AudioObjectID); return 0;
            case kAudioObjectPropertyOwnedObjects:        *outSize = 0; return 0;
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency:             *outSize = sizeof(UInt32); return 0;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:      *outSize = sizeof(AudioStreamBasicDescription); return 0;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: *outSize = sizeof(AudioStreamRangedDescription); return 0;
        }
        return kAudioHardwareUnknownPropertyError;
    }
    return kAudioHardwareBadObjectError;
}

static Boolean VM_HasProperty(AudioServerPlugInDriverRef drv, AudioObjectID obj, pid_t pid,
                              const AudioObjectPropertyAddress* a) {
    UInt32 size;
    return a != NULL && PropertySize(obj, a, &size) == 0;
}

static OSStatus VM_IsPropertySettable(AudioServerPlugInDriverRef drv, AudioObjectID obj, pid_t pid,
                                      const AudioObjectPropertyAddress* a, Boolean* outSettable) {
    UInt32 size;
    if (a == NULL || outSettable == NULL) return kAudioHardwareIllegalOperationError;
    OSStatus err = PropertySize(obj, a, &size);
    if (err != 0) return err;
    switch (a->mSelector) {
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: *outSettable = true; break;
        default:                                 *outSettable = false; break;
    }
    return 0;
}

static OSStatus VM_GetPropertyDataSize(AudioServerPlugInDriverRef drv, AudioObjectID obj, pid_t pid,
                                       const AudioObjectPropertyAddress* a, UInt32 qualSize,
                                       const void* qual, UInt32* outSize) {
    if (a == NULL || outSize == NULL) return kAudioHardwareIllegalOperationError;
    return PropertySize(obj, a, outSize);
}

#define RETURN(type, value) do { \
        if (inSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; \
        *((type*)outData) = (value); *outSize = sizeof(type); return 0; \
    } while (0)

static OSStatus VM_GetPropertyData(AudioServerPlugInDriverRef drv, AudioObjectID obj, pid_t pid,
                                   const AudioObjectPropertyAddress* a, UInt32 qualSize, const void* qual,
                                   UInt32 inSize, UInt32* outSize, void* outData) {
    Device* d;
    if (a == NULL || outSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;

    if (obj == kAudioObjectPlugInObject) {
        switch (a->mSelector) {
            case kAudioObjectPropertyBaseClass:  RETURN(AudioClassID, kAudioObjectClassID);
            case kAudioObjectPropertyClass:      RETURN(AudioClassID, kAudioPlugInClassID);
            case kAudioObjectPropertyOwner:      RETURN(AudioObjectID, kAudioObjectUnknown);
            case kAudioObjectPropertyManufacturer:   RETURN(CFStringRef, kManufacturer);
            case kAudioPlugInPropertyResourceBundle: RETURN(CFStringRef, CFSTR(""));
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList: {
                UInt32 n = inSize / sizeof(AudioObjectID);
                if (n > 2) n = 2;
                if (n > 0) ((AudioObjectID*)outData)[0] = kObjectID_Mic;
                if (n > 1) ((AudioObjectID*)outData)[1] = kObjectID_AppIO;
                *outSize = n * sizeof(AudioObjectID);
                return 0;
            }
            case kAudioPlugInPropertyBoxList: *outSize = 0; return 0;
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                if (qualSize != sizeof(CFStringRef) || qual == NULL) return kAudioHardwareBadPropertySizeError;
                CFStringRef uid = *((CFStringRef*)qual);
                AudioObjectID found = kAudioObjectUnknown;
                if (uid != NULL && CFEqual(uid, gMic.uid)) found = kObjectID_Mic;
                else if (uid != NULL && CFEqual(uid, gAppIO.uid)) found = kObjectID_AppIO;
                RETURN(AudioObjectID, found);
            }
            case kAudioPlugInPropertyTranslateUIDToBox: RETURN(AudioObjectID, kAudioObjectUnknown);
        }
        return kAudioHardwareUnknownPropertyError;
    }

    if ((d = DeviceByID(obj)) != NULL) {
        switch (a->mSelector) {
            case kAudioObjectPropertyBaseClass:  RETURN(AudioClassID, kAudioObjectClassID);
            case kAudioObjectPropertyClass:      RETURN(AudioClassID, kAudioDeviceClassID);
            case kAudioObjectPropertyOwner:      RETURN(AudioObjectID, kAudioObjectPlugInObject);
            case kAudioObjectPropertyName:       RETURN(CFStringRef, d->name);
            case kAudioObjectPropertyManufacturer: RETURN(CFStringRef, kManufacturer);
            case kAudioDevicePropertyDeviceUID:  RETURN(CFStringRef, d->uid);
            case kAudioDevicePropertyModelUID:   RETURN(CFStringRef, d->modelUID);
            case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyStreams:
                if (StreamInScope(d, a->mScope) && inSize >= sizeof(AudioObjectID)) {
                    *((AudioObjectID*)outData) = d->streamID;
                    *outSize = sizeof(AudioObjectID);
                } else {
                    *outSize = 0;
                }
                return 0;
            case kAudioObjectPropertyControlList: *outSize = 0; return 0;
            case kAudioDevicePropertyRelatedDevices: RETURN(AudioObjectID, d->id);
            case kAudioDevicePropertyTransportType:  RETURN(UInt32, kAudioDeviceTransportTypeVirtual);
            case kAudioDevicePropertyClockDomain:    RETURN(UInt32, 0);
            case kAudioDevicePropertyDeviceIsAlive:  RETURN(UInt32, 1);
            case kAudioDevicePropertyDeviceIsRunning: {
                pthread_mutex_lock(&gStateMutex);
                UInt32 running = d->ioCount > 0 ? 1 : 0;
                pthread_mutex_unlock(&gStateMutex);
                RETURN(UInt32, running);
            }
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                // Só o microfone pode virar padrão, e só como entrada. O App IO nunca.
                RETURN(UInt32, (!d->hidden && a->mScope != kAudioObjectPropertyScopeOutput) ? 1 : 0);
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RETURN(UInt32, 0);
            case kAudioDevicePropertyLatency:        RETURN(UInt32, 0);
            case kAudioDevicePropertySafetyOffset:   RETURN(UInt32, 0);
            case kAudioDevicePropertyIsHidden:       RETURN(UInt32, d->hidden ? 1 : 0);
            case kAudioDevicePropertyZeroTimeStampPeriod: RETURN(UInt32, kZeroTimeStampPeriod);
            case kAudioDevicePropertyNominalSampleRate:   RETURN(Float64, kSampleRate);
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                if (inSize < sizeof(AudioValueRange)) { *outSize = 0; return 0; }
                AudioValueRange range = { kSampleRate, kSampleRate };
                *((AudioValueRange*)outData) = range;
                *outSize = sizeof(AudioValueRange);
                return 0;
            }
            case kAudioDevicePropertyPreferredChannelsForStereo: {
                if (inSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                ((UInt32*)outData)[0] = 1;
                ((UInt32*)outData)[1] = 1;
                *outSize = 2 * sizeof(UInt32);
                return 0;
            }
            case kAudioDevicePropertyPreferredChannelLayout: {
                if (inSize < kLayoutSize) return kAudioHardwareBadPropertySizeError;
                AudioChannelLayout* layout = (AudioChannelLayout*)outData;
                memset(layout, 0, kLayoutSize);
                layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                layout->mNumberChannelDescriptions = 1;
                layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Mono;
                *outSize = (UInt32)kLayoutSize;
                return 0;
            }
        }
        return kAudioHardwareUnknownPropertyError;
    }

    if ((d = DeviceByStreamID(obj)) != NULL) {
        switch (a->mSelector) {
            case kAudioObjectPropertyBaseClass:  RETURN(AudioClassID, kAudioObjectClassID);
            case kAudioObjectPropertyClass:      RETURN(AudioClassID, kAudioStreamClassID);
            case kAudioObjectPropertyOwner:      RETURN(AudioObjectID, d->id);
            case kAudioObjectPropertyOwnedObjects: *outSize = 0; return 0;
            case kAudioStreamPropertyIsActive: {
                pthread_mutex_lock(&gStateMutex);
                UInt32 active = d->streamActive ? 1 : 0;
                pthread_mutex_unlock(&gStateMutex);
                RETURN(UInt32, active);
            }
            case kAudioStreamPropertyDirection:  RETURN(UInt32, d->isInput ? 1 : 0);
            case kAudioStreamPropertyTerminalType:
                RETURN(UInt32, d->isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeLine);
            case kAudioStreamPropertyStartingChannel: RETURN(UInt32, 1);
            case kAudioStreamPropertyLatency:    RETURN(UInt32, 0);
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat: RETURN(AudioStreamBasicDescription, StreamFormat());
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                if (inSize < sizeof(AudioStreamRangedDescription)) { *outSize = 0; return 0; }
                AudioStreamRangedDescription* r = (AudioStreamRangedDescription*)outData;
                r->mFormat = StreamFormat();
                r->mSampleRateRange.mMinimum = kSampleRate;
                r->mSampleRateRange.mMaximum = kSampleRate;
                *outSize = sizeof(AudioStreamRangedDescription);
                return 0;
            }
        }
        return kAudioHardwareUnknownPropertyError;
    }
    return kAudioHardwareBadObjectError;
}

static OSStatus VM_SetPropertyData(AudioServerPlugInDriverRef drv, AudioObjectID obj, pid_t pid,
                                   const AudioObjectPropertyAddress* a, UInt32 qualSize, const void* qual,
                                   UInt32 inSize, const void* inData) {
    Device* d;
    if (a == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;

    if (DeviceByID(obj) != NULL && a->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return *((const Float64*)inData) == kSampleRate ? 0 : kAudioDeviceUnsupportedFormatError;
    }
    if ((d = DeviceByStreamID(obj)) != NULL) {
        switch (a->mSelector) {
            case kAudioStreamPropertyIsActive:
                if (inSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                pthread_mutex_lock(&gStateMutex);
                d->streamActive = *((const UInt32*)inData) != 0;
                pthread_mutex_unlock(&gStateMutex);
                return 0;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                if (inSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
                return IsOurFormat((const AudioStreamBasicDescription*)inData) ? 0 : kAudioDeviceUnsupportedFormatError;
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

#pragma mark - IO

static OSStatus VM_StartIO(AudioServerPlugInDriverRef drv, AudioObjectID devID, UInt32 clientID) {
    Device* d = DeviceByID(devID);
    if (d == NULL) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (d->ioCount == 0) {
        d->anchorHostTime = mach_absolute_time();
        d->numberTimeStamps = 0;
        d->baseFrames = (Float64)(d->anchorHostTime - gEpochHostTime) / gHostTicksPerFrame;
    }
    d->ioCount++;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus VM_StopIO(AudioServerPlugInDriverRef drv, AudioObjectID devID, UInt32 clientID) {
    Device* d = DeviceByID(devID);
    if (d == NULL) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (d->ioCount > 0) d->ioCount--;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus VM_GetZeroTimeStamp(AudioServerPlugInDriverRef drv, AudioObjectID devID, UInt32 clientID,
                                    Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    Device* d = DeviceByID(devID);
    if (d == NULL) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    Float64 ticksPerPeriod = gHostTicksPerFrame * (Float64)kZeroTimeStampPeriod;
    UInt64 now = mach_absolute_time();
    UInt64 next = d->anchorHostTime + (UInt64)((Float64)(d->numberTimeStamps + 1) * ticksPerPeriod);
    if (next <= now) d->numberTimeStamps++;
    *outSampleTime = (Float64)(d->numberTimeStamps * kZeroTimeStampPeriod);
    *outHostTime = d->anchorHostTime + (UInt64)((Float64)d->numberTimeStamps * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus VM_WillDoIOOperation(AudioServerPlugInDriverRef drv, AudioObjectID devID, UInt32 clientID,
                                     UInt32 op, Boolean* outWillDo, Boolean* outInPlace) {
    Device* d = DeviceByID(devID);
    if (d == NULL) return kAudioHardwareBadObjectError;
    bool will = (d->isInput && op == kAudioServerPlugInIOOperationReadInput) ||
                (!d->isInput && op == kAudioServerPlugInIOOperationWriteMix);
    if (outWillDo) *outWillDo = will;
    if (outInPlace) *outInPlace = true;
    return 0;
}

static OSStatus VM_BeginIOOperation(AudioServerPlugInDriverRef drv, AudioObjectID devID, UInt32 clientID,
                                    UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* info) {
    return 0;
}

static OSStatus VM_DoIOOperation(AudioServerPlugInDriverRef drv, AudioObjectID devID, AudioObjectID streamID,
                                 UInt32 clientID, UInt32 op, UInt32 frames,
                                 const AudioServerPlugInIOCycleInfo* info, void* mainBuffer, void* secondaryBuffer) {
    Device* d = DeviceByID(devID);
    if (d == NULL) return kAudioHardwareBadObjectError;
    if (mainBuffer == NULL || info == NULL) return 0;
    Float32* samples = (Float32*)mainBuffer;

    if (op == kAudioServerPlugInIOOperationWriteMix && !d->isInput) {
        // O DeadNoise tocando áudio limpo: guarda na posição global correspondente.
        SInt64 start = (SInt64)(d->baseFrames + info->mOutputTime.mSampleTime);
        for (UInt32 i = 0; i < frames; i++) gRing[(start + i) & (kRingFrames - 1)] = samples[i];
        atomic_store(&gWriteEnd, start + (SInt64)frames);
    } else if (op == kAudioServerPlugInIOOperationReadInput && d->isInput) {
        // App de chamada lendo o microfone: só entrega o que foi escrito e ainda está no buffer.
        SInt64 start = (SInt64)(d->baseFrames + info->mInputTime.mSampleTime);
        SInt64 end = atomic_load(&gWriteEnd);
        for (UInt32 i = 0; i < frames; i++) {
            SInt64 pos = start + i;
            samples[i] = (pos < end && pos >= end - kRingFrames) ? gRing[pos & (kRingFrames - 1)] : 0.0f;
        }
    }
    return 0;
}

static OSStatus VM_EndIOOperation(AudioServerPlugInDriverRef drv, AudioObjectID devID, UInt32 clientID,
                                  UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* info) {
    return 0;
}

#pragma mark - Ciclo de vida

static AudioServerPlugInDriverInterface  gInterface;
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef        gDriverRef = &gInterfacePtr;

static HRESULT VM_QueryInterface(void* drv, REFIID iid, LPVOID* outInterface) {
    if (drv != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, iid);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        gRefCount++;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = 0;
    }
    CFRelease(requested);
    return result;
}

static ULONG VM_AddRef(void* drv) {
    pthread_mutex_lock(&gStateMutex);
    ULONG count = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static ULONG VM_Release(void* drv) {
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG count = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static OSStatus VM_Initialize(AudioServerPlugInDriverRef drv, AudioServerPlugInHostRef host) {
    gHost = host;
    struct mach_timebase_info timebase;
    mach_timebase_info(&timebase);
    Float64 ticksPerSecond = ((Float64)timebase.denom / (Float64)timebase.numer) * 1000000000.0;
    gHostTicksPerFrame = ticksPerSecond / kSampleRate;
    gEpochHostTime = mach_absolute_time();
    return 0;
}

static OSStatus VM_CreateDevice(AudioServerPlugInDriverRef drv, CFDictionaryRef desc,
                                const AudioServerPlugInClientInfo* client, AudioObjectID* outID) {
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus VM_DestroyDevice(AudioServerPlugInDriverRef drv, AudioObjectID devID) {
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus VM_AddDeviceClient(AudioServerPlugInDriverRef drv, AudioObjectID devID,
                                   const AudioServerPlugInClientInfo* client) { return 0; }
static OSStatus VM_RemoveDeviceClient(AudioServerPlugInDriverRef drv, AudioObjectID devID,
                                      const AudioServerPlugInClientInfo* client) { return 0; }
static OSStatus VM_PerformConfigChange(AudioServerPlugInDriverRef drv, AudioObjectID devID,
                                       UInt64 action, void* info) { return 0; }
static OSStatus VM_AbortConfigChange(AudioServerPlugInDriverRef drv, AudioObjectID devID,
                                     UInt64 action, void* info) { return 0; }

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    VM_QueryInterface,
    VM_AddRef,
    VM_Release,
    VM_Initialize,
    VM_CreateDevice,
    VM_DestroyDevice,
    VM_AddDeviceClient,
    VM_RemoveDeviceClient,
    VM_PerformConfigChange,
    VM_AbortConfigChange,
    VM_HasProperty,
    VM_IsPropertySettable,
    VM_GetPropertyDataSize,
    VM_GetPropertyData,
    VM_SetPropertyData,
    VM_StartIO,
    VM_StopIO,
    VM_GetZeroTimeStamp,
    VM_WillDoIOOperation,
    VM_BeginIOOperation,
    VM_DoIOOperation,
    VM_EndIOOperation,
};

// Ponto de entrada declarado no Info.plist (CFPlugInFactories).
void* VolMixAudio_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    if (!CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    SetUpDevices();
    return gDriverRef;
}
