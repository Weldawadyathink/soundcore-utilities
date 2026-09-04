# App Store listing (ready to paste)

Everything App Store Connect asks for, prepared in advance. Field limits are Apple's.

## Names

- **Name** (30 chars max): `Headphone Control`
- **Subtitle** (30 chars max): `for Soundcore Sleep A30`
- **Bundle ID**: `com.weldawadyathink.Soundcore-Utilities` (already in the project; cannot change after first upload)
- **Home-screen label** (`CFBundleDisplayName`): `Headphone Control`
- **Primary category**: Utilities. **Secondary**: Health & Fitness (sleep) or none.
- **Age rating**: 4+.

## Promotional text (170 chars max)

Switch your Sleep A30 between Bluetooth and local audio, toggle noise cancelling, and set the sleep timer, all from Shortcuts and Siri.

## Description

Headphone Control puts the Soundcore Sleep A30's settings where iOS can automate them.

Every control is a Shortcuts action and a Siri phrase, so your bedtime routine can switch the earbuds to local audio, turn noise cancelling on, and start a 30-minute sleep timer in one tap, or you can just say "Switch Headphone Control to Local mode".

Controls
• Audio source: stream from your iPhone or play the sounds stored on the earbuds
• Noise cancelling on or off
• Sleep timer with 10, 20, 30, 60, and 90-minute presets and a live countdown
• Once-asleep behaviour: keep audio, pause audio, or play local audio with ANC off

Shortcuts and Siri
• Set Audio Source, Set Noise Cancelling, Start Sleep Timer, Stop Sleep Timer, Set Once-Asleep Behavior
• Get Audio Source, Get Noise Cancelling State, Get Sleep Timer, Get Sleep A30 Status
• Actions run in the background; the app does not need to be open

The app finds the earbuds automatically once they are connected in Settings › Bluetooth. Each command waits for the earbuds to confirm it, so you always know whether it took effect.

Headphone Control is an independent, open-source project (MIT) and is not affiliated with, endorsed by, or supported by Anker. Soundcore and Sleep A30 are trademarks of Anker Innovations. Requires a Soundcore Sleep A30.

## Keywords (100 chars max, comma separated)

sleep,earbuds,shortcuts,siri,noise cancelling,sleep timer,bluetooth,anc,automation,bedtime

## What's New (version 1.0)

First release.

## URLs

- **Support URL**: https://github.com/Weldawadyathink/soundcore-utilities
- **Privacy policy URL** (required): https://github.com/Weldawadyathink/soundcore-utilities/blob/main/PRIVACY.md
- **Marketing URL**: optional, same repo.

## App Privacy questionnaire

- Data collection: **No, we do not collect data from this app.** (The feedback email is composed
  by the user in their own mail app; nothing is transmitted by the app itself.)
- Tracking: No.
- The privacy manifest in the project already declares UserDefaults use with reason CA92.1.

## App Review information

Notes for the reviewer:

> This app controls the Anker Soundcore Sleep A30 earbuds over Bluetooth. It requires that
> hardware; without it the app shows a "Sleep A30 not found" state, which is the expected
> behaviour. The `bluetooth-central` background mode is used so Shortcuts actions can send a
> command to the earbuds while the app is not in the foreground. No accounts, servers, or
> purchases are involved. The app is not affiliated with Anker; the description and in-app
> Settings state this.

- Sign-in required: No.
- Contact: developer@weldawadyathink.com

## Export compliance

`ITSAppUsesNonExemptEncryption` is set to NO in Info.plist, so no questionnaire appears at upload.

## Screenshots (required sizes: 6.9-inch and 6.5-inch iPhone; iPad 13-inch if iPad stays enabled)

Suggested set, taken on a real phone with the earbuds connected:
1. Main screen, connected, with a timer running.
2. The Shortcuts app showing the actions list for the app.
3. A Siri result card after "Switch Headphone Control to Local mode".
4. Settings sheet.

If you would rather not produce iPad screenshots, set `TARGETED_DEVICE_FAMILY` to `1` (iPhone
only) in the project before uploading.

## Before uploading

- Set `MARKETING_VERSION` (1.0) and bump `CURRENT_PROJECT_VERSION` for every build.
- Archive with automatic signing under the developer team; the team ID is already in the project.
- TestFlight one build first and exercise a Shortcut after the phone has been idle overnight.
