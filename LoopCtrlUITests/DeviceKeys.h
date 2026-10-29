#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Hardware button events XCTest exposes only through private classes.
/// Everything is probed at runtime: a missing selector returns NO instead of
/// crashing the runner.
@interface DeviceKeys : NSObject

/// Whether `XCDeviceEvent` + `-[XCUIDevice performDeviceEvent:error:]` are
/// usable on this OS.
+ (BOOL)available;

/// Send one HID page/usage event. page 0x07 usage 0x68 is F13 (iOS ignores
/// it, which is what keep-awake uses); page 0x0C usage 0x65 is the Consumer
/// "Snapshot" key (the system screenshot).
+ (BOOL)sendPage:(unsigned int)page usage:(unsigned int)usage duration:(double)duration
           error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
