# iPad Mouse

Turns an iPad Pro into a pen tablet and trackpad for a Mac. Two apps:

```
 iPad (sender)                                  Mac (receiver, menu bar)
 ┌──────────────────────┐   UDP datagrams    ┌──────────────────────────┐
 │ Pencil hover/touch   │  20 bytes each,    │ Receiver: Bonjour listener│
 │ finger gestures      │ ───────────────▶   │ Injector: CGEvent posting │
 │ UIScrollView scroll  │  Bonjour discovery │   (needs Accessibility)   │
 └──────────────────────┘ ◀───────────────   └──────────────────────────┘
                           config reply: display size
```

| File | Role |
|---|---|
| `Shared/Protocol.swift` | The packet format both sides speak |
| `Mac/Receiver.swift` | Advertises `_ipadmouse._udp`, parses packets |
| `Mac/Injector.swift` | Moves the cursor, clicks, scrolls, presses keys |
| `Mac/AppDelegate.swift` | Menu bar UI, display picker, Accessibility prompt |
| `iPad/TouchpadViewController.swift` | All gesture mapping |
| `iPad/TouchpadView.swift` | The black surface (a UIScrollView for native momentum) |
| `iPad/Link.swift` | Finds the Mac, keeps the link alive |
| `project.yml` | XcodeGen spec that produces the Xcode project |

## What it does

Two modes, switched with the **Mode** button on the iPad and remembered between launches.

### Desktop mode

| Input | Result on the Mac |
|---|---|
| Pencil hovering (M2 iPad Pro or newer) | Pointer follows, hover effects work |
| Pencil touch | Left click; keep it down to drag |
| Pencil double-tap (barrel) | Right click |
| Pencil Pro squeeze | Back (mouse button 4) |
| Quick hard stab with the Pencil | Back (mouse button 4) |
| One finger tap | Pointer jumps to that spot, then left click |
| One finger drag | Move the pointer like a trackpad |
| Two finger drag | Scroll with momentum |
| Two finger tap | Right click |
| Three finger swipe left/right/up/down | Next/previous Space, Mission Control, App Exposé |
| Pinch | Cmd + / Cmd - |

### League mode

A one-handed finger layout for League of Legends, with the Pencil as an optional precision aimer.
Matches bindings where left click is attack-move, right click is move, mouse 4 is a summoner
spell and mouse 5 is item 1 (check `League of Legends.app/Contents/LoL/Config/input.ini`).

| Input | Result on the Mac |
|---|---|
| One finger down or held | Pointer follows the finger (aim for skillshots; no click) |
| Quick one-finger tap | Right click there (move) |
| Two-finger tap | Left click at the midpoint (attack-move) |
| Three-finger tap | Mouse 4 (summoner spell) |
| Four-finger tap | Mouse 5 (item 1) |
| Two-finger drag | Scroll (camera zoom) |
| Pencil hovering | Pointer follows |
| Pencil tip tap | Right click there (move); hold to keep moving |
| Pencil barrel double-tap | Left click at the pointer (attack-move) |
| Pencil Pro squeeze | Mouse 4 |
| Hard stab, three-finger swipes, pinch | Disabled |

Orb walking one-handed: two fingers on the target, one finger where you want to step, repeat.

### Training mode

A rhythm-game trainer for mechanics. Nothing is sent to the Mac. Prompts appear as circles
with a shrinking approach ring; hit them on the beat with the gesture the label asks for
(ATK = two fingers or Pencil barrel double-tap, MOVE = one finger or Pencil tip, SUMM = three, ITEM = four). Each hit is
judged Perfect / Early / Late / Off-position / Miss, and the stats line tracks accuracy,
perfects, streak, timing bias in ms and position error in points.

Drills live in `Drill.library` in `iPad/TrainingView.swift`: a name, a beat period, and steps
at fractional offsets within the beat. Shipped drills: Orb Walk, Kite + Summoner, Burst Combo,
Reaction. Slower / Faster scale the beat.

Planned: key prompts (F1-F5 ally camera, QWER combos) once the Mac app relays keyboard events,
and game-aware drills fed by League's local Live Client Data API.

### Both modes

| Input | Result |
|---|---|
| "Dim screen" button | Backlight to zero; the restore button stays in the top right |
| "Prefer USB" button | Refuses Wi-Fi so only a wired link is used |

