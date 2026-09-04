# Soundcore Sleep A30 control protocol

What this app knows about talking to the Sleep A30, how it was learned, and what is still open.
Everything here came from PacketLogger captures of the official Soundcore iOS app and from
labelled state snapshots taken with this app's developer tools. Nothing is from Anker documentation.

## Transport

- The earbuds are a dual-mode device and appear in CoreBluetooth as two peripherals:
  `soundcore Sleep A30` (Classic identity) and `soundcore Sleep A30 LE` (LE identity, random address).
- The control channel is GATT carried over the **Bluetooth Classic** link (ATT over BR/EDR).
  Writes to the same characteristic over a plain LE connection are accepted and silently ignored.
- On iOS the working path is the `soundcore Sleep A30 LE` peripheral **as returned by
  `retrieveConnectedPeripherals(withServices:)`**, which iOS bridges onto the Classic link.
  The same name reached via a scan result gives a real LE link that does not work.
  `CBConnectPeripheralOptionEnableTransportBridgingKey` alone does not fix this because the LE
  address is random and iOS cannot match the two identities.
- Service `0209F5DA-0000-1000-8000-00805F9B34FB`: characteristic `7777` (write, write without
  response) carries commands, `8888` (read, notify) carries replies. ATT handles 0xA102 / 0xA105.
  A second service `66666666-…` / `77777777-…` is not the control channel.
- The app does not hard-code any of the above. It ranks writable characteristics structurally,
  probes each with `01 01`, and remembers the identity that answers.

## Framing

```
host -> earbuds:   08 EE 00 00 00 | cmd(2) | len(2, LE) | body | checksum
earbuds -> host:   09 FF 00 00 01 | cmd(2) | len(2, LE) | body | checksum
```

- `len` is the total packet length including the checksum.
- `checksum` is the low byte of the sum of every preceding byte.
- Quirk: the official app sends sleep-timer packets (`15 85`) with `len` one byte short of the
  bytes actually sent. The earbuds accept them; this app mirrors the quirk byte for byte.

## Commands

| cmd     | direction | body                                             | meaning |
|---------|-----------|--------------------------------------------------|---------|
| `01 01` | out       | none                                             | request state; reply is the 150-byte state dump |
| `01 A9` | out       | `00` Bluetooth, `01` Local                        | set audio source; acked with `01 A9`, then `01 14` and `01 13` pushes |
| `01 14` | in        | source                                           | audio source changed |
| `01 13` | in        | `00 93 71 40 00 00 00 00 00 [source] 25`          | audio status push, layout unknown |
| `06 87` | out       | `00` off, `01` on                                 | set noise cancelling; acked with `06 87` + body |
| `06 07` | in        | value                                            | noise cancelling changed |
| `15 03` | out/in    | out: none. in: `enabled, minutes u16, flag, remaining seconds u32` | sleep timer status; also pushed after any `15 85` |
| `15 85` | out       | `00, enabled, minutes u16, flag`                  | set sleep timer (see quirk above) |
| `15 85` | out       | `FF FF FF flag`                                   | change only the once-asleep flag |
| `15 8F` | out       | `01` on, `00` off                                 | auto-switch once asleep |

Once-asleep options in the official app map to two settings: `15 8F` is on/off ("Keep Audio" = off)
and the flag byte picks the action when on: `01` = "Play local audio, ANC Off", `00` = "Pause Audio".
The official app writes only the byte that changed; this app writes both.

Switching to Local mode was observed to turn the sleep timer off.

## State dump (`01 01` reply body, 150 bytes)

| offset  | meaning | status |
|---------|---------|--------|
| 0       | primary earbud, `00` left / `01` right | confirmed |
| 1       | both earbuds connected | confirmed |
| 2, 3    | battery level left, right; `FF` when in the case | confirmed position, **scale unknown** (raw 7 while the app showed 80 %) |
| 4–8     | left firmware, ASCII, e.g. `01.91` | confirmed |
| 9–13    | right firmware | confirmed |
| 14–29   | serial number, 16 ASCII chars | confirmed |
| 30–35   | a Bluetooth address, reversed | probable |
| 36–40   | secondary firmware, ASCII `01.68` | confirmed string, role unknown |
| 58      | sleep timer enabled | confirmed |
| 59–60   | sleep timer minutes, u16 LE | confirmed |
| 61      | once-asleep flag | confirmed |
| 65      | audio source | confirmed |
| 70      | probably case battery percent (`0x32` while the case showed 50 %) | one data point |
| 73      | local audio active | probable |
| 95–134  | four 10-byte records `NN NN 80 00 00 00 00 00 00 04`, purpose unknown | unknown |
| 140     | noise cancelling | confirmed |
| 144, 148| went `00 -> 01` after this app's auto-switch writes; one is probably `15 8F` | **unresolved** |
| 145     | Bluetooth audio playing | confirmed |

The dump does not include the timer's remaining seconds; the app queries `15 03` for that.

## Open issues

1. **Once-asleep changes made by this app are not shown by the official app.** After this app
   sent `15 85 FF FF FF 01` and `15 8F 01`, the Soundcore app still displayed its previous choice.
   Both writes are acknowledged by the earbuds, and the state dump changed at offsets 61, 144 and
   148. Possible causes: the official app caches the setting locally and only re-reads it on a
   fresh connection, or it reads it through a query not yet captured. To resolve: set an option
   from this app, force-quit and relaunch the Soundcore app, and note what it shows; and capture
   the Soundcore app's startup traffic (force-quit, start PacketLogger, open the app) to see every
   query it sends.
2. **Auto-switch on/off offset in the state dump** is unlocated (144 or 148). Snapshots taken from
   the Soundcore app in the order Keep Audio → Play local audio, ANC Off → Pause Audio would settle it.
3. **Battery scale.** Raw level 7 displayed as 80 %. Snapshots labelled with the app's percentages
   at full charge and around half charge would pin the scale, and a case reading other than 50 %
   would confirm offset 70.
4. **Offsets 73 vs 65.** Both go to 1 in Local mode; a snapshot with local playback paused would
   show whether 73 is a play state.
5. **Unmapped regions**: 41–57, 62–64, 66–69, 71–72, 74–94, 95–134, 135–139, 141–143, 146–149.

## Tools in the app (developer mode: Settings › tap the version 7 times)

- **Bluetooth tab**: adapter state, auto-connect, learned identity, GATT table, ranked write
  candidates, every known command, and raw or framed custom packets.
- **Settings › Send feedback** composes an email to the developer with the log and snapshots attached.
- **Log tab**: timestamped TX/RX with decoded summaries; Share exports it.
- **Snapshots tab**: capture the state dump with a label; bytes that changed from the previous
  snapshot are highlighted; Share exports all snapshots with changed offsets.

## Shortcuts

App Intents (Shortcuts and Siri): Set Audio Source, Set Noise Cancelling, Start Sleep Timer,
Stop Sleep Timer, Set Once-Asleep Behavior, Get Audio Source, Get Noise Cancelling State,
Get Sleep Timer, Get Sleep A30 Status. They run in the app process in the background
(`bluetooth-central` background mode) and wait for the earbuds' acknowledgement, so a failed
command fails the Shortcut with a readable reason.
