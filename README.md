# battery-saver

![Bash](https://img.shields.io/badge/bash-4.4%2B-4EAA25?logo=gnubash&logoColor=white)
![Linux Mint](https://img.shields.io/badge/Linux%20Mint-21%20%7C%2022%20%7C%20LMDE-87CF3E?logo=linuxmint&logoColor=white)
![X11](https://img.shields.io/badge/session-X11-blue)

Automatic battery/AC tuning for Linux Mint laptops. Unplug the charger and
battery-saver lowers the screen refresh rate, turns off CPU turbo and Bluetooth,
and optionally dims the screen and keyboard. Plug back in and everything is
restored.

It's a single Bash script with no dependencies beyond what Mint already ships,
plus [TLP](https://linrunner.de/tlp/) for the CPU settings.

---

## What it does

| | On battery | On AC |
|---|---|---|
| Built-in screen refresh rate | 60 Hz | Highest available (e.g. 165 Hz) |
| CPU turbo | Off | On |
| CPU energy policy | `power` | `balance_performance` |
| Bluetooth | Off, if nothing is connected | On |
| Screen brightness *(optional)* | Capped, e.g. at 40% | Restored |
| Keyboard backlight *(optional)* | Off | Restored |

- **Switches instantly.** It listens for plug/unplug events from UPower, with a
  periodic check as a backup.
- **Survives sleep.** After the laptop wakes, it re-applies its settings, because
  the desktop can reset the display on resume.
- **Respects your changes.** If you adjust brightness yourself on battery, it
  won't override it.
- **Leaves external monitors alone.** Only the built-in screen is changed.
- **Doesn't wake the GPU.** `battery-saver status` shows the NVIDIA GPU's power
  state by reading sysfs, not by running `lspci` or `nvidia-smi`, which wake it.

### Example result

Developed on a Metabox Prime-16 (Clevo, Intel i9-14900HX, RTX 4060,
2560×1600 165 Hz panel) running Linux Mint 22.3 Cinnamon. With the settings
battery-saver applies, idle power draw went from **17 W to 12.7 W**, and the
estimated battery life went from **3.5 to 4.7 hours**.

---

## Compatibility

**Works on:**

- Any Linux Mint laptop: 21.x, 22.x and LMDE, with Cinnamon, MATE or Xfce
- Intel, AMD and NVIDIA graphics, including hybrid (PRIME) setups
- Any built-in screen named `eDP`, `LVDS` or `DSI` (auto-detected)
- Screens of any refresh rate. It picks the closest available rate, and on a
  60 Hz-only screen the refresh-rate part simply does nothing

It should also work on Ubuntu and other Debian-based distributions with an X11
session. Only Mint has been tested.

**Doesn't apply to:**

- **Wayland sessions.** `xrandr` can't change the refresh rate there. Mint's
  default sessions are X11.
- **Desktop PCs.** There's no battery or built-in screen. It does no harm, but
  does nothing useful.

**Known limitations:**

- On AMD CPUs, the turbo line in `battery-saver status` shows `n/a`. TLP still
  turns boost off correctly; only the status line is Intel-specific.
- Wi-Fi power saving is set to **off** by default. See [TLP settings](#tlp-settings)
  for why, and how to turn it on.

---

## Requirements

| Package | Why | Install |
|---|---|---|
| `xrandr` | Changes the refresh rate | Preinstalled on Mint (`x11-xserver-utils`) |
| `upower` | Detects plug/unplug instantly, reports power draw | Preinstalled on Mint |
| `tlp` | CPU turbo, energy policy, Bluetooth | `sudo apt install tlp tlp-rdw` |
| `brightnessctl` | Only for the optional brightness/keyboard settings | `sudo apt install brightnessctl` |

If `power-profiles-daemon` is installed, remove it, because it conflicts with
TLP:

```bash
sudo apt remove power-profiles-daemon
```

---

## Installation

```bash
git clone https://github.com/<your-username>/battery-saver.git
cd battery-saver
chmod +x battery-saver.sh
./battery-saver.sh install
```

Run the installer as your **normal user**, not with `sudo`. It asks for your
password itself, only when it writes the TLP file. If you run it with `sudo`, it
refuses and tells you why.

The installer:

1. Copies the program to `~/.local/bin/battery-saver`
2. Creates the settings file `~/.config/battery-saver.conf` (it keeps an
   existing one)
3. Adds a login entry, `~/.config/autostart/battery-saver.desktop`, which shows
   up in **Startup Applications**
4. Writes the TLP settings to `/etc/tlp.d/01-battery.conf`, backing up any
   existing file as `.bak`
5. Starts the background program straight away

To skip the TLP part, use `./battery-saver.sh install --no-tlp`.

> **Note:** `~/.local/bin` is added to your `PATH` when you log in. If
> `battery-saver` reports "command not found" right after installing, log out
> and back in, or use the full path `~/.local/bin/battery-saver` for now.

### Check it's working

Unplug the charger, wait a few seconds, then run:

```bash
battery-saver status
```

Example output:

```
Power source:    battery  (draw 12.7358 W, 4.7 hours left)
Display:         eDP-1 2560x1600 @ 60.00 Hz (available: 165.00 60.00 60.00)
CPU turbo:       off (no_turbo=1)
CPU energy pref: power
NVIDIA GPU:      suspended (0000:01:00.0)
PRIME mode:      on-demand
Bluetooth:       off
TLP:             enabled, drop-in /etc/tlp.d/01-battery.conf present
Daemon:          running (pid 4321)
```

To check just the power draw and remaining battery time:

```bash
upower -i $(upower -e | grep BAT) | grep -E "energy-rate|time to empty"
```

```
    energy-rate:         12.7358 W
    time to empty:       4.7 hours
```

Run it before and after installing to see the difference. See
[Measuring battery drain](#measuring-battery-drain) for how to get a reliable
reading.

---

## Usage

| Command | What it does |
|---|---|
| `battery-saver install [--no-tlp]` | Install, start at login, write TLP settings, start now |
| `battery-saver status` | Show power source, draw, refresh rate, CPU, GPU, Bluetooth |
| `battery-saver apply [bat\|ac\|auto]` | Apply battery or AC settings once (default `auto`) |
| `battery-saver restart` | Restart the background program after editing settings |
| `battery-saver uninstall [--keep-tlp]` | Remove everything and return the screen to its AC rate |
| `battery-saver daemon` | Run in the foreground (this is what runs at login) |
| `battery-saver help` | Show usage |

---

## Measuring battery drain

To see how many watts the laptop is using right now, and how long the battery
will last at that rate:

```bash
upower -i $(upower -e | grep BAT) | grep -E "energy-rate|time to empty"
```

Example output:

```
    energy-rate:         12.7358 W
    time to empty:       4.7 hours
```

How to get a reliable reading:

1. **Unplug the charger.** On AC, `energy-rate` shows the charging rate, and
   `time to empty` doesn't appear.
2. **Leave the laptop idle for about a minute.** Don't touch the mouse and close
   busy browser tabs. The figure is a short average, so activity pushes it up.
3. **Compare readings at the same screen brightness.** The screen is one of the
   biggest power users.

To keep the reading on screen and update it every 5 seconds:

```bash
watch -n 5 'upower -i $(upower -e | grep BAT) | grep -E "energy-rate|time to empty"'
```

`battery-saver status` shows the same two numbers on its first line.

**What's a good number?** It depends on the hardware. Ultrabooks can idle at
3–6 W, while gaming laptops with high-end CPUs rarely go below 10–12 W. The
useful comparison is before and after on your own machine. If idle draw is
**much** higher than you'd expect and your laptop has an NVIDIA GPU, check
`battery-saver status`. A GPU that shows `active` while idle is the most common
cause of high drain on hybrid laptops.

---

## Configuration

Edit `~/.config/battery-saver.conf`, then run `battery-saver restart`.

| Setting | Default | Meaning |
|---|---|---|
| `BAT_RATE` | `60` | Refresh rate on battery, in Hz. Leave empty to never change the refresh rate |
| `AC_RATE` | `max` | Refresh rate on AC: `max`, or a number such as `144` |
| `OUTPUT` | `auto` | Built-in screen name. `auto` finds `eDP`, `LVDS` or `DSI` |
| `BAT_BRIGHTNESS` | *(empty)* | Brightness cap on battery in percent, e.g. `40`. Empty = don't touch |
| `KBD_BACKLIGHT_OFF` | `0` | `1` = keyboard backlight off on battery |
| `NOTIFY` | `0` | `1` = desktop notification when switching |
| `POLL_SECONDS` | `60` | Backup check interval, in case a plug/unplug event is missed |

The file is read as plain `KEY=value` lines, never run as code. Unknown settings
and invalid values are reported and replaced with the default.

Notes on the brightness settings:

- Brightness is only ever lowered, never raised.
- When you plug back in, brightness is restored, unless you changed it yourself
  while on battery. Then your setting is kept.
- If you get permission errors, add yourself to the `video` group
  (`sudo usermod -aG video $USER`) and log out and back in.

---

## TLP settings

The installer writes `/etc/tlp.d/01-battery.conf`:

```
CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance
CPU_ENERGY_PERF_POLICY_ON_BAT=power
CPU_BOOST_ON_AC=1
CPU_BOOST_ON_BAT=0
WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=off
DEVICES_TO_DISABLE_ON_BAT_NOT_IN_USE="bluetooth"
DEVICES_TO_ENABLE_ON_AC="bluetooth"
```

- **AC and battery values come in pairs on purpose.** TLP's documentation warns
  that a value set for only one power source can carry over to the other. For
  example, turbo could stay off after plugging back in.
- **Wi-Fi power saving is off.** It was turned off on the development machine
  while investigating system freezes, which some Intel Wi-Fi drivers can cause
  with power saving on. If your Wi-Fi is stable, set `WIFI_PWR_ON_BAT=on` for a
  little more battery life, then run `sudo tlp start`.
- **Bluetooth turns back on when you plug in,** even if you'd switched it off. To
  stop that, delete the `DEVICES_TO_ENABLE_ON_AC` line and run `sudo tlp start`.
- **Active lines in `/etc/tlp.conf` override this file.** The installer warns you
  if it finds any.

Re-running `battery-saver install` puts the file back to these defaults.

---

## Not automated

A few things that help battery life can't be (or shouldn't be) changed by a
script:

- **NVIDIA hybrid graphics.** Use PRIME `on-demand` mode (or `intel` for the
  most battery) in the NVIDIA settings or with `sudo prime-select on-demand`.
  The GPU then powers off by itself when idle. `battery-saver status` shows
  whether it's actually asleep.
- **Browsers.** Chromium-based browsers (Chrome, Brave, Edge) have an
  **Energy saver** setting that can turn on automatically when unplugged. Search
  for "Energy saver" in the browser's settings.

---

## Troubleshooting

**See what the background program is doing:**

```bash
journalctl -t battery-saver --since today
```

**The refresh rate didn't change.** Run `battery-saver apply bat` in a terminal
and read the message. If the built-in screen wasn't found, run `xrandr` to get
its name, then set it with `OUTPUT=` in the settings file.

**"run this as your normal user".** You used `sudo`. Run the command again
without it.

**Turbo is still on while on battery.** Check for conflicting lines in
`/etc/tlp.conf`, and make sure `power-profiles-daemon` isn't installed. Then run
`sudo tlp-stat -s`, which reports any conflicts.

---

## Uninstall

```bash
battery-saver uninstall
```

This stops the background program, puts the screen back to its AC refresh rate,
and removes the login entry, the program and the TLP file. TLP then goes back to
its own defaults. Use `--keep-tlp` to keep the TLP settings.

The uninstaller only removes a TLP file it wrote itself.

Your settings file is kept. To delete it:

```bash
rm ~/.config/battery-saver.conf
```

---

## How it works

- **Starting at login.** An XDG autostart entry launches `battery-saver daemon`
  10 seconds after login, once the desktop has applied its own display settings.
- **Detecting the power source.** It reads `/sys/class/power_supply/`, the same
  rule TLP uses: on AC if any mains or USB-C supply is online. It wakes on
  `upower --monitor` events and also checks every `POLL_SECONDS` in case one is
  missed.
- **Detecting sleep.** If the clock jumps forward between checks, it assumes the
  laptop was asleep and re-applies its settings.
- **One copy at a time.** Each new copy stops any older one (for example, one
  left over from a previous login). The program also exits by itself when your
  X session ends.
- **CPU and Bluetooth.** These are left to TLP, which already switches them on
  power events. battery-saver only writes TLP's settings file.

---

## Contributing

Issues and pull requests are welcome. Please run
[ShellCheck](https://www.shellcheck.net/) before submitting:

```bash
shellcheck battery-saver.sh
```

It should report no warnings.
