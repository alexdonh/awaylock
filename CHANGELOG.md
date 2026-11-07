# Changelog

## Unreleased

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
