#import "DeviceKeys.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <XCTest/XCTest.h>

@implementation DeviceKeys

+ (BOOL)available {
    Class eventClass = NSClassFromString(@"XCDeviceEvent");
    if (!eventClass) { return NO; }
    SEL make = NSSelectorFromString(@"deviceEventWithPage:usage:duration:");
    SEL perform = NSSelectorFromString(@"performDeviceEvent:error:");
    if (![eventClass respondsToSelector:make]) { return NO; }
    if (![[XCUIDevice sharedDevice] respondsToSelector:perform]) { return NO; }
    NSMethodSignature *factory = [eventClass methodSignatureForSelector:make];
    NSMethodSignature *dispatch = [[XCUIDevice sharedDevice] methodSignatureForSelector:perform];
    if (!factory || factory.numberOfArguments != 5 || factory.methodReturnType[0] != '@') { return NO; }
    if (!dispatch || dispatch.numberOfArguments != 4) { return NO; }
    return YES;
}

+ (BOOL)sendPage:(unsigned int)page usage:(unsigned int)usage duration:(double)duration
           error:(NSError **)error {
    if (![self available]) {
        if (error) {
            *error = [NSError errorWithDomain:@"LoopCtrlDeviceKeys" code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"XCDeviceEvent is not available on this OS"}];
        }
        return NO;
    }
    @try {
        Class eventClass = NSClassFromString(@"XCDeviceEvent");
        SEL make = NSSelectorFromString(@"deviceEventWithPage:usage:duration:");
        SEL perform = NSSelectorFromString(@"performDeviceEvent:error:");
        NSMethodSignature *factory = [eventClass methodSignatureForSelector:make];
        BOOL wide = strcmp([factory getArgumentTypeAtIndex:2], "Q") == 0;
        id event = wide
            ? ((id (*)(id, SEL, unsigned long long, unsigned long long, double))objc_msgSend)
                (eventClass, make, page, usage, duration)
            : ((id (*)(id, SEL, unsigned int, unsigned int, double))objc_msgSend)
                (eventClass, make, page, usage, duration);
        if (!event) {
            if (error) {
                *error = [NSError errorWithDomain:@"LoopCtrlDeviceKeys" code:2
                                         userInfo:@{NSLocalizedDescriptionKey: @"XCDeviceEvent could not be built"}];
            }
            return NO;
        }
        return ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(
            [XCUIDevice sharedDevice], perform, event, error);
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"LoopCtrlDeviceKeys" code:3
                                     userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: exception.name}];
        }
        return NO;
    }
}

@end
