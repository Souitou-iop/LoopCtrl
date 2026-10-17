//! The per-device state machine.
//!
//! Pure: it takes inputs (results of device operations, usbmuxd attach/detach,
//! user commands) and says what to do next. The driver in `session.rs` runs
//! the actions against a backend and feeds the results back. Every device in
//! batch mode has its own machine.

use serde::{Deserialize, Serialize};

use crate::model::{AppMatch, ErrorCode, PairError, RecordKind, RpVia, TrustOutcome, UserCommand, WriteVia};
use crate::DeviceInfo;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    /// Attached, info read (or being read); waiting for Begin in single mode.
    Detected,
    /// Lockdown pair in progress: the Trust dialog is (or will be) on screen.
    Trusting,
    CheckingDevMode,
    RevealingDevMode,
    /// Toggle revealed; the user turns it on and taps Restart.
    DevModeGuide,
    /// Detached after the guide: waiting for the phone to come back.
    Rebooting,
    /// Back after the reboot: waiting for the user to tap "Turn On".
    ConfirmingDevMode,
    Generating,
    FindingApp,
    Writing,
    Verifying,
    Done,
    Failed,
}

/// Where a failure happened, which is also where Retry resumes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Step {
    Info,
    Trust,
    DevModeCheck,
    Reboot,
    DevModeConfirm,
    Generate,
    FindApp,
    Write,
    Verify,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Input {
    /// usbmuxd reported the device (first time, or back after replug/reboot).
    Attached,
    /// usbmuxd lost the device.
    Detached,
    Info(DeviceInfo),
    User(UserCommand),
    Trust(TrustOutcome),
    DevMode(bool),
    Revealed,
    /// The current wait (reboot or Developer Mode confirmation) ran out.
    Timeout,
    Generated { kind: RecordKind, via: Option<RpVia> },
    App(Option<AppMatch>),
    Written(WriteVia),
    Verified,
    Failed(PairError),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    ReadInfo,
    Trust,
    /// Trust again after a pause (the phone was locked).
    TrustAfterDelay,
    ReadDevMode,
    RevealDevMode,
    /// Nothing to do until the phone detaches for its reboot.
    AwaitReboot,
    /// Wait for the phone to attach again, with the reboot timeout.
    AwaitReconnect,
    /// Poll Developer Mode until it is on, with the confirmation timeout.
    ConfirmDevMode,
    Generate(RecordKind),
    FindApp,
    Write,
    Verify(RecordKind),
    /// Nothing running; wait for a user command or an attach.
    Idle,
}

#[derive(Debug, Clone)]
pub struct Machine {
    pub phase: Phase,
    pub info: Option<DeviceInfo>,
    pub error: Option<PairError>,
    pub failed_at: Option<Step>,
    /// Developer Mode was off when checked (the guide was shown).
    pub dev_mode_was_off: bool,
    pub record_kind: Option<RecordKind>,
    pub rp_via: Option<RpVia>,
    pub app: Option<AppMatch>,
    pub write_via: Option<WriteVia>,
    /// Start without waiting for Begin (batch mode).
    pub auto_begin: bool,
}

impl Machine {
    pub fn new(auto_begin: bool) -> Self {
        Self {
            phase: Phase::Detected,
            info: None,
            error: None,
            failed_at: None,
            dev_mode_was_off: false,
            record_kind: None,
            rp_via: None,
            app: None,
            write_via: None,
            auto_begin,
        }
    }

    fn kind(&self) -> RecordKind {
        self.record_kind
            .or_else(|| self.info.as_ref().and_then(DeviceInfo::version).map(|v| v.record_kind()))
            .unwrap_or(RecordKind::RemotePairing)
    }

    fn current_step(&self) -> Step {
        match self.phase {
            Phase::Detected => Step::Info,
            Phase::Trusting => Step::Trust,
            Phase::CheckingDevMode | Phase::RevealingDevMode | Phase::DevModeGuide => Step::DevModeCheck,
            Phase::Rebooting => Step::Reboot,
            Phase::ConfirmingDevMode => Step::DevModeConfirm,
            Phase::Generating => Step::Generate,
            Phase::FindingApp => Step::FindApp,
            Phase::Writing => Step::Write,
            Phase::Verifying | Phase::Done => Step::Verify,
            Phase::Failed => self.failed_at.unwrap_or(Step::Info),
        }
    }

