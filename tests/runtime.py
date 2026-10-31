import json, os, pathlib, shutil, subprocess, tempfile, time
# Use real Quickshell file/process handling with mocked power, idle, media,
# logind, lock and system commands. Nothing here can suspend or lock the machine.
source = pathlib.Path(__file__).resolve().parents[1]
base = pathlib.Path(tempfile.mkdtemp(prefix='foamy-idle-runtime-'))
app = base / 'app'; app.mkdir()
mock = app / 'mocks'; mock.mkdir()
bin_dir = base / 'bin'; bin_dir.mkdir()
runtime = base / 'runtime'; runtime.mkdir(mode=0o700)
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
                 ('readonly property int retryBaseMs: 60000', 'readonly property int retryBaseMs: 700')]:
    assert old in service, old
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
command = '''#!/usr/bin/python3
import json, os, pathlib, sys, time
home = pathlib.Path(os.environ['HOME'])
name = pathlib.Path(sys.argv[0]).name
def read(file, default):
    path = home / file
    return path.read_text().strip() if path.exists() else default
if name == 'hostnamectl': print('laptop')
elif name == 'omarchy':
    if (home / 'bad-state').exists(): print('invalid state')
    else: print(json.dumps({'enabled': (home / '.local/state/omarchy/indicators/stay-awake').exists()}))
elif name == 'busctl':
    if 'get-property' in sys.argv: print(json.dumps({'type': 's', 'data': read('block-inhibited', '')}))
    else: print(json.dumps({'type': 's', 'data': [read('can-' + sys.argv[-1], 'yes')]}))
elif name == 'omarchy-shell' and sys.argv[1:3] == ['lock', 'status']:
    pending = home / 'locked-at'
    if pending.exists() and time.time() >= float(pending.read_text()): (home / 'locked').touch()
    secure = (home / 'locked').exists()
    print(json.dumps({'secure': secure, 'requested': secure or pending.exists()}))
else:
    with (home / 'calls').open('a') as f: f.write(json.dumps([name] + sys.argv[1:]) + '\\n')
    if name == 'omarchy-shell':
        reply = read('lock-reply', 'ok')
        delay = read('lock-delay', '')
        if reply == 'ok' and delay:
            if not (home / 'locked-at').exists(): (home / 'locked-at').write_text(str(time.time() + float(delay)))
        elif reply == 'ok': (home / 'locked').touch()
        print(reply)
    if name == 'systemctl':
        time.sleep(0.1)
        (home / 'locked').unlink(missing_ok=True)  # the next attempt must lock again
        (home / 'locked-at').unlink(missing_ok=True)
        if (home / 'fail-sleep').exists():
            print('mock sleep unavailable.', file=sys.stderr); sys.exit(1)
'''
for name in ['hostnamectl', 'omarchy', 'systemctl', 'notify-send', 'busctl', 'omarchy-shell']:
    file = bin_dir / name; file.write_text(command); file.chmod(0o755)
# This machine (and most stock installs) cannot hibernate.
(base / 'can-CanSuspendThenHibernate').write_text('na')
(base / 'can-CanHibernate').write_text('na')
env = dict(os.environ, HOME=str(base), XDG_RUNTIME_DIR=str(runtime), QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='basic', QT_STYLE_OVERRIDE='Fusion', PATH=str(bin_dir) + ':' + os.environ['PATH'])
env.pop('WAYLAND_DISPLAY', None)
env.pop('DISPLAY', None)
def write_config(extra=None, **settings):
    plugins = [{'id': 'foamy.idle-suspend', **settings}] + (extra or [])
    config.write_text(json.dumps({'version': 1, 'plugins': plugins}))
def ipc(target, method, *args):
    return subprocess.check_output(['qs', 'ipc', '-p', str(app), 'call', target, method, *[str(a).lower() for a in args]], env=env, text=True, stderr=subprocess.DEVNULL, timeout=3).strip()
def status(): return json.loads(ipc('foamy.idle-suspend', 'status'))
def wait_for(predicate, timeout=6):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = status()
            if predicate(value): return value
        except (ValueError, subprocess.SubprocessError): pass
        time.sleep(0.05)
    raise AssertionError('Timed out: ' + str(status()))
