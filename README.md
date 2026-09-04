# Soundcore Utilities

An independent iOS app that controls the Anker Soundcore Sleep A30 earbuds and exposes every
control to Shortcuts and Siri: audio source (Bluetooth or local), noise cancelling, the sleep
timer, and the once-asleep behaviour.

Soundcore and Sleep A30 are trademarks of Anker Innovations. This project is not affiliated with
or endorsed by Anker.

## How it works

The official app talks to the earbuds over GATT carried on the Bluetooth Classic link. This app
finds that channel with CoreBluetooth, without hard-coded identifiers, and speaks the same packet
format. `PROTOCOL.md` documents everything learned so far, how it was learned, and what is open.

## Building

Open `Soundcore Utilities.xcodeproj` in Xcode 26 or later and run on a physical iPhone; the
simulator has no Bluetooth. Unit tests cover the packet layer and state-dump parsing:

```
xcodebuild -project "Soundcore Utilities.xcodeproj" -scheme "Soundcore Utilities" \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## Developer mode

Settings › tap the version number seven times. This reveals the raw Bluetooth view, the packet
log, and the state-snapshot tool used to map the earbuds' state dump.

## License

MIT. See `LICENSE`.

## Feedback

Settings › Send feedback composes an email to developer@weldawadyathink.com with the diagnostic
log attached.
