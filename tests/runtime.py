import json, os, pathlib, shutil, subprocess, tempfile, time
# Use real Quickshell file/process handling with mocked power, idle, and system commands.
source = pathlib.Path(__file__).resolve().parents[1]
base = pathlib.Path(tempfile.mkdtemp(prefix='foamy-idle-runtime-'))
app = base / 'app'; app.mkdir()
mock = app / 'mocks'; mock.mkdir()
bin_dir = base / 'bin'; bin_dir.mkdir()
runtime = base / 'runtime'; runtime.mkdir(mode=0o700)
config = base / '.config/omarchy/shell.json'; config.parent.mkdir(parents=True)
state_dir = base / '.local/state/omarchy/indicators'; state_dir.mkdir(parents=True)
calls = base / 'calls'
shutil.copy(source / 'Policy.js', app)
service = (source / 'Service.qml').read_text().replace('import Quickshell.Services.UPower', 'import "mocks" as Mock').replace('import Quickshell.Wayland', '').replace('UPower.onBattery', 'Mock.TestState.onBattery').replace('  IdleMonitor {', '  Mock.IdleMonitor {')
(app / 'Service.qml').write_text(service)
(mock / 'qmldir').write_text('module Mock\nsingleton TestState 1.0 State.qml\nIdleMonitor 1.0 IdleMonitor.qml\n')
(mock / 'State.qml').write_text('pragma Singleton\nimport QtQuick\nQtObject { property bool onBattery: true; property bool idle: false; property bool inhibited: false }\n')
(mock / 'IdleMonitor.qml').write_text('import QtQuick\nQtObject { property bool enabled: false; property int timeout: 1; property bool respectInhibitors: false; readonly property bool isIdle: enabled && TestState.idle && !(respectInhibitors && TestState.inhibited) }\n')
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
    function duplicate(): string { service.requestSuspend("battery"); return "ok" }
  }
}
''')
command = '''#!/usr/bin/python3
import json, os, pathlib, sys, time
home = pathlib.Path(os.environ['HOME'])
name = pathlib.Path(sys.argv[0]).name
if name == 'hostnamectl': print('laptop')
elif name == 'omarchy':
    if (home / 'bad-state').exists(): print('invalid state')
    else: print(json.dumps({'enabled': (home / '.local/state/omarchy/indicators/stay-awake').exists()}))
else:
    with (home / 'calls').open('a') as f: f.write(json.dumps([name] + sys.argv[1:]) + '\\n')
    if name == 'systemctl':
        time.sleep(0.5)
        if (home / 'fail-sleep').exists():
            print('mock sleep unavailable', file=sys.stderr); sys.exit(1)
