# Changelog

## 1.1.1 (2026-11-08)

- Maintenance release.

## 1.1.0 (2026-11-08)

- Doesn't lock while you're typing or using the mouse. It locks 5 seconds after you stop, if your device is still away.
- A signal that vanishes straight out of a strong, steady reading gets 15 seconds more, since that's usually a Bluetooth hiccup, not you leaving.
- When the Mac's own Bluetooth stops hearing anything, a "signal lost" countdown pauses (up to 60 seconds) and AwayLock restarts Bluetooth. A connection that stops answering is reconnected.
- "When I come back" now has three choices: Off, Wake the screen (lets your Apple Watch unlock, no password or Accessibility needed), and Type my password. Unlocking only happens within 30 minutes of the lock (5 minutes to 2 hours) and tries the password once per lock. Your 1.0 auto-unlock setting carries over as Type my password.
- New History tab: why each lock happened, which ones were probably wrong, and how long AwayLock held off while you worked. Kept on this Mac only.
- Calibrate: measure where you sit, and optionally where it should lock, to set the lock level. Replaces "Use current signal".
- Suggests a better lock level or away delay after several probably-wrong locks in a week. Never applied without you.
- The About window no longer opens cut off at the top and bottom.

## 1.0.2 (2026-11-07)

- Make it runable on macOS 14 Sonoma and macOS 15 Sequoia.

## 1.0.1 (2026-11-07)

- iPhone: locks within about 10 seconds plus your away delay when you walk off right after the phone drops its Bluetooth link. It used to wait up to a minute.
- Auto unlock checks your login password when you save it, so a typo can't get stuck in the Keychain.

## 1.0.0 (2026-11-06)

First public release.

- Locks your Mac when your chosen Bluetooth device has been away for a few seconds, or as soon as its signal is lost.
- Keeps the Mac awake and unlocked while the device is near.
- Works with Apple Watch and iPhone on the same iCloud account, and with bands that advertise with a fixed address.
- Set the lock distance from your current signal, with a live signal needle in Settings.
- Optional auto unlock when you come back. Off by default. Uses your Keychain and Accessibility access.
- Pause for 1 hour, Lock Now, and start at login.
- Automatic updates that install only while your device is near.
- Available in English, Chinese (Simplified and Traditional), French, German, Italian, Japanese, Korean, Portuguese (Brazil), Russian, Spanish and Vietnamese.
