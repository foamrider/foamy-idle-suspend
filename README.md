# Foamy Idle Suspend

Automatic sleep for Omarchy, with separate idle timeouts for battery and AC power.
By default, laptops suspend after 15 minutes idle on battery and do not
sleep automatically on AC. The default action is `suspend`. Before sleeping the
plugin locks the screen and waits until the lock is secure, and it waits while
music or video is playing.

## Install

```sh
omarchy plugin add https://github.com/foamrider/foamy-idle-suspend.git --enable
```

Requires Omarchy 4.0.6 or later and targets Omarchy 4.5. This is a background
service with no bar widget.
Disable any previous automatic sleep plugin so only one sleep service runs.

## Configuration

Edit the `foamy.idle-suspend` entry in the `plugins` array of
`~/.config/omarchy/shell.json`. Keep the file's other entries and `version: 1`.
Settings go directly on the entry, without a `config` object:

```json
{
  "id": "foamy.idle-suspend",
  "batteryTimeoutSec": 900,
  "acTimeoutSec": null,
  "laptopsOnly": true,
  "suspendAction": "suspend",
  "pauseForMedia": true,
  "lockBeforeSuspend": true
}
```

All settings are optional. The example shows their defaults, so an entry
containing only `"id": "foamy.idle-suspend"` has the same behavior.

| Setting | Default | Meaning |
| --- | --- | --- |
| `batteryTimeoutSec` | `900` | Idle seconds before sleeping while UPower reports battery power. |
| `acTimeoutSec` | `null` | Idle seconds before sleeping while UPower reports AC power. |
| `laptopsOnly` | `true` | Require `hostnamectl chassis` to report `laptop`. Set `false` to allow desktops and other chassis types. |
| `suspendAction` | `"suspend"` | The systemd sleep action to run when the active timeout expires. |
| `pauseForMedia` | `true` | Wait while any MPRIS player (music, video, podcast, browser tab) is playing. Paused players do not count. |
| `lockBeforeSuspend` | `true` | Lock the screen and wait until the lock reports it is secure before sleeping. If it cannot lock, it does not sleep. |

For either timeout:

- **Omitted:** use its default.
- **`null`:** disable automatic sleep for that power source.
- **Positive integer:** timeout in seconds, from `1` to `2147483`.
- **`0`, negative numbers, fractions, or strings:** configuration error.

Use JSON `null`, not the string `"null"`. The two timeouts are independent;
setting one to `null` does not disable the other. Only the monitor for the
current power source is enabled. Timeout seconds refer to user inactivity,
not time since the screensaver started or the screen locked.

### Examples

Sleep after 10 minutes on battery or 30 minutes on AC, using ordinary suspend:

```json
{
  "id": "foamy.idle-suspend",
  "batteryTimeoutSec": 600,
  "acTimeoutSec": 1800,
  "suspendAction": "suspend"
}
```

Allow a desktop to suspend after 30 minutes idle on AC:

```json
{
  "id": "foamy.idle-suspend",
  "batteryTimeoutSec": null,
  "acTimeoutSec": 1800,
  "laptopsOnly": false,
  "suspendAction": "suspend"
}
```

Set **both timeouts to `null`** to pause all automatic sleep while keeping the
plugin loaded. Remove its entry from `plugins` to disable the plugin itself.

### Sleep actions

| `suspendAction` | Behavior |
| --- | --- |
| `"suspend"` | Suspend to memory. |
| `"hibernate"` | Save the session to disk and power down. |
| `"hybrid-sleep"` | Save the session to disk, then suspend to memory. |
| `"suspend-then-hibernate"` | Suspend first, then hibernate according to systemd's sleep policy. |

The machine must already support the selected action. This plugin does not
configure swap, hibernation support, or systemd's hibernation delay. At startup
and when `suspendAction` changes it asks logind which actions are available. If
the selected one is not (for example `suspend-then-hibernate` without
`omarchy-hibernation-setup`), it uses `suspend` instead and shows a notification
once. Status reports `effectiveAction`, `actionFallback` and `actionSupport`.

When the configured idle timeout expires, the plugin:

1. waits while media is playing (`pauseForMedia`) or while an application holds
   a logind `idle` or `sleep` block inhibitor (`systemd-inhibit`);
