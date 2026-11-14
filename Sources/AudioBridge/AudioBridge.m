#import "AudioBridge.h"
#import <AppKit/AppKit.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <libproc.h>
#import <stdatomic.h>
#import <math.h>

float VMClampGain(float value) { return isfinite(value) ? fminf(1, fmaxf(0, value)) : 1; }
static AudioObjectPropertyAddress Address(AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    return (AudioObjectPropertyAddress){selector, scope, kAudioObjectPropertyElementMain};
}
static OSStatus Read(AudioObjectID object, AudioObjectPropertySelector selector, void *data, UInt32 size) {
    AudioObjectPropertyAddress address = Address(selector, kAudioObjectPropertyScopeGlobal);
    return AudioObjectGetPropertyData(object, &address, 0, NULL, &size, data);
}
static NSString *StringProperty(AudioObjectID object, AudioObjectPropertySelector selector) {
    CFStringRef value = NULL;
    if (Read(object, selector, &value, sizeof(value)) != noErr || !value) return @"";
    return CFBridgingRelease(value);
}
static NSArray<NSNumber *> *ObjectList(AudioObjectID object, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = Address(selector, kAudioObjectPropertyScopeGlobal);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(object, &address, 0, NULL, &size) || !size) return @[];
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(object, &address, 0, NULL, &size, data.mutableBytes)) return @[];
    NSMutableArray *result = [NSMutableArray array];
    AudioObjectID *ids = data.mutableBytes;
    for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) [result addObject:@(ids[i])];
    return result;
}
static pid_t Parent(pid_t pid) {
    struct proc_bsdinfo info = {0};
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info) ? info.pbi_ppid : 0;
}
@implementation VMAudio
+ (NSDictionary *)outputDevice {
    AudioObjectID device = 0;
    Read(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, &device, sizeof(device));
    Float64 rate = 0;
    Read(device, kAudioDevicePropertyNominalSampleRate, &rate, sizeof(rate));
    return @{@"id": @(device), @"uid": StringProperty(device, kAudioDevicePropertyDeviceUID),
             @"name": StringProperty(device, kAudioObjectPropertyName), @"rate": @(rate)};
}
+ (NSArray *)processes {
    NSArray<NSRunningApplication *> *apps = NSWorkspace.sharedWorkspace.runningApplications;
    NSMutableDictionary<NSNumber *, NSRunningApplication *> *visible = [NSMutableDictionary dictionary];
    pid_t faceTimePID = 0;
    for (NSRunningApplication *app in apps) {
        if (app.activationPolicy == NSApplicationActivationPolicyRegular) visible[@(app.processIdentifier)] = app;
        if ([app.bundleIdentifier isEqualToString:@"com.apple.FaceTime"]) faceTimePID = app.processIdentifier;
    }
    NSMutableArray *result = [NSMutableArray array];
    for (NSNumber *object in ObjectList(kAudioObjectSystemObject, kAudioHardwarePropertyProcessObjectList)) {
        AudioObjectID oid = object.unsignedIntValue;
        pid_t pid = 0;
        if (Read(oid, kAudioProcessPropertyPID, &pid, sizeof(pid)) || pid == getpid()) continue;
        NSString *bundle = StringProperty(oid, kAudioProcessPropertyBundleID);
        pid_t owner = visible[@(pid)] ? pid : 0;
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        proc_pidpath(pid, path, sizeof(path));
        NSString *executable = @(path);
        // Chromium/Electron audio runs in helpers nested inside the parent application bundle.
        if (!owner) for (NSRunningApplication *app in visible.allValues) {
            NSString *prefix = [app.bundleURL.path stringByAppendingString:@"/"];
            if ((prefix && [executable hasPrefix:prefix]) || [bundle isEqualToString:app.bundleIdentifier]) {
                owner = app.processIdentifier; break;
            }
        }
        for (pid_t parent = pid, depth = 0; !owner && parent > 1 && depth < 20; depth++) {
            parent = Parent(parent);
            if (visible[@(parent)]) owner = parent;
        }
        // FaceTime's media service is not a child of FaceTime. Only map while FaceTime is open.
        if (!owner && faceTimePID && [executable.lastPathComponent isEqualToString:@"avconferenced"]) owner = faceTimePID;
        UInt32 playing = 0;
        Read(oid, kAudioProcessPropertyIsRunningOutput, &playing, sizeof(playing));
        [result addObject:@{@"objectID": object, @"pid": @(pid), @"ownerPID": @(owner),
                           @"bundleID": bundle, @"playing": @(playing != 0)}];
    }
    return result;
}
@end

