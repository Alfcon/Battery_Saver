#!/usr/bin/env bash
# battery-saver — switch a Linux Mint (Cinnamon, X11) laptop between battery
# and AC tuning automatically.
#
#   * CPU turbo / energy policy, Wi-Fi power save, Bluetooth   -> TLP drop-in
#   * Built-in screen refresh rate (e.g. 165 Hz <-> 60 Hz)      -> this daemon
#   * Optional: screen brightness cap, keyboard backlight off   -> this daemon
#   * `status` reports everything, including the NVIDIA GPU power
#     state, without waking the GPU (no lspci / nvidia-smi).
#
# Usage: battery-saver.sh {install|uninstall|status|apply|restart|daemon|help}

set -uo pipefail

readonly PROG=battery-saver
readonly VERSION=1.0

# ---------------------------------------------------------------- paths ----
# The BS_* overrides exist so the script can be tested against fake files.
CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
CONFIG_FILE=${BS_CONFIG:-$CONFIG_HOME/$PROG.conf}
AUTOSTART_FILE=${BS_AUTOSTART:-$CONFIG_HOME/autostart/$PROG.desktop}
INSTALL_BIN=${BS_INSTALL_BIN:-$HOME/.local/bin/$PROG}
TLP_DROPIN=${BS_TLP_DROPIN:-/etc/tlp.d/01-battery.conf}
TLP_MAIN_CONF=${BS_TLP_MAIN_CONF:-/etc/tlp.conf}
SYSFS=${BS_SYSFS_ROOT:-/sys}
STATE_DIR=${XDG_RUNTIME_DIR:-/tmp/$PROG-$(id -u)}/$PROG
PIDFILE=$STATE_DIR/daemon.pid

# ------------------------------------------------------------- settings ----
BAT_RATE=60
AC_RATE=max
OUTPUT=auto
BAT_BRIGHTNESS=
KBD_BACKLIGHT_OFF=0
NOTIFY=0
POLL_SECONDS=60

# ------------------------------------------------------------- helpers -----
have() { command -v "$1" >/dev/null 2>&1; }

log() {
    printf '%s %s: %s\n' "$(date '+%F %T')" "$PROG" "$*" >&2
    if [[ ${BS_DAEMON:-0} == 1 ]] && have logger; then
        logger -t "$PROG" -- "$*" 2>/dev/null || true
    fi
}
warn() { log "warning: $*"; }
die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

is_number() { [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]]; }
trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }

ensure_state_dir() {
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR" 2>/dev/null || true
}

# ------------------------------------------------------------- config ------
write_default_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat >"$CONFIG_FILE" <<'EOF'
# battery-saver settings. After editing, run: battery-saver restart

# Refresh rate for the built-in screen on battery (Hz).
# Leave empty to stop battery-saver changing the refresh rate.
BAT_RATE=60

# Refresh rate on AC: "max" (highest the panel offers at the current
# resolution) or a number such as 165.
AC_RATE=max

# Built-in display output name, or "auto" to detect eDP/LVDS/DSI.
OUTPUT=auto

# Screen brightness cap on battery, in percent (e.g. 40). Leave empty to
# not touch brightness. Only ever lowers it, and restores it on AC unless
# you changed it yourself in the meantime. Needs brightnessctl.
BAT_BRIGHTNESS=

# 1 = keyboard backlight off on battery, restored on AC. Needs brightnessctl.
KBD_BACKLIGHT_OFF=0

# 1 = desktop notification when switching modes.
NOTIFY=0

# Safety-net check interval in seconds, in case a plug/unplug event is missed.
POLL_SECONDS=60
EOF
}

# Parse KEY=value lines instead of `source`-ing the file, so a typo can't
# run as code. Unknown keys and bad values fall back to defaults.
load_config() {
    [[ -r $CONFIG_FILE ]] || return 0
    local line key val n=0
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        line=${line%%#*}
        [[ -z $(trim "$line") ]] && continue
        if [[ ! $line =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=(.*)$ ]]; then
            warn "$CONFIG_FILE:$n: ignoring unreadable line"
            continue
        fi
        key=${BASH_REMATCH[1]}
        val=$(trim "${BASH_REMATCH[2]}")
        val=${val#\"}; val=${val%\"}; val=${val#\'}; val=${val%\'}
        case $key in
            BAT_RATE|AC_RATE|OUTPUT|BAT_BRIGHTNESS|KBD_BACKLIGHT_OFF|NOTIFY|POLL_SECONDS)
                printf -v "$key" '%s' "$val" ;;
            *) warn "$CONFIG_FILE:$n: unknown setting $key" ;;
        esac
    done <"$CONFIG_FILE"
    validate_config
}