2. locks the screen through the public lock interface (`omarchy-shell lock lock`,
   answered by the stock lock or a replacement such as Foamy Lock) and waits up
   to about ten seconds for `omarchy-shell lock status` to report `secure`
   (`lockBeforeSuspend`). This is in addition to Omarchy's own lock-before-sleep
   service, so the computer never sleeps unlocked if that service is not running;
3. calls `systemctl` with the selected sleep action.

If the lock or the sleep request fails, a notification says so once, and the
plugin tries again while the computer stays idle: after one minute, doubling up
to fifteen minutes. After a successful request it also checks again a minute
later, so a wake without input (an RTC alarm, a USB device, the lid) does not
leave the computer awake on battery. Any input stops the retries. Enabling the plugin enables this automatic policy;
it does not ask for confirmation at each timeout. System authorization rules
still apply to the sleep request.

### Applying settings

Edits to `shell.json` reload automatically. Missing options use defaults;
invalid options or unreadable configuration pause automatic sleep and report
an error. A malformed override never silently enables a different sleep policy.
Writes that do not change this plugin's settings (bar edits, other plugins) do
not restart the idle countdown.
For local source edits or a manually linked installation, run
`omarchy restart shell` after changing plugin code.

Omarchy's **Stay awake** toggle, Wayland idle inhibitors (video players and
browsers playing video), logind block inhibitors and MPRIS playback pause
automatic sleep. Apps that only call `org.freedesktop.ScreenSaver.Inhibit` are not
covered: Omarchy runs no service under that D-Bus name, so those calls reach
nobody. When the plugin would put this computer to sleep, it also shows a
notification when Stay awake changes.
Screensaver and lock timings remain under stock `idle.screensaver` and
`idle.lock`. Keep Omarchy's idle and lock services enabled; locking before sleep
remains the responsibility of Omarchy's existing sleep/lock setup.

## Status

```sh
omarchy-shell foamy.idle-suspend status
```

Status includes the effective policy and sleep action, configuration validity,
chassis, power source, Stay awake state, enabled monitors, whether media is
playing, the current attempt (`phase`, `deferredReason`, `lastLockResult`,
`failureStreak`, `retryScheduled`) and the latest error. On Omarchy 4.5 the
call is answered over the shell socket. `enabled`
means a sleep monitor is currently enabled, so it is `false` on AC with the
default settings, on a desktop with `laptopsOnly: true`, or while Stay awake
is enabled. The `debug` method returns the same data.

## Development

The plugin is independent of other Foamy plugins and works with the stock bar.
It reads the same `~/.config/omarchy/shell.json` path as the stock shell because
the restricted service API does not expose plugin entries. Runtime dependencies
are Omarchy, Quickshell with Wayland, UPower and MPRIS, systemd (`systemctl`,
`busctl`), `jq`, `omarchy-shell`, and `notify-send`; no additional runtime package
is required on standard Omarchy.

```sh
node --test tests/*.test.cjs
python3 -I -B tests/runtime.py
bash tests/kit-check.sh
qmllint Service.qml
omarchy plugin validate .
```

Set `FOAMY_TEST_COMMONS` to an Omarchy 4.5 `shell/Commons` directory to run the
runtime test against that version. Shared foamy components (translations, IPC)
live in `kit/`, copied from [foamy-kit](https://github.com/foamrider/foamy-kit).

The runtime test uses a temporary home with mocked power, idle events, and
system commands. It tests real Quickshell configuration watching and process
handling, including invalid settings and failed sleep requests. It requires
local IPC socket access and never suspends the machine. Actual compositor idle
delivery and physical suspend/resume need separate validation on a target machine.

## Remove

```sh
omarchy plugin remove foamy.idle-suspend
```

Removal stops this plugin's automatic sleep policy. Omarchy's stock lock and
screensaver services remain responsible for their own timers. This does not
undo an already requested sleep action or change systemd's sleep configuration.

Omarchy manages the plugin entry in `shell.json`. Packages and data outside
the plugin directory are retained unless you remove them separately.

## License

Licensed under [MIT](LICENSE).

Provided **as is**, without warranty or guaranteed support. Use at your own risk.

Notifications follow **Omarchy → Setup → Language** on Omarchy 4.5 (English and
Norwegian catalogs; missing translations fall back to English). Omarchy 4.0 shows
them in English. The plugin does not set or override the Omarchy language.
