import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import Quickshell.Wayland
import "Policy.js" as Policy

Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null

  property var configuration: ({ valid: false, settings: Policy.defaults(), error: "Loading shell.json" })
  readonly property var policy: configuration.settings
  readonly property var batteryTimeoutSeconds: policy.batteryTimeoutSec
  readonly property var acTimeoutSeconds: policy.acTimeoutSec
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
  readonly property string stayAwakeStateDir: Quickshell.env("HOME") + "/.local/state/omarchy/indicators"
  readonly property bool idleEnabled: stayAwakeStateKnown && !lastStayAwake
  property bool stateRefreshPending: false
  readonly property bool suspendAllowed: Policy.allowed(policy, configuration.valid, chassisLoaded, isLaptop, idleEnabled)

  property bool chassisLoaded: false
  property bool isLaptop: false
  property string chassis: "unknown"
  property string lastEvent: "starting"
  property string lastEventAt: ""
  property string processError: ""
  property string stayAwakeError: ""
  readonly property string lastError: configuration.error || stayAwakeError || processError
  property bool stayAwakeStateKnown: false
  property bool stayAwakeObserved: false
  property bool lastStayAwake: false

  function nowIso() {
    return new Date().toISOString()
  }

  function logEvent(event, details) {
    var suffix = details ? ": " + String(details) : ""
    root.lastEventAt = nowIso()
    root.lastEvent = event + suffix
    console.log("foamy.idle-suspend " + root.lastEventAt + " " + root.lastEvent)
  }

  function requestSuspend(source) {
    var expectedSource = UPower.onBattery ? "battery" : "ac"
    var monitor = source === "battery" ? batteryMonitor : acMonitor
    if (!root.suspendAllowed || source !== expectedSource || !monitor.enabled || !monitor.isIdle) {
      logEvent("suspend-skipped", source + " current=" + expectedSource)
      return
    }
    if (suspendProcess.running) {
      logEvent("suspend-skipped", "request already running")
      return
    }

    root.processError = ""
    suspendProcess.command = ["systemctl", root.policy.suspendAction]
    logEvent("suspend-request", source + " " + root.policy.suspendAction)
    suspendProcess.running = true
  }

  function syncStayAwakeNotification(stayAwake) {
    // Establish the startup baseline without presenting persisted state as a
    // fresh user action after every shell restart.
    if (!root.stayAwakeObserved) {
      root.lastStayAwake = stayAwake
      root.stayAwakeObserved = true
      return
    }
    if (root.lastStayAwake === stayAwake) return

    root.lastStayAwake = stayAwake
    Quickshell.execDetached([
      "notify-send", "-a", "omarchy-action", "-u", "low",
      "-h", "boolean:transient:true",
      "-h", "string:omarchy-glyph:" + (stayAwake ? "󰅶" : "󰾪"),
      stayAwake ? "Stay awake enabled" : "Stay awake disabled",
      stayAwake
        ? "Idle lock and screensaver are paused"
        : "Idle lock and screensaver are restored"
    ])
  }

  function statusJson() {
    return JSON.stringify({
      enabled: batteryMonitor.enabled || acMonitor.enabled,
      configPath: root.configPath,
      configValid: root.configuration.valid,
      policy: root.policy,
      chassis: root.chassis,
      chassisLoaded: root.chassisLoaded,
      isLaptop: root.isLaptop,
      onBattery: UPower.onBattery,
      stayAwake: root.stayAwakeStateKnown ? root.lastStayAwake : null,
      batteryTimeout: root.batteryTimeoutSeconds,
      monitors: {
        batteryEnabled: batteryMonitor.enabled,
        batteryIdle: batteryMonitor.isIdle,
        acEnabled: acMonitor.enabled,
        acIdle: acMonitor.isIdle
      },
      suspendRunning: suspendProcess.running,
      lastEvent: root.lastEvent,
      lastEventAt: root.lastEventAt,
      lastError: root.lastError
    })
  }

  IdleMonitor {
    id: batteryMonitor
    enabled: root.suspendAllowed && UPower.onBattery && root.batteryTimeoutSeconds !== null
    timeout: root.batteryTimeoutSeconds === null ? 1 : root.batteryTimeoutSeconds
    respectInhibitors: true
    onIsIdleChanged: if (isIdle) root.requestSuspend("battery")
  }

  IdleMonitor {
    id: acMonitor
    enabled: root.suspendAllowed && !UPower.onBattery && root.acTimeoutSeconds !== null
    timeout: root.acTimeoutSeconds === null ? 1 : root.acTimeoutSeconds
    respectInhibitors: true
    onIsIdleChanged: if (isIdle) root.requestSuspend("ac")
  }

  // Third-party service APIs do not expose plugins[] entries. Watch the same
  // file as the stock shell so edits apply without private host access.
  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: {
      root.configuration = { valid: false, settings: Policy.defaults(), error: "Reloading shell.json" }
      reload()
    }
    onLoaded: {
      root.configuration = Policy.parseConfig(text())
      root.logEvent(root.configuration.valid ? "config-ready" : "config-error", root.configuration.error)
    }
    onLoadFailed: {
      root.configuration = { valid: false, settings: Policy.defaults(), error: "Cannot read " + root.configPath }
      root.logEvent("config-error", root.configuration.error)
    }
  }

  // Use Omarchy's persisted state rather than a restricted cross-plugin API.
  function refreshStayAwakeState() {
    if (stayAwakeProbe.running) {
      root.stateRefreshPending = true
      return
    }
    root.stateRefreshPending = false
    // Do not act on stale Stay awake state while a refresh is in flight.
    root.stayAwakeStateKnown = false
    stayAwakeProbe.running = true
  }

  FileView {
    id: stayAwakeWatcher
    path: root.stayAwakeStateDir
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshStayAwakeState()
  }

  Process {
    id: stayAwakeProbe
    command: ["omarchy", "toggle", "idle", "status"]
    stdout: StdioCollector { id: awakeOutput; waitForEnd: true }
    onExited: function(exitCode) {
      try {
        if (exitCode !== 0) throw new Error("idle status exited " + exitCode)
        var state = JSON.parse(awakeOutput.text)
        if (typeof state.enabled !== "boolean") throw new Error("idle status missing enabled")
        root.syncStayAwakeNotification(state.enabled)
        root.stayAwakeError = ""
        root.stayAwakeStateKnown = true
      } catch (error) {
        root.stayAwakeStateKnown = false
        root.stayAwakeError = String(error)
        root.logEvent("idle-state-error", root.stayAwakeError)
      }
      stayAwakeWatcher.reload()
      // A change while the read was running needs another read of current state.
      if (root.stateRefreshPending) root.refreshStayAwakeState()
    }
  }

  Process {
    id: chassisProbe
    command: ["hostnamectl", "chassis"]
    stdout: StdioCollector {
      id: chassisOutput
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: chassisError
      waitForEnd: true
    }
    onExited: function(exitCode, exitStatus) {
      root.chassis = String(chassisOutput.text || "").trim() || "unknown"
      root.isLaptop = exitCode === 0 && root.chassis === "laptop"
      root.chassisLoaded = true
      if (exitCode !== 0) {
        root.processError = String(chassisError.text || "hostnamectl chassis failed").trim()
        root.logEvent("chassis-error", root.processError)
      } else {
        root.logEvent("chassis-ready", root.chassis)
      }
    }
  }

  Process {
    id: suspendProcess
    stderr: StdioCollector {
      id: suspendError
      waitForEnd: true
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) {
        root.processError = String(suspendError.text || "systemctl " + command[1] + " failed").trim()
        root.logEvent("suspend-error", root.processError)
      } else {
        root.logEvent("resume", "suspend request completed")
      }
    }
  }

  Component.onCompleted: {
    logEvent("service-ready")
    chassisProbe.running = true
    refreshStayAwakeState()
  }

  IpcHandler {
    target: "foamy.idle-suspend"

    function status(): string {
      return root.statusJson()
    }

    function debug(): string {
      return root.statusJson()
    }
  }
}
