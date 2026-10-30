function defaults() {
  return {
    batteryTimeoutSec: 900,
    acTimeoutSec: null,
    laptopsOnly: true,
    // Works without hibernation, which Omarchy sets up only on request.
    suspendAction: "suspend",
    // Defer while an MPRIS player is playing (see mediaPlaying).
    pauseForMedia: true,
    // Lock the screen and wait for a secure lock before sleeping.
    lockBeforeSuspend: true
  }
}

var ACTIONS = ["suspend", "hibernate", "hybrid-sleep", "suspend-then-hibernate"]
// logind's Manager method that says whether an action can run.
var CAN_METHODS = {
  "suspend": "CanSuspend",
  "hibernate": "CanHibernate",
  "hybrid-sleep": "CanHybridSleep",
  "suspend-then-hibernate": "CanSuspendThenHibernate"
}

function parseConfig(text) {
  try {
    var config = JSON.parse(text)
    if (!config || config.version !== 1 || !Array.isArray(config.plugins))
      throw new Error("Expected version: 1 and a plugins array in shell.json")
    var entries = config.plugins.filter(function(entry) {
      return entry && entry.id === "foamy.idle-suspend"
    })
    if (entries.length !== 1)
      throw new Error("Keep exactly one foamy.idle-suspend entry in plugins")
    var entry = entries[0]
    var policy = defaults()
    for (var key in policy) {
      if (entry[key] !== undefined) policy[key] = entry[key]
    }
    for (var i = 0; i < 2; i++) {
      var name = i === 0 ? "batteryTimeoutSec" : "acTimeoutSec"
      var value = policy[name]
      if (value === null) continue
      // Keep seconds-to-milliseconds conversion within a signed 32-bit value.
      if (typeof value !== "number" || !isFinite(value) || Math.floor(value) !== value
          || value <= 0 || value > 2147483)
        throw new Error(name + " must be null or an integer from 1 to 2147483; null disables sleep")
    }
    if (typeof policy.laptopsOnly !== "boolean")
      throw new Error("laptopsOnly must be true or false")
    if (typeof policy.pauseForMedia !== "boolean")
      throw new Error("pauseForMedia must be true or false")
    if (typeof policy.lockBeforeSuspend !== "boolean")
      throw new Error("lockBeforeSuspend must be true or false")
    if (ACTIONS.indexOf(policy.suspendAction) === -1)
      throw new Error("suspendAction must be suspend, hibernate, hybrid-sleep, or suspend-then-hibernate")
    return { valid: true, settings: policy, error: "" }
  } catch (error) {
    // Never apply a fallback sleep policy after a malformed user override.
    return { valid: false, settings: defaults(), error: String(error.message || error) }
  }
}

// Same effective configuration: a write to shell.json that changes nothing
// here (bar edits, other plugins) must not restart the idle countdown.
function sameConfiguration(a, b) {
  if (!a || !b) return false
  return a.valid === b.valid && a.error === b.error && JSON.stringify(a.settings) === JSON.stringify(b.settings)
}

function allowed(policy, configValid, chassisLoaded, isLaptop, idleEnabled) {
  return configValid && idleEnabled && (!policy.laptopsOnly || (chassisLoaded && isLaptop))
}

// Whether this plugin would sleep at all, Stay awake aside. Its notifications
// stay quiet on machines where it does nothing.
function active(policy, configValid, chassisLoaded, isLaptop) {
  return allowed(policy, configValid, chassisLoaded, isLaptop, true)
    && (policy.batteryTimeoutSec !== null || policy.acTimeoutSec !== null)
}

// Shared with foamy-lock (Model.mediaPlaying), see tests/media-playing.json:
// media is playing when any MPRIS player reports isPlaying === true.
function mediaPlaying(players) {
  var list = players || []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].isPlaying === true) return true
  }
  return false
}

// logind's BlockInhibited is a colon-separated list ("idle:sleep").
function blockedByInhibitor(blockInhibited) {
  var what = String(blockInhibited || "").split(":")
  return what.indexOf("idle") !== -1 || what.indexOf("sleep") !== -1
}

// Answers from logind's Can* methods: "yes", "challenge" (allowed after
// authentication), "no", "na". Unknown answers (probe failed) are trusted
// and left to systemctl. An unavailable action falls back to suspend.
function usable(answer) {
  return answer === undefined || answer === null || answer === "" || answer === "yes" || answer === "challenge"
}

function chooseAction(configured, answers) {
  var support = answers || {}
  if (usable(support[configured])) return { action: configured, fallback: false }
  if (configured !== "suspend" && usable(support["suspend"])) return { action: "suspend", fallback: true }
  return { action: "", fallback: false }
}

// Retry while still idle: one minute after a wake without input or a
// deferral, doubling after each failure up to fifteen minutes.
function retryDelayMs(failures, baseMs) {
  var base = baseMs || 60000
  var n = Math.max(0, Math.min(4, Number(failures) || 0))
  return Math.min(base * Math.pow(2, n), base * 15)
}

if (typeof module !== "undefined") module.exports = {
  defaults: defaults, parseConfig: parseConfig, allowed: allowed, active: active,
  sameConfiguration: sameConfiguration, mediaPlaying: mediaPlaying,
  blockedByInhibitor: blockedByInhibitor, chooseAction: chooseAction, retryDelayMs: retryDelayMs,
  ACTIONS: ACTIONS, CAN_METHODS: CAN_METHODS
}
