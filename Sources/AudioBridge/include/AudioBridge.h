#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
NS_ASSUME_NONNULL_BEGIN
/// Linear attenuation only. Invalid values fail open to unity.
float VMClampGain(float value);
bool VMRenderAudio(const AudioBufferList *input, AudioBufferList *output, UInt32 channels, float *currentGain, float targetGain);
@interface VMAudio : NSObject
+ (NSArray<NSDictionary<NSString *, id> *> *)processes;
+ (NSDictionary<NSString *, id> *)outputDevice;
@end
/// One private tap per app, created only below 100%. Never changes the default output.
@interface VMRoute : NSObject
@property(nonatomic, readonly) NSArray<NSNumber *> *processIDs;
@property(nonatomic, readonly) AudioObjectID outputDeviceID;
@property(nonatomic, readonly) uint64_t callbackCount;
@property(nonatomic, readonly) BOOL healthy;
- (nullable instancetype)initWithProcesses:(NSArray<NSNumber *> *)processes
                                     gain:(float)gain
                                    error:(NSError * _Nullable * _Nullable)error;
- (void)setGain:(float)gain;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