The mapped area is letterboxed to the Mac display's aspect ratio and drawn as a faint outline.

---

## Part 1: One-time setup (do this while Xcode downloads)

1. **Install Xcode** from the Mac App Store. It is large (tens of GB) and takes a while.
   When it finishes, open it once so it installs its components, then in Terminal:
   ```
   sudo xcode-select -s /Applications/Xcode.app
   sudo xcodebuild -license accept
   xcodebuild -runFirstLaunch
   ```
   The first time you pick an iPad as a run destination, Xcode will offer to download the
   iOS platform support. Say yes. (Xcode > Settings > Components lists them if you need them later.)

2. **Add your Apple ID**: Xcode > Settings > Accounts > "+" > Apple ID.
   A free Apple ID is enough to run on your own iPad. The limits of a free account:
   - the app expires after 7 days (just run it from Xcode again),
   - at most 3 apps installed this way at a time,
   - no TestFlight, no App Store, no push notifications or iCloud.
   The paid Apple Developer Program (99 USD per year) removes all of that and is required for Part 4.

3. **Enable Developer Mode on the iPad**: Settings > Privacy & Security > Developer Mode > on.
   The iPad restarts and asks you to confirm. Without this, Xcode cannot install anything.

4. **Generate the Xcode project** (XcodeGen is downloaded on first run, about 10 MB):
   ```
   cd ~/Documents/ipad_mouse
   ./tools/generate.sh
   open iPadMouse.xcodeproj
   ```
   Any time you change `project.yml`, re-run the script. Do not edit the `.xcodeproj` by hand.

   *Alternative, and good practice:* make the two projects yourself with File > New > Project
   (iOS App, interface Storyboard, language Swift; and macOS App), delete the generated
   ContentView/ViewController/storyboard files, drag the `iPad`, `Mac` and `Shared` folders in,
   and copy the Info.plist keys from `project.yml`. Everything you learn there transfers to visionOS.

5. **Signing**: in Xcode, click the blue project icon at the top of the file list, pick the
   `iPadMouse` target, open *Signing & Capabilities*, and set *Team* to your name.
   Do the same for `iPadMouseMac`. If Xcode complains the bundle identifier is taken,
   change `bundleIdPrefix` in `project.yml` to something unique and re-generate.

---

## Part 2: Run the Mac side

1. Scheme picker (top of the window): choose `iPadMouseMac` and destination *My Mac*. Press Cmd-R.
2. macOS will ask for **Accessibility** access. Open System Settings > Privacy & Security >
   Accessibility, turn on "iPad Mouse", then quit and relaunch the app from Xcode.
   CGEvent posting is silently dropped until this is granted.
3. If the firewall asks whether "iPad Mouse" may accept incoming connections, allow it.
4. An iPad icon appears in the menu bar. Its first item shows the status
   ("Waiting for iPad…"). *Target Display* lists your screens.

Every time you rebuild, macOS may ask for Accessibility again, because the signature of a
debug build changes. Turning the toggle off and on again in System Settings fixes it.

---

## Part 3: Run the iPad side

1. Plug the iPad into the Mac with USB-C. On the iPad tap **Trust** when asked.
2. In Xcode choose scheme `iPadMouse` and pick your iPad as the destination
   (it is listed by name; it may say "preparing" for a minute the first time while Xcode copies symbols).
3. Press Cmd-R. Xcode builds, signs, installs and launches the app.
4. First launch with a free account: the iPad shows "Untrusted Developer". Go to
   Settings > General > VPN & Device Management > your Apple ID > Trust. Launch again.
5. iPadOS asks "iPad Mouse would like to find and connect to devices on your local network". Allow.
   This is the `NSLocalNetworkUsageDescription` prompt; denying it makes Bonjour return nothing.
6. The HUD at the top of the black screen shows "Connected to <your Mac> via USB" or "via Wi-Fi".

**Wireless debugging**: Window > Devices and Simulators > select the iPad > "Connect via network".
After that you can build to the iPad without the cable.

**Reading logs**: Xcode's console (bottom pane) shows `print()` output from whichever app you ran.
To see both apps at once, run the Mac app from Xcode and look at the iPad app's logs in
Console.app with the iPad selected in the sidebar.