    fn go(&mut self, phase: Phase, action: Action) -> Option<Action> {
        if phase != Phase::Failed {
            self.error = None;
            self.failed_at = None;
        }
        self.phase = phase;
        Some(action)
    }

    fn fail(&mut self, error: PairError) -> Option<Action> {
        self.failed_at = Some(self.current_step());
        self.error = Some(error);
        self.phase = Phase::Failed;
        Some(Action::Idle)
    }

    fn resume(&mut self, at: Step) -> Option<Action> {
        match at {
            Step::Info => self.go(Phase::Detected, Action::ReadInfo),
            Step::Trust => self.go(Phase::Trusting, Action::Trust),
            Step::DevModeCheck => self.go(Phase::CheckingDevMode, Action::ReadDevMode),
            Step::Reboot => self.go(Phase::Rebooting, Action::AwaitReconnect),
            Step::DevModeConfirm => self.go(Phase::ConfirmingDevMode, Action::ConfirmDevMode),
            Step::Generate => {
                let k = self.kind();
                self.go(Phase::Generating, Action::Generate(k))
            }
            Step::FindApp => self.go(Phase::FindingApp, Action::FindApp),
            Step::Write => self.go(Phase::Writing, Action::Write),
            Step::Verify => {
                let k = self.kind();
                self.go(Phase::Verifying, Action::Verify(k))
            }
        }
    }

    /// Where Retry goes after a failure.
    fn retry_target(&self) -> Step {
        match (self.error.as_ref().map(|e| e.code), self.failed_at) {
            // "重新检查": the toggle is visible now, check again.
            (Some(ErrorCode::DevModeCancelled), _) => Step::DevModeCheck,
            (_, Some(at)) => at,
            _ => Step::Info,
        }
    }

    /// Feeds one input. `None` means "keep doing what you are doing".
    pub fn step(&mut self, input: Input) -> Option<Action> {
        use Phase as P;
        match input {
            Input::Attached => match self.phase {
                P::Detected if self.info.is_none() => Some(Action::ReadInfo),
                P::Rebooting => self.go(P::ConfirmingDevMode, Action::ConfirmDevMode),
                P::Failed => match self.error.as_ref().map(|e| e.code) {
                    // Came back late: carry on as if in time.
                    Some(ErrorCode::RebootTimeout) => self.go(P::ConfirmingDevMode, Action::ConfirmDevMode),
                    // Unsupported stays unsupported.
                    Some(ErrorCode::Unsupported) => None,
                    // Replugging is the natural retry ("拔掉数据线，两秒后再插上").
                    _ => {
                        let at = self.retry_target();
                        self.resume(at)
                    }
                },
                _ => None,
            },

            Input::Detached => match self.phase {
                P::DevModeGuide | P::ConfirmingDevMode => self.go(P::Rebooting, Action::AwaitReconnect),
                P::Detected | P::Done | P::Failed | P::Rebooting => Some(Action::Idle),
                _ => self.fail(PairError::new(ErrorCode::Disconnected, "device detached")),
            },

            Input::Info(info) => {
                let supported = info.version().is_some_and(|v| v.is_supported());
                let ios = info.ios.clone();
                self.info = Some(info);
                if !supported {
                    self.phase = P::Detected;
                    return self.fail(PairError::new(ErrorCode::Unsupported, format!("iOS {ios}")));
                }
                self.record_kind = self.info.as_ref().and_then(DeviceInfo::version).map(|v| v.record_kind());
                if self.auto_begin {
                    self.go(P::Trusting, Action::Trust)
                } else {
                    self.go(P::Detected, Action::Idle)
                }
            }

            Input::User(cmd) => match cmd {
                UserCommand::Begin => match self.phase {
                    P::Detected if self.info.is_some() => self.go(P::Trusting, Action::Trust),
                    _ => None,
                },
                UserCommand::Retry => match self.phase {
                    P::Failed if self.error.as_ref().map(|e| e.code) == Some(ErrorCode::Unsupported) => None,
                    P::Failed => {
                        let at = self.retry_target();
                        self.resume(at)
                    }
                    _ => None,
                },
                UserCommand::Recheck => match self.phase {
                    P::Failed | P::DevModeGuide | P::ConfirmingDevMode | P::Rebooting => {
                        self.go(P::CheckingDevMode, Action::ReadDevMode)
                    }
                    _ => None,
                },
                UserCommand::Cancel => match self.phase {
                    P::Detected | P::Done => None,
                    _ if self.info.is_none() => None,
                    _ => self.go(P::Detected, Action::Idle),
                },
            },

            Input::Trust(outcome) if self.phase == P::Trusting => match outcome {
                TrustOutcome::AlreadyTrusted | TrustOutcome::Paired => self.go(P::CheckingDevMode, Action::ReadDevMode),
                TrustOutcome::Locked => Some(Action::TrustAfterDelay),
            },

            Input::DevMode(on) => match self.phase {
                P::CheckingDevMode if on => {
                    let k = self.kind();
                    self.go(P::Generating, Action::Generate(k))
                }
                P::CheckingDevMode => {
                    self.dev_mode_was_off = true;
                    self.go(P::RevealingDevMode, Action::RevealDevMode)
                }
                P::ConfirmingDevMode if on => {
                    let k = self.kind();
                    self.go(P::Generating, Action::Generate(k))
                }
                _ => None,
            },

            Input::Revealed if self.phase == P::RevealingDevMode => self.go(P::DevModeGuide, Action::AwaitReboot),

            Input::Timeout => match self.phase {
                P::Rebooting => self.fail(PairError::new(ErrorCode::RebootTimeout, "no reconnect")),
                P::ConfirmingDevMode => self.fail(PairError::new(ErrorCode::DevModeCancelled, "Developer Mode still off")),
                _ => None,
            },

            Input::Generated { kind, via } if self.phase == P::Generating => {
                self.record_kind = Some(kind);
                self.rp_via = via;
                self.go(P::FindingApp, Action::FindApp)
            }

            Input::App(found) if self.phase == P::FindingApp => match found {
                Some(app) => {
                    self.app = Some(app);
                    self.go(P::Writing, Action::Write)
                }
                None => self.fail(PairError::new(ErrorCode::AppNotFound, "no LoopCtrl among user apps")),
            },

            Input::Written(via) if self.phase == P::Writing => {
                self.write_via = Some(via);
                let k = self.kind();
                self.go(P::Verifying, Action::Verify(k))
            }

            Input::Verified if self.phase == P::Verifying => self.go(P::Done, Action::Idle),

            Input::Failed(e) => match self.phase {
                P::Done | P::Failed => None,
                _ => self.fail(e),
            },

            // Late results of an action that no longer applies.
            _ => None,
        }
    }

