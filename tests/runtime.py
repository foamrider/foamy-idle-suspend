import json, os, pathlib, shutil, subprocess, sys, tempfile, time
# Use real Quickshell file/process handling with mocked power, idle, media,
# logind, lock and system commands. Nothing here can suspend or lock the machine.
source = pathlib.Path(__file__).resolve().parents[1]
KIT = pathlib.Path(os.environ.get('FOAMY_KIT', pathlib.Path.home() / 'GitHub/Personal/foamy-kit'))
sys.path.insert(0, str(KIT / 'preview'))
import harness, hostenv  # noqa: E402
# Short names: Quickshell's IPC socket lives under XDG_RUNTIME_DIR, and a Unix
# socket path longer than 107 bytes fails ("Failed to start IPC server").
base = pathlib.Path(tempfile.mkdtemp(prefix='fis-'))
app = base / 'app'; app.mkdir()
mock = app / 'mocks'; mock.mkdir()
bin_dir = base / 'bin'; bin_dir.mkdir()
runtime = base / 'r'; runtime.mkdir(mode=0o700)
config = base / '.config/omarchy/shell.json'; config.parent.mkdir(parents=True)
state_dir = base / '.local/state/omarchy/indicators'; state_dir.mkdir(parents=True)
calls = base / 'calls'
commons = pathlib.Path(os.environ.get('FOAMY_TEST_COMMONS', '/usr/share/omarchy/shell/Commons'))
(app / 'Commons').symlink_to(commons, target_is_directory=True)
(app / 'kit').symlink_to(source / 'kit', target_is_directory=True)
(app / 'i18n').symlink_to(source / 'i18n', target_is_directory=True)
shutil.copy(source / 'Policy.js', app)
service = (source / 'Service.qml').read_text()
for old, new in [('import Quickshell.Services.UPower', 'import "mocks" as Mock'),
                 ('import Quickshell.Services.Mpris\n', ''), ('import Quickshell.Wayland', ''),
                 ('UPower.onBattery', 'Mock.TestState.onBattery'), ('Mpris.players.values', 'Mock.TestState.players'),
                 ('  IdleMonitor {', '  Mock.IdleMonitor {'),
                 ('readonly property int retryBaseMs: 60000', 'readonly property int retryBaseMs: 700'),
                 ('readonly property int suspendWatchdogMs: 60000', 'readonly property int suspendWatchdogMs: 4000'),
                 ('readonly property int stayAwakeTimeoutSec: 5', 'readonly property int stayAwakeTimeoutSec: 2')]:
    assert old in service, old
    service = service.replace(old, new)
# Every command the service runs, by absolute path to its mock, with the
# number of places that run it: a mock that can't start must never fall
# through to the real command on PATH, and a new call site must be added here.
for old, new, places in [('["systemctl", ', '["%s/systemctl", ' % bin_dir, 1),
                         ('"omarchy", "toggle", "idle", "status"]', '"%s/omarchy", "toggle", "idle", "status"]' % bin_dir, 1),
                         ('["hostnamectl", "chassis"]', '["%s/hostnamectl", "chassis"]' % bin_dir, 1),
                         ('"notify-send"', '"%s/notify-send"' % bin_dir, 3),
                         ('"busctl", "--system"', '"%s/busctl", "--system"' % bin_dir, 1),
                         ('busctl --system --json=short call', '%s/busctl --system --json=short call' % bin_dir, 1),
                         ('omarchy-shell lock ', '%s/omarchy-shell lock ' % bin_dir, 2)]:
    assert service.count(old) == places, (old, service.count(old))
    service = service.replace(old, new)