typedef struct {
    _Atomic(float) target;
    float current;
    _Atomic(uint64_t) callbacks;
    _Atomic(bool) failed;
    UInt32 channels;
} RenderState;

// Shared DSP kernel used by the real-time callback and offline tests.
bool VMRenderAudio(const AudioBufferList *input, AudioBufferList *output, UInt32 channels, float *currentGain, float targetGain) {
    for (UInt32 b = 0; b < output->mNumberBuffers; b++)
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    UInt32 inChannels = 0, outChannels = 0, frames = UINT32_MAX;
    for (UInt32 b = 0; b < input->mNumberBuffers; b++) {
        const AudioBuffer *buffer = &input->mBuffers[b];
        inChannels += buffer->mNumberChannels;
        if (buffer->mNumberChannels) frames = MIN(frames, buffer->mDataByteSize / (sizeof(float) * buffer->mNumberChannels));
    }
    for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
        AudioBuffer *buffer = &output->mBuffers[b];
        outChannels += buffer->mNumberChannels;
        if (buffer->mNumberChannels) frames = MIN(frames, buffer->mDataByteSize / (sizeof(float) * buffer->mNumberChannels));
    }
    if (inChannels != channels || outChannels != channels || frames == UINT32_MAX) {
        return false;
    }
    float target = VMClampGain(targetGain);
    *currentGain = VMClampGain(*currentGain);
    // Short bounded ramp avoids clicks when the slider moves. Gain never exceeds one.
    float step = (target - *currentGain) / MAX(frames, 1);
    for (UInt32 f = 0; f < frames; f++) {
        float gain = *currentGain + step * (f + 1);
        UInt32 ib = 0, ic = 0, ob = 0, oc = 0;
        for (UInt32 c = 0; c < channels; c++) {
            while (ib < input->mNumberBuffers && ic >= input->mBuffers[ib].mNumberChannels) { ib++; ic = 0; }
            while (ob < output->mNumberBuffers && oc >= output->mBuffers[ob].mNumberChannels) { ob++; oc = 0; }
            const AudioBuffer *src = &input->mBuffers[ib];
            AudioBuffer *dst = &output->mBuffers[ob];
            if (src->mData && dst->mData)
                ((float *)dst->mData)[f * dst->mNumberChannels + oc] = ((const float *)src->mData)[f * src->mNumberChannels + ic] * gain;
            ic++; oc++;
        }
    }
    *currentGain = target;
    return true;
}

// No allocation, locks, Objective-C, logging, or disk/network access in the audio callback.
static OSStatus Render(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                       const AudioTimeStamp *inputTime, AudioBufferList *output,
                       const AudioTimeStamp *outputTime, void *context) {
    RenderState *state = context;
    atomic_fetch_add_explicit(&state->callbacks, 1, memory_order_relaxed);
    if (!VMRenderAudio(input, output, state->channels, &state->current,
                       atomic_load_explicit(&state->target, memory_order_relaxed)))
        atomic_store_explicit(&state->failed, true, memory_order_relaxed);
    return noErr;
}

