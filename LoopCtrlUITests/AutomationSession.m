//
//  AutomationSession.m
//  Clears iOS's "Automation Running" overlay on Stop in the all-in-one build
//  without ending the test, and takes automation back on Start.
//
//  What keeps the overlay up (testmanagerd and XCTestCore, Xcode 27 / iOS 27
//  DDI, disassembled):
//
//    testmanagerd   -[XCTestSession _XCT_enableAutomationModeWithReply:]
//                     → -[XCTDAutomationModeInterface enableAutomationModeForClient:error:]
//                       adds the session to a client set, enables Automation Mode
//                   -[XCTestSession invalidate]  (its XPC connection went away)
//                     → -[XCTDAutomationModeInterface disableAutomationModeForClient:]
//                       removes it; the last one out disables Automation Mode
//
//  There is no other path to disableAutomationModeForClient:, so the overlay
//  is tied to the test process's connection to testmanagerd, not to the test
//  being alive. On the test's side that connection belongs to the one shared
//  XCTRunnerDaemonSession, a dispatch_once singleton every XCTest call reaches
//  through +sharedSession → -daemonProxy → -connection. It can't be replaced,
//  but -initWithConnection:remoteInterfaceCapabilities: only sets up ivars
//  (queue, connection, capabilities, handler table, XPC interfaces, exported
//  object = self) and resumes, so running it again on the same object with a
//  new connection is exactly what +sessionWithConnection:completion: does for
//  a fresh one. Then -[XCUIDevice enableAutomationMode:] and
//  -loadAccessibility: as _XCUIInitializeForUITesting does at bootstrap.
//

#import "AutomationSession.h"
#import <XCTest/XCTest.h>
#import <objc/message.h>
#import <objc/runtime.h>

extern void _XCTSetApplicationStateTimeout(NSTimeInterval timeout) __attribute__((weak_import));
extern NSTimeInterval _XCTApplicationStateTimeout(void) __attribute__((weak_import));

@implementation AutomationSession

static BOOL released = NO;

+ (BOOL)isReleased { return released; }

static void setWhy(NSString **why, NSString *text) {
    if (why) *why = text;
}

static Class daemonSessionClass(void) {
    return NSClassFromString(@"XCTRunnerDaemonSession");
}

/// The shared session, without creating one.
static id sharedSession(void) {
    Class cls = daemonSessionClass();
    SEL sel = NSSelectorFromString(@"sharedSessionIfInitiated");
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, sel);
}

+ (BOOL)releaseAutomation:(NSString **)why {
    if (released) return YES;
    id session = sharedSession();
    if (!session) { setWhy(why, @"no XCTRunnerDaemonSession"); return NO; }
    if (![session respondsToSelector:@selector(connection)]
        || ![session respondsToSelector:NSSelectorFromString(@"initWithConnection:remoteInterfaceCapabilities:")]
        || ![daemonSessionClass() respondsToSelector:NSSelectorFromString(@"connectionForInitiatingSharedSession")]
        || ![daemonSessionClass() respondsToSelector:NSSelectorFromString(@"capabilitiesForDaemonConnection:completion:")]) {
        // Without these, a release could not be undone: refuse it.
        setWhy(why, @"XCTRunnerDaemonSession lacks the methods to reconnect");
        return NO;
    }
    NSXPCConnection *connection = [session valueForKey:@"connection"];
    if (![connection isKindOfClass:[NSXPCConnection class]]) {
        setWhy(why, @"XCTRunnerDaemonSession has no NSXPCConnection");
        return NO;
    }
    [connection invalidate];
    released = YES;
    return YES;
}

+ (BOOL)reacquire:(NSString **)why {
    if (!released) return YES;
    id session = sharedSession();
    Class cls = daemonSessionClass();
    if (!session || !cls) { setWhy(why, @"no XCTRunnerDaemonSession"); return NO; }

    // 1. A new connection, through the capability handshake that
    //    +sessionWithConnection:completion: does first (it registers this
    //    process with testmanagerd as a test session).
    NSXPCConnection *connection = ((id (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"connectionForInitiatingSharedSession"));
    if (!connection) { setWhy(why, @"connectionForInitiatingSharedSession returned nil"); return NO; }

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block id capabilities = nil;
    __block NSError *handshakeError = nil;
    void (^completion)(id, NSError *) = ^(id caps, NSError *error) {
        capabilities = caps;
        handshakeError = error;
        dispatch_semaphore_signal(done);
    };
    ((void (*)(id, SEL, id, id))objc_msgSend)(cls, NSSelectorFromString(@"capabilitiesForDaemonConnection:completion:"),
                                             connection, completion);
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC))) != 0) {
        [connection invalidate];
        setWhy(why, @"testmanagerd did not answer the capability handshake");
        return NO;
    }
    if (handshakeError || !capabilities) {
        [connection invalidate];
        setWhy(why, [NSString stringWithFormat:@"capability handshake failed: %@", handshakeError.localizedDescription ?: @"no capabilities"]);
        return NO;
    }

    // 2. Re-run the session's initializer on the same object, so the singleton
    //    every caller holds now talks over the new connection. Declared with
    //    init's ownership rules so ARC balances the call.
    typedef id __attribute__((ns_returns_retained)) (*InitFn)(id __attribute__((ns_consumed)), SEL, id, id);
    InitFn reinit = (InitFn)objc_msgSend;
    id same = reinit(session, NSSelectorFromString(@"initWithConnection:remoteInterfaceCapabilities:"),
                     connection, capabilities);
    if (same != session) {
        setWhy(why, @"XCTRunnerDaemonSession init returned another object");
        return NO;
    }
    released = NO;

    // 3. Automation Mode and accessibility, as _XCUIInitializeForUITesting.
    //    enableAutomationMode: waits up to the application-state timeout, which
    //    QuiescenceDisabler caps at 2 s after bootstrap; the passcode prompt
    //    iOS may show needs far longer.
    BOOL canTime = (&_XCTSetApplicationStateTimeout != NULL) && (&_XCTApplicationStateTimeout != NULL);
    NSTimeInterval previous = canTime ? _XCTApplicationStateTimeout() : 0;
    if (canTime) _XCTSetApplicationStateTimeout(120);

    BOOL ok = YES;
    XCUIDevice *device = [XCUIDevice sharedDevice];
    SEL enable = NSSelectorFromString(@"enableAutomationMode:");
    if ([device respondsToSelector:enable]) {
        NSError *error = nil;
        BOOL enabled = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(device, enable, &error);
        if (!enabled) {
            ok = NO;
            setWhy(why, [NSString stringWithFormat:@"enableAutomationMode failed: %@", error.localizedDescription ?: @"?"]);
        }
    }
    if (ok && [device respondsToSelector:NSSelectorFromString(@"accessibilityInterface")]) {
        id ax = [device valueForKey:@"accessibilityInterface"];
        SEL load = NSSelectorFromString(@"loadAccessibility:");
        if ([ax respondsToSelector:load]) {
            NSError *error = nil;
            if (!((BOOL (*)(id, SEL, NSError **))objc_msgSend)(ax, load, &error)) {
                // Not fatal: queries load it on demand.
                setWhy(why, [NSString stringWithFormat:@"loadAccessibility failed: %@", error.localizedDescription ?: @"?"]);
            }
        }
    }

    if (canTime) _XCTSetApplicationStateTimeout(previous);
    return ok;
}

@end
