# Privacy Policy

_Last updated: November 7, 2026_

AwayLock is a macOS menu bar app that locks your Mac when a Bluetooth device you carry moves away. It has no account, analytics, telemetry, crash reporting, ads or cloud service. Everything it keeps stays on your Mac.

## What AwayLock stores

### Settings (`UserDefaults`, domain `app.awaylock.mac`)

| Setting | What it is |
| --- | --- |
| Device ID | The identifier macOS assigns to the device you picked. It is generated on your Mac and is not the device's hardware Bluetooth address. |
| Device name | The name the device broadcasts, for example "Alex's Apple Watch", shown in Settings and the menu. |
| Apple device | Whether the device is an Apple device, which changes how its signal is read. |
| Lock distance, away delay, signal mode | The lock settings you choose. |
| Lock when signal is lost, keep awake while near, auto-unlock, start at login | Your on/off choices. |
| Untrackable devices | IDs of devices that stopped broadcasting or changed address, so the picker hides them. |
| Update settings | Sparkle's automatic check and download choices and the time of the last check. |

### Login password (Keychain, only if you turn on auto-unlock)

- Before it is saved, the password is checked against your macOS account on this Mac using Open Directory. A wrong entry counts toward your account's failed login limit, like a wrong entry on the lock screen.
- It is saved as a Keychain item that only works while this Mac is unlocked and only on this Mac (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). It does not sync to iCloud Keychain.
- It is used only to type into the macOS lock screen. AwayLock checks that the screen is locked right before typing.
- It is never written to settings or logs and never sent anywhere.
- Turning off auto-unlock deletes it from the Keychain.

### Logs (macOS unified log)

AwayLock writes diagnostics to the macOS system log under the subsystem `app.awaylock.mac`. They include signal strength readings, why a lock happened, and Bluetooth connect and disconnect times. They never include your password. The log stays on your Mac and macOS deletes old entries automatically. AwayLock doesn't send logs anywhere. You can read them with:

```sh
log show --last 1h --predicate 'subsystem == "app.awaylock.mac"'
```

## Bluetooth

- **While the device picker is open**, AwayLock lists nearby Bluetooth devices by name and signal strength so you can choose one. Devices you don't choose are not saved, except IDs in the untrackable list above.
- **After you pick a device**, AwayLock only reads that device's signal strength: from its broadcasts, or by connecting to it and reading signal strength. When it connects, it lists the device's Bluetooth services, which is how it detects that the link is up. It reads no data from the device: no health, notification, message or location data.
- AwayLock never talks to iCloud. Apple devices are followed through macOS's own Bluetooth support.

## Network

AwayLock makes one kind of network request: the update check.

- Once a day (if update checks are on in Settings), or when you choose **Check for Updates…**, the [Sparkle](https://sparkle-project.org) updater sends one HTTPS GET to `https://awaylock.app/appcast.xml`.
- `awaylock.app` is a static site on Cloudflare. That URL redirects to the latest release on GitHub (`github.com/alexdonh/awaylock`).
- The request carries what any web request carries: your IP address and a User-Agent with the app name and version. Sparkle's system profile reporting is off, so no hardware or system details are sent.
- If an update is available and you install it, the DMG is downloaded from GitHub Releases.
- Cloudflare and GitHub can log these requests under their own privacy policies. AwayLock's developer runs no analytics on them.

Links in the About window (GitHub, GitHub Sponsors, PayPal) and the Language & Region button only open in your browser or System Settings when you click them.

## Permissions

| Permission | Why | Required |
| --- | --- | --- |
| Bluetooth | To read your device's signal strength | Yes |
| Accessibility | To type your password on the lock screen | Only for auto-unlock |
| Login item | To start AwayLock when you log in | Only if you turn on start at login |

## Removing your data

1. Turn off auto-unlock in Settings, which deletes the saved password. Or delete the `app.awaylock.mac` item in Keychain Access.
2. Quit AwayLock and move it to the Trash.
3. Remove the settings:

   ```sh
   defaults delete app.awaylock.mac
   ```

4. Optionally, revoke Bluetooth and Accessibility access in System Settings → Privacy & Security.

## Children

AwayLock collects no personal data from anyone, including children.

## Changes

Changes to this policy are made in this file and are visible in its [commit history](https://github.com/alexdonh/awaylock/commits/main/PRIVACY.md).

## Contact

Questions: [open an issue](https://github.com/alexdonh/awaylock/issues). For security issues, see [SECURITY.md](SECURITY.md).
