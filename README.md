# Foamy Idle Suspend

Automatic sleep for Omarchy, with separate idle timeouts for battery and AC power.
By default, laptops suspend after 15 minutes idle on battery and do not
sleep automatically on AC. The default action is `suspend-then-hibernate`.

## Install

```sh
omarchy plugin add https://github.com/foamrider/foamy-idle-suspend.git --enable
```

Requires Omarchy Quattro. This is a background service with no bar widget.
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
  "suspendAction": "suspend-then-hibernate"
}
```

All four settings are optional. The example shows their defaults, so an entry
containing only `"id": "foamy.idle-suspend"` has the same behavior.

| Setting | Default | Meaning |
| --- | --- | --- |
| `batteryTimeoutSec` | `900` | Idle seconds before sleeping while UPower reports battery power. |
| `acTimeoutSec` | `null` | Idle seconds before sleeping while UPower reports AC power. |
| `laptopsOnly` | `true` | Require `hostnamectl chassis` to report `laptop`. Set `false` to allow desktops and other chassis types. |
| `suspendAction` | `"suspend-then-hibernate"` | The systemd sleep action to run when the active timeout expires. |

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
configure swap, hibernation support, or systemd's hibernation delay. Failed
sleep requests are reported in its status and shell logs.

### Applying settings

Edits to `shell.json` reload automatically. Missing options use defaults;
invalid options or unreadable configuration pause automatic sleep and report
an error. A malformed override never silently enables a different sleep policy.
For local source edits or a manually linked installation, run
`omarchy restart shell` after changing plugin code.

Omarchy's **Stay awake** toggle and Wayland idle inhibitors pause automatic
sleep. The plugin also shows a notification when Stay awake changes.
Screensaver and lock timings remain under stock `idle.screensaver` and
`idle.lock`. Keep Omarchy's idle and lock services enabled; locking before sleep
remains the responsibility of Omarchy's existing sleep/lock setup.

## Status

```sh
omarchy-shell foamy.idle-suspend status
```

Status includes the effective policy, configuration validity, chassis, power
source, Stay awake state, enabled monitors, and the latest error. `enabled`
means a sleep monitor is currently enabled, so it is `false` on AC with the
default settings, on a desktop with `laptopsOnly: true`, or while Stay awake
is enabled. The `debug` method returns the same data.

## Development

The plugin is independent of other Foamy plugins and works with the stock bar.
It reads the same `~/.config/omarchy/shell.json` path as the stock shell because
the restricted service API does not expose plugin entries. Runtime dependencies
are Omarchy Quattro, Quickshell with Wayland and UPower, systemd, and
`notify-send`; no additional runtime package is required on standard Omarchy.

```sh
node tests/policy.test.cjs
python tests/runtime.py
qmllint Service.qml
omarchy plugin validate .
```

The runtime test uses a temporary home with mocked power, idle events, and
system commands. It tests real Quickshell configuration watching and process
handling, including invalid settings and failed sleep requests. It requires
local IPC socket access and never suspends the machine. Actual compositor idle
delivery and physical suspend/resume need separate validation on a target machine.

## License

Licensed under [MIT](LICENSE).

Provided **as is**, without warranty or guaranteed support. Use at your own risk.
