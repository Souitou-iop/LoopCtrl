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
import app.loopctrl.pair.core.Phase
import app.loopctrl.pair.core.Step
import java.util.Calendar
import kotlinx.coroutines.launch

enum class Page { Single, Batch, Settings }

enum class Screen { Welcome, Wait, Device, Trust, DevCheck, Reboot, DevUnlock, Progress, Done }

data class Paired(val udid: String, val name: String, val ios: String, val time: String)

fun screenOf(d: DeviceView): Screen = if (d.phase == Phase.Failed) {
    when (d.failedAt ?: Step.Info) {
        Step.Info -> Screen.Device
        Step.Trust -> Screen.Trust
        Step.DevModeCheck -> Screen.DevCheck
        Step.Reboot -> Screen.Reboot
        Step.DevModeConfirm -> Screen.DevUnlock
        Step.Generate, Step.FindApp, Step.Write, Step.Verify -> Screen.Progress
    }
} else {
    when (d.phase) {
        Phase.Detected -> Screen.Device
        Phase.Trusting -> Screen.Trust
        Phase.CheckingDevMode, Phase.RevealingDevMode, Phase.DevModeGuide -> Screen.DevCheck
        Phase.Rebooting -> Screen.Reboot
        Phase.ConfirmingDevMode -> Screen.DevUnlock
        Phase.Generating, Phase.FindingApp, Phase.Writing, Phase.Verifying, Phase.Failed -> Screen.Progress
        Phase.Done -> Screen.Done
    }
}

/**
 * UI state on top of pair-core's device views: the page, which phone single
 * mode follows, the phones paired this session. Same rules as the desktop
 * store (ui/src/lib/store.svelte.ts).
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
    var page by mutableStateOf(Page.Single)
        private set
    var started by mutableStateOf(false)
    var focus by mutableStateOf<String?>(null)
        private set
    var paired by mutableStateOf<List<Paired>>(emptyList())
        private set
    var skipped by mutableStateOf<List<String>>(emptyList())
        private set
    /** Environment problem from 开始配对, shown as a dialog. */
    var envDialog by mutableStateOf(false)
    /** Batch: the phone whose sheet is open. */
    var sheet by mutableStateOf<String?>(null)

    val current: DeviceView? get() = devices.firstOrNull { it.udid == focus }

    val screen: Screen
        get() {
            if (!started) return Screen.Welcome
            return current?.let(::screenOf) ?: Screen.Wait
        }

    init {
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
            pickFocus()
            checkEnv()
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
        pickFocus()
    }

    /** Single mode follows one phone: keep it while it is there, else take
     *  the next connected one not paired this session. */
    private fun pickFocus() {
        val cur = current
        if (cur != null && cur.udid !in skipped && (cur.connected || cur.phase != Phase.Detected)) return
        focus = devices.firstOrNull { d ->
            d.connected && d.phase != Phase.Done && paired.none { it.udid == d.udid } && d.udid !in skipped
        }?.udid
    }

    fun start() {
        viewModelScope.launch {
            if (!envReady(checkEnv())) {
                envDialog = true
                return@launch
            }
            started = true
            pickFocus()
        }
    }

    /** After 重新检测 in the environment dialog. */
    fun redetect() {
        viewModelScope.launch {
            if (envReady(checkEnv())) {
                envDialog = false
                started = true
                pickFocus()
            }
        }
    }

    /** Simulated phones need no USB host. */
    private fun envReady(r: EnvReport) = r.usbmuxOk && (mock || usbHostSupported)

    /** Single mode will not come back to this phone. */
    fun skip(udid: String) {
        skipped = skipped + udid
        focus = null
        pickFocus()
    }

    fun nextDevice() {
        val cur = current
        if (cur != null) skip(cur.udid) else pickFocus()
    }

    /** Back to the welcome screen; a finished phone is not shown again. */
    fun finish() {
        val cur = current
        if (cur != null && cur.phase == Phase.Done) skipped = skipped + cur.udid
        started = false
        focus = null
        pickFocus()
    }

    fun go(p: Page) {
        page = p
        sheet = null
        // Batch starts every phone by itself; single waits for 继续.
        core.setAutoBegin(p == Page.Batch)
        if (p == Page.Single) pickFocus()
    }

    fun command(udid: String, cmd: String) = core.command(udid, cmd)

    /** 取消 in an error dialog: stop this phone and go back to the start. */
    fun cancelToWelcome(udid: String) {
        core.command(udid, "cancel")
        finish()
    }

    fun switchMock(on: Boolean) {
        core.setMock(on)
        mock = core.isMock
        devices = emptyList()
        focus = null
        viewModelScope.launch { checkEnv() }
    }

    fun clearDone() {
        devices.filter { it.phase == Phase.Done || !it.connected }.forEach { core.forget(it.udid) }
    }

    fun resetDemo() {
        core.mockReset()
        devices.forEach { core.forget(it.udid) }
        core.mockBatch()
    }
}