'''
for name in ['hostnamectl', 'omarchy', 'systemctl', 'notify-send']:
    file = bin_dir / name; file.write_text(command); file.chmod(0o755)
env = dict(os.environ, HOME=str(base), XDG_RUNTIME_DIR=str(runtime), QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='basic', QT_STYLE_OVERRIDE='Fusion', PATH=str(bin_dir) + ':' + os.environ['PATH'])
env.pop('WAYLAND_DISPLAY', None)
env.pop('DISPLAY', None)
def write_config(**settings):
    config.write_text(json.dumps({'version': 1, 'plugins': [{'id': 'foamy.idle-suspend', **settings}]}))
def ipc(target, method, *args):
    return subprocess.check_output(['qs', 'ipc', '-p', str(app), 'call', target, method, *[str(a).lower() for a in args]], env=env, text=True, stderr=subprocess.DEVNULL, timeout=3).strip()
def status(): return json.loads(ipc('foamy.idle-suspend', 'status'))
def wait_for(predicate):
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        try:
            value = status()
            if predicate(value): return value
        except (ValueError, subprocess.SubprocessError): pass
        time.sleep(0.05)
    raise AssertionError('Timed out: ' + str(status()))
def sleep_calls():
    return [json.loads(line) for line in calls.read_text().splitlines() if json.loads(line)[0] == 'systemctl'] if calls.exists() else []
write_config()
log = (base / 'runtime.log').open('w')
process = subprocess.Popen(['qs', '-p', str(app), '--no-color'], env=env, stdout=log, stderr=log)
try:
    value = wait_for(lambda s: s['enabled'] and s['chassisLoaded'])
    assert value['policy']['batteryTimeoutSec'] == 900
    assert value['policy']['acTimeoutSec'] is None
    ipc('test', 'state', True, True, True)
    time.sleep(0.15); assert not sleep_calls(), 'inhibitor did not block sleep'
    ipc('test', 'state', True, True, False)
    wait_for(lambda s: s['suspendRunning'])
    ipc('test', 'duplicate')
    wait_for(lambda s: not s['suspendRunning'])
    assert sleep_calls() == [['systemctl', 'suspend-then-hibernate']]
    ipc('test', 'state', False, False, False)
    wait_for(lambda s: not s['enabled'])
    write_config(acTimeoutSec=1800, suspendAction='suspend')
    wait_for(lambda s: s['monitors']['acEnabled'] and s['policy']['acTimeoutSec'] == 1800)
    awake = state_dir / 'stay-awake'; awake.touch()
    wait_for(lambda s: s['stayAwake'] is True and not s['enabled'])
    ipc('test', 'state', False, True, False)
    time.sleep(0.15); assert len(sleep_calls()) == 1
    ipc('test', 'state', False, False, False)
    awake.unlink(); wait_for(lambda s: s['stayAwake'] is False and s['enabled'])
    write_config(acTimeoutSec='1800')
    wait_for(lambda s: not s['configValid'] and not s['enabled'] and 'acTimeoutSec' in s['lastError'])
    ipc('test', 'state', False, True, False)
    time.sleep(0.15); assert len(sleep_calls()) == 1
    ipc('test', 'state', False, False, False)
    write_config(acTimeoutSec=1800, suspendAction='suspend')
    wait_for(lambda s: s['configValid'] and s['enabled'])
    (base / 'fail-sleep').touch()
    ipc('test', 'state', False, True, False)
    wait_for(lambda s: s['lastError'] == 'mock sleep unavailable')
    assert sleep_calls()[-1] == ['systemctl', 'suspend']
    ipc('test', 'state', False, False, False)
    (base / 'bad-state').touch(); (state_dir / 'refresh').touch()
    wait_for(lambda s: s['stayAwake'] is None and not s['enabled'] and 'SyntaxError' in s['lastError'])
    (base / 'bad-state').unlink(); (state_dir / 'refresh').unlink()
    wait_for(lambda s: s['enabled'])
    replacement = config.with_suffix('.new'); replacement.write_text(config.read_text()); replacement.replace(config)
    wait_for(lambda s: s['configValid'])
    write_config(batteryTimeoutSec=None, acTimeoutSec=None)
    wait_for(lambda s: s['configValid'] and not s['enabled'] and s['policy']['batteryTimeoutSec'] is None)
    for battery in (True, False):
        ipc('test', 'state', battery, True, False)
        value = wait_for(lambda s: not s['enabled'])
        assert value['policy']['batteryTimeoutSec'] is None
        assert value['policy']['acTimeoutSec'] is None
    time.sleep(0.15); assert len(sleep_calls()) == 2
    ipc('test', 'state', False, False, False)
    write_config(acTimeoutSec=0)
    wait_for(lambda s: not s['configValid'] and not s['enabled'] and 'acTimeoutSec' in s['lastError'])
    print('PASS: runtime config reload, defaults, power switching, inhibitors, duplicate requests, Stay awake, invalid configuration/state, sleep errors, atomic save, disabled timeouts')
finally:
    process.terminate()
    try: process.wait(timeout=3)
    except subprocess.TimeoutExpired: process.kill(); process.wait()
    log.close()
    print('Runtime evidence:', base)
    print((base / 'runtime.log').read_text())
