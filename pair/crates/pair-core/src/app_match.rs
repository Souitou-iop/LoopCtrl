//! Recognising LoopCtrl among the installed apps.
//!
//! The bundle ID prefix differs per signer (`$(LOOPCTRL_BUNDLE_PREFIX).loopctrl`),
//! so the match is, strongest first:
//! 1. Info.plist marker key [`MARKER_KEY`] set to true / 1 (reserved; LoopCtrl
//!    does not ship it yet);
//! 2. bundle ID ending in `.loopctrl`;
//! 3. CFBundleDisplayName or CFBundleName equal to "LoopCtrl".

use plist::Value;

use crate::model::{AppMatch, MatchedBy};

pub const MARKER_KEY: &str = "LoopCtrlPairingDropbox";
pub const BUNDLE_SUFFIX: &str = ".loopctrl";
pub const DISPLAY_NAME: &str = "LoopCtrl";

fn str_of<'a>(info: &'a plist::Dictionary, key: &str) -> Option<&'a str> {
    info.get(key).and_then(Value::as_string)
}

fn truthy(v: Option<&Value>) -> bool {
    match v {
        Some(Value::Boolean(b)) => *b,
        Some(Value::Integer(i)) => i.as_signed() == Some(1) || i.as_unsigned() == Some(1),
        Some(Value::String(s)) => matches!(s.as_str(), "1" | "true" | "YES" | "yes"),
        _ => false,
    }
}

fn classify(bundle_id: &str, info: &plist::Dictionary) -> Option<MatchedBy> {
    if truthy(info.get(MARKER_KEY)) {
        return Some(MatchedBy::Marker);
    }
    if bundle_id.to_ascii_lowercase().ends_with(BUNDLE_SUFFIX) {
        return Some(MatchedBy::BundleSuffix);
    }
    let named = |k| str_of(info, k).is_some_and(|n| n.trim().eq_ignore_ascii_case(DISPLAY_NAME));
    if named("CFBundleDisplayName") || named("CFBundleName") {
        return Some(MatchedBy::DisplayName);
    }
    None
}

/// Picks LoopCtrl from an installation_proxy lookup (bundle ID → Info dict).
/// If several apps match, the strongest match wins, then the bundle ID order
/// (stable output).
pub fn find_loopctrl<'a, I>(apps: I) -> Option<AppMatch>
where
    I: IntoIterator<Item = (&'a String, &'a Value)>,
{
    let mut found: Vec<AppMatch> = apps
        .into_iter()
        .filter_map(|(id, v)| {
            let info = v.as_dictionary()?;
            let matched_by = classify(id, info)?;
            let name = str_of(info, "CFBundleDisplayName")
                .or_else(|| str_of(info, "CFBundleName"))
                .unwrap_or(DISPLAY_NAME)
                .to_owned();
            Some(AppMatch {
                bundle_id: id.clone(),
                name,
                version: str_of(info, "CFBundleShortVersionString").map(str::to_owned),
                matched_by,
                file_sharing: truthy(info.get("UIFileSharingEnabled")),
            })
        })
        .collect();
    found.sort_by(|a, b| a.matched_by.cmp(&b.matched_by).then_with(|| a.bundle_id.cmp(&b.bundle_id)));
    found.into_iter().next()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn app(pairs: &[(&str, Value)]) -> Value {
        let mut d = plist::Dictionary::new();
        for (k, v) in pairs {
            d.insert((*k).into(), v.clone());
        }
        Value::Dictionary(d)
    }
    fn s(v: &str) -> Value {
        Value::String(v.into())
    }

    #[test]
    fn matches_by_suffix_any_prefix() {
        let mut apps = HashMap::new();
        apps.insert("com.tencent.xin".to_string(), app(&[("CFBundleDisplayName", s("微信"))]));
        apps.insert(
            "com.customer123.loopctrl".to_string(),
            app(&[("CFBundleDisplayName", s("LoopCtrl")), ("CFBundleShortVersionString", s("1.4"))]),
        );
        let m = find_loopctrl(&apps).unwrap();
        assert_eq!(m.bundle_id, "com.customer123.loopctrl");
        assert_eq!(m.matched_by, MatchedBy::BundleSuffix);
        assert_eq!(m.version.as_deref(), Some("1.4"));
        assert!(!m.file_sharing);
    }

    #[test]
    fn ignores_uitests_runner_and_lookalikes() {
        let mut apps = HashMap::new();
        apps.insert(
            "top.ebato.loopctrl.uitests.xctrunner".to_string(),
            app(&[("CFBundleName", s("LoopCtrlUITests-Runner"))]),
        );
        apps.insert("com.example.loopctrlpro".to_string(), app(&[("CFBundleName", s("LoopCtrl Pro"))]));
        assert!(find_loopctrl(&apps).is_none());
    }

    #[test]
    fn display_name_fallback() {
        let mut apps = HashMap::new();
        apps.insert(
            "com.resigned.app".to_string(),
            app(&[("CFBundleDisplayName", s("LoopCtrl")), ("UIFileSharingEnabled", Value::Boolean(true))]),
        );
        let m = find_loopctrl(&apps).unwrap();
        assert_eq!(m.matched_by, MatchedBy::DisplayName);
        assert!(m.file_sharing);
    }

    #[test]
    fn marker_beats_suffix() {
        let mut apps = HashMap::new();
        apps.insert("a.loopctrl".to_string(), app(&[]));
        apps.insert("z.renamed".to_string(), app(&[(MARKER_KEY, Value::Boolean(true)), ("CFBundleName", s("LC"))]));
        let m = find_loopctrl(&apps).unwrap();
        assert_eq!(m.bundle_id, "z.renamed");
        assert_eq!(m.matched_by, MatchedBy::Marker);
        assert_eq!(m.name, "LC");
    }

    #[test]
    fn marker_accepts_integer_and_string() {
        for v in [Value::Integer(1.into()), s("YES")] {
            let mut apps = HashMap::new();
            apps.insert("x.y".to_string(), app(&[(MARKER_KEY, v)]));
            assert_eq!(find_loopctrl(&apps).unwrap().matched_by, MatchedBy::Marker);
        }
        let mut apps = HashMap::new();
        apps.insert("x.y".to_string(), app(&[(MARKER_KEY, Value::Boolean(false))]));
        assert!(find_loopctrl(&apps).is_none());
    }
}
