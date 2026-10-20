package app.loopctrl.pair.ui

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import app.loopctrl.pair.PairApp
import app.loopctrl.pair.core.CoreEvent
import app.loopctrl.pair.core.DeviceView
import app.loopctrl.pair.core.EnvReport
import app.loopctrl.pair.core.ErrorCode
import app.loopctrl.pair.core.Phase
import java.util.Calendar
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

enum class View { Pair, Settings }

/** Idle: listing phones, waiting for 开始配对. Running: pairing. Finished: every phone settled. */
enum class Stage { Idle, Running, Finished }

data class Paired(val udid: String, val name: String, val ios: String, val time: String)

/** Pairing can't go further for this phone without something new from the user (old iOS). */
val DeviceView.unsupported get() = phase == Phase.Failed && error?.code == ErrorCode.Unsupported

/** Nothing left to do for this phone in this run. */
val DeviceView.settled get() = phase == Phase.Done || unsupported

/** Waiting for 开始配对. */
val DeviceView.ready get() = connected && phase == Phase.Detected && info != null

/** Something to do on the phone, or an error to fix. pair-core does not flag a Trust prompt as attention. */
val DeviceView.needsUser get() = !unsupported && (attention || phase == Phase.Trusting || phase == Phase.Failed)

/**
 * UI state on top of pair-core's device views. One flow for any number of
 * phones, the same rules as the desktop store (ui/src/lib/store.svelte.ts):
 * connected iPhones are listed as they are detected and nothing happens to
 * them until 开始配对, which turns auto-begin on for every waiting phone and
 * any phone plugged in while the run lasts.
 */
class PairViewModel(app: Application) : AndroidViewModel(app) {
    private val pairApp = app as PairApp
    val core = pairApp.core
    val prefs = pairApp.prefs
    val usbHostSupported = pairApp.usbHostSupported

    var devices by mutableStateOf<List<DeviceView>>(emptyList())
        private set
    var env by mutableStateOf<EnvReport?>(null)
        private set
    var mock by mutableStateOf(core.isMock)
        private set
    var view by mutableStateOf(View.Pair)
    var running by mutableStateOf(false)
        private set
    /** Phones put away by 完成; they stay listed under 本次已配对 only. */
    var hidden by mutableStateOf<List<String>>(emptyList())
        private set
    /** Phones whose step list the user opened. */
    var open by mutableStateOf<List<String>>(emptyList())
        private set
    var paired by mutableStateOf<List<Paired>>(emptyList())
        private set
    /** How to fix the environment, as a dialog. */
    var envDialog by mutableStateOf(false)

    /** Simulated phones need no USB host. */
    val envOk: Boolean get() = env?.let { it.usbmuxOk && (mock || usbHostSupported) } ?: true

    /** Phones on screen: not put away, and not a never-started phone that was unplugged. */
    val shown: List<DeviceView> get() = devices.filter { it.udid !in hidden && (it.connected || it.phase != Phase.Detected) }
    val ready: List<DeviceView> get() = shown.filter { it.ready }
    val doneCount: Int get() = shown.count { it.phase == Phase.Done }
    val needsYou: Int get() = shown.count { it.needsUser }

    val stage: Stage
        get() {
            if (!running) return Stage.Idle
            val s = shown
            return if (s.isNotEmpty() && s.all { it.settled } && s.any { it.phase == Phase.Done }) Stage.Finished else Stage.Running
        }

    init {
        // Phones wait for 开始配对.
        core.setAutoBegin(false)
        viewModelScope.launch {
            core.events.collect { e ->
                when (e) {
                    is CoreEvent.Device -> upsert(e.device)
                    is CoreEvent.Removed -> devices = devices.filter { it.udid != e.udid }
                    is CoreEvent.Watch -> Unit
                }
            }
        }
        viewModelScope.launch {
            devices = core.devices()
            checkEnv()
            // Look again while something is wrong, so a fix shows up without a tap.
            while (true) {
                delay(3000)
                if (!envOk) checkEnv()
            }
        }
    }

    suspend fun checkEnv(): EnvReport {
        val r = core.envCheck()
        env = r
        return r
    }

    private fun upsert(d: DeviceView) {
        val i = devices.indexOfFirst { it.udid == d.udid }
        devices = if (i < 0) (devices + d).sortedBy { it.order } else devices.toMutableList().also { it[i] = d }
        if (d.phase == Phase.Done && paired.none { it.udid == d.udid }) {
            val at = Calendar.getInstance().apply { timeInMillis = d.doneAt ?: System.currentTimeMillis() }
            val time = "%d:%02d".format(at.get(Calendar.HOUR_OF_DAY), at.get(Calendar.MINUTE))
            paired = paired + Paired(d.udid, d.name, d.info?.ios ?: "", time)
        }
    }

    fun start() {
        viewModelScope.launch {
            checkEnv()
            if (!envOk) {
                envDialog = true
                return@launch
            }
            running = true
            core.setAutoBegin(true)
        }
    }

    /** Back to the list: phones not finished return to waiting; finished ones move to 本次已配对. */
    fun stop() {
        running = false
        core.setAutoBegin(false)
        shown.filter { it.phase != Phase.Detected && !it.settled }.forEach { core.command(it.udid, "cancel") }
        hidden = hidden + shown.filter { it.phase == Phase.Done }.map { it.udid }
        open = emptyList()
    }

    /** 完成: put the finished phones away and wait for the next ones. */
    fun finish() {
        running = false
        core.setAutoBegin(false)
        hidden = hidden + shown.filter { it.settled }.map { it.udid }
        open = emptyList()
    }

    /** After 重新检测 in the environment dialog. */
    fun redetect() {
        viewModelScope.launch {
            checkEnv()
            if (envOk) envDialog = false
        }
    }

    fun toggle(udid: String) {
        open = if (udid in open) open - udid else open + udid
    }

    fun command(udid: String, cmd: String) = core.command(udid, cmd)

    fun switchMock(on: Boolean) {
        stop()
        core.setMock(on)
        mock = core.isMock
        devices = emptyList()
        hidden = emptyList()
        viewModelScope.launch { checkEnv() }
    }

    fun resetDemo() {
        stop()
        core.mockReset()
        devices.forEach { core.forget(it.udid) }
        devices = emptyList()
    }
}