    /// Rough share of the work done, for the batch progress bars.
    pub fn progress(&self) -> f32 {
        let at = |s: Step| match s {
            Step::Info => 0.02,
            Step::Trust => 0.08,
            Step::DevModeCheck => 0.15,
            Step::Reboot => 0.25,
            Step::DevModeConfirm => 0.3,
            Step::Generate => 0.5,
            Step::FindApp => 0.6,
            Step::Write => 0.7,
            Step::Verify => 0.88,
        };
        match self.phase {
            Phase::Detected => 0.0,
            Phase::Done => 1.0,
            _ => at(self.current_step()),
        }
    }

    /// The user has to do something on this phone (batch "需要处理").
    pub fn needs_attention(&self) -> bool {
        matches!(self.phase, Phase::DevModeGuide | Phase::ConfirmingDevMode | Phase::Failed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::MatchedBy;

    fn info(ios: &str) -> DeviceInfo {
        DeviceInfo { udid: "U1".into(), name: "林晓的 iPhone".into(), model: "iPhone 15 Pro".into(), product_type: "iPhone16,1".into(), ios: ios.into() }
    }
    fn app() -> AppMatch {
        AppMatch { bundle_id: "a.loopctrl".into(), name: "LoopCtrl".into(), version: Some("1.4".into()), matched_by: MatchedBy::BundleSuffix, file_sharing: false }
    }

    /// Runs a machine through the happy path up to the Developer Mode check.
    fn trusted(ios: &str, auto: bool) -> Machine {
        let mut m = Machine::new(auto);
        assert_eq!(m.step(Input::Attached), Some(Action::ReadInfo));
        let a = m.step(Input::Info(info(ios)));
        if auto {
            assert_eq!(a, Some(Action::Trust));
        } else {
            assert_eq!(a, Some(Action::Idle));
            assert_eq!(m.phase, Phase::Detected);
            assert_eq!(m.step(Input::User(UserCommand::Begin)), Some(Action::Trust));
        }
        assert_eq!(m.phase, Phase::Trusting);
        assert_eq!(m.step(Input::Trust(TrustOutcome::Paired)), Some(Action::ReadDevMode));
        m
    }

    #[test]
    fn happy_path_rp() {
        let mut m = trusted("18.6.2", false);
        assert_eq!(m.step(Input::DevMode(true)), Some(Action::Generate(RecordKind::RemotePairing)));
        assert_eq!(
            m.step(Input::Generated { kind: RecordKind::RemotePairing, via: Some(RpVia::LockdownService) }),
            Some(Action::FindApp)
        );
        assert_eq!(m.step(Input::App(Some(app()))), Some(Action::Write));
        assert_eq!(m.step(Input::Written(WriteVia::VendContainer)), Some(Action::Verify(RecordKind::RemotePairing)));
        assert_eq!(m.step(Input::Verified), Some(Action::Idle));
        assert_eq!(m.phase, Phase::Done);
        assert_eq!(m.progress(), 1.0);
        assert!(!m.needs_attention());
    }

    #[test]
    fn ios16_and_17_early_get_lockdown() {
        for v in ["16.7.10", "17.2.1"] {
            let mut m = trusted(v, true);
            assert_eq!(m.step(Input::DevMode(true)), Some(Action::Generate(RecordKind::Lockdown)));
        }
    }

    #[test]
    fn unsupported_ios_fails_and_stays() {
        let mut m = Machine::new(true);
        m.step(Input::Attached);
        assert_eq!(m.step(Input::Info(info("15.8"))), Some(Action::Idle));
        assert_eq!(m.phase, Phase::Failed);
        assert_eq!(m.error.as_ref().unwrap().code, ErrorCode::Unsupported);
        assert_eq!(m.step(Input::User(UserCommand::Retry)), None);
        assert_eq!(m.step(Input::Attached), None);
    }

    #[test]
    fn begin_is_needed_in_single_mode_only() {
        let mut m = Machine::new(false);
        m.step(Input::Attached);
        m.step(Input::Info(info("18.0")));
        assert_eq!(m.phase, Phase::Detected);
        // Begin before info is ignored, after info starts.
        let mut early = Machine::new(false);
        assert_eq!(early.step(Input::User(UserCommand::Begin)), None);
    }

    #[test]
    fn locked_phone_retries_trust() {
        let mut m = Machine::new(true);
        m.step(Input::Attached);
        m.step(Input::Info(info("18.0")));
        assert_eq!(m.step(Input::Trust(TrustOutcome::Locked)), Some(Action::TrustAfterDelay));
        assert_eq!(m.phase, Phase::Trusting);
        assert_eq!(m.step(Input::Trust(TrustOutcome::AlreadyTrusted)), Some(Action::ReadDevMode));
    }

    #[test]
    fn dont_trust_then_replug_retries() {
        let mut m = Machine::new(true);
        m.step(Input::Attached);
        m.step(Input::Info(info("18.0")));
        assert_eq!(m.step(Input::Failed(PairError::new(ErrorCode::Untrusted, "denied"))), Some(Action::Idle));
        assert_eq!(m.failed_at, Some(Step::Trust));
        assert_eq!(m.step(Input::Detached), Some(Action::Idle));
        assert_eq!(m.step(Input::Attached), Some(Action::Trust));
        assert_eq!(m.phase, Phase::Trusting);
        assert!(m.error.is_none());
    }

    #[test]
    fn developer_mode_full_branch() {
        let mut m = trusted("18.6.2", true);
        assert_eq!(m.step(Input::DevMode(false)), Some(Action::RevealDevMode));
        assert_eq!(m.phase, Phase::RevealingDevMode);
        assert_eq!(m.step(Input::Revealed), Some(Action::AwaitReboot));
        assert_eq!(m.phase, Phase::DevModeGuide);
        assert!(m.needs_attention());
        // The phone reboots: usbmuxd drops it.
        assert_eq!(m.step(Input::Detached), Some(Action::AwaitReconnect));
        assert_eq!(m.phase, Phase::Rebooting);
        assert!(!m.needs_attention());
        assert_eq!(m.step(Input::Attached), Some(Action::ConfirmDevMode));
        assert_eq!(m.phase, Phase::ConfirmingDevMode);
        assert_eq!(m.step(Input::DevMode(true)), Some(Action::Generate(RecordKind::RemotePairing)));
        assert!(m.dev_mode_was_off);
    }

    #[test]
    fn reboot_timeout_continue_or_late_return() {
        let mut m = trusted("18.6.2", true);
        m.step(Input::DevMode(false));
        m.step(Input::Revealed);
        m.step(Input::Detached);
        assert_eq!(m.step(Input::Timeout), Some(Action::Idle));
        assert_eq!(m.error.as_ref().unwrap().code, ErrorCode::RebootTimeout);
        // 继续等待
        assert_eq!(m.step(Input::User(UserCommand::Retry)), Some(Action::AwaitReconnect));
        assert_eq!(m.phase, Phase::Rebooting);
        m.step(Input::Timeout);
        // Shows up after the timeout anyway.
        assert_eq!(m.step(Input::Attached), Some(Action::ConfirmDevMode));
    }

    #[test]
    fn devmode_prompt_cancelled_then_recheck() {
        let mut m = trusted("17.5.1", true);
        m.step(Input::DevMode(false));
        m.step(Input::Revealed);
        m.step(Input::Detached);
        m.step(Input::Attached);
        assert_eq!(m.step(Input::Timeout), Some(Action::Idle));
        assert_eq!(m.error.as_ref().unwrap().code, ErrorCode::DevModeCancelled);
        assert_eq!(m.step(Input::User(UserCommand::Retry)), Some(Action::ReadDevMode));
        assert_eq!(m.phase, Phase::CheckingDevMode);
    }

    #[test]
    fn app_missing_retry_finds_it() {
        let mut m = trusted("18.0", true);
        m.step(Input::DevMode(true));
        m.step(Input::Generated { kind: RecordKind::RemotePairing, via: Some(RpVia::CoreDeviceProxy) });
        assert_eq!(m.step(Input::App(None)), Some(Action::Idle));
        assert_eq!(m.error.as_ref().unwrap().code, ErrorCode::AppNotFound);
        assert!(m.needs_attention());
        assert_eq!(m.step(Input::User(UserCommand::Retry)), Some(Action::FindApp));
        assert_eq!(m.step(Input::App(Some(app()))), Some(Action::Write));
        assert_eq!(m.rp_via, Some(RpVia::CoreDeviceProxy));
    }

    #[test]
    fn unplug_mid_write_resumes_write_on_replug() {
        let mut m = trusted("18.0", true);
        m.step(Input::DevMode(true));
        m.step(Input::Generated { kind: RecordKind::RemotePairing, via: None });
        m.step(Input::App(Some(app())));
        assert_eq!(m.step(Input::Detached), Some(Action::Idle));
        assert_eq!(m.error.as_ref().unwrap().code, ErrorCode::Disconnected);
        assert_eq!(m.failed_at, Some(Step::Write));
        assert_eq!(m.progress(), 0.7);
        assert_eq!(m.step(Input::Attached), Some(Action::Write));
    }

    #[test]
    fn stale_results_are_ignored() {
        let mut m = trusted("18.0", true);
        assert_eq!(m.step(Input::Verified), None);
        assert_eq!(m.step(Input::Written(WriteVia::VendDocuments)), None);
        assert_eq!(m.step(Input::Revealed), None);
        assert_eq!(m.phase, Phase::CheckingDevMode);
    }

    #[test]
    fn done_ignores_detach_and_failures() {
        let mut m = trusted("18.0", true);
        m.step(Input::DevMode(true));
        m.step(Input::Generated { kind: RecordKind::RemotePairing, via: None });
        m.step(Input::App(Some(app())));
        m.step(Input::Written(WriteVia::VendContainer));
        m.step(Input::Verified);
        assert_eq!(m.step(Input::Detached), Some(Action::Idle));
        assert_eq!(m.step(Input::Failed(PairError::internal("late"))), None);
        assert_eq!(m.step(Input::Attached), None);
        assert_eq!(m.phase, Phase::Done);
    }

    #[test]
    fn cancel_returns_to_detected() {
        let mut m = trusted("18.0", false);
        assert_eq!(m.step(Input::User(UserCommand::Cancel)), Some(Action::Idle));
        assert_eq!(m.phase, Phase::Detected);
        assert_eq!(m.step(Input::User(UserCommand::Begin)), Some(Action::Trust));
    }
}
