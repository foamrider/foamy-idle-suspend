import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.UPower
import Quickshell.Wayland
import "kit"
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
  readonly property bool sleepActive: Policy.active(policy, configuration.valid, chassisLoaded, isLaptop)
  readonly property bool mediaPlaying: Policy.mediaPlaying(Mpris.players.values)

  // logind's answer per action ("yes", "challenge", "no", "na"); empty until probed.
  property var actionSupport: ({})
  readonly property var actionChoice: Policy.chooseAction(policy.suspendAction, actionSupport)
  readonly property string effectiveAction: actionChoice.action

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

  // One sleep attempt at a time: checking inhibitors, locking, suspending.
  property string phase: "idle"
  property string attemptSource: ""
  property string deferredReason: ""
  property string lastLockResult: ""
  property string blockInhibited: ""
  property int failureStreak: 0
  // Failure notifications are shown once per idle period.
  property var notified: ({})
  property string fallbackNotified: ""
  readonly property int retryBaseMs: 60000

  function nowIso() {
    return new Date().toISOString()
  }

  function logEvent(event, details) {
    var suffix = details ? ": " + String(details) : ""
    root.lastEventAt = nowIso()
    root.lastEvent = event + suffix
    console.log("foamy.idle-suspend " + root.lastEventAt + " " + root.lastEvent)
  }

  function currentSource() {
    return UPower.onBattery ? "battery" : "ac"
  }

  function monitorFor(source) {
    return source === "battery" ? batteryMonitor : acMonitor
  }

  // Everything that must still hold right before each step of an attempt.
  function stillIdle(source) {
    var monitor = monitorFor(source)
    return root.suspendAllowed && source === currentSource() && monitor.enabled && monitor.isIdle
  }

  function notifyOnce(key, title, body, urgency) {
    if (notified[key]) return
    var next = {}
    for (var name in notified) next[name] = true
    next[key] = true
    notified = next
    Quickshell.execDetached([
      "notify-send", "-a", "Foamy Idle Suspend", "-u", urgency || "normal",
      "-h", "string:omarchy-glyph:󰒲", title, body
    ])
  }

  function requestSuspend(source) {
    if (!stillIdle(source)) {
      logEvent("suspend-skipped", source + " current=" + currentSource())
      return
    }
    if (root.phase !== "idle") {
      logEvent("suspend-skipped", "request already running")
      return
    }
    if (!root.effectiveAction) {
      root.processError = "No sleep action is available on this system"
      logEvent("suspend-unavailable", root.policy.suspendAction)
      notifyOnce("unavailable", FoamyI18n.t("Sleep isn't available"),
        FoamyI18n.t("This computer reports that it can't suspend, so automatic sleep is off."))
      return
    }
    if (root.policy.pauseForMedia && root.mediaPlaying) {
      // Retried as soon as playback stops while still idle.
      root.deferredReason = "media-playing"
      logEvent("suspend-deferred", "media playing")
      return
    }
    root.deferredReason = ""
    root.attemptSource = source
    root.phase = "checking"
    inhibitorProbe.running = true
  }

  function afterInhibitorCheck(text) {
    var source = root.attemptSource
    var value = ""
    try { value = String(JSON.parse(text).data || "") } catch (error) { value = "" }
    root.blockInhibited = value
    if (!stillIdle(source)) return finishAttempt("suspend-skipped", "activity during checks")
    if (Policy.blockedByInhibitor(value)) {
      root.deferredReason = "inhibited"
      finishAttempt("suspend-deferred", "logind inhibitor: " + value)
      scheduleRetry()
      return
    }
    if (root.policy.lockBeforeSuspend) {
      root.phase = "locking"
      lockProcess.running = true
    } else {
      runSuspend()
    }
  }

  function afterLock(result) {
    root.lastLockResult = result
    var source = root.attemptSource
    if (result === "secure") {
      if (!stillIdle(source)) return finishAttempt("suspend-skipped", "activity while locking")
      runSuspend()
      return
    }
    // Defense in depth: never sleep with the session exposed. The user is
    // told, and the attempt repeats while the computer stays idle.
    root.failureStreak += 1
    root.processError = "The screen did not lock (" + result + ")"
    finishAttempt("lock-failed", result)
    notifyOnce("lock-failed", FoamyI18n.t("Screen didn't lock"),
      FoamyI18n.t("Automatic sleep was skipped because the screen couldn't be locked. It tries again while the computer stays idle."), "critical")
    scheduleRetry()
  }

  function runSuspend() {
    root.phase = "suspending"
    root.processError = ""
    suspendProcess.command = ["systemctl", root.effectiveAction]
    logEvent("suspend-request", root.attemptSource + " " + root.effectiveAction)
    suspendProcess.running = true
  }

  function afterSuspend(exitCode, errorText) {
    if (exitCode !== 0) {
      root.failureStreak += 1
      root.processError = String(errorText || "systemctl " + root.effectiveAction + " failed").trim()
      finishAttempt("suspend-error", root.processError)
      notifyOnce("suspend-failed", FoamyI18n.t("Automatic sleep failed"),
        FoamyI18n.t("%1. It tries again while the computer stays idle.", root.processError.replace(/[.\s]+$/, "")))
      // The action may have stopped being available (swap removed, …).
      probeActions()
    } else {
      root.failureStreak = 0
      finishAttempt("resume", "suspend request completed")
    }
    // A wake without input (RTC, USB, lid) can leave the compositor idle:
    // ask again later instead of waiting for activity that never comes.
    scheduleRetry()
  }

  function finishAttempt(event, details) {
    root.phase = "idle"
    logEvent(event, details)
  }

  function scheduleRetry() {
    retryTimer.interval = Policy.retryDelayMs(root.failureStreak, root.retryBaseMs)
    retryTimer.restart()
  }

  function activityResumed() {
    if (batteryMonitor.isIdle || acMonitor.isIdle) return
    retryTimer.stop()
    root.failureStreak = 0
    root.deferredReason = ""
    root.notified = ({})
  }

  function probeActions() {
    if (!actionProbe.running) actionProbe.running = true
  }

  function applyActionProbe(text) {
    var answers = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var space = lines[i].indexOf(" ")
      if (space < 0) continue
      var method = lines[i].slice(0, space)
      var answer = ""
      try { answer = String(JSON.parse(lines[i].slice(space + 1)).data[0] || "") } catch (error) { answer = "" }
      for (var a = 0; a < Policy.ACTIONS.length; a++) {
        if (Policy.CAN_METHODS[Policy.ACTIONS[a]] === method && answer) answers[Policy.ACTIONS[a]] = answer
      }
    }
    root.actionSupport = answers
    logEvent("actions", JSON.stringify(answers))
  }

  onActionChoiceChanged: {
    if (!actionChoice.fallback || !sleepActive || fallbackNotified === policy.suspendAction) return
    fallbackNotified = policy.suspendAction
    logEvent("action-fallback", policy.suspendAction + " unavailable, using suspend")
    Quickshell.execDetached([
      "notify-send", "-a", "Foamy Idle Suspend", "-u", "normal", "-h", "string:omarchy-glyph:󰒲",
      FoamyI18n.t("%1 isn't available", policy.suspendAction),
      FoamyI18n.t("Automatic sleep uses suspend instead. Set up hibernation or choose another suspendAction.")
    ])
  }

  onMediaPlayingChanged: {
    if (mediaPlaying || deferredReason !== "media-playing") return
    deferredReason = ""
    var source = currentSource()
    if (monitorFor(source).isIdle) requestSuspend(source)
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
    // Only where this plugin would put the computer to sleep.
    if (!root.sleepActive) return
    Quickshell.execDetached([
      "notify-send", "-a", "omarchy-action", "-u", "low",
      "-h", "boolean:transient:true",
      "-h", "string:omarchy-glyph:" + (stayAwake ? "󰅶" : "󰾪"),
      stayAwake ? FoamyI18n.t("Stay awake enabled") : FoamyI18n.t("Stay awake disabled"),
      stayAwake
        ? FoamyI18n.t("Automatic sleep is paused")
        : FoamyI18n.t("Automatic sleep is back on")
    ])
  }

  function statusJson() {
    return JSON.stringify({
      enabled: batteryMonitor.enabled || acMonitor.enabled,
      configPath: root.configPath,
      configValid: root.configuration.valid,
      policy: root.policy,
      effectiveAction: root.effectiveAction,
      actionFallback: root.actionChoice.fallback,
      actionSupport: root.actionSupport,
      chassis: root.chassis,
      chassisLoaded: root.chassisLoaded,
      isLaptop: root.isLaptop,
      onBattery: UPower.onBattery,
      stayAwake: root.stayAwakeStateKnown ? root.lastStayAwake : null,
      batteryTimeout: root.batteryTimeoutSeconds,
      mediaPlaying: root.mediaPlaying,
      monitors: {
        batteryEnabled: batteryMonitor.enabled,
        batteryIdle: batteryMonitor.isIdle,
        acEnabled: acMonitor.enabled,
        acIdle: acMonitor.isIdle
      },
      phase: root.phase,
      suspendRunning: suspendProcess.running,
      deferredReason: root.deferredReason,
      blockInhibited: root.blockInhibited,
      lastLockResult: root.lastLockResult,
      failureStreak: root.failureStreak,
      retryScheduled: retryTimer.running,
      retryInMs: retryTimer.running ? retryTimer.interval : null,
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
    onIsIdleChanged: isIdle ? root.requestSuspend("battery") : root.activityResumed()
  }

  IdleMonitor {
    id: acMonitor
    enabled: root.suspendAllowed && !UPower.onBattery && root.acTimeoutSeconds !== null
    timeout: root.acTimeoutSeconds === null ? 1 : root.acTimeoutSeconds
    respectInhibitors: true
    onIsIdleChanged: isIdle ? root.requestSuspend("ac") : root.activityResumed()
  }

  // Retries while the computer stays idle: after a failed or deferred
  // attempt, and after a wake that brought no input.
  Timer {
    id: retryTimer
    repeat: false
    onTriggered: {
      var source = root.currentSource()
      if (root.monitorFor(source).isIdle) root.requestSuspend(source)
    }
  }

  function applyConfiguration(next) {
    // Keep the current object when nothing effective changed, so the idle
    // monitors keep counting through unrelated shell.json writes.
    if (Policy.sameConfiguration(root.configuration, next)) return
    var actionChanged = next.settings.suspendAction !== root.policy.suspendAction
    root.configuration = next
    root.logEvent(next.valid ? "config-ready" : "config-error", next.error)
    if (actionChanged) probeActions()
  }

  // Third-party service APIs do not expose plugins[] entries. Watch the same
  // file as the stock shell so edits apply without private host access.
  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    // The last configuration stays in force while the file is re-read.
    onFileChanged: reload()
    onLoaded: root.applyConfiguration(Policy.parseConfig(text()))
    onLoadFailed: root.applyConfiguration({ valid: false, settings: Policy.defaults(), error: "Cannot read " + root.configPath })
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

  // Which sleep actions logind can run. Hibernation needs setup that stock
  // Omarchy only does on request, so suspend-then-hibernate is often "na".
  Process {
    id: actionProbe
    command: ["timeout", "--kill-after=1s", "5s", "bash", "-c",
      'for m in CanSuspend CanHibernate CanHybridSleep CanSuspendThenHibernate; do printf "%s " "$m"; busctl --system --json=short call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager "$m" 2>/dev/null || echo "{}"; done']
    stdout: StdioCollector { id: actionOutput; waitForEnd: true }
    onExited: root.applyActionProbe(actionOutput.text)
  }

  // Applications that hold a logind "idle" or "sleep" block inhibitor
  // (systemd-inhibit, GNOME/KDE apps) keep the computer awake.
  Process {
    id: inhibitorProbe
    command: ["timeout", "--kill-after=1s", "3s", "busctl", "--system", "--json=short", "get-property",
      "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "BlockInhibited"]
    stdout: StdioCollector { id: inhibitorOutput; waitForEnd: true }
    onExited: root.afterInhibitorCheck(inhibitorOutput.text)
  }

  // Lock through the public lock interface (foamy.lock or the stock lock) and
  // wait for ext-session-lock to report the session secure, like Omarchy's
  // pre-suspend omarchy-system-sleep-lock does. Prints secure, missing-pam
  // or timeout.
  Process {
    id: lockProcess
    command: ["timeout", "--kill-after=1s", "12s", "bash", "-c",
      'request() { case $(timeout --kill-after=0.2s 2s omarchy-shell lock lock 2>/dev/null) in missing-pam) echo missing-pam; exit 3;; esac; }; '
      + 'request; '
      + 'for _ in $(seq 1 40); do '
      + 'state=$(timeout --kill-after=0.2s 1s omarchy-shell lock status 2>/dev/null | jq -r \'if .secure == true then "secure" elif .requested == true then "locking" else "idle" end\' 2>/dev/null); '
      + 'case $state in secure) echo secure; exit 0;; locking) ;; *) request;; esac; '
      + 'sleep 0.2; done; echo timeout; exit 4']
    stdout: StdioCollector { id: lockOutput; waitForEnd: true }
    onExited: function(exitCode) {
      var result = String(lockOutput.text || "").trim().split("\n").pop()
      root.afterLock(exitCode === 0 && result === "secure" ? "secure" : (result || "timeout"))
    }
  }

  Process {
    id: suspendProcess
    stderr: StdioCollector {
      id: suspendError
      waitForEnd: true
    }
    onExited: function(exitCode, exitStatus) {
      root.afterSuspend(exitCode, suspendError.text)
    }
  }

  Component.onCompleted: {
    logEvent("service-ready")
    chassisProbe.running = true
    probeActions()
    refreshStayAwakeState()
  }

  FoamyIpc {
    target: "foamy.idle-suspend"

    function status(): string {
      return root.statusJson()
    }

    function debug(): string {
      return root.statusJson()
    }
  }
}
