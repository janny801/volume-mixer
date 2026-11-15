#import "AudioBridge.h"
#import <assert.h>
#import <math.h>
#import <stdio.h>
// Run entirely on synthetic buffers. Never captures or plays user audio.
int main(void) {
    @autoreleasepool {
        assert(VMClampGain(NAN) == 1);
        assert(VMClampGain(INFINITY) == 1);
        assert(VMClampGain(-1) == 0);
        assert(VMClampGain(4) == 2);
        float input[] = {-1, 1, -.5, .5, -.25, .25, 0, 0};
        float output[8];
        AudioBufferList in = {.mNumberBuffers = 1, .mBuffers = {{2, sizeof(input), input}}};
        AudioBufferList out = {.mNumberBuffers = 1, .mBuffers = {{2, sizeof(output), output}}};
        float gains[] = {0, .01, .25, .5, .99, 1, 2, -1};
        for (size_t g = 0; g < sizeof(gains)/sizeof(float); g++) {
            float current = gains[g];
            assert(VMRenderAudio(&in, &out, 2, &current, gains[g]));
            for (size_t i = 0; i < 8; i++) {
                assert(output[i] == input[i] * VMClampGain(gains[g]));
                assert(fabsf(output[i]) <= fabsf(input[i]));
            }
            if (gains[g] == 1) assert(memcmp(input, output, sizeof(input)) == 0);
        }
        // Ramp down and up stays bounded and reaches the requested value.
        float current = 1;
        assert(VMRenderAudio(&in, &out, 2, &current, 0));
        assert(current == 0);
        assert(output[0] == -.75 && output[2] == -.25 && output[4] == -.0625);
        assert(VMRenderAudio(&in, &out, 2, &current, 1));
        assert(current == 1);
        for (size_t i = 0; i < 8; i++) assert(fabsf(output[i]) <= fabsf(input[i]));
        // Planar to interleaved mapping preserves both channels without duplication/attenuation.
        struct { UInt32 count; AudioBuffer buffers[2]; } planar;
        float left[] = {-1, -.5, -.25, 0}, right[] = {1, .5, .25, 0};
        planar.count = 2;
        planar.buffers[0] = (AudioBuffer){1, sizeof(left), left};
        planar.buffers[1] = (AudioBuffer){1, sizeof(right), right};
        assert(VMRenderAudio((AudioBufferList *)&planar, &out, 2, &current, 1));
        assert(memcmp(input, output, sizeof(input)) == 0);
        // Interleaved to planar uses the same channel map.
        memset(left, 0, sizeof(left)); memset(right, 0, sizeof(right));
        assert(VMRenderAudio(&in, (AudioBufferList *)&planar, 2, &current, 1));
        for (int i = 0; i < 4; i++) { assert(left[i] == input[2*i]); assert(right[i] == input[2*i+1]); }
        // Unknown layouts fail safely, with output zeroed until main-thread cleanup restores bypass.
        assert(!VMRenderAudio(&in, &out, 1, &current, .5));
        for (int i = 0; i < 8; i++) assert(output[i] == 0);
        // No source samples: do not read a null input buffer.
        in.mBuffers[0].mData = NULL;
        assert(VMRenderAudio(&in, &out, 2, &current, .5));
        for (int i = 0; i < 8; i++) assert(output[i] == 0);
        puts("PASS: unity, attenuation, mute, gain clamping, ramps, channel layouts, invalid layouts, null input");
    }
}