### If the iPad cannot find the Mac
- Both must be on the same Wi-Fi, or the USB network link must be up.
- Check that the Mac menu bar status says "Waiting for iPad".
- Toggle "Prefer USB" off on the iPad if it is on and you are not wired.
- iPad Settings > Privacy & Security > Local Network > iPad Mouse must be on.

### About USB
Bonjour runs over every interface, so if macOS exposes the iPad as a network interface
(System Settings > Network, an "iPad" entry), the app uses that link automatically and the HUD
says "via USB". If that interface never appears on your setup, the next milestone is a tunnel
through `usbmuxd`, the same mechanism Xcode uses. That is a change to `Link.swift` and
`Receiver.swift` only; the protocol and gesture code stay the same.

---

## Part 4: Shipping

### iPad app: TestFlight and the App Store
Requires the paid Developer Program.

1. **App Store Connect** (appstoreconnect.apple.com): My Apps > "+" > New App. Pick the bundle ID
   `com.hsuche.ipadmouse.ipad` (register it under Certificates, Identifiers & Profiles if it is not listed).
2. In Xcode set the destination to *Any iOS Device*, then **Product > Archive**.
   The Organizer window opens with the archive.
3. **Distribute App > TestFlight & App Store > Upload**. Xcode signs with a distribution
   certificate it creates for you (automatic signing handles this).
4. In App Store Connect > TestFlight the build appears after processing (10 to 30 minutes).
   - *Internal testers* (up to 100 people on your team): no review, available immediately.
   - *External testers* (up to 10,000, by link or email): the first build goes through a short Beta App Review.
   Testers install the TestFlight app and get builds for 90 days.
5. For the App Store: fill in the listing (screenshots, description, privacy policy URL,
   App Privacy answers), attach the build, and *Submit for Review*. Review usually takes a day or two.
   Our local network prompt and Bonjour service are already declared, which reviewers check.

Each new upload needs a higher build number: bump `CURRENT_PROJECT_VERSION` in `project.yml`
(and `MARKETING_VERSION` for user-visible versions), re-generate, archive again.

### Mac app: Developer ID, not the Mac App Store
The Mac app injects input with CGEvent, which is not allowed inside the App Sandbox, and the
Mac App Store requires the sandbox. So it ships the way utilities like BetterTouchTool do:

1. Product > Archive with destination *Any Mac*.
2. Distribute App > **Direct Distribution**. Xcode signs with your Developer ID certificate,
   uploads to Apple's notarization service, and staples the ticket. This takes a few minutes.
3. Export the `.app`, zip it or put it in a DMG, and host it anywhere. Gatekeeper accepts it
   on any Mac because it is notarized.

Hardened Runtime is already enabled in `project.yml`, which notarization requires.

### Ad hoc builds (a handful of specific iPads, no TestFlight)
Register each device's UDID in the developer portal, then Distribute App > Ad Hoc.
Useful for a friend's iPad; TestFlight is easier for anything more.

### visionOS
Same pipeline exactly: a visionOS target in the same project, same signing, same Archive,
same TestFlight and App Store Connect. Developer Mode on Vision Pro is enabled the same way.

---

## Tuning

Constants at the top of `TouchpadViewController.swift`:

| Constant | Effect |
|---|---|
| `trackpadSensitivity` | Finger-drag speed multiplier |
| `scrollScale` | Scroll distance per finger travel |
| `hardPressRatio` | How hard a Pencil stab must be to count as "back" (fraction of max force) |
| `hardPressWindow` | How quickly the stab must happen after touch-down |
| `pencilGrace` | How long after Pencil use a finger tap still right-clicks |

On the Mac, the menu has *Natural Scrolling*. If two-finger scrolling feels inverted, flip it.

## Known gaps
- Pencil hover needs an M2 iPad Pro or newer. On older iPads the finger trackpad still works and
  the Pencil moves the pointer only while touching.
- Pinch sends Cmd +/- rather than a true trackpad magnify gesture (macOS has no public API for that).
- No app icon yet. Xcode warns but runs fine; add an `Assets.xcassets` with an AppIcon set when you ship.
- The `Prefer USB` toggle relies on the USB link being reported as wired Ethernet by iPadOS.
