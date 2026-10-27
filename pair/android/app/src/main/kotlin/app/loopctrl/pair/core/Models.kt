package app.loopctrl.pair.core

import org.json.JSONArray
import org.json.JSONObject

// pair-core's serde shapes (camelCase), the same the desktop UI reads.

enum class Phase {
    Detected, Trusting, CheckingDevMode, RevealingDevMode, DevModeGuide, Rebooting, ConfirmingDevMode,
    Generating, FindingApp, Writing, Verifying, Done, Failed;

    companion object {
        fun of(s: String): Phase = entries.firstOrNull { it.wire == s } ?: Detected
    }
}

enum class Step {
    Info, Trust, DevModeCheck, Reboot, DevModeConfirm, Generate, FindApp, Write, Verify;

    companion object {
        fun of(s: String?): Step? = entries.firstOrNull { it.wire == s }
    }
}

enum class ErrorCode {
    NoDriver, NoUsbmux, Untrusted, DevModeCancelled, RebootTimeout, Unsupported, RecordFailed,
    AppNotFound, WriteFailed, VerifyFailed, Disconnected, Internal;

    companion object {
        fun of(s: String?): ErrorCode = entries.firstOrNull { it.wire == s } ?: Internal
    }
}

/** camelCase name pair-core uses for an enum constant. */
val Enum<*>.wire: String get() = name.replaceFirstChar { it.lowercase() }

data class DeviceInfo(val udid: String, val name: String, val model: String, val productType: String, val ios: String)

data class PairError(val code: ErrorCode, val detail: String)

data class AppMatch(val bundleId: String, val name: String, val version: String?)

data class DeviceView(
    val udid: String,
    val order: Int,
    val connected: Boolean,
    val info: DeviceInfo?,
    val phase: Phase,
    val error: PairError?,
    val failedAt: Step?,
    val progress: Float,
    val attention: Boolean,
    val devModeWasOff: Boolean,
    val recordKind: String?,
    val app: AppMatch?,
    val locked: Boolean,
    val phaseSince: Long,
    val doneAt: Long?,
) {
    val name: String get() = info?.name ?: "iPhone"
}

data class EnvReport(val os: String, val osVersion: String, val usbmuxOk: Boolean, val usbmuxAddr: String, val detail: String?)

sealed interface CoreEvent {
    data class Device(val device: DeviceView) : CoreEvent
    data class Removed(val udid: String) : CoreEvent
    data class Watch(val ok: Boolean, val detail: String?) : CoreEvent
}

private fun JSONObject.str(key: String): String? = if (isNull(key)) null else optString(key)

object Json {
    fun deviceInfo(o: JSONObject?): DeviceInfo? = o?.let {
        DeviceInfo(it.getString("udid"), it.getString("name"), it.getString("model"), it.optString("productType"), it.getString("ios"))
    }

    fun device(o: JSONObject): DeviceView = DeviceView(
        udid = o.getString("udid"),
        order = o.optInt("order"),
        connected = o.optBoolean("connected"),
        info = deviceInfo(o.optJSONObject("info")),
        phase = Phase.of(o.getString("phase")),
        error = o.optJSONObject("error")?.let { PairError(ErrorCode.of(it.str("code")), it.optString("detail")) },
        failedAt = Step.of(o.str("failedAt")),
        progress = o.optDouble("progress", 0.0).toFloat(),
        attention = o.optBoolean("attention"),
        devModeWasOff = o.optBoolean("devModeWasOff"),
        recordKind = o.str("recordKind"),
        app = o.optJSONObject("app")?.let { AppMatch(it.getString("bundleId"), it.getString("name"), it.str("version")) },
        locked = o.optBoolean("locked"),
        phaseSince = o.optLong("phaseSince"),
        doneAt = if (o.isNull("doneAt")) null else o.optLong("doneAt"),
    )

    fun devices(json: String): List<DeviceView> {
        val a = JSONArray(json)
        return (0 until a.length()).map { device(a.getJSONObject(it)) }
    }

    fun env(json: String): EnvReport {
        val o = JSONObject(json)
        return EnvReport(o.optString("os"), o.optString("osVersion"), o.optBoolean("usbmuxOk"), o.optString("usbmuxAddr"), o.str("detail"))
    }

    fun event(json: String): CoreEvent? {
        val o = JSONObject(json)
        return when (o.optString("type")) {
            "device" -> CoreEvent.Device(device(o.getJSONObject("device")))
            "removed" -> CoreEvent.Removed(o.getString("udid"))
            "watch" -> CoreEvent.Watch(o.optBoolean("ok"), o.str("detail"))
            else -> null
        }
    }
}
