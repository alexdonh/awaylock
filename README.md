# AwayLock

Locks your Mac when you walk away and keeps it unlocked while you're nearby.

AwayLock is a menu bar app. Pick one Bluetooth device you carry: an Apple Watch, an iPhone, or a band that advertises with a fixed address. While it's near, your Mac won't idle lock or put the display to sleep. When it has been out of range for a few seconds, or the signal is lost, the Mac locks.

- No companion iPhone app and no account.
- Doesn't lock while you're typing or using the mouse, even if your phone is in a bag.
- Opt-in unlock when you come back: wake the screen for your Apple Watch, or type your password (off by default, see [Security](#security)).
- A local lock history shows why each lock happened and flags the ones that were probably wrong.
- Low power: it samples fast only when a decision is close.

Requires macOS 14 Sonoma or later. Available in English, Chinese (Simplified and Traditional), French, German, Italian, Japanese, Korean, Portuguese (Brazil), Russian, Spanish and Vietnamese.

## Install

1. Download `AwayLock-<version>.dmg` from the [latest release](https://github.com/alexdonh/awaylock/releases/latest).
2. Open it and drag **AwayLock** to **Applications**.
3. Launch AwayLock and allow Bluetooth when asked.
4. In Settings, press **Choose…** and pick the device you carry. A device shows up after it has been detected for 10 seconds.
5. Set the lock distance: press **Calibrate…** and sit as you normally work (optionally walk to where it should lock), or drag the slider. Then pick how long the device must be away before the Mac locks: immediately, or after 5 to 60 seconds.

The app is signed with Developer ID and notarized by Apple.

## Which devices work

| Device | Works? |
| --- | --- |
| Apple Watch on the same iCloud account | Yes, recommended |
| iPhone on the same iCloud account | Yes. The signal is weaker in a pocket or bag, so adjust the distance |
| AirPods | Partly. A closed case stops the signal, so the Mac locks |
| Bands with a fixed Bluetooth address (some Mi Band / Amazfit models) | Depends on the model. AwayLock hides devices whose address keeps changing |
| Garmin and most watches paired to a phone | Usually not. They stop broadcasting while connected to a phone |

Apple devices change their Bluetooth address every few minutes. Your Mac can follow them only when they're signed in to the same iCloud account. AwayLock never talks to iCloud.

## Updates

AwayLock checks for updates once a day using [Sparkle](https://sparkle-project.org). You can turn on automatic download and install in Settings under Updates. Updates only install while your device is near. **Check for Updates…** is also in the menu.

## Privacy

Your data stays on this Mac. Settings live in `UserDefaults`. The login password, used only if you choose **Type my password**, lives in your Keychain. The lock history is a small file in `~/Library/Application Support/AwayLock/`.

The only network request is the daily update check: one HTTPS GET of `https://awaylock.app/appcast.xml`, which redirects to this repository's latest release. Full details: [PRIVACY.md](PRIVACY.md).

## Security

- **No signal counts as away**, if you turn on Lock when signal is lost.
- **Unlock on return is off by default.** **Wake the screen** only wakes the display, so an Apple Watch set to unlock your Mac does the unlocking with macOS's own distance check. It needs no permission. **Type my password** enters your login password on the lock screen after your device has been back in range for 3 seconds. Only that mode needs Accessibility access. Either way, AwayLock only unlocks a lock it made, within 5 minutes to 2 hours of it (30 by default), and tries the password at most once per lock. Someone could relay your device's Bluetooth signal to make it seem near, so don't use Type my password on shared Macs or Macs with sensitive data.
- **Not locking while you type has a limit.** AwayLock holds the lock only if you kept using the Mac without a 5-second break since the device started leaving. Someone who sits down in that moment could hold it open; in Passive signal mode the window can be up to 10 seconds longer.
- **A lock you start yourself (Control-Command-Q) is never auto unlocked.**
- Locking uses `SACLockScreenImmediate`, the same private call BLEUnlock uses. If a future macOS removes it, AwayLock sleeps the display instead, which locks only when Require password is set to Immediately in Lock Screen settings. Because it relies on a private API and Accessibility, AwayLock can't be sandboxed and isn't on the Mac App Store.

To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Build from source

```sh
brew install xcodegen
xcodegen generate
xcodebuild -scheme AwayLock build
xcodebuild -scheme AwayLock test -destination 'platform=macOS'
```

Requires Xcode 26 or later. Dev builds are ad-hoc signed. To keep Bluetooth and Accessibility grants across rebuilds, put your team and signing identity in `Config/Local.xcconfig` (git-ignored; see `Config/Base.xcconfig`).

## Releasing

```sh
scripts/release.sh 1.2.0          # bump version + build number, write CHANGELOG entry, commit, tag
git push origin main v1.2.0       # CI builds, notarizes and publishes the release
```

Release notes come from the `## Unreleased` section of `CHANGELOG.md` if there is one. Otherwise they're generated from `feat:`/`fix:`/`perf:` commits since the last tag. `.github/workflows/release.yml` lists the secrets it needs. A manual run of that workflow is a dry run: it builds a notarized DMG as an artifact and publishes nothing.

## Support

AwayLock is free and open source. If it's useful to you, you can support it:

[![GitHub Sponsors](https://img.shields.io/badge/GitHub%20Sponsors-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/alexdonh)
[![PayPal](https://img.shields.io/badge/PayPal-003087?logo=paypal&logoColor=white)](https://paypal.me/alexdonh)

## Acknowledgements

- [Sparkle](https://sparkle-project.org) for updates (MIT). Full notices in [Acknowledgements.txt](AwayLock/Resources/Acknowledgements.txt), also shown in the app under About → Acknowledgements.

## License

[Apache-2.0](LICENSE)