def recorded(name=None):
    lines = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
    return [line for line in lines if name is None or line[0] == name]
def sleep_calls(): return recorded('systemctl')
def notes(): return [line[-2] for line in recorded('notify-send')]
def active(battery=True):
    ipc('test', 'state', battery, False, False)
    wait_for(lambda s: s['phase'] == 'idle' and not s['retryScheduled'])
write_config()
log = (base / 'runtime.log').open('w')
process = subprocess.Popen(['qs', '-p', str(app), '--no-color'], env=env, stdout=log, stderr=log)
try:
    value = wait_for(lambda s: s['enabled'] and s['chassisLoaded'] and s['actionSupport'])
    assert value['policy']['batteryTimeoutSec'] == 900 and value['policy']['acTimeoutSec'] is None
    assert value['policy']['suspendAction'] == 'auto' and value['effectiveAction'] == 'suspend' and value['autoAction'] == 'suspend'
    assert value['actionSupport']['suspend-then-hibernate'] == 'na' and not value['actionFallback']
    ipc('test', 'state', True, True, True)
    time.sleep(0.15); assert not sleep_calls(), 'Wayland inhibitor did not block sleep'
    # Lock first, then sleep only once the lock reports secure.
    ipc('test', 'state', True, True, False)
    wait_for(lambda s: len(sleep_calls()) == 1)
    ipc('test', 'duplicate')
    order = [line[0] for line in recorded() if line[0] in ('omarchy-shell', 'systemctl')]
    assert order[:2] == ['omarchy-shell', 'systemctl'], order
    assert sleep_calls() == [['systemctl', 'suspend']]
    assert wait_for(lambda s: s['phase'] == 'idle')['lastLockResult'] == 'secure'
    # Woken without input and still idle: ask again after the retry delay.
    wait_for(lambda s: len(sleep_calls()) == 2, timeout=4)
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
    # An unrelated shell.json write keeps the idle countdown running.
    arms = int(ipc('test', 'arms'))
    write_config(extra=[{'id': 'foamy.other', 'value': 1}])
    time.sleep(0.4)
    replacement = config.with_suffix('.new'); replacement.write_text(config.read_text()); replacement.replace(config)
    time.sleep(0.4)
    assert int(ipc('test', 'arms')) == arms and status()['configValid'], 'unrelated writes restarted the countdown'
    # Media playback defers sleep until it stops.
    ipc('test', 'playing', True)
    count = len(sleep_calls())
    ipc('test', 'state', True, True, False)
    wait_for(lambda s: s['deferredReason'] == 'media-playing' and s['mediaPlaying'])
    time.sleep(0.3); assert len(sleep_calls()) == count, 'slept while media was playing'
    ipc('test', 'playing', False)
    wait_for(lambda s: len(sleep_calls()) == count + 1)
    active()
    # A logind idle/sleep block inhibitor defers; it is checked again while idle.
    (base / 'block-inhibited').write_text('handle-lid-switch:idle')
    count = len(sleep_calls())
    ipc('test', 'state', True, True, False)
    wait_for(lambda s: s['deferredReason'] == 'inhibited' and s['retryScheduled'])
    time.sleep(0.3); assert len(sleep_calls()) == count
    (base / 'block-inhibited').write_text('shutdown')
    wait_for(lambda s: len(sleep_calls()) == count + 1, timeout=3)
    active()
    (base / 'block-inhibited').unlink()
    # Playback or an inhibitor that starts while the lock comes up still defers.
    (base / 'lock-delay').write_text('1.0')
    count = len(sleep_calls())
    ipc('test', 'state', True, True, False)
    wait_for(lambda s: s['phase'] == 'locking')
    ipc('test', 'playing', True)
    wait_for(lambda s: s['deferredReason'] == 'media-playing' and s['phase'] == 'idle', timeout=4)
    time.sleep(0.3); assert len(sleep_calls()) == count, 'slept although media started during locking'
    ipc('test', 'playing', False)
    wait_for(lambda s: len(sleep_calls()) == count + 1, timeout=4)
    active()
    count = len(sleep_calls())
    ipc('test', 'state', True, True, False)
    wait_for(lambda s: s['phase'] == 'locking')
    (base / 'block-inhibited').write_text('sleep')
    wait_for(lambda s: s['deferredReason'] == 'inhibited' and s['phase'] == 'idle', timeout=4)
    time.sleep(0.3); assert len(sleep_calls()) == count, 'slept although an inhibitor appeared during locking'
    (base / 'block-inhibited').unlink()
    wait_for(lambda s: len(sleep_calls()) == count + 1, timeout=4)
    active()
    # Power source changes while an attempt is locking: the new source's single
    # idle notification must still lead to sleep once the old attempt ends.
    write_config(acTimeoutSec=1)
    wait_for(lambda s: s['policy']['acTimeoutSec'] == 1)
    count = len(sleep_calls())
    ipc('test', 'state', True, True, False)
    wait_for(lambda s: s['phase'] == 'locking')
    ipc('test', 'state', False, True, False)
    wait_for(lambda s: len(sleep_calls()) == count + 1, timeout=5)
    assert status()['onBattery'] is False
    active(False)
    write_config()
    wait_for(lambda s: s['policy']['acTimeoutSec'] is None)
    (base / 'lock-delay').unlink()
    # Turning pauseForMedia off re-evaluates an attempt deferred for media.
    ipc('test', 'playing', True)
    count = len(sleep_calls())
    ipc('test', 'state', True, True, False)
    wait_for(lambda s: s['deferredReason'] == 'media-playing')
    write_config(pauseForMedia=False)
    wait_for(lambda s: len(sleep_calls()) == count + 1, timeout=4)
    assert status()['mediaPlaying'] is True
    active()
    ipc('test', 'playing', False)
    write_config()
    wait_for(lambda s: s['policy']['pauseForMedia'] is True)
    print('PASS: unrelated config writes keep the countdown, MPRIS playback and logind inhibitors defer sleep, also when they start during locking; a power-source change mid-attempt and turning pauseForMedia off still lead to sleep')
    # No secure lock, no sleep: notify once and retry while idle.
    (base / 'lock-reply').write_text('missing-pam')
    count = len(sleep_calls())
    ipc('test', 'state', True, True, False)
    value = wait_for(lambda s: s['lastLockResult'] == 'missing-pam' and s['retryScheduled'])
    assert value['failureStreak'] == 1 and value['retryInMs'] == 1400
    wait_for(lambda s: s['failureStreak'] >= 2, timeout=4)
    assert len(sleep_calls()) == count, 'slept without a secure lock'
    assert notes().count("Screen didn't lock") == 1, notes()
    active()
    (base / 'lock-reply').unlink()
    write_config(lockBeforeSuspend=False)
    wait_for(lambda s: s['policy']['lockBeforeSuspend'] is False)
    locks = len(recorded('omarchy-shell'))
    ipc('test', 'state', True, True, False)
    wait_for(lambda s: len(sleep_calls()) == count + 1)
    assert len(recorded('omarchy-shell')) == locks, 'lockBeforeSuspend false must not lock'
    active()
    print('PASS: missing lock refuses sleep with one notification and backoff; lockBeforeSuspend false skips locking')
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
    assert value['failureStreak'] == 1 and value['retryInMs'] == 1400
    wait_for(lambda s: s['failureStreak'] == 2, timeout=4)
    assert notes().count('Automatic sleep failed') == 1
    assert sleep_calls()[-1] == ['systemctl', 'suspend']
    active(False)
    (base / 'fail-sleep').unlink()
    print('PASS: unavailable action falls back to suspend with a notification; failed sleep notifies once and backs off')
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
    print('PASS: Stay awake (announced only when active), invalid configuration/state, disabled timeouts')
finally:
    process.terminate()
    try: process.wait(timeout=3)
    except subprocess.TimeoutExpired: process.kill(); process.wait()
    log.close()
    print('Runtime evidence:', base)
    print((base / 'runtime.log').read_text()[-3000:])
