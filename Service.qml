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

  property var configuration: ({
      valid: false,
      settings: Policy.defaults(),
      error: "Loading shell.json"
    })
  readonly property var policy: configuration.settings
  readonly property var batteryTimeoutSeconds: policy.batteryTimeoutSec
  readonly property var acTimeoutSeconds: policy.acTimeoutSec
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
  readonly property string stayAwakeStateDir: Quickshell.env("HOME") + "/.local/state/omarchy/indicators"
  readonly property bool idleEnabled: stayAwakeStateKnown && !lastStayAwake
  property bool stateRefreshPending: false
  // Deadline for `omarchy toggle idle status` (it normally answers in tens
  // of milliseconds); a hung read would otherwise keep sleep off silently.
  readonly property int stayAwakeTimeoutSec: 5
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
  // The last logind inhibitor check that failed; cleared by the next good one.
  property string inhibitorError: ""
  readonly property string lastError: configuration.error || stayAwakeError || inhibitorError || processError
  property bool stayAwakeStateKnown: false
  property bool stayAwakeObserved: false
  property bool lastStayAwake: false

  // One sleep attempt at a time: probing sleep actions, checking inhibitors,
  // locking, rechecking inhibitors, suspending.
  property string phase: "idle"
  property string attemptSource: ""
  // An idle request from the other power source that arrived while an
  // attempt was running; its monitor fires only once, so it is kept.
  property string pendingSource: ""
  property string deferredReason: ""
  property string lastLockResult: ""
  property string blockInhibited: ""
  property int failureStreak: 0
  // Failure notifications are shown once per idle period.
  property var notified: ({})
  // "Sleep isn't available" describes the machine, not one idle period:
  // shown once per configuration (see applyConfiguration).
  property bool unavailableNotified: false
  property string fallbackNotified: ""
  readonly property int retryBaseMs: 60000
  // How long systemctl may take to hand the sleep request to logind; it
  // normally returns within a second or two (see suspendWatchdog).
  readonly property int suspendWatchdogMs: 60000
  // The sleep request in flight: suspendProcess's exit, its failure to start
  // and the watchdog each settle it, and only the first one counts.
  property bool suspendPending: false
  property int suspendAttempts: 0
  property double suspendStartedAt: 0

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
    if (notified[key])
      return
    var next = {}
    for (const name in notified)
      next[name] = true
    next[key] = true
    notified = next
    Quickshell.execDetached(["notify-send", "-a", "Foamy Idle Suspend", "-u", urgency || "normal", "-h", "string:omarchy-glyph:\u{f04b2}", title, body])
  }

  function requestSuspend(source) {
    if (!stillIdle(source)) {
      logEvent("suspend-skipped", source + " current=" + currentSource())
      return
    }
    if (root.phase !== "idle") {
      // A repeat for the same source is redundant; a request for the other
      // source (power changed mid-attempt) runs once this attempt ends.
      if (source !== root.attemptSource)
        root.pendingSource = source
      logEvent("suspend-skipped", "request already running")
      return
    }
    if (deferForMedia())
      return finishAttempt("suspend-deferred", "media playing")
    root.deferredReason = ""
    root.attemptSource = source
    // Ask logind again on every attempt: swap and hibernation can change
    // between attempts, and "auto" follows them.
    root.phase = "probing"
    probeActions()
  }

  function afterActionProbe() {
    var source = root.attemptSource
    if (!stillIdle(source))
      return finishAttempt("suspend-skipped", "activity during checks")
    if (!root.effectiveAction) {
      root.processError = "No sleep action is available on this system"
      finishAttempt("suspend-unavailable", root.policy.suspendAction)
      if (root.unavailableNotified)
        return
      root.unavailableNotified = true
      notifyOnce("unavailable", FoamyI18n.t("Sleep isn't available"), FoamyI18n.t("This computer reports that it can't suspend, so automatic sleep is off."))
      return
    }
    root.phase = "checking"
    checkInhibitors()
  }

  // Media can start (remote control, a timer) while the asynchronous checks
  // or the lock run, so every step re-checks it. The deferral is retried as
  // soon as playback stops while still idle (onMediaPlayingChanged).
  function deferForMedia() {
    if (!root.policy.pauseForMedia || !root.mediaPlaying)
      return false
    root.deferredReason = "media-playing"
    return true
  }

  // Reset before the start, like the other probes: a start that fails may
  // never report running, so exitSeen can't be reset from runningChanged.
  function checkInhibitors() {
    inhibitorProbe.exitSeen = false
    inhibitorProbe.running = true
  }

  function afterInhibitorCheck(exitCode, text, errorText) {
    var source = root.attemptSource
    var check = Policy.readBlockInhibited(exitCode, text, errorText)
    root.blockInhibited = check.value
    root.inhibitorError = check.ok ? "" : "Couldn't check logind inhibitors: " + check.error
    if (!stillIdle(source))
      return finishAttempt("suspend-skipped", "activity during checks")
    if (deferForMedia())
      return finishAttempt("suspend-deferred", "media playing")
    // Unknown is not "none": an idle inhibitor (systemd-inhibit around a
    // backup) is only honored here, logind doesn't enforce it for suspend.
    if (!check.ok) {
      root.deferredReason = "inhibitor-check-failed"
      finishAttempt("suspend-deferred", root.inhibitorError)
      scheduleRetry()
      return
    }
    if (Policy.blockedByInhibitor(check.value)) {
      root.deferredReason = "inhibited"
      finishAttempt("suspend-deferred", "logind inhibitor: " + check.value)
      scheduleRetry()
      return
    }
    // The second check runs after locking, right before sleeping: an
    // inhibitor taken while the lock was coming up still keeps us awake.
    if (root.phase === "rechecking") {
      runSuspend()
    } else if (root.policy.lockBeforeSuspend) {
      root.phase = "locking"
      // Reset before the start: a start that fails never reports running.
      lockProcess.exitSeen = false
      lockProcess.running = true
    } else {
      runSuspend()
    }
  }

  function afterLock(result) {
    root.lastLockResult = result
    var source = root.attemptSource
    if (result === "secure") {
      if (!stillIdle(source))
        return finishAttempt("suspend-skipped", "activity while locking")
      if (deferForMedia())
        return finishAttempt("suspend-deferred", "media playing")
      root.phase = "rechecking"
      checkInhibitors()
      return
    }
    // Defense in depth: never sleep with the session exposed. The user is
    // told, and the attempt repeats while the computer stays idle.
    root.failureStreak += 1
    root.processError = "The screen did not lock (" + result + ")"
    finishAttempt("lock-failed", result)
    notifyOnce("lock-failed", FoamyI18n.t("Screen didn't lock"), FoamyI18n.t("Automatic sleep was skipped because the screen couldn't be locked. It tries again while the computer stays idle."), "critical")
    scheduleRetry()
  }

  function runSuspend() {
    // Last synchronous check before the sleep command.
    if (!stillIdle(root.attemptSource))
      return finishAttempt("suspend-skipped", "activity before sleep")
    if (deferForMedia())
      return finishAttempt("suspend-deferred", "media playing")
    root.phase = "suspending"
    root.processError = ""
    // No polkit prompt: logind can answer "challenge" (a sleep inhibitor
    // taken just now, site rules), and a password dialog behind the lock
    // would wait for nobody until the watchdog. Without it the request fails
    // at once and is reported and retried like any other failure.
    suspendProcess.command = ["systemctl", "--no-ask-password", root.effectiveAction]
    logEvent("suspend-request", root.attemptSource + " " + root.effectiveAction)
    root.suspendAttempts += 1
    suspendProcess.attempt = root.suspendAttempts
    root.suspendPending = true
    root.suspendStartedAt = Date.now()
    suspendWatchdog.restart()
    suspendProcess.running = true
  }

  // The one way a sleep request ends; later calls for the same attempt
  // (runningChanged after exited, the exit of a request the watchdog
  // stopped) find nothing pending.
  function settleSuspend(attempt, exitCode, errorText) {
    if (!root.suspendPending || attempt !== root.suspendAttempts)
      return
    root.suspendPending = false
    suspendWatchdog.stop()
    afterSuspend(exitCode, errorText)
  }

  function afterSuspend(exitCode, errorText) {
    if (exitCode !== 0) {
      root.failureStreak += 1
      root.processError = String(errorText || "systemctl " + root.effectiveAction + " failed").trim()
      finishAttempt("suspend-error", root.processError)
      notifyOnce("suspend-failed", FoamyI18n.t("Automatic sleep failed"), FoamyI18n.t("%1. It tries again while the computer stays idle.", root.processError.replace(/[.\s]+$/, "")))
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
    var pending = root.pendingSource
    root.pendingSource = ""
    if (pending && pending === currentSource())
      Qt.callLater(resumeIfIdle)
  }

  // Start an attempt for the current power source if it is idle and nothing
  // is running; requestSuspend re-checks everything else.
  function resumeIfIdle() {
    var source = currentSource()
    if (root.phase === "idle" && monitorFor(source).isIdle)
      requestSuspend(source)
  }

  function scheduleRetry() {
    retryTimer.interval = Policy.retryDelayMs(root.failureStreak, root.retryBaseMs)
    retryTimer.restart()
  }

  function activityResumed() {
    if (batteryMonitor.isIdle || acMonitor.isIdle)
      return
    retryTimer.stop()
    root.failureStreak = 0
    root.deferredReason = ""
    root.notified = ({})
  }

  function probeActions() {
    if (actionProbe.running)
      return
    // Reset before the start: a start that fails never reports running.
    actionProbe.exitSeen = false
    actionProbe.running = true
  }

  // The probe's one way to end: its exit, or a start that failed.
  function afterActionProbeRun(text) {
    root.applyActionProbe(text)
    if (root.phase === "probing")
      root.afterActionProbe()
  }

  function applyActionProbe(text) {
    root.actionSupport = Policy.parseActionSupport(text)
    logEvent("actions", JSON.stringify(root.actionSupport))
  }

  onActionChoiceChanged: {
    if (!actionChoice.fallback || !sleepActive || fallbackNotified === policy.suspendAction)
      return
    fallbackNotified = policy.suspendAction
    logEvent("action-fallback", policy.suspendAction + " unavailable, using suspend")
    Quickshell.execDetached(["notify-send", "-a", "Foamy Idle Suspend", "-u", "normal", "-h", "string:omarchy-glyph:\u{f04b2}", FoamyI18n.t("%1 isn't available", policy.suspendAction), FoamyI18n.t("Automatic sleep uses suspend instead. Set up hibernation, or set suspendAction to auto.")])
  }

  onMediaPlayingChanged: {
    if (mediaPlaying || deferredReason !== "media-playing" || phase !== "idle")
      return
    deferredReason = ""
    var source = currentSource()
    if (monitorFor(source).isIdle)
      requestSuspend(source)
  }

  function syncStayAwakeNotification(stayAwake) {
    // Establish the startup baseline without presenting persisted state as a
    // fresh user action after every shell restart.
    if (!root.stayAwakeObserved) {
      root.lastStayAwake = stayAwake
      root.stayAwakeObserved = true
      return
    }
    if (root.lastStayAwake === stayAwake)
      return
    root.lastStayAwake = stayAwake
    // Only where this plugin would put the computer to sleep.
    if (!root.sleepActive)
      return
    Quickshell.execDetached(["notify-send", "-a", "omarchy-action", "-u", "low", "-h", "boolean:transient:true", "-h", "string:omarchy-glyph:" + (stayAwake ? "\u{f0176}" : "\u{f0faa}"), stayAwake ? FoamyI18n.t("Stay awake enabled") : FoamyI18n.t("Stay awake disabled"), stayAwake ? FoamyI18n.t("Automatic sleep is paused") : FoamyI18n.t("Automatic sleep is back on")])
  }

  function statusJson() {
    return JSON.stringify({
      enabled: batteryMonitor.enabled || acMonitor.enabled,
      configPath: root.configPath,
      configValid: root.configuration.valid,
      // Entry keys that aren't settings (a typo keeps that setting's default).
      unknownKeys: root.configuration.unknownKeys || [],
      policy: root.policy,
      effectiveAction: root.effectiveAction,
      // What "auto" resolved to at the last probe (null for explicit actions).
      autoAction: root.policy.suspendAction === "auto" ? root.effectiveAction : null,
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
      if (root.monitorFor(source).isIdle)
        root.requestSuspend(source)
    }
  }

  function applyConfiguration(next) {
    // Keep the current object when nothing effective changed, so the idle
    // monitors keep counting through unrelated shell.json writes.
    if (Policy.sameConfiguration(root.configuration, next))
      return
    var actionChanged = next.settings.suspendAction !== root.policy.suspendAction
    root.configuration = next
    root.unavailableNotified = false
    root.logEvent(next.valid ? "config-ready" : "config-error", next.error)
    if (next.unknownKeys && next.unknownKeys.length)
      root.logEvent("config-unknown-keys", next.unknownKeys.join(", "))
    if (actionChanged)
      probeActions()
    // A deferred attempt has no idle transition left to wake it; re-evaluate
    // it under the new settings (for example pauseForMedia turned off).
    if (root.deferredReason !== "")
      Qt.callLater(resumeIfIdle)
  }

  // A tool that rewrites shell.json in place (truncate, then write, as with
  // `jq … > shell.json`) can be read half-done; the shell itself writes
  // atomically. Text that isn't JSON at all keeps the configuration in force
  // and is read once more after configRereadMs; only an unreadable re-read
  // applies the error. A complete but invalid entry applies at once.
  readonly property int configRereadMs: 250
  property bool configReread: false

  function configLoaded(text) {
    var next = Policy.parseConfig(text)
    if (!next.valid && !Policy.parsesAsJson(text) && !root.configReread) {
      if (!configRereadTimer.running) {
        root.logEvent("config-partial", "reading shell.json again in " + root.configRereadMs + " ms")
        configRereadTimer.restart()
      }
      return
    }
    configRereadTimer.stop()
    root.configReread = false
    root.applyConfiguration(next)
  }

  Timer {
    id: configRereadTimer
    interval: root.configRereadMs
    repeat: false
    onTriggered: {
      root.configReread = true
      configFile.reload()
    }
  }

  // The scoped service API can write this plugin's plugins[] entry
  // (shell.updateEntryInline) but offers no way to read it. Watch the same
  // file as the stock shell so edits apply without private host access.
  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    // The last configuration stays in force while the file is re-read.
    onFileChanged: reload()
    onLoaded: root.configLoaded(text())
    onLoadFailed: {
      configRereadTimer.stop()
      root.configReread = false
      root.applyConfiguration({
        valid: false,
        settings: Policy.defaults(),
        error: "Cannot read " + root.configPath,
        unknownKeys: []
      })
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
    stayAwakeProbe.exitSeen = false
    stayAwakeProbe.running = true
  }

  // A Stay awake read that failed: sleep stays off until a read succeeds.
  function stayAwakeFailed(message) {
    root.stayAwakeStateKnown = false
    root.stayAwakeError = message
    root.logEvent("idle-state-error", root.stayAwakeError)
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
    property bool exitSeen: false
    command: ["timeout", "--kill-after=1s", root.stayAwakeTimeoutSec + "s", "omarchy", "toggle", "idle", "status"]
    stdout: StdioCollector {
      id: awakeOutput
      waitForEnd: true
    }
    onExited: function (exitCode) {
      stayAwakeProbe.exitSeen = true
      // timeout's own codes: 124/137 the deadline, 126/127 omarchy couldn't run.
      if (exitCode === 124 || exitCode === 137) {
        root.stayAwakeFailed("omarchy toggle idle status didn't finish within " + root.stayAwakeTimeoutSec + " seconds")
      } else if (exitCode === 126 || exitCode === 127) {
        root.stayAwakeFailed("omarchy toggle idle status couldn't start")
      } else {
        try {
          if (exitCode !== 0)
            throw new Error("idle status exited " + exitCode)
          const state = JSON.parse(awakeOutput.text)
          if (typeof state.enabled !== "boolean")
            throw new Error("idle status missing enabled")
          root.syncStayAwakeNotification(state.enabled)
          root.stayAwakeError = ""
          root.stayAwakeStateKnown = true
        } catch (error) {
          root.stayAwakeFailed(String(error))
        }
      }
      stayAwakeWatcher.reload()
      // A change while the read was running needs another read of current state.
      if (root.stateRefreshPending)
        root.refreshStayAwakeState()
    }
    // Not running without an exit: `timeout` couldn't start (no exited()).
    onRunningChanged: {
      if (running || exitSeen)
        return
      exitSeen = true
      root.stayAwakeFailed("omarchy toggle idle status couldn't start")
      stayAwakeWatcher.reload()
      if (root.stateRefreshPending)
        root.refreshStayAwakeState()
    }
  }

  function chassisRead(exitCode, text, errorText) {
    root.chassis = String(text || "").trim() || "unknown"
    root.isLaptop = exitCode === 0 && root.chassis === "laptop"
    root.chassisLoaded = true
    if (exitCode !== 0) {
      root.processError = String(errorText || "hostnamectl chassis failed").trim()
      root.logEvent("chassis-error", root.processError)
    } else {
      root.logEvent("chassis-ready", root.chassis)
    }
  }

  Process {
    id: chassisProbe
    property bool exitSeen: false
    command: ["hostnamectl", "chassis"]
    stdout: StdioCollector {
      id: chassisOutput
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: chassisError
      waitForEnd: true
    }
    onExited: function (exitCode, exitStatus) {
      chassisProbe.exitSeen = true
      root.chassisRead(exitCode, chassisOutput.text, chassisError.text)
    }
    // Not running without an exit: hostnamectl couldn't start. Not a laptop
    // as far as we know, like a failed hostnamectl.
    onRunningChanged: {
      if (running || exitSeen)
        return
      exitSeen = true
      root.chassisRead(-1, "", "hostnamectl chassis couldn't start")
    }
  }

  // Which sleep actions logind can run. Hibernation needs setup that stock
  // Omarchy only does on request, so suspend-then-hibernate is often "na".
  Process {
    id: actionProbe
    property bool exitSeen: false
    command: ["timeout", "--kill-after=1s", "5s", "bash", "-c", 'for m in CanSuspend CanHibernate CanHybridSleep CanSuspendThenHibernate; do printf "%s " "$m"; busctl --system --json=short call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager "$m" 2>/dev/null || echo "{}"; done']
    stdout: StdioCollector {
      id: actionOutput
      waitForEnd: true
    }
    onExited: {
      actionProbe.exitSeen = true
      root.afterActionProbeRun(actionOutput.text)
    }
    // Not running without an exit: the probe couldn't start (no exited()).
    // No answer for any action, like a failed busctl call inside the probe:
    // the attempt goes on and systemctl decides, instead of waiting at
    // "probing" for good.
    onRunningChanged: {
      if (running || exitSeen)
        return
      exitSeen = true
      root.logEvent("actions-error", "the action probe couldn't start")
      root.afterActionProbeRun("")
    }
  }

  // Applications that hold a logind "idle" or "sleep" block inhibitor
  // (systemd-inhibit, GNOME/KDE apps) keep the computer awake.
  Process {
    id: inhibitorProbe
    property bool exitSeen: false
    command: ["timeout", "--kill-after=1s", "3s", "busctl", "--system", "--json=short", "get-property", "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "BlockInhibited"]
    stdout: StdioCollector {
      id: inhibitorOutput
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: inhibitorErrorOutput
      waitForEnd: true
    }
    // Not running without an exit: the check couldn't start (no exited()).
    onRunningChanged: {
      if (running || exitSeen)
        return
      exitSeen = true
      root.afterInhibitorCheck(-1, "", "busctl couldn't start")
    }
    onExited: function (exitCode) {
      inhibitorProbe.exitSeen = true
      root.afterInhibitorCheck(exitCode, inhibitorOutput.text, inhibitorErrorOutput.text)
    }
  }

  // Lock through the public lock interface (foamy.lock or the stock lock) and
  // wait for ext-session-lock to report the session secure, like Omarchy's
  // pre-suspend omarchy-system-sleep-lock does. Prints secure, missing-pam
  // or timeout.
  Process {
    id: lockProcess
    property bool exitSeen: false
    command: ["timeout", "--kill-after=1s", "12s", "bash", "-c", 'request() { case $(timeout --kill-after=0.2s 2s omarchy-shell lock lock 2>/dev/null) in missing-pam) echo missing-pam; exit 3;; esac; }; ' + 'request; ' + 'for _ in $(seq 1 40); do ' + 'state=$(timeout --kill-after=0.2s 1s omarchy-shell lock status 2>/dev/null | jq -r \'if .secure == true then "secure" elif .requested == true then "locking" else "idle" end\' 2>/dev/null); ' + 'case $state in secure) echo secure; exit 0;; locking) ;; *) request;; esac; ' + 'sleep 0.2; done; echo timeout; exit 4']
    stdout: StdioCollector {
      id: lockOutput
      waitForEnd: true
    }
    onExited: function (exitCode) {
      lockProcess.exitSeen = true
      var result = String(lockOutput.text || "").trim().split("\n").pop()
      root.afterLock(exitCode === 0 && result === "secure" ? "secure" : (result || "timeout"))
    }
    // Not running without an exit: the lock couldn't start (no exited()).
    // That is no secure lock, so no sleep, instead of waiting at "locking".
    onRunningChanged: {
      if (running || exitSeen)
        return
      exitSeen = true
      root.afterLock("start-failed")
    }
  }

  Process {
    id: suspendProcess
    property int attempt: 0
    stderr: StdioCollector {
      id: suspendError
      waitForEnd: true
    }
    onExited: function (exitCode, exitStatus) {
      root.settleSuspend(suspendProcess.attempt, exitCode, suspendError.text)
    }
    // After exited() this finds nothing pending. Without exited() before it
    // (systemctl missing or not executable) the request never started.
    onRunningChanged: if (!running)
      root.settleSuspend(suspendProcess.attempt, -1, "systemctl " + root.effectiveAction + " couldn't start")
  }

  // A sleep request that never ends would leave phase "suspending" and
  // automatic sleep off for good. Not GNU timeout: its clock counts time
  // asleep, so it would fire right after a resume. Qt timers run on
  // CLOCK_MONOTONIC, which stops while the computer sleeps, so this counts
  // only time awake with systemctl still running (systemctl returns as soon
  // as logind takes the request, or right after a resume if it is frozen
  // mid-call). If the wall clock shows the computer slept meanwhile anyway,
  // the request took effect: that counts as a completed sleep, not a failure.
  Timer {
    id: suspendWatchdog
    interval: root.suspendWatchdogMs
    repeat: false
    onTriggered: {
      if (!root.suspendPending)
        return
      var attempt = root.suspendAttempts
      // systemctl is the direct child: SIGKILL ends it (its exit is ignored).
      if (suspendProcess.running)
        suspendProcess.signal(9)
      if (Policy.sleptDuring(Date.now() - root.suspendStartedAt, root.suspendWatchdogMs)) {
        root.logEvent("suspend-watchdog", "systemctl " + root.effectiveAction + " was still running after a sleep")
        root.settleSuspend(attempt, 0, "")
      } else {
        root.settleSuspend(attempt, -1, "systemctl " + root.effectiveAction + " didn't finish within " + Math.round(root.suspendWatchdogMs / 1000) + " seconds")
      }
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