@implementation VMRoute {
    AudioObjectID _tap;
    AudioObjectID _aggregate;
    AudioDeviceIOProcID _ioProc;
    RenderState *_state;
}
- (instancetype)initWithProcesses:(NSArray<NSNumber *> *)processes gain:(float)gain error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    _processIDs = [processes copy];
    OSStatus status = noErr;
    NSString *stage = @"Find audio output";
    NSDictionary *device = VMAudio.outputDevice;
    _outputDeviceID = [device[@"id"] unsignedIntValue];
    NSString *uid = device[@"uid"];
    if (!processes.count || !_outputDeviceID || !uid.length) { status = kAudioHardwareBadDeviceError; goto fail; }
    _state = calloc(1, sizeof(RenderState));
    if (!_state) { status = -108; goto fail; }
    atomic_init(&_state->target, VMClampGain(gain));
    atomic_init(&_state->callbacks, 0);
    atomic_init(&_state->failed, false);
    _state->current = VMClampGain(gain);
    {
        // Device-specific capture preserves the hardware stream format; no stereo mixdown gain.
        CATapDescription *description = [[CATapDescription alloc] initWithProcesses:processes andDeviceUID:uid withStream:0];
        description.name = @"Volume Mixer";
        description.privateTap = YES;
        description.muteBehavior = CATapMutedWhenTapped;
        stage = @"Create app audio tap";
        status = AudioHardwareCreateProcessTap(description, &_tap);
        if (status) goto fail;
        AudioStreamBasicDescription format = {0};
        stage = @"Read audio format";
        status = Read(_tap, kAudioTapPropertyFormat, &format, sizeof(format));
        if (status) goto fail;
        // Only use layouts whose exact channel mapping is known. Fail open for other devices.
        if (format.mFormatID != kAudioFormatLinearPCM || !(format.mFormatFlags & kAudioFormatFlagIsFloat)
            || format.mBitsPerChannel != 32 || format.mChannelsPerFrame < 1 || format.mChannelsPerFrame > 2) {
            stage = @"This output needs an unsupported audio format (use stereo speakers or headphones)";
            status = kAudioHardwareUnsupportedOperationError; goto fail;
        }
        _state->channels = format.mChannelsPerFrame;
        NSString *tapUID = StringProperty(_tap, kAudioTapPropertyUID);
        NSDictionary *composition = @{
            @kAudioAggregateDeviceNameKey: @"Volume Mixer (private)",
            @kAudioAggregateDeviceUIDKey: NSUUID.UUID.UUIDString,
            @kAudioAggregateDeviceIsPrivateKey: @YES,
            @kAudioAggregateDeviceIsStackedKey: @NO,
            @kAudioAggregateDeviceMainSubDeviceKey: uid,
            @kAudioAggregateDeviceSubDeviceListKey: @[@{
                @kAudioSubDeviceUIDKey: uid,
                @kAudioSubDeviceInputChannelsKey: @0,
                @kAudioSubDeviceOutputChannelsKey: @(format.mChannelsPerFrame)
            }],
            @kAudioAggregateDeviceTapListKey: @[@{
                @kAudioSubTapUIDKey: tapUID,
                @kAudioSubTapDriftCompensationKey: @YES
            }]
        };
        stage = @"Create private audio route";
        status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)composition, &_aggregate);
        if (status) goto fail;
        stage = @"Connect audio output";
        status = AudioDeviceCreateIOProcID(_aggregate, Render, _state, &_ioProc);
        if (status) goto fail;
        stage = @"Start audio (check System Settings → Privacy & Security → Screen & System Audio Recording)";
        status = AudioDeviceStart(_aggregate, _ioProc);
        if (status) goto fail;
    }
    return self;
fail:
    [self stop];
    if (error) *error = [NSError errorWithDomain:@"VolumeMixer.Audio" code:status
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %d", stage, (int)status]}];
    return nil;
}
- (uint64_t)callbackCount { return _state ? atomic_load(&_state->callbacks) : 0; }
- (BOOL)healthy { return _state && !atomic_load(&_state->failed); }
- (void)setGain:(float)gain { if (_state) atomic_store_explicit(&_state->target, VMClampGain(gain), memory_order_relaxed); }
- (void)stop {
    if (_aggregate && _ioProc) {
        AudioDeviceStop(_aggregate, _ioProc);
        AudioDeviceDestroyIOProcID(_aggregate, _ioProc);
        _ioProc = NULL;
    }
    if (_aggregate) { AudioHardwareDestroyAggregateDevice(_aggregate); _aggregate = 0; }
    if (_tap) { AudioHardwareDestroyProcessTap(_tap); _tap = 0; }
    if (_state) { free(_state); _state = NULL; }
}
- (void)dealloc { [self stop]; }
@end