(app / 'Service.qml').write_text(service)
(mock / 'qmldir').write_text('module Mock\nsingleton TestState 1.0 State.qml\nIdleMonitor 1.0 IdleMonitor.qml\n')
(mock / 'State.qml').write_text('pragma Singleton\nimport QtQuick\nQtObject { property bool onBattery: true; property bool idle: false; property bool inhibited: false; property var players: []; property int arms: 0 }\n')
# arms counts every (re)start of the compositor idle countdown.
(mock / 'IdleMonitor.qml').write_text('import QtQuick\nQtObject { property bool enabled: false; property int timeout: 1; property bool respectInhibitors: false; readonly property bool isIdle: enabled && TestState.idle && !(respectInhibitors && TestState.inhibited); onEnabledChanged: if (enabled) TestState.arms++; onTimeoutChanged: if (enabled) TestState.arms++ }\n')
(app / 'shell.qml').write_text('''import QtQuick
import Quickshell
import Quickshell.Io
import "mocks" as Mock
ShellRoot {
  Service { id: service }
  IpcHandler {
    target: "test"
    function state(battery: bool, idle: bool, inhibited: bool): string {
      Mock.TestState.idle = false
      Mock.TestState.onBattery = battery
      Mock.TestState.inhibited = inhibited
      Mock.TestState.idle = idle
      return "ok"
    }
    function playing(value: bool): string { Mock.TestState.players = value ? [{isPlaying: true}] : [{isPlaying: false}]; return "ok" }
    function arms(): string { return String(Mock.TestState.arms) }
    function duplicate(): string { service.requestSuspend("battery"); return "ok" }
  }
}
''')
# One bash mock for every command: bash starts in a few milliseconds where
# Python needs tens, and on a loaded machine a slow mock outran the test's
# short watchdog and probe deadlines. State lives in files under $HOME; calls
# that matter (systemctl, notify-send, the lock request) go to $HOME/calls as
# JSON arrays.
command = r'''#!/bin/bash
home=$HOME
name=${0##*/}
json() {
  local out='[' sep='' s
  for s in "$name" "$@"; do
    s=${s//\\/\\\\}; s=${s//\"/\\\"}
    out+="$sep\"$s\""; sep=', '
  done
  printf '%s]\n' "$out" >> "$home/calls"
}
read_or() { if [[ -e $home/$1 ]]; then tr -d '\n' < "$home/$1"; else printf '%s' "$2"; fi; }
case $name in
  hostnamectl) echo laptop ;;
  omarchy)
    [[ -e $home/hang-state ]] && sleep 30
    if [[ -e $home/bad-state ]]; then echo 'invalid state'
    elif [[ -e $home/.local/state/omarchy/indicators/stay-awake ]]; then echo '{"enabled": true}'
    else echo '{"enabled": false}'; fi ;;
  busctl)
    if [[ " $* " == *" get-property "* ]]; then
      if [[ -e $home/inhibitor-fail ]]; then
        echo 'Failed to get property BlockInhibited: Connection timed out' >&2; exit 1
      fi
      if [[ -e $home/inhibitor-garbage ]]; then echo garbage
      else printf '{"type": "s", "data": "%s"}\n' "$(read_or block-inhibited '')"; fi
    else
      printf '{"type": "s", "data": ["%s"]}\n' "$(read_or "can-${!#}" yes)"
    fi ;;
  omarchy-shell)
    if [[ $1 == lock && $2 == status ]]; then
      if [[ -e $home/lock-requested && ! -e $home/lock-hold ]]; then touch "$home/locked"; fi
      secure=false requested=false
      [[ -e $home/locked ]] && secure=true requested=true
      [[ -e $home/lock-requested ]] && requested=true
      printf '{"secure": %s, "requested": %s}\n' "$secure" "$requested"
    else
      json "$@"
      reply=$(read_or lock-reply ok)
      # While lock-hold exists the lock stays requested, not secure, so the
      # test can act during "locking" however slow the machine is.
      if [[ $reply == ok && -e $home/lock-hold ]]; then touch "$home/lock-requested"
      elif [[ $reply == ok ]]; then touch "$home/locked"; fi
      echo "$reply"
    fi ;;
  systemctl)
    json "$@"
    [[ -e $home/hang-sleep ]] && exec sleep 30
    sleep 0.1
    # The next attempt must lock again.
    rm -f "$home/locked" "$home/lock-requested"
    if [[ -e $home/fail-sleep ]]; then echo 'mock sleep unavailable.' >&2; exit 1; fi ;;
  *) json "$@" ;;
esac
'''
for name in ['hostnamectl', 'omarchy', 'systemctl', 'notify-send', 'busctl', 'omarchy-shell']:
    file = bin_dir / name; file.write_text(command); file.chmod(0o755)
