#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Hands iOS's UI automation back while the test stays alive, and takes it
/// again later. All-in-one build only (the test runs inside LoopCtrl and is
/// parked on Stop instead of ending; see docs/runner-merge-spike.md).
///
/// The "Automation Running" overlay is testmanagerd's Automation Mode, which
/// it reference-counts per test session and turns off when the last session's
/// XPC connection goes away (-[XCTestSession invalidate] →
/// -[XCTDAutomationModeInterface disableAutomationModeForClient:]). XCTest has
/// no "disable" call, but dropping that connection does the same thing.
@interface AutomationSession : NSObject

/// Close the test's connection to testmanagerd. Automation Mode, and with it
/// the overlay, goes away if no other test session holds it. Nothing that
/// talks to testmanagerd works until `reacquire`. Returns NO (with a reason
/// in `why`) if XCTest's internals are not what this expects.
+ (BOOL)releaseAutomation:(NSString * _Nullable * _Nullable)why;

/// Whether `releaseAutomation:` succeeded and `reacquire` has not run since.
@property (class, nonatomic, readonly) BOOL isReleased;

/// Open a new connection, put it into the shared XCTRunnerDaemonSession every
/// XCTest call goes through, and enable Automation Mode again (iOS may ask for
/// the passcode). Blocks; call it off the main thread.
+ (BOOL)reacquire:(NSString * _Nullable * _Nullable)why;

@end

NS_ASSUME_NONNULL_END