validate_config() {
    if [[ -n $BAT_RATE ]] && ! is_number "$BAT_RATE"; then
        warn "BAT_RATE='$BAT_RATE' is not a number; using 60"; BAT_RATE=60
    fi
    if [[ $AC_RATE != max ]] && ! is_number "$AC_RATE"; then
        warn "AC_RATE='$AC_RATE' is not 'max' or a number; using max"; AC_RATE=max
    fi
    [[ -n $OUTPUT ]] || OUTPUT=auto
    if [[ -n $BAT_BRIGHTNESS ]] && { [[ ! $BAT_BRIGHTNESS =~ ^[0-9]+$ ]] \
            || (( 10#$BAT_BRIGHTNESS < 1 || 10#$BAT_BRIGHTNESS > 100 )); }; then
        warn "BAT_BRIGHTNESS='$BAT_BRIGHTNESS' must be 1-100; brightness left alone"
        BAT_BRIGHTNESS=
    fi
    [[ $KBD_BACKLIGHT_OFF == [01] ]] || { warn "KBD_BACKLIGHT_OFF must be 0 or 1"; KBD_BACKLIGHT_OFF=0; }
    [[ $NOTIFY == [01] ]] || { warn "NOTIFY must be 0 or 1"; NOTIFY=0; }
    if [[ ! $POLL_SECONDS =~ ^[0-9]+$ ]] || (( 10#$POLL_SECONDS < 5 )); then
        warn "POLL_SECONDS must be a whole number >= 5; using 60"; POLL_SECONDS=60
    fi
    POLL_SECONDS=$((10#$POLL_SECONDS))
}

# -------------------------------------------------------- power source -----
# Same rule TLP uses: AC if any mains/USB supply is online. If the machine
# has no such supply at all, fall back to the battery's own status.
power_state() {
    local ps type found=0
    for ps in "$SYSFS"/class/power_supply/*; do
        [[ -r $ps/type ]] || continue
        type=$(<"$ps/type")
        case $type in
            Mains|USB|USB_C|USB_PD|USB_PD_DRP)
                found=1
                if [[ -r $ps/online && $(<"$ps/online") == 1 ]]; then
                    echo ac; return
                fi ;;
        esac
    done
    if (( found )); then echo bat; return; fi
    for ps in "$SYSFS"/class/power_supply/*; do
        [[ -r $ps/type && $(<"$ps/type") == Battery ]] || continue
        [[ -r $ps/scope && $(<"$ps/scope") == Device ]] && continue  # mouse etc.
        if [[ -r $ps/status && $(<"$ps/status") == Discharging ]]; then
            echo bat; return
        fi
    done
    echo ac
}

# ------------------------------------------------------------- display -----
display_alive() { [[ -n ${DISPLAY:-} ]] && xrandr --current >/dev/null 2>&1; }

internal_output() {
    if [[ $OUTPUT != auto ]]; then printf '%s\n' "$OUTPUT"; return; fi
    xrandr --current 2>/dev/null |
        awk '$2 == "connected" && $1 ~ /^(eDP|LVDS|DSI)/ { print $1; exit }'
}

# Prints "<resolution> <current-rate> <rate> <rate> ..." for the active mode
# of output $1, or nothing if the output is off. xrandr marks the current
# rate with '*' glued to the number; '+' (preferred) may be glued or apart.
mode_info() {
    xrandr --current 2>/dev/null | awk -v out="$1" '
        $1 == out && ($2 == "connected" || $2 == "disconnected") { inside = 1; next }
        inside && /^[^ \t]/ { exit }
        inside && $1 ~ /^[0-9]+x[0-9]+/ && index($0, "*") {
            cur = ""; rates = ""
            for (i = 2; i <= NF; i++) {
                t = $i
                if (t !~ /^[0-9]+[.][0-9]+/) continue
                r = t; sub(/[^0-9.].*$/, "", r)
                rates = rates " " r
                if (index(t, "*")) cur = r
            }
            print $1, cur rates
            exit
        }'
}

# pick_rate TARGET RATE... -> the listed rate closest to TARGET, or the
# highest one when TARGET is "max". Prints the rate exactly as xrandr lists it.
pick_rate() {
    local target=$1; shift
    printf '%s\n' "$@" | awk -v t="$target" '
        { r = $1 + 0
          if (t == "max") { if (best == "" || r > bestv) { best = $1; bestv = r } }
          else { d = r - t; if (d < 0) d = -d
                 if (best == "" || d < bestd) { best = $1; bestd = d } } }
        END { if (best != "") print best }'
}

apply_display() {
    local mode=$1 out info res cur target want
    [[ -n $BAT_RATE ]] || return 0
    if ! display_alive; then warn "no X display; refresh rate not changed"; return 0; fi
    out=$(internal_output)
    if [[ -z $out ]]; then warn "built-in display not found (set OUTPUT=)"; return 0; fi
    info=$(mode_info "$out")
    if [[ -z $info ]]; then log "$out is off; refresh rate not changed"; return 0; fi
    # shellcheck disable=SC2086  # deliberate word splitting of the rate list
    set -- $info
    res=$1 cur=$2; shift 2
    if [[ $mode == bat ]]; then target=$BAT_RATE; else target=$AC_RATE; fi
    want=$(pick_rate "$target" "$@")
    [[ -n $want ]] || return 0
    if awk -v a="$cur" -v b="$want" 'BEGIN { exit !(a + 0 == b + 0) }'; then
        return 0
    fi
    if xrandr --output "$out" --mode "$res" --rate "$want" 2>/dev/null; then
        log "$out: ${cur} Hz -> ${want} Hz"
    else
        warn "xrandr could not set $out to $res @ $want Hz"
    fi
}

# ---------------------------------------------------------- backlights -----
# brightnessctl -m prints: device,class,current,percent%,max
bctl_field() { brightnessctl "${@:2}" -m 2>/dev/null | head -n1 | cut -d, -f"$1"; }

apply_brightness() {
    local mode=$1 state=$STATE_DIR/brightness pct raw saved setraw now
    [[ -n $BAT_BRIGHTNESS ]] || { rm -f "$state"; return 0; }
    have brightnessctl || { warn "BAT_BRIGHTNESS needs brightnessctl (sudo apt install brightnessctl)"; return 0; }
    if [[ $mode == bat ]]; then
        # Already capped this battery session (e.g. re-apply after resume):
        # leave any brightness the user picked since then alone.
        [[ -e $state ]] && return 0
        pct=$(bctl_field 4 -c backlight); pct=${pct%\%}
        raw=$(bctl_field 3 -c backlight)
        [[ $pct =~ ^[0-9]+$ && $raw =~ ^[0-9]+$ ]] || { warn "could not read screen brightness"; return 0; }
        (( pct > BAT_BRIGHTNESS )) || return 0
        if brightnessctl -q -c backlight set "${BAT_BRIGHTNESS}%" >/dev/null 2>&1; then
            setraw=$(bctl_field 3 -c backlight)
            printf '%s %s\n' "$raw" "$setraw" >"$state"
            log "brightness ${pct}% -> ${BAT_BRIGHTNESS}%"
        else
            warn "brightnessctl could not set brightness (add yourself to the 'video' group?)"
        fi
    else
        [[ -r $state ]] || return 0
        read -r saved setraw <"$state" || true
        rm -f "$state"
        now=$(bctl_field 3 -c backlight)
        # Only restore if the user hasn't adjusted brightness while on battery.
        if [[ $saved =~ ^[0-9]+$ && $now == "$setraw" ]]; then
            if brightnessctl -q -c backlight set "$saved" >/dev/null 2>&1; then
                log "brightness restored"
            else
                warn "could not restore brightness"
            fi
        fi
    fi
}

apply_kbd_backlight() {
    local mode=$1 state=$STATE_DIR/kbd saved now dev='*kbd_backlight*'
    [[ $KBD_BACKLIGHT_OFF == 1 ]] || { rm -f "$state"; return 0; }
    have brightnessctl || { warn "KBD_BACKLIGHT_OFF needs brightnessctl"; return 0; }
    now=$(bctl_field 3 -d "$dev")
    if [[ ! $now =~ ^[0-9]+$ ]]; then
        [[ -e $STATE_DIR/kbd-missing ]] || warn "no keyboard backlight device found"
        : >"$STATE_DIR/kbd-missing"
        return 0
    fi
    if [[ $mode == bat ]]; then
        [[ -e $state ]] && return 0
        (( now > 0 )) || return 0
        if brightnessctl -q -d "$dev" set 0 >/dev/null 2>&1; then
            printf '%s\n' "$now" >"$state"; log "keyboard backlight off"
        else
            warn "could not turn off keyboard backlight"
        fi
    else
        [[ -r $state ]] || return 0
        read -r saved <"$state" || true
        rm -f "$state"
        if [[ $saved =~ ^[0-9]+$ && $now == 0 ]]; then
            brightnessctl -q -d "$dev" set "$saved" >/dev/null 2>&1 && log "keyboard backlight restored"
        fi
    fi
}

# --------------------------------------------------------------- apply -----
apply_mode() {
    local mode=$1
    ensure_state_dir
    log "power source: $([[ $mode == bat ]] && echo battery || echo AC)"
    apply_display "$mode"
    apply_brightness "$mode"
    apply_kbd_backlight "$mode"
    if [[ $NOTIFY == 1 ]] && have notify-send; then
        if [[ $mode == bat ]]; then
            notify-send -a "$PROG" -i battery "Battery saver on" "Running on battery" 2>/dev/null || true
        else
            notify-send -a "$PROG" -i battery-full-charging "Battery saver off" "Plugged in" 2>/dev/null || true
        fi
    fi
}

# -------------------------------------------------------------- daemon -----
pid_is_daemon() {
    local pid=$1
    local cmdline name=${0##*/}
    [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1
    cmdline=" $(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)" || return 1
    # Our process looks like "bash /path/<script> daemon", whatever the
    # script is called; anything else holding a recycled PID is left alone.
    [[ $cmdline == *[/\ ]battery-saver*" daemon "* || $cmdline == *[/\ ]"$name daemon "* ]]
}

running_pid() {
    local pid
    [[ -r $PIDFILE ]] || return 1
    read -r pid <"$PIDFILE" || return 1
    pid_is_daemon "$pid" && printf '%s\n' "$pid"
}

stop_daemon() {
    local pid
    pid=$(running_pid) || return 0
    kill "$pid" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    return 0
}

MON_PID=
MON_FD=
LAST_STATE=
LAST_TICK=0

daemon_cleanup() {
    [[ -n $MON_PID ]] && kill "$MON_PID" 2>/dev/null
    local pid
    if [[ -r $PIDFILE ]] && read -r pid <"$PIDFILE" && [[ $pid == "$$" ]]; then
        rm -f "$PIDFILE"
    fi
}

# Re-check the power source; apply settings when it changed, or when the
# clock jumped (the laptop was asleep, so the display config may have been
# reset on resume).
daemon_check() {
    local now st force=0
    now=$(date +%s)
    if (( LAST_TICK > 0 && now - LAST_TICK > 2 * POLL_SECONDS + 30 )); then force=1; fi
    LAST_TICK=$now
    st=$(power_state)
    if [[ $st != "$LAST_STATE" || $force == 1 ]]; then
        (( force )) && [[ $st == "$LAST_STATE" ]] && log "resume detected; re-applying"
        apply_mode "$st"
        LAST_STATE=$st
    fi
}

cmd_daemon() {
    export BS_DAEMON=1
    load_config
    [[ -n ${DISPLAY:-} ]] || die "DISPLAY is not set; the daemon must run inside your X session"
    ensure_state_dir

    # Newest instance wins: an old daemon from a previous login may still be
    # around with a dead DISPLAY.
    stop_daemon
    echo $$ >"$PIDFILE"
    trap daemon_cleanup EXIT
    trap 'exit 0' TERM INT HUP

    log "started (v$VERSION, battery ${BAT_RATE:-unchanged} Hz / AC $AC_RATE)"
    local line rc n
    while :; do
        display_alive || { log "X display gone; exiting"; exit 0; }
        daemon_check
        if have upower; then
            exec {MON_FD}< <(exec upower --monitor 2>/dev/null)
            MON_PID=$!
            while :; do
                if IFS= read -r -t "$POLL_SECONDS" -u "$MON_FD" line; then
                    # upower prints several lines per change; swallow the
                    # rest of the burst (gap < 0.2 s, at most ~2 s) so we act
                    # once, without stalling if events keep coming.
                    n=0
                    while (( n++ < 10 )) && IFS= read -r -t 0.2 -u "$MON_FD" line; do :; done
                else
                    rc=$?
                    (( rc > 128 )) || break   # EOF: upower exited, restart it
                fi
                display_alive || { log "X display gone; exiting"; exit 0; }
                daemon_check
            done
            exec {MON_FD}<&-
            kill "$MON_PID" 2>/dev/null; MON_PID=
            warn "upower --monitor stopped; restarting it in 5 s"
            sleep 5 & wait $!      # backgrounded so SIGTERM is handled at once
        else
            sleep "$POLL_SECONDS" & wait $!
        fi
    done
}

start_daemon_detached() {
    local bin=$1
    [[ -n ${DISPLAY:-} ]] || { warn "no DISPLAY; daemon will start at next login"; return 0; }
    setsid "$bin" daemon >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null || true
    sleep 1
    if running_pid >/dev/null; then echo "Daemon running."; else warn "daemon did not start; try: $bin daemon"; fi
}

# ----------------------------------------------------------------- TLP -----
tlp_dropin_content() {
    cat <<'EOF'
# Managed by battery-saver. Re-run `battery-saver install` to rewrite it,
# `battery-saver uninstall` to remove it.
#
# TLP settings must be given for AC and BAT in pairs: a value set for only
# one power source can carry over to the other (e.g. turbo staying off
# after plugging back in).

# CPU: no turbo and the most efficient energy policy on battery.
CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance
CPU_ENERGY_PERF_POLICY_ON_BAT=power
CPU_BOOST_ON_AC=1
CPU_BOOST_ON_BAT=0

# Wi-Fi power saving stays off on both: the iwlwifi driver is a suspect in
# this machine's random freezes. Change BAT to "on" once that's ruled out.
WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=off

# Bluetooth: off when switching to battery if nothing is connected,
# back on when the charger is plugged in.
DEVICES_TO_DISABLE_ON_BAT_NOT_IN_USE="bluetooth"
DEVICES_TO_ENABLE_ON_AC="bluetooth"
EOF
}

# /etc/tlp.conf is read after /etc/tlp.d/, so active lines there win.
check_tlp_conflicts() {
    [[ -r $TLP_MAIN_CONF ]] || return 0
    local hits
    hits=$(grep -nE '^[[:space:]]*(CPU_BOOST_ON_|CPU_ENERGY_PERF_POLICY_ON_|WIFI_PWR_ON_|DEVICES_TO_DISABLE_ON_BAT|DEVICES_TO_ENABLE_ON_AC)' "$TLP_MAIN_CONF" || true)
    if [[ -n $hits ]]; then
        warn "these active lines in $TLP_MAIN_CONF override the drop-in; comment them out:"
        printf '    %s\n' "$hits" >&2
    fi
}

install_tlp_dropin() {
    if ! have tlp; then
        warn "TLP is not installed (sudo apt install tlp tlp-rdw); CPU/Bluetooth/Wi-Fi tuning skipped"
        return 0
    fi
    local tmp
    tmp=$(mktemp) || return 1
    tlp_dropin_content >"$tmp"
    if [[ -f $TLP_DROPIN ]] && cmp -s "$tmp" "$TLP_DROPIN"; then
        echo "TLP drop-in $TLP_DROPIN is already up to date."
        rm -f "$tmp"; check_tlp_conflicts; return 0
    fi
    echo "Writing $TLP_DROPIN (needs sudo)..."
    if [[ -f $TLP_DROPIN ]]; then
        # .bak suffix: TLP only reads *.conf, so the backup is inert.
        sudo cp -p "$TLP_DROPIN" "$TLP_DROPIN.$(date +%Y%m%d-%H%M%S).bak" || { rm -f "$tmp"; return 1; }
    fi
    if sudo install -D -m 644 "$tmp" "$TLP_DROPIN"; then
        rm -f "$tmp"
        sudo tlp start >/dev/null && echo "TLP settings applied."
        check_tlp_conflicts
    else
        rm -f "$tmp"; warn "could not write $TLP_DROPIN"; return 1
    fi
}

remove_tlp_dropin() {
    [[ -f $TLP_DROPIN ]] || return 0
    if ! grep -q '^# Managed by battery-saver' "$TLP_DROPIN"; then
        warn "$TLP_DROPIN was not written by battery-saver; leaving it"
        return 0
    fi
    echo "Removing $TLP_DROPIN (needs sudo)..."
    sudo rm -f "$TLP_DROPIN" && { have tlp && sudo tlp start >/dev/null; echo "TLP back to its defaults."; }
}

# ------------------------------------------------------------- install -----
write_autostart() {
    mkdir -p "$(dirname "$AUTOSTART_FILE")"
    cat >"$AUTOSTART_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Battery saver
Comment=Lower the screen refresh rate and other settings on battery
Exec="$INSTALL_BIN" daemon
Icon=battery
Terminal=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=10
EOF
}

cmd_install() {
    local with_tlp=1 arg self
    for arg in "$@"; do
        case $arg in
            --no-tlp) with_tlp=0 ;;
            *) die "install: unknown option $arg" ;;
        esac
    done
    have xrandr || die "xrandr not found (sudo apt install x11-xserver-utils)"
    have upower || warn "upower not found; falling back to checking every ${POLL_SECONDS}s"

    self=$(readlink -f "$0")
    if [[ $self != "$(readlink -f "$INSTALL_BIN" 2>/dev/null)" ]]; then
        install -D -m 755 "$self" "$INSTALL_BIN" || die "could not copy to $INSTALL_BIN"
        echo "Installed $INSTALL_BIN"
    fi
    if [[ -f $CONFIG_FILE ]]; then
        echo "Keeping existing settings in $CONFIG_FILE"
    else
        write_default_config; echo "Settings: $CONFIG_FILE"
    fi
    write_autostart
    echo "Autostart entry: $AUTOSTART_FILE (shown in Startup Applications)"
    load_config
    (( with_tlp )) && install_tlp_dropin
    stop_daemon
    start_daemon_detached "$INSTALL_BIN"
}

cmd_uninstall() {
    local keep_tlp=0 arg
    for arg in "$@"; do
        case $arg in
            --keep-tlp) keep_tlp=1 ;;
            *) die "uninstall: unknown option $arg" ;;
        esac
    done
    load_config
    stop_daemon
    # Leave the screen at its AC refresh rate and restore saved backlights.
    if [[ -n ${DISPLAY:-} ]]; then apply_mode ac 2>/dev/null; fi
    rm -f "$AUTOSTART_FILE"
    (( keep_tlp )) || remove_tlp_dropin
    if [[ $(readlink -f "$0") != "$(readlink -f "$INSTALL_BIN" 2>/dev/null)" ]]; then
        rm -f "$INSTALL_BIN"
    else
        echo "Remove the program itself with: rm $INSTALL_BIN"
    fi
    echo "Uninstalled. Settings kept in $CONFIG_FILE (delete it if you like)."
}

# -------------------------------------------------------------- status -----
read_sys() { [[ -r $1 ]] && tr -d '\n' <"$1" || printf 'n/a'; }

cmd_status() {
    load_config
    local st out info d found=0 rf bt="n/a" pid batdev rate tte

    st=$(power_state)
    printf '%-16s %s' "Power source:" "$([[ $st == bat ]] && echo battery || echo AC)"
    if have upower; then
        batdev=$(upower -e 2>/dev/null | grep -m1 -i 'battery_BAT')
        if [[ -n $batdev ]]; then
            rate=$(upower -i "$batdev" 2>/dev/null | awk -F: '/energy-rate/ { gsub(/^[ \t]+/, "", $2); print $2 }')
            tte=$(upower -i "$batdev" 2>/dev/null | awk -F: '/time to empty/ { gsub(/^[ \t]+/, "", $2); print $2 }')
            [[ -n $rate ]] && printf '  (draw %s' "$rate"
            [[ -n $rate && -n $tte ]] && printf ', %s left' "$tte"
            [[ -n $rate ]] && printf ')'
        fi
    fi
    echo

    if display_alive && out=$(internal_output) && [[ -n $out ]]; then
        info=$(mode_info "$out")
        if [[ -n $info ]]; then
            # shellcheck disable=SC2086
            set -- $info
            printf '%-16s %s %s @ %s Hz (available: %s)\n' "Display:" "$out" "$1" "$2" "${*:3}"
        else
            printf '%-16s %s is off\n' "Display:" "$out"
        fi
    else
        printf '%-16s %s\n' "Display:" "no X display / built-in panel not found"
    fi

    local nt; nt=$(read_sys "$SYSFS/devices/system/cpu/intel_pstate/no_turbo")
    case $nt in 1) nt="off (no_turbo=1)" ;; 0) nt="on (no_turbo=0)" ;; esac
    printf '%-16s %s\n' "CPU turbo:" "$nt"
    printf '%-16s %s\n' "CPU energy pref:" "$(read_sys "$SYSFS/devices/system/cpu/cpu0/cpufreq/energy_performance_preference")"

    # Reading vendor/class/runtime_status from sysfs doesn't touch the GPU.
    for d in "$SYSFS"/bus/pci/devices/*; do
        [[ -r $d/vendor && -r $d/class ]] || continue
        [[ $(<"$d/vendor") == 0x10de ]] || continue
        [[ $(<"$d/class") == 0x03* ]] || continue
        found=1
        printf '%-16s %s (%s)\n' "NVIDIA GPU:" "$(read_sys "$d/power/runtime_status")" "${d##*/}"
    done
    (( found )) || printf '%-16s %s\n' "NVIDIA GPU:" "not present or powered off"
    have prime-select && printf '%-16s %s\n' "PRIME mode:" "$(prime-select query 2>/dev/null)"

    for rf in "$SYSFS"/class/rfkill/rfkill*; do
        [[ -r $rf/type && $(<"$rf/type") == bluetooth ]] || continue
        if [[ $(read_sys "$rf/soft") == 1 || $(read_sys "$rf/hard") == 1 ]]; then bt=off; else bt=on; fi
        break
    done
    printf '%-16s %s\n' "Bluetooth:" "$bt"

    if have tlp; then
        local tlp_state="installed"
        systemctl is-enabled tlp >/dev/null 2>&1 && tlp_state="enabled"
        [[ -f $TLP_DROPIN ]] && tlp_state+=", drop-in $TLP_DROPIN present" || tlp_state+=", drop-in missing"
        printf '%-16s %s\n' "TLP:" "$tlp_state"
    else
        printf '%-16s %s\n' "TLP:" "not installed"
    fi

    if have brightnessctl; then
        printf '%-16s %s\n' "Brightness:" "$(bctl_field 4 -c backlight)"
    fi
    if pid=$(running_pid); then
        printf '%-16s %s\n' "Daemon:" "running (pid $pid)"
    else
        printf '%-16s %s\n' "Daemon:" "not running"
    fi
}

