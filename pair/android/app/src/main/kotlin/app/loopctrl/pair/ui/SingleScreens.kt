package app.loopctrl.pair.ui

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import app.loopctrl.pair.R
import app.loopctrl.pair.core.DeviceView
import app.loopctrl.pair.core.Phase
import app.loopctrl.pair.core.Step
import kotlinx.coroutines.delay
import top.yukonga.miuix.kmp.basic.BasicComponent
import top.yukonga.miuix.kmp.icon.MiuixIcons
import top.yukonga.miuix.kmp.icon.extended.Info
import top.yukonga.miuix.kmp.icon.extended.Lock
import top.yukonga.miuix.kmp.icon.extended.Ok
import top.yukonga.miuix.kmp.icon.extended.Phone
import top.yukonga.miuix.kmp.icon.extended.Refresh
import top.yukonga.miuix.kmp.theme.MiuixTheme

val SCENARIOS = listOf("ready", "devModeOff", "noRpService", "legacy16", "early17", "noApp", "rebootHangs", "unsupported", "locked")

@Composable
fun scenarioLabel(s: String): String = stringResource(
    when (s) {
        "devModeOff" -> R.string.scenario_devModeOff
        "noRpService" -> R.string.scenario_noRpService
        "legacy16" -> R.string.scenario_legacy16
        "early17" -> R.string.scenario_early17
        "noApp" -> R.string.scenario_noApp
        "rebootHangs" -> R.string.scenario_rebootHangs
        "unsupported" -> R.string.scenario_unsupported
        "locked" -> R.string.scenario_locked
        else -> R.string.scenario_ready
    },
)

@Composable
fun SingleFlow(vm: PairViewModel, bottom: PaddingValues) {
    val s = vm.screen
    if (s == Screen.Welcome) return WelcomeScreen(vm, bottom)
    // The other screens follow a phone; without one, wait for it.
    val d = vm.current
    if (s == Screen.Wait || d == null) return WaitScreen(vm, bottom)
    when (s) {
        Screen.Welcome, Screen.Wait -> Unit
        Screen.Device -> DeviceScreen(vm, d, bottom)
        Screen.Trust -> TrustScreen(vm, d, bottom)
        Screen.DevCheck -> DevCheckScreen(vm, d, bottom)
        Screen.Reboot -> RebootScreen(d, bottom)
        Screen.DevUnlock -> DevUnlockScreen(vm, d, bottom)
        Screen.Progress -> ProgressScreen(d, bottom)
        Screen.Done -> DoneScreen(vm, d, bottom)
    }
}

@Composable
private fun WelcomeScreen(vm: PairViewModel, bottom: PaddingValues) {
    val env = vm.env
    val muxOk = env?.usbmuxOk ?: false
    val okText = stringResource(R.string.welcome_ok)
    val badText = stringResource(R.string.welcome_unavailable)
    Page(stringResource(R.string.welcome_title), stringResource(R.string.welcome_subtitle), bottom) {
        Section("LoopCtrl") {
            BasicComponent(
                title = stringResource(R.string.app_name),
                summary = stringResource(R.string.welcome_card_summary),
                startAction = { AppLogo() },
            )
        }
        Section(stringResource(R.string.welcome_many)) {
            InfoRow(stringResource(R.string.welcome_batch), stringResource(R.string.welcome_batch_summary), end = "›", onClick = { vm.go(Page.Batch) })
        }
        Section(stringResource(R.string.welcome_env)) {
            InfoRow(
                stringResource(R.string.welcome_usb_host), stringResource(R.string.welcome_usb_host_summary),
                end = if (vm.usbHostSupported) okText else badText,
                endColor = if (vm.usbHostSupported) PairColors.ok else MiuixTheme.colorScheme.error,
            )
            InfoRow(
                stringResource(R.string.welcome_mux), stringResource(R.string.welcome_mux_summary),
                end = when {
                    env == null -> stringResource(R.string.welcome_checking)
                    muxOk -> okText
                    else -> badText
                },
                endColor = if (env == null) null else if (muxOk) PairColors.ok else MiuixTheme.colorScheme.error,
            )
        }
        Buttons { PrimaryButton(stringResource(R.string.welcome_start), vm::start, Modifier.weight(1f)) }
    }
}

@Composable
private fun SessionList(vm: PairViewModel) {
    for (p in vm.paired) InfoRow(p.name, "iOS ${p.ios}", end = p.time, endColor = PairColors.ok)
}

