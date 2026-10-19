<!--
Standard part of every GitHub release description. The release workflow
appends everything below this comment to the generated notes; for a release
made by hand, copy it in and add the changes for that version above it.
-->
### Install

Download **`LoopCtrl.ipa`**. It is one app and takes one sideloading slot. It
replaces an older LoopCtrl install. Check it against `SHA256SUMS.txt` if you
like.

1. Re-sign and install it: the latest SideStore (My Apps → +) with a free
   Apple ID, or on a Mac `Scripts/sign-ipa.sh -i LoopCtrl.ipa`.
   Signers that skip the nested `.xctest` produce an app that crashes on open.
2. Trust the certificate under Settings → General → VPN & Device Management,
   and turn on Developer Mode.
3. Below iOS 27, pair once over USB with
   [LoopCtrl Pair](https://github.com/Souitou-iop/LoopCtrl-Pair) (Windows,
   macOS, Linux, Android) or import a pairing file. On iOS 27 and later, pair
   on the phone.
4. Open LoopCtrl → mount the Developer Disk Image (with LocalDevVPN or
   Shadowrocket connected) → **Start**. The first start asks for your passcode
   and for Notifications and Local Network access.

The package is unsigned, so iOS will not install it as-is. It carries no
provisioning profile, no team id and no device identifiers.

See the [README](https://github.com/Souitou-iop/LoopCtrl#readme) for
requirements by iOS version, pairing approval, LAN and remote access, and the
API.
