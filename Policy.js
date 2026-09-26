function defaults() {
  return {
    batteryTimeoutSec: 900,
    acTimeoutSec: null,
    laptopsOnly: true,
    suspendAction: "suspend-then-hibernate"
  }
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
    if (["suspend", "hibernate", "hybrid-sleep", "suspend-then-hibernate"].indexOf(policy.suspendAction) === -1)
      throw new Error("suspendAction must be suspend, hibernate, hybrid-sleep, or suspend-then-hibernate")
    return { valid: true, settings: policy, error: "" }
  } catch (error) {
    // Never apply a fallback sleep policy after a malformed user override.
    return { valid: false, settings: defaults(), error: String(error.message || error) }
  }
}

function allowed(policy, configValid, chassisLoaded, isLaptop, idleEnabled) {
  return configValid && idleEnabled && (!policy.laptopsOnly || (chassisLoaded && isLaptop))
}

if (typeof module !== "undefined") module.exports = { defaults: defaults, parseConfig: parseConfig, allowed: allowed }
