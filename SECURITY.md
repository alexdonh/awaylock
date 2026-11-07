# Security Policy

## Supported versions

Only the latest release gets security fixes. AwayLock updates itself through Sparkle, so fixes reach users as a normal update.

| Version | Supported |
| --- | --- |
| 1.0.x (latest) | Yes |
| Older | No, please update |

## Reporting a vulnerability

Please **don't open a public issue** for a security problem.

Report it privately through [GitHub Security Advisories](https://github.com/alexdonh/awaylock/security/advisories/new). Please include:

- The AwayLock and macOS versions
- Steps to reproduce, and what an attacker gains
- A proof of concept if you have one

You'll get a reply within 7 days. Once a fix is released, the advisory is published with credit to you, unless you'd rather not be named.

## How AwayLock protects you

### Distribution and updates

- Release builds are signed with a Developer ID certificate, built with the hardened runtime and notarized by Apple.
- Releases are built by [GitHub Actions](.github/workflows/release.yml) from tagged commits in this repository. Commits and release tags are signed.
- Updates use [Sparkle](https://sparkle-project.org) 2 over HTTPS. Each update is signed with an EdDSA (ed25519) key. Sparkle rejects any update whose signature doesn't match the public key built into the app. The private key is stored only as a CI secret.

### Login password (auto-unlock)

Auto-unlock is **off by default**. If you turn it on:

- Your password is checked against your macOS account before it is saved, so a typo is never typed on the lock screen.
- It is stored in the Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: readable only while the Mac is unlocked, never synced to iCloud, and never in settings or logs.
- AwayLock only types it after a lock **it** made and after your device has been back in range for 3 seconds. It checks the screen is still locked right before typing, so the password never lands in another app.
- A lock you start yourself (Control-Command-Q, Lock Screen in the Apple menu, a hot corner) is never auto-unlocked.
- Turning off auto-unlock deletes the password from the Keychain.

### Locking

- With **Lock when signal is lost** on, a device that can't be heard counts as away.
- Locking calls `SACLockScreenImmediate` from macOS's private `login` framework. If a future macOS removes it, AwayLock sleeps the display instead, which only locks when **Require password** is set to **Immediately** in Lock Screen settings. AwayLock shows a warning if a lock fails.

## Known limitations

These are inherent to how AwayLock works. They are not considered vulnerabilities:

- **Relay attacks.** Bluetooth signal strength proves that a device's signal is nearby, not that you are. Someone with the right equipment could relay your device's signal to make it seem close. That can keep the Mac unlocked and, with auto-unlock on, unlock it. **Don't use auto-unlock on shared Macs or Macs with sensitive data.**
- **Signal strength is approximate.** Walls, bodies, pockets and bags change it. The Mac may lock late or early depending on the lock distance you set.
- **Accessibility access.** Auto-unlock needs Accessibility access to type the password. Any app with that access can send keystrokes, so grant it only if you use auto-unlock.
- **Not sandboxed.** The private lock call and Accessibility can't be used inside the App Sandbox, so AwayLock isn't sandboxed and isn't on the Mac App Store. The source is in this repository for review.
- **Your Mac's own security still applies.** Anyone who can log in to or unlock your Mac account can read AwayLock's Keychain item, the same as any other app's.

## Data

See [PRIVACY.md](PRIVACY.md) for what AwayLock stores and its one network request.