@Composable
private fun WaitScreen(vm: PairViewModel, bottom: PaddingValues) {
    var scenario by remember { mutableStateOf(0) }
    Page(stringResource(R.string.wait_title), stringResource(R.string.wait_subtitle), bottom) {
        Section(stringResource(R.string.status)) {
            Hero(MiuixIcons.Phone, stringResource(R.string.wait_heading), stringResource(R.string.wait_body), waiting = stringResource(R.string.wait_waiting))
        }
        if (vm.paired.isNotEmpty()) Section(stringResource(R.string.wait_session_done)) { SessionList(vm) }
        Buttons { SecondaryButton(stringResource(R.string.back), vm::finish) }
        MockRow(vm) {
            MockButton(scenarioLabel(SCENARIOS[scenario])) { scenario = (scenario + 1) % SCENARIOS.size }
            MockButton(stringResource(R.string.mock_plug)) { vm.core.mockPlug(SCENARIOS[scenario]) }
        }
    }
}

@Composable
private fun DeviceScreen(vm: PairViewModel, d: DeviceView, bottom: PaddingValues) {
    Page(d.name, stringResource(R.string.device_subtitle), bottom) {
        Section(stringResource(R.string.device_info)) {
            InfoRow(stringResource(R.string.device_model), end = d.info?.model ?: "…")
            InfoRow(stringResource(R.string.device_ios), end = d.info?.ios ?: "…")
            InfoRow(stringResource(R.string.device_dev_mode), stringResource(R.string.device_dev_mode_summary), end = stringResource(R.string.device_pending))
        }
        Section(stringResource(R.string.device_next)) {
            InfoRow(stringResource(R.string.device_next_title), stringResource(R.string.device_next_summary))
        }
        Buttons {
            PrimaryButton(
                stringResource(if (d.info != null) R.string.device_continue else R.string.device_reading),
                { vm.command(d.udid, "begin") },
                Modifier.weight(1f),
                enabled = d.info != null,
            )
        }
        MockRow(vm) { MockButton(stringResource(R.string.mock_unplug)) { vm.core.mockPhone(d.udid, "unplug") } }
    }
}

@Composable
private fun TrustScreen(vm: PairViewModel, d: DeviceView, bottom: PaddingValues) {
    Page(stringResource(R.string.trust_title), stringResource(R.string.trust_subtitle), bottom) {
        Section(stringResource(R.string.on_iphone)) {
            Hero(
                MiuixIcons.Lock, stringResource(R.string.trust_heading), stringResource(R.string.trust_body),
                warn = if (d.locked) stringResource(R.string.trust_locked) else null,
                waiting = stringResource(R.string.waiting_confirm),
            )
        }
        MockRow(vm) {
            if (d.locked) MockButton(stringResource(R.string.mock_unlock)) { vm.core.mockPhone(d.udid, "unlock") }
            MockButton(stringResource(R.string.mock_trust)) { vm.core.mockPhone(d.udid, "trust") }
            MockButton(stringResource(R.string.mock_dont_trust)) { vm.core.mockPhone(d.udid, "dontTrust") }
        }
    }
}

@Composable
private fun DevCheckScreen(vm: PairViewModel, d: DeviceView, bottom: PaddingValues) {
    val reading = d.phase == Phase.CheckingDevMode || (d.phase == Phase.Failed && d.failedAt == Step.DevModeCheck)
    val off = d.devModeWasOff && !reading
    val guide = d.phase == Phase.DevModeGuide
    val subtitle = stringResource(if (reading) R.string.devcheck_checking else if (off) R.string.devcheck_off else R.string.devcheck_on)
    Page(stringResource(R.string.devcheck_title), subtitle, bottom) {
        Section(stringResource(R.string.devcheck_auto)) {
            StepRow(
                if (reading) StepState.Run else if (off) StepState.Bad else StepState.Ok,
                stringResource(R.string.devcheck_read),
                end = stringResource(if (reading) R.string.step_reading else if (off) R.string.step_off else R.string.step_on),
            )
            if (off) {
                val revealing = d.phase == Phase.RevealingDevMode
                StepRow(
                    if (revealing) StepState.Run else StepState.Ok,
                    stringResource(R.string.devcheck_reveal), stringResource(R.string.devcheck_reveal_summary),
                    stringResource(if (revealing) R.string.step_run else R.string.step_done),
                )
            }
        }
        if (guide) {
            Section(stringResource(R.string.on_iphone)) {
                NumberedRow(1, stringResource(R.string.devcheck_step1), stringResource(R.string.devcheck_step1_summary))
                NumberedRow(2, stringResource(R.string.devcheck_step2))
                NumberedRow(3, stringResource(R.string.devcheck_step3), stringResource(R.string.devcheck_step3_summary))
            }
            Block { Waiting(stringResource(R.string.devcheck_wait_reboot), Modifier.padding(horizontal = 4.dp)) }
            Block { Note(stringResource(R.string.devcheck_why_title), stringResource(R.string.devcheck_why)) }
            MockRow(vm) { MockButton(stringResource(R.string.mock_restart)) { vm.core.mockPhone(d.udid, "restart") } }
        }
    }
}

