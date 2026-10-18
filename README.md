# phonelink

Use your Android phone as a secondary device for your Mac's mouse and keyboard.

Push the cursor off the edge of your screen and it moves onto the phone: a real
Android pointer appears, clicks and scrolling work, and your keyboard types into
the phone. Push back (or press **⌃⌥Space**) to return to the Mac. Like Universal
Control, but for Android.

- **No app on the phone.** It runs over adb (USB or wireless debugging).
- **No mirroring.** You look at the phone; the Mac just lends it its mouse and keyboard.
- **Shared clipboard.** Copy on one side, paste on the other (text).
- **Send files.** Drag files from Finder against the screen edge and they land in
  the phone's `Download` folder.
- **Starts at login** and reconnects automatically when the phone comes back.

## Install (Homebrew)

```sh
brew install whizgenius1/tap/phonelink
brew install --cask android-platform-tools   # adb, if you don't have it
brew services start phonelink                # start now and at every login
```

Then grant **Accessibility** permission (macOS requires it to capture the mouse
and keyboard): System Settings → Privacy & Security → Accessibility → **+** →
⌘⇧G → paste the path printed by `realpath $(brew --prefix)/bin/phonelink`.
Then restart it: `brew services restart phonelink`.

You also need an Android phone with **USB debugging** (or Wireless debugging)
enabled. Run `phonelink --self-test` to check the link: the phone pointer
moves in a small square, with no clicks.

phonelink reuses scrcpy's small on-device server (installed as a dependency)
purely to inject keyboard and mouse input as virtual USB HID devices. It doesn't
open a scrcpy window or install anything on the phone.

## Configuration

`brew services` can't pass options, so put them in `~/.config/phonelink/config`:

```sh
mkdir -p ~/.config/phonelink
cat > ~/.config/phonelink/config <<'CFG'
--serial 1A2B3C4D5E6F    # from `adb devices`; a USB serial also matches the same phone over Wi-Fi
--speed 2.5             # phone pointer speed multiplier (default 2.0)
CFG
brew services restart phonelink
```

| Option | Meaning |
|---|---|
| `--serial SERIAL` | Use this device (from `adb devices`). Default: first connected device. |
| `--speed N` | Phone pointer speed multiplier (default 2.0) |
| `--edge left` | The phone sits to the left of your screens (default right) |
| `--no-clipboard` | Don't share the clipboard |
| `--no-cmd-as-ctrl` | Send ⌘ as Android Meta instead of Ctrl |

The same flags work on the command line (`phonelink --speed 3`); they're applied
after the config file.

<details>
<summary>Install from source instead</summary>

```sh
brew install scrcpy && brew install --cask android-platform-tools
git clone https://github.com/whizgenius1/phonelink.git && cd phonelink
./install.sh --autostart --serial <SERIAL> --speed 2.5
```

This installs to `~/.local/bin/phonelink` with its own login item
(`com.libeforge.phonelink`); remove it with `./uninstall.sh`.
</details>

## Using it

| | |
|---|---|
| Go to the phone | Push the cursor past the screen edge |
| Back to the Mac | Push back past the phone's near edge, or **⌃⌥Space** |
| ⌘C / ⌘V / ⌘A | Work on the phone (left ⌘ is sent as Ctrl) |
| Esc / right-click | Back on the phone |
| Send files | Drag them in Finder against the screen edge, or `phonelink --send FILE...` |
| Clipboard | Synced automatically (text only; password-manager entries marked concealed are skipped) |

## Commands

```sh
pgrep -fl phonelink                                   # is it running? (one line = one session)
brew services stop phonelink                          # stop (and don't start at login)
brew services restart phonelink                       # restart, e.g. after editing the config
tail -f $(brew --prefix)/var/log/phonelink.log        # log
phonelink --self-test                                 # moves the phone pointer in a square (no clicks)
phonelink --send ~/Desktop/report.pdf                 # send files without dragging
```

## Notes

- **After every upgrade** (`brew upgrade phonelink`), remove phonelink from
  Accessibility (−) and add it again, then `brew services restart phonelink`.
  macOS ties the permission to the exact build, so toggling it isn't enough.
- **Only one copy runs at a time.** A second one exits ("already running").
- **Files go Mac → phone only.** Android doesn't expose drags to outside tools.
- Pushing back to the Mac uses an estimate of the phone pointer's position. If it
  feels early or late, use ⌃⌥Space.
- **Careful with devices that take payments or other irreversible actions.** Your
  mouse becomes a real finger. Use `--serial` to pin phonelink to the right device.

## Uninstall

```sh
brew services stop phonelink && brew uninstall phonelink
```

Then remove phonelink from Accessibility in System Settings.

## License

MIT. See [LICENSE](LICENSE). Uses scrcpy's server (Apache 2.0); see [NOTICE](NOTICE).