# ---------------------------------------------------------------- main -----
usage() {
    cat <<EOF
$PROG $VERSION — automatic battery/AC tuning for Linux Mint laptops

Usage: ${0##*/} COMMAND

  install [--no-tlp]      Copy to ~/.local/bin, write settings, start at login,
                          install the TLP drop-in (sudo), start the daemon now
  uninstall [--keep-tlp]  Undo install and put the screen back to its AC rate
  status                  Show power source, draw, refresh rate, CPU, GPU, Bluetooth
  apply [bat|ac|auto]     Apply battery or AC settings once (default: auto)
  restart                 Restart the daemon (after editing settings)
  daemon                  Run in the foreground (what autostart runs)
  help                    This text

Settings: $CONFIG_FILE
EOF
}

main() {
    local cmd=${1:-help}
    (( $# )) && shift
    if (( EUID == 0 )) && [[ $cmd == @(install|uninstall|apply|restart|daemon) ]]; then
        die "run this as your normal user, not with sudo (it asks for sudo itself when needed)"
    fi
    case $cmd in
        install)   cmd_install "$@" ;;
        uninstall) cmd_uninstall "$@" ;;
        status)    cmd_status ;;
        apply)
            load_config
            case ${1:-auto} in
                bat|battery) apply_mode bat ;;
                ac)          apply_mode ac ;;
                auto)        apply_mode "$(power_state)" ;;
                *) die "apply: expected bat, ac or auto" ;;
            esac ;;
        restart)
            load_config
            stop_daemon
            start_daemon_detached "$(if [[ -x $INSTALL_BIN ]]; then echo "$INSTALL_BIN"; else readlink -f "$0"; fi)" ;;
        daemon)    cmd_daemon ;;
        help|-h|--help) usage ;;
        version|--version) echo "$PROG $VERSION" ;;
        *) usage >&2; exit 2 ;;
    esac
}

main "$@"