@Composable
private fun RebootScreen(d: DeviceView, bottom: PaddingValues) {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(1000)
            now = System.currentTimeMillis()
        }
    }
    val secs = ((now - d.phaseSince) / 1000).coerceAtLeast(0)
    val clock = if (d.phase == Phase.Rebooting) "%d:%02d".format(secs / 60, secs % 60) else ""
    Page(stringResource(R.string.reboot_title), stringResource(R.string.reboot_subtitle), bottom) {
        Section(stringResource(R.string.status)) {
            Hero(
                MiuixIcons.Refresh, stringResource(R.string.reboot_heading), stringResource(R.string.reboot_body),
                warn = stringResource(R.string.reboot_no_unplug), waiting = stringResource(R.string.reboot_waiting, clock),
            )
        }
    }
}

@Composable
private fun DevUnlockScreen(vm: PairViewModel, d: DeviceView, bottom: PaddingValues) {
    Page(stringResource(R.string.unlock_title), stringResource(R.string.unlock_subtitle), bottom) {
        Section(stringResource(R.string.on_iphone)) {
            Hero(MiuixIcons.Info, stringResource(R.string.unlock_heading), stringResource(R.string.unlock_body), waiting = stringResource(R.string.waiting_confirm))
        }
        Buttons { SecondaryButton(stringResource(R.string.unlock_no_prompt), { vm.command(d.udid, "recheck") }) }
        MockRow(vm) {
            MockButton(stringResource(R.string.mock_turn_on)) { vm.core.mockPhone(d.udid, "turnOn") }
            MockButton(stringResource(R.string.mock_cancel)) { vm.core.mockPhone(d.udid, "cancel") }
        }
    }
}

@Composable
private fun ProgressScreen(d: DeviceView, bottom: PaddingValues) {
    val order = listOf(Step.Generate, Step.FindApp, Step.Write, Step.Verify)
    val at = if (d.phase == Phase.Failed) order.indexOf(d.failedAt) else when (d.phase) {
        Phase.Generating -> 0
        Phase.FindingApp -> 1
        Phase.Writing -> 2
        Phase.Verifying -> 3
        Phase.Done -> 4
        else -> 0
    }
    val titles = listOf(R.string.progress_gen, R.string.progress_find, R.string.progress_write, R.string.progress_verify).map { stringResource(it) }
    val doneText = listOf(
        stringResource(if (d.recordKind == "lockdown") R.string.progress_lockdown_only else R.string.step_done),
        d.app?.let { a -> a.name + (a.version?.let { " $it" } ?: "") } ?: stringResource(R.string.step_done),
        stringResource(R.string.progress_written),
        stringResource(R.string.progress_passed),
    )
    val run = stringResource(R.string.step_run)
    val wait = stringResource(R.string.step_wait)
    val failed = stringResource(R.string.chip_failed)
    Page(stringResource(R.string.progress_title), stringResource(R.string.progress_subtitle), bottom) {
        Section(stringResource(R.string.progress_heading)) {
            titles.forEachIndexed { i, title ->
                val st = when {
                    i < at -> StepState.Ok
                    i == at -> if (d.phase == Phase.Failed) StepState.Bad else StepState.Run
                    else -> StepState.Wait
                }
                StepRow(st, title, end = when (st) {
                    StepState.Ok -> doneText[i]
                    StepState.Run -> run
                    StepState.Bad -> failed
                    StepState.Wait -> wait
                })
            }
        }
        Block { LinearProgress(at.coerceAtLeast(0) / 4f) }
    }
}

@Composable
private fun DoneScreen(vm: PairViewModel, d: DeviceView, bottom: PaddingValues) {
    Page(stringResource(R.string.done_title), "${d.name} · iOS ${d.info?.ios ?: ""}", bottom) {
        Section(stringResource(R.string.done_result)) {
            Hero(MiuixIcons.Ok, stringResource(R.string.done_heading), stringResource(R.string.done_body), ok = true)
        }
        Section(stringResource(R.string.done_later)) {
            InfoRow(stringResource(R.string.done_after_reboot), stringResource(R.string.done_after_reboot_summary))
            InfoRow(stringResource(R.string.done_no_more), stringResource(R.string.done_no_more_summary))
        }
        Section(stringResource(R.string.done_session_count, vm.paired.size)) { SessionList(vm) }
        Buttons {
            SecondaryButton(stringResource(R.string.done_finish), vm::finish, Modifier.weight(1f))
            PrimaryButton(stringResource(R.string.done_next), vm::nextDevice, Modifier.weight(1f))
        }
    }
}