# This machine (and most stock installs) cannot hibernate.
(base / 'can-CanSuspendThenHibernate').write_text('na')
(base / 'can-CanHibernate').write_text('na')
# The kit's isolation for a qs the test starts itself: no Omarchy bin
# directory or AppImage entry ($APPDIR) on PATH or LD_LIBRARY_PATH, and dead
# audio and system-bus addresses. Every command the service runs is a mock
# reached by absolute path (above), so nothing reaches logind or the desktop.
env = hostenv.isolate(dict(os.environ, HOME=str(base), XDG_RUNTIME_DIR=str(runtime), QT_QPA_PLATFORM='offscreen',
                           QT_QPA_PLATFORMTHEME='basic', QT_STYLE_OVERRIDE='Fusion'), base)
env['PATH'] = str(bin_dir) + ':' + env['PATH']
# Temporary XDG directories too: 4.5's Commons reads the language from the
# config home, and the desktop's choice must not leak into the notifications.
env.update(XDG_CONFIG_HOME=str(base / '.config'), XDG_STATE_HOME=str(base / '.local/state'),
           XDG_CACHE_HOME=str(base / '.cache'), XDG_DATA_HOME=str(base / '.local/share'))
for name in ('WAYLAND_DISPLAY', 'DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'OMARCHY_LANGUAGE_FILE'):
    env.pop(name, None)
# Atomic, like the shell's own shell.json writes (FileView atomicWrites): an
# in-place write can be read half-done, which pauses sleep for a moment and
# restarts the idle countdown.
def write_config(extra=None, **settings):
    plugins = [{'id': 'foamy.idle-suspend', **settings}] + (extra or [])
    replacement = config.with_suffix('.tmp')
    replacement.write_text(json.dumps({'version': 1, 'plugins': plugins}))
    replacement.replace(config)
def ipc(target, method, *args):
    return subprocess.check_output(['qs', 'ipc', '-p', str(app), 'call', target, method, *[str(a).lower() for a in args]], env=env, text=True, stderr=subprocess.DEVNULL, timeout=15).strip()
def status(): return json.loads(ipc('foamy.idle-suspend', 'status'))
# The limits only bound how long a broken run takes to fail: a loaded machine
# (parallel test runs, Python mocks starting slowly) needs the room, and a
# passing wait returns as soon as its condition holds. A status poll can take
# seconds under load while idle retries keep sleeping (700 ms apart here), so
# a wait for "slept again" counts at least one more call, never exactly one.
def wait_for(predicate, timeout=30):
    def ready():
        try:
            value = status()
        except (ValueError, subprocess.SubprocessError):
            return None
        return value if predicate(value) else None
    value = harness.wait_for(ready, timeout, stop=lambda: process.poll() is not None)
    if value is None: raise AssertionError('Timed out: ' + str(status()))
    return value
def recorded(name=None):
    lines = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
    return [line for line in lines if name is None or line[0] == name]
# Every sleep request refuses interactive authorization: polkit must never
# prompt behind the lock with nobody there. Returns [name, action] per call.
def sleep_calls():
    calls_made = recorded('systemctl')
    assert all(line[1:2] == ['--no-ask-password'] and len(line) == 3 for line in calls_made), calls_made
    return [[line[0], line[2]] for line in calls_made]
def notes(): return [line[-2] for line in recorded('notify-send')]
# Failure backoff in this test (retryBaseMs 700): a status poll can be slower
# than the first retry, so a check accepts whichever streak it sees.
BACKOFF_MS = {1: 1400, 2: 2800, 3: 5600, 4: 10500}
def backoff_ok(value): return value['retryInMs'] == BACKOFF_MS.get(min(value['failureStreak'], 4))
# The user is back: input, and (once no attempt is running) the screen
# unlocked, so a lock left by a skipped attempt can't count for the next one.
def active(battery=True):
    ipc('test', 'state', battery, False, False)
    wait_for(lambda s: s['phase'] == 'idle' and not s['retryScheduled'])
    for name in ('locked', 'lock-requested'): (base / name).unlink(missing_ok=True)
write_config()
log = (base / 'runtime.log').open('w')
passed = False
process = subprocess.Popen(['qs', '-p', str(app), '--no-color'], env=env, stdout=log, stderr=log)
try:
    value = wait_for(lambda s: s['enabled'] and s['chassisLoaded'] and s['actionSupport'])
    assert value['policy']['batteryTimeoutSec'] == 900 and value['policy']['acTimeoutSec'] is None
    assert value['policy']['suspendAction'] == 'auto' and value['effectiveAction'] == 'suspend' and value['autoAction'] == 'suspend'
    assert value['actionSupport']['suspend-then-hibernate'] == 'na' and not value['actionFallback']
    ipc('test', 'state', True, True, True)
    # The fixed sleeps below are quiet periods: they check that nothing happens
    # (a sleep request, a second report) within a time the service would need.
    time.sleep(0.15); assert not sleep_calls(), 'Wayland inhibitor did not block sleep'
    # Lock first, then sleep only once the lock reports secure.
    ipc('test', 'state', True, True, False)
    wait_for(lambda s: len(sleep_calls()) >= 1)
    ipc('test', 'duplicate')
    order = [line[0] for line in recorded() if line[0] in ('omarchy-shell', 'systemctl')]
    assert order[:2] == ['omarchy-shell', 'systemctl'], order
    assert sleep_calls()[0] == ['systemctl', 'suspend'], sleep_calls()
    value = wait_for(lambda s: s['phase'] == 'idle')
    assert value['lastLockResult'] == 'secure' and value['failureStreak'] == 0 and value['lastError'] == '', value
    # Woken without input and still idle: ask again after the retry delay.
    wait_for(lambda s: len(sleep_calls()) >= 2)
    active()
    time.sleep(0.9); count = len(sleep_calls())
    time.sleep(0.9); assert len(sleep_calls()) == count, 'activity must stop retries'
    print('PASS: lock then suspend, duplicate request, retry after a wake without input, activity stops retries')
    # "auto" re-asks logind on every attempt: once hibernation is set up it
    # uses suspend-then-hibernate, and plain suspend again when it is not.
    (base / 'can-CanSuspendThenHibernate').write_text('yes')
    ipc('test', 'state', True, True, False)
    wait_for(lambda s: sleep_calls()[-1] == ['systemctl', 'suspend-then-hibernate'])
    assert status()['autoAction'] == 'suspend-then-hibernate' and not status()['actionFallback']
    active()
    (base / 'can-CanSuspendThenHibernate').write_text('na')
    ipc('test', 'state', True, True, False)
    wait_for(lambda s: sleep_calls()[-1] == ['systemctl', 'suspend'] and s['autoAction'] == 'suspend')
    active()
    assert not [n for n in notes() if "isn't available" in n], 'auto never notifies a fallback'
    print('PASS: auto resolves per attempt (suspend-then-hibernate when logind says yes, else suspend)')
    # An unrelated shell.json write keeps the idle countdown running. The
    # lockBeforeSuspend change after them doesn't touch the idle monitors; once
    # it shows, the service has read every write before it. The writes are
    # spaced: the file watcher can miss a replace that follows another within
    # a few milliseconds (seen under load), and the shell doesn't write that fast.
    arms = int(ipc('test', 'arms'))
    write_config(extra=[{'id': 'foamy.other', 'value': 1}])
    time.sleep(0.4)
    replacement = config.with_suffix('.new'); replacement.write_text(config.read_text()); replacement.replace(config)
    time.sleep(0.4)
    write_config(extra=[{'id': 'foamy.other', 'value': 1}], lockBeforeSuspend=False)
    wait_for(lambda s: s['policy']['lockBeforeSuspend'] is False)
    write_config()
    wait_for(lambda s: s['policy']['lockBeforeSuspend'] is True)
    assert int(ipc('test', 'arms')) == arms and status()['configValid'], 'unrelated writes restarted the countdown'
    # Media playback defers sleep until it stops.
    ipc('test', 'playing', True)
    count = len(sleep_calls())
    ipc('test', 'state', True, True, False)
    wait_for(lambda s: s['deferredReason'] == 'media-playing' and s['mediaPlaying'])
    time.sleep(0.3); assert len(sleep_calls()) == count, 'slept while media was playing'
    ipc('test', 'playing', False)
    wait_for(lambda s: len(sleep_calls()) >= count + 1)
    active()
    # A logind idle/sleep block inhibitor defers; it is checked again while idle.
    (base / 'block-inhibited').write_text('handle-lid-switch:idle')
    count = len(sleep_calls())
    ipc('test', 'state', True, True, False)
    wait_for(lambda s: s['deferredReason'] == 'inhibited' and s['retryScheduled'])
    time.sleep(0.3); assert len(sleep_calls()) == count
    (base / 'block-inhibited').write_text('shutdown')
    wait_for(lambda s: len(sleep_calls()) >= count + 1)
    active()
    (base / 'block-inhibited').unlink()
    # An inhibitor check that fails is no answer, never "no inhibitor": sleep
    # waits, says why and asks again while idle.
    (base / 'inhibitor-fail').touch()
    count = len(sleep_calls())
    ipc('test', 'state', True, True, False)
    value = wait_for(lambda s: s['deferredReason'] == 'inhibitor-check-failed' and s['retryScheduled'])
    assert value['lastError'] == "Couldn't check logind inhibitors: Failed to get property BlockInhibited: Connection timed out", value
    time.sleep(0.3); assert len(sleep_calls()) == count, 'slept although the inhibitor check failed'
    (base / 'inhibitor-fail').unlink()
    wait_for(lambda s: len(sleep_calls()) >= count + 1)
    value = wait_for(lambda s: s['phase'] == 'idle')
    assert value['lastError'] == '', value
    active()
    # Playback or an inhibitor that starts while the lock comes up still defers.
    hold = base / 'lock-hold'
    count = len(sleep_calls())
    hold.touch()
    ipc('test', 'state', True, True, False)
    wait_for(lambda s: s['phase'] == 'locking')
    ipc('test', 'playing', True)
    hold.unlink()
    wait_for(lambda s: s['deferredReason'] == 'media-playing' and s['phase'] == 'idle')
    time.sleep(0.3); assert len(sleep_calls()) == count, 'slept although media started during locking'
    ipc('test', 'playing', False)
    wait_for(lambda s: len(sleep_calls()) >= count + 1)
    active()
    count = len(sleep_calls())
    hold.touch()
    ipc('test', 'state', True, True, False)
    wait_for(lambda s: s['phase'] == 'locking')
    (base / 'block-inhibited').write_text('sleep')
    hold.unlink()
    wait_for(lambda s: s['deferredReason'] == 'inhibited' and s['phase'] == 'idle')
    time.sleep(0.3); assert len(sleep_calls()) == count, 'slept although an inhibitor appeared during locking'
    (base / 'block-inhibited').unlink()
    wait_for(lambda s: len(sleep_calls()) >= count + 1)
    active()
    # An unreadable reply to the check after locking defers too.
    count = len(sleep_calls())
    hold.touch()
    ipc('test', 'state', True, True, False)
    wait_for(lambda s: s['phase'] == 'locking')
    (base / 'inhibitor-garbage').touch()
    hold.unlink()
    value = wait_for(lambda s: s['deferredReason'] == 'inhibitor-check-failed' and s['phase'] == 'idle')
    assert value['lastError'] == "Couldn't check logind inhibitors: busctl's reply didn't parse", value
    time.sleep(0.3); assert len(sleep_calls()) == count, 'slept although the check after locking failed'
    (base / 'inhibitor-garbage').unlink()
    wait_for(lambda s: len(sleep_calls()) >= count + 1)
    active()
    # Power source changes while an attempt is locking: the new source's single
    # idle notification must still lead to sleep once the old attempt ends.
    write_config(acTimeoutSec=1)
    wait_for(lambda s: s['policy']['acTimeoutSec'] == 1)
    count = len(sleep_calls())
    hold.touch()
    ipc('test', 'state', True, True, False)
    wait_for(lambda s: s['phase'] == 'locking')
    ipc('test', 'state', False, True, False)
    hold.unlink()
    wait_for(lambda s: len(sleep_calls()) >= count + 1)
    assert status()['onBattery'] is False
    active(False)
    write_config()
    wait_for(lambda s: s['policy']['acTimeoutSec'] is None)
    # Turning pauseForMedia off re-evaluates an attempt deferred for media.
    ipc('test', 'playing', True)
    count = len(sleep_calls())
    ipc('test', 'state', True, True, False)
    wait_for(lambda s: s['deferredReason'] == 'media-playing')
    write_config(pauseForMedia=False)
    wait_for(lambda s: len(sleep_calls()) >= count + 1)
    assert status()['mediaPlaying'] is True
    active()
    ipc('test', 'playing', False)
    write_config()
    wait_for(lambda s: s['policy']['pauseForMedia'] is True)
    print('PASS: unrelated config writes keep the countdown, MPRIS playback and logind inhibitors defer sleep, also when they start during locking; a failed or unreadable inhibitor check defers and retries; a power-source change mid-attempt and turning pauseForMedia off still lead to sleep')
    # No secure lock, no sleep: notify once and retry while idle.
    (base / 'lock-reply').write_text('missing-pam')
    count = len(sleep_calls())
    ipc('test', 'state', True, True, False)
    value = wait_for(lambda s: s['lastLockResult'] == 'missing-pam' and s['retryScheduled'])
    assert value['failureStreak'] >= 1 and backoff_ok(value), value
    wait_for(lambda s: s['failureStreak'] >= 2)
    assert len(sleep_calls()) == count, 'slept without a secure lock'
    assert notes().count("Screen didn't lock") == 1, notes()
    active()
    # A lock that never reports secure ends in a timeout (the status poll runs
    # out, or the outer timeout stops it): no sleep either.
    (base / 'lock-reply').write_text('failed')
    ipc('test', 'state', True, True, False)
    value = wait_for(lambda s: s['lastLockResult'] == 'timeout' and s['phase'] == 'idle')
    assert value['failureStreak'] >= 1 and value['lastError'] == 'The screen did not lock (timeout)', value
    assert len(sleep_calls()) == count, 'slept although the lock timed out'
    # notify-send runs detached: wait for it to record the call.
    wait_for(lambda s: notes().count("Screen didn't lock") == 2)
    active()
    (base / 'lock-reply').unlink()
    write_config(lockBeforeSuspend=False)
    wait_for(lambda s: s['policy']['lockBeforeSuspend'] is False)
    locks = len(recorded('omarchy-shell'))
    ipc('test', 'state', True, True, False)
    wait_for(lambda s: len(sleep_calls()) >= count + 1)
    assert len(recorded('omarchy-shell')) == locks, 'lockBeforeSuspend false must not lock'
    active()
    print('PASS: missing lock or a lock that times out refuses sleep with one notification and backoff; lockBeforeSuspend false skips locking')
    # Sleep off on this machine (logind answers "na", as with Omarchy's
    # sleep-disabled setting): say so once per configuration, not after every
    # idle period.
    (base / 'can-CanSuspend').write_text('na')
    count = len(sleep_calls())
    def unavailable_period():
        before = status()['lastEventAt']
        ipc('test', 'state', True, True, False)
        wait_for(lambda s: s['lastEvent'] == 'suspend-unavailable: ' + s['policy']['suspendAction'] and s['lastEventAt'] != before)
        active()
    unavailable_period()
    wait_for(lambda s: notes().count("Sleep isn't available") == 1)
    unavailable_period()
    time.sleep(0.5); assert notes().count("Sleep isn't available") == 1, notes()
    write_config(suspendAction='suspend')
    wait_for(lambda s: s['policy']['suspendAction'] == 'suspend')
    unavailable_period()
    wait_for(lambda s: notes().count("Sleep isn't available") == 2)
    assert len(sleep_calls()) == count, 'slept although no action is available'
    (base / 'can-CanSuspend').unlink()
    write_config()
    wait_for(lambda s: s['policy']['suspendAction'] == 'auto')
    # Hibernation not set up: fall back to suspend and say so once.
    write_config(suspendAction='suspend-then-hibernate')
    value = wait_for(lambda s: s['actionFallback'] and s['effectiveAction'] == 'suspend')
    wait_for(lambda s: "suspend-then-hibernate isn't available" in notes())
    ipc('test', 'state', True, True, False)
    wait_for(lambda s: sleep_calls()[-1] == ['systemctl', 'suspend'])
    active()
    # A failed request is reported once and retried with backoff.
    (base / 'fail-sleep').touch()
    write_config(acTimeoutSec=1800, suspendAction='suspend')
    wait_for(lambda s: s['monitors']['acEnabled'] or s['monitors']['batteryEnabled'])
    ipc('test', 'state', False, True, False)
    value = wait_for(lambda s: s['lastError'] == 'mock sleep unavailable.' and s['retryScheduled'])
    assert value['failureStreak'] >= 1 and backoff_ok(value), value
    value = wait_for(lambda s: s['failureStreak'] >= 2 and s['retryScheduled'])
    assert backoff_ok(value), value
    assert notes().count('Automatic sleep failed') == 1
    assert sleep_calls()[-1] == ['systemctl', 'suspend']
    active(False)
    (base / 'fail-sleep').unlink()
    print('PASS: no sleep action notifies once per configuration; unavailable action falls back to suspend with a notification; failed sleep notifies once and backs off')
    # A sleep request that never ends: the watchdog stops it and reports it
    # once (the killed request's exit changes nothing).
    def log_count(text): return (base / 'runtime.log').read_text().count(text)
    # The sleep requests and their outcomes logged since `start` (a log offset).
    def settles(start):
        text = (base / 'runtime.log').read_text()[start:]
        out = []
        for line in text.splitlines():
            if ' suspend-request: ' in line: out.append('request')
            elif ' suspend-error: ' in line or ' resume: ' in line: out.append('settled')
        return out
    hang_from = len((base / 'runtime.log').read_text())
    (base / 'hang-sleep').touch()
    count = len(sleep_calls())
    ipc('test', 'state', False, True, False)
    wait_for(lambda s: s['phase'] == 'suspending' and s['suspendRunning'])
    value = wait_for(lambda s: "didn't finish within 4 seconds" in s['lastError'] and s['phase'] == 'idle' and s['retryScheduled'])
    assert value['failureStreak'] >= 1 and backoff_ok(value) and not value['suspendRunning'], value
    (base / 'hang-sleep').unlink()
    wait_for(lambda s: s['phase'] == 'idle' and s['failureStreak'] == 0 and s['lastError'] == '')
    active(False)
    # Each request settles once: a killed request's exit adds no second report.
    # (On a slow machine a retry can hang too before the test sees the first.)
    events = settles(hang_from)
    assert len(events) >= 4 and events == ['request', 'settled'] * (len(events) // 2), events
    assert log_count("suspend-error: systemctl suspend didn't finish") >= 1 and len(sleep_calls()) >= count + 2
    # A sleep command that can't start (no exited()) ends the attempt too.
    systemctl = bin_dir / 'systemctl'; systemctl.chmod(0o644)
    count = len(sleep_calls())
    ipc('test', 'state', False, True, False)
    value = wait_for(lambda s: "couldn't start" in s['lastError'] and s['phase'] == 'idle' and s['retryScheduled'])
    assert value['failureStreak'] == 1 and len(sleep_calls()) == count, value
    assert log_count("suspend-error: systemctl suspend couldn't start") == 1
    systemctl.chmod(0o755)
    wait_for(lambda s: len(sleep_calls()) >= count + 1 and s['phase'] == 'idle' and s['failureStreak'] == 0 and s['lastError'] == '')
    active(False)
    print('PASS: a hung or unstartable sleep command ends the attempt with one report and a retry')
    awake = state_dir / 'stay-awake'; awake.touch()
    wait_for(lambda s: s['stayAwake'] is True and not s['enabled'])
    # notify-send runs detached; give it a moment to record the call.
    wait_for(lambda s: 'Stay awake enabled' in notes())
    ipc('test', 'state', False, True, False)
    time.sleep(0.15); count = len(sleep_calls())
    time.sleep(0.3); assert len(sleep_calls()) == count
    ipc('test', 'state', False, False, False)
    awake.unlink(); wait_for(lambda s: s['stayAwake'] is False and s['enabled'])
    write_config(acTimeoutSec='1800')
    wait_for(lambda s: not s['configValid'] and not s['enabled'] and 'acTimeoutSec' in s['lastError'])
    ipc('test', 'state', False, True, False)
    time.sleep(0.3); assert len(sleep_calls()) == count
    ipc('test', 'state', False, False, False)
    write_config(acTimeoutSec=1800)
    wait_for(lambda s: s['configValid'] and s['enabled'])
    (base / 'bad-state').touch(); (state_dir / 'refresh').touch()
    wait_for(lambda s: s['stayAwake'] is None and not s['enabled'] and 'SyntaxError' in s['lastError'])
    (base / 'bad-state').unlink(); (state_dir / 'refresh').unlink()
    wait_for(lambda s: s['enabled'])
    omarchy = bin_dir / 'omarchy'; omarchy.chmod(0o644); (state_dir / 'refresh').touch()
    wait_for(lambda s: s['stayAwake'] is None and not s['enabled'] and "couldn't start" in s['lastError'])
    omarchy.chmod(0o755); (state_dir / 'refresh').unlink()
    wait_for(lambda s: s['enabled'] and s['stayAwake'] is False and s['lastError'] == '')
    # A status command that hangs is stopped at its deadline and said so;
    # sleep stays off until a read succeeds.
    (base / 'hang-state').touch(); (state_dir / 'refresh').touch()
    value = wait_for(lambda s: s['stayAwake'] is None and "didn't finish" in s['lastError'])
    assert not value['enabled'] and value['lastError'] == "omarchy toggle idle status didn't finish within 2 seconds", value
    (base / 'hang-state').unlink(); (state_dir / 'refresh').unlink()
    wait_for(lambda s: s['enabled'] and s['stayAwake'] is False and s['lastError'] == '')
    write_config(batteryTimeoutSec=None, acTimeoutSec=None)
    wait_for(lambda s: s['configValid'] and not s['enabled'] and s['policy']['batteryTimeoutSec'] is None)
    for battery in (True, False):
        ipc('test', 'state', battery, True, False)
        value = wait_for(lambda s: not s['enabled'])
    time.sleep(0.3); assert len(sleep_calls()) == count
    ipc('test', 'state', False, False, False)
    # Inert plugin: Stay awake changes are not announced.
    before = len(notes())
    awake.touch(); wait_for(lambda s: s['stayAwake'] is True)
    awake.unlink(); wait_for(lambda s: s['stayAwake'] is False)
    assert len(notes()) == before, 'an inert plugin must not notify'
    write_config(acTimeoutSec=0)
    wait_for(lambda s: not s['configValid'] and not s['enabled'] and 'acTimeoutSec' in s['lastError'])
    print('PASS: Stay awake (announced only when active), invalid configuration/state, a status command that cannot start or hangs, disabled timeouts')
    # hostnamectl can't start: the chassis is unknown (not a laptop) and says why.
    process.terminate(); process.wait(timeout=5)
    write_config()
    (bin_dir / 'hostnamectl').unlink()
    process = subprocess.Popen(['qs', '-p', str(app), '--no-color'], env=env, stdout=log, stderr=log)
    value = wait_for(lambda s: s['chassisLoaded'] and s['stayAwake'] is False)
    assert value['chassis'] == 'unknown' and not value['isLaptop'] and not value['enabled'], value
    assert value['lastError'] == "hostnamectl chassis couldn't start", value
    print('PASS: a chassis probe that cannot start is reported and keeps a laptops-only policy off')
    runtime_log = (base / 'runtime.log').read_text()
    hostenv.check(env, runtime_log)
    # A script error in a handler would leave an attempt stuck mid-phase.
    assert not [line for line in runtime_log.splitlines() if 'ReferenceError' in line or 'TypeError' in line], runtime_log
    passed = True
finally:
    process.terminate()
    try: process.wait(timeout=3)
    except subprocess.TimeoutExpired: process.kill(); process.wait()
    log.close()
    if passed:
        shutil.rmtree(base)
    else:
        print('Runtime evidence:', base)
        print((base / 'runtime.log').read_text()[-3000:])
