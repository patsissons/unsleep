<p align="center">
  <img src="icon.png" width="120" alt="UnSleep app icon">
</p>

# UnSleep

A tiny macOS menu bar app and CLI that keeps your Mac awake—even with the
lid closed.

**Website:** [unsleep.lgtm.page](https://unsleep.lgtm.page)

> [!WARNING]
> UnSleep bypasses macOS’s intended lid-close sleep behavior. This is mostly
> okay, but for legal reasons :tm:, keeping your Mac awake with the lid closed can
> trap heat that would otherwise escape through the keyboard and hinge,
> increasing the risk of overheating and battery drain. Please use this feature
> sparingly and with caution. Prefer timed and non-intensive tasks. Where
> possible, keep the lid open or use Apple’s supported clamshell setup while
> connected to power.

## Install

UnSleep needs macOS 12 or later.

### Homebrew (Apple silicon)

```bash
brew install --cask patsissons/tap/unsleep
```

This installs `/Applications/UnSleep.app` from the latest
[release](https://github.com/patsissons/unsleep/releases) and puts `unsleep`
on your `PATH`. Update with `brew upgrade --cask unsleep`.

The app isn't notarized by Apple yet, so the first time you open it macOS says
it can't verify it. Open **System Settings → Privacy & Security**, scroll to
**Security**, and click **Open Anyway** next to the UnSleep message. If you'd
rather do it from the terminal, this clears the download quarantine instead:

```bash
xattr -dr com.apple.quarantine /Applications/UnSleep.app
```

### Install script (any Mac)

```bash
curl -fsSL https://raw.githubusercontent.com/patsissons/unsleep/main/install.sh | bash
```

This builds UnSleep from source, on Apple silicon or Intel, and installs
`~/Applications/UnSleep.app` with `~/.local/bin/unsleep` linked to the CLI
inside it, then launches the app. Nothing is cloned: the source
downloads to a temporary directory that's deleted after the build. Run the
same command again to update.

The installer checks its dependencies first. The only one that might be
missing is the Xcode Command Line Tools, which provide the Swift compiler. If
they're missing, it offers to install them (a ~1–2 GB download that usually
takes 5–20 minutes) and continues when they finish.

To pin or roll back to a tag, branch, or commit:

```bash
curl -fsSL https://raw.githubusercontent.com/patsissons/unsleep/main/install.sh | UNSLEEP_INSTALL_REF=<ref> bash
```

From a clone, run `./install.sh` to build and install that working tree.

## Menu bar app

Use the menu bar icon to:

- toggle **Keep Awake**
- choose a duration from **Keep Awake For**
- **Schedule** a start and end time
- see version info and a link to this repo in **About UnSleep**

<p align="center">
  <img src="site/screenshots/menu-off.png" width="176" alt="UnSleep menu while off">
  &nbsp;
  <img src="site/screenshots/menu-on.png" width="268" alt="UnSleep menu while keeping the Mac awake, showing the end time and minutes left">
</p>

<p align="center">
  <img src="site/screenshots/keep-awake-for.png" width="271" alt="Keep Awake For submenu with durations from 15 minutes to 8 hours">
</p>

<p align="center">
  <img src="site/screenshots/schedule.png" width="352" alt="Schedule Keep Awake dialog with From and To time pickers">
  &nbsp;
  <img src="site/screenshots/about.png" width="260" alt="About UnSleep dialog with version and GitHub link">
</p>

Turning UnSleep off or quitting restores the sleep settings it changed. To
start it at login, add `UnSleep.app` in **System Settings → General → Login
Items**.

## CLI

The CLI shares state with the menu bar app. Commands that change state launch
the app when needed.

```bash
unsleep on                              # stay awake until turned off
unsleep on --for 2h                     # stay awake for a duration
unsleep on --until 17:30                # stay awake until a time
unsleep on --from 13:00 --until 15:00   # schedule a window
unsleep off                             # restore sleep and cancel schedules
unsleep status                          # print the current state
unsleep status --json                   # machine-readable state
```

### Coding agents

The CLI is useful for agents that run unattended. For example, an agent
harness hook can run `unsleep on` when a session starts and `unsleep off` when
it shuts down, keeping your Mac awake for the session. Use `--for` if you
also want a safety cutoff.

## Password-free mode

UnSleep uses `pmset`, so macOS asks for an admin password on each toggle by
default. On first launch, enable password-free mode when prompted, or choose
**Set Up Password-Free Mode…** from the menu.

> [!NOTE]
> Password-free mode is intentionally narrow. It only allows these three sleep
> commands to run without a password:
>
> - `sudo /usr/bin/pmset -b sleep 0` — set battery idle sleep to never
> - `sudo /usr/bin/pmset -b disablesleep 1` — block sleep while on battery,
>   including lid-close sleep
> - `sudo /usr/bin/pmset -b disablesleep 0` — remove that sleep block
>
> These commands only change sleep settings. They do not grant broader admin
> access or access to your files, so password-free mode is low risk.

You can also enable it from the terminal, no clone needed:

```bash
curl -fsSL https://raw.githubusercontent.com/patsissons/unsleep/main/install-sudoers.sh | sudo bash
```

This runs [`install-sudoers.sh`](install-sudoers.sh) as root, so you may want
to read it first. From a clone, run `sudo ./install-sudoers.sh` instead.

This adds a validated sudoers rule for UnSleep's three exact `pmset` commands.
Remove it anytime:

```bash
sudo rm -f /etc/sudoers.d/unsleep
```

## Uninstall

Turn UnSleep off first so your sleep settings are restored. With Homebrew:

```bash
unsleep off
brew uninstall --cask unsleep        # quits the app first
sudo rm -f /etc/sudoers.d/unsleep
```

`brew uninstall --zap --cask unsleep` also removes the app's preferences and
the password-free sudoers rule.

With the install script:

```bash
unsleep off
osascript -e 'quit app "UnSleep"'
rm -rf ~/Applications/UnSleep.app ~/.local/bin/unsleep
sudo rm -f /etc/sudoers.d/unsleep
```

## Website

[unsleep.lgtm.page](https://unsleep.lgtm.page) is served from [`site/`](site).
`site/og.png` is its Open Graph image, rendered from the site's logo and the
menu screenshots by `scripts/og-image.sh` (headless Chrome); re-run it after
changing either.

## Releasing

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.
2. Merge to `main`, then tag `v<version>` and publish a GitHub release for it.
   The [release workflow](.github/workflows/release.yml) builds the Apple
   silicon app, ad-hoc signs it, and attaches `UnSleep-<version>.zip` (and its
   `.sha256`) to the release.
3. Update `version` and `sha256` in
   [`Casks/unsleep.rb`](https://github.com/patsissons/homebrew-tap/blob/main/Casks/unsleep.rb)
   in the tap.

## License

[MIT](LICENSE)
