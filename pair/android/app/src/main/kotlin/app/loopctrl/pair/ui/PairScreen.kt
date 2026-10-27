package app.loopctrl.pair.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringArrayResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.loopctrl.pair.R
import app.loopctrl.pair.core.DeviceView
import app.loopctrl.pair.core.ErrorCode
import app.loopctrl.pair.core.Phase
import app.loopctrl.pair.core.Step
import kotlinx.coroutines.delay
import top.yukonga.miuix.kmp.basic.BasicComponent
import top.yukonga.miuix.kmp.basic.Card
import top.yukonga.miuix.kmp.basic.Icon
import top.yukonga.miuix.kmp.basic.IconButton
import top.yukonga.miuix.kmp.basic.InfiniteProgressIndicator
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.basic.TextButton
import top.yukonga.miuix.kmp.icon.MiuixIcons
import top.yukonga.miuix.kmp.icon.extended.ChevronForward
import top.yukonga.miuix.kmp.icon.extended.Lock
import top.yukonga.miuix.kmp.icon.extended.Ok
import top.yukonga.miuix.kmp.icon.extended.Phone
import top.yukonga.miuix.kmp.icon.extended.Refresh
import top.yukonga.miuix.kmp.icon.extended.Settings
import top.yukonga.miuix.kmp.icon.extended.Unlock
import top.yukonga.miuix.kmp.overlay.OverlayBottomSheet
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

enum class ChipKind { Wait, Ready, Run, Act, Ok, Bad, Off }

/** Chip colour and label for a phone in the list. `running`: a pairing run is on. */
@Composable
fun chipOf(d: DeviceView, running: Boolean): Pair<ChipKind, String> = when {
    d.unsupported -> ChipKind.Bad to stringResource(R.string.row_too_old)
    d.phase == Phase.Done -> ChipKind.Ok to stringResource(R.string.chip_done)
    !d.connected && d.phase != Phase.Rebooting -> ChipKind.Off to stringResource(R.string.row_unplugged)
    d.phase == Phase.Detected -> when {
        d.info == null -> ChipKind.Wait to stringResource(R.string.row_reading)
        running -> ChipKind.Wait to stringResource(R.string.chip_detected)
        else -> ChipKind.Ready to stringResource(R.string.row_ready)
    }
    d.phase == Phase.Trusting -> ChipKind.Act to stringResource(if (d.locked) R.string.chip_locked else R.string.chip_trusting)
    d.phase == Phase.Failed -> ChipKind.Bad to stringResource(R.string.chip_failed)
    else -> (if (d.attention) ChipKind.Act else ChipKind.Run) to stringResource(
        when (d.phase) {
            Phase.DevModeGuide -> R.string.chip_dev_off
            Phase.Rebooting -> R.string.chip_rebooting
            Phase.ConfirmingDevMode -> R.string.chip_turn_on
            Phase.Generating -> R.string.chip_generating
            Phase.FindingApp -> R.string.chip_finding
            Phase.Writing -> R.string.chip_writing
            Phase.Verifying -> R.string.chip_verifying
            else -> R.string.chip_checking
        },
    )
}

/** Index into the five steps (信任 / 开发者模式 / 生成 / 写入 / 校验); 5 when done. */
fun stepOf(d: DeviceView): Int = if (d.phase == Phase.Failed) {
    when (d.failedAt) {
        Step.DevModeCheck, Step.Reboot, Step.DevModeConfirm -> 1
        Step.Generate, Step.FindApp -> 2
        Step.Write -> 3
        Step.Verify -> 4
        else -> 0
    }
} else {
    when (d.phase) {
        Phase.Detected, Phase.Trusting -> 0
        Phase.CheckingDevMode, Phase.RevealingDevMode, Phase.DevModeGuide, Phase.Rebooting, Phase.ConfirmingDevMode -> 1
        Phase.Generating, Phase.FindingApp -> 2
        Phase.Writing -> 3
        Phase.Verifying -> 4
        Phase.Done -> 5
        Phase.Failed -> 0
    }
}

@Composable
private fun Chip(kind: ChipKind, label: String) {
    val color = when (kind) {
        ChipKind.Run, ChipKind.Ready -> MiuixTheme.colorScheme.primary
        ChipKind.Act -> PairColors.warn
        ChipKind.Ok -> PairColors.ok
        ChipKind.Bad -> MiuixTheme.colorScheme.error
        ChipKind.Wait, ChipKind.Off -> MiuixTheme.colorScheme.onSurfaceVariantSummary
    }
    Row(
        Modifier.clip(RoundedCornerShape(10.dp)).background(color.copy(alpha = 0.12f)).padding(horizontal = 8.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (kind == ChipKind.Run || (kind == ChipKind.Wait && label == stringResource(R.string.row_reading))) {
            InfiniteProgressIndicator(color = color, size = 10.dp)
            Spacer(Modifier.width(5.dp))
        }
        Text(label, color = color, fontSize = 12.sp, fontWeight = FontWeight.Medium)
    }
}

/** Top bar actions: environment status and settings. */
@Composable
fun PairActions(vm: PairViewModel, onEnv: () -> Unit) {
    val state = when {
        vm.env == null -> null
        vm.envOk -> true
        else -> false
    }
    val color = when (state) {
        null -> MiuixTheme.colorScheme.onSurfaceVariantSummary
        true -> PairColors.ok
        false -> MiuixTheme.colorScheme.error
    }
    Row(
        Modifier.clip(RoundedCornerShape(14.dp)).background(color.copy(alpha = 0.12f)).clickable(onClick = onEnv)
            .padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(7.dp).clip(CircleShape).background(color))
        Spacer(Modifier.width(6.dp))
        Text(
            stringResource(when (state) { null -> R.string.env_checking; true -> R.string.env_ok; false -> R.string.env_bad }),
            color = color, fontSize = 12.sp, fontWeight = FontWeight.Medium,
        )
    }
    IconButton(onClick = { vm.view = View.Settings }, modifier = Modifier.padding(start = 4.dp, end = 8.dp)) {
        Icon(MiuixIcons.Settings, contentDescription = stringResource(R.string.nav_settings))
    }
}

/** The one pairing screen, for one phone or many. */
@Composable
fun PairScreen(vm: PairViewModel, bottom: PaddingValues) {
    var envSheet by remember { mutableStateOf(false) }
    val stage = vm.stage
    val list = vm.shown
    val sorted = if (stage == Stage.Idle) list else list.sortedWith(compareByDescending<DeviceView> { it.needsUser }.thenBy { it.order })
    val solo = list.size == 1 && stage != Stage.Idle
    val title = when {
        stage == Stage.Finished -> stringResource(R.string.home_title_done)
        stage == Stage.Running -> stringResource(R.string.home_title_running)
        list.isNotEmpty() -> stringResource(R.string.home_title_found, list.size)
        else -> stringResource(R.string.home_title_empty)
    }
    val subtitle = when {
        stage == Stage.Finished -> stringResource(R.string.home_sub_done, vm.doneCount)
        stage == Stage.Running -> if (vm.needsYou > 0) stringResource(R.string.home_sub_running_act, vm.doneCount, list.size, vm.needsYou)
        else stringResource(R.string.home_sub_running, vm.doneCount, list.size)
        list.isNotEmpty() -> stringResource(R.string.home_sub_found)
        else -> stringResource(R.string.home_sub_empty)
    }

    EnvSheet(vm, envSheet) { envSheet = false }
    Page(title, bottom = bottom, actions = { PairActions(vm) { envSheet = true } }) {
        Text(
            subtitle,
            style = MiuixTheme.textStyles.body2,
            color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
            modifier = Modifier.padding(horizontal = 24.dp).padding(bottom = 12.dp),
        )
        if (stage != Stage.Idle && list.size > 1) {
            val avg = list.sumOf { (if (it.phase == Phase.Done) 1f else it.progress).toDouble() }.toFloat() / list.size
            Box(Modifier.padding(horizontal = 24.dp).padding(bottom = 14.dp)) { LinearProgress(avg) }
        }
        if (!vm.envOk) EnvBanner(vm)
        if (stage == Stage.Finished) DoneCard()
        if (list.isEmpty()) {
            Card(Modifier.padding(horizontal = 12.dp).padding(bottom = 12.dp)) {
                Hero(
                    MiuixIcons.Phone, stringResource(R.string.home_hero_title), stringResource(R.string.home_hero_body),
                    waiting = if (vm.envOk) stringResource(R.string.home_detecting) else null,
                )
            }
        } else {
            for (d in sorted) DeviceCard(vm, d, solo)
        }
        if (stage == Stage.Idle && vm.paired.isNotEmpty()) {
            Section(stringResource(R.string.home_paired)) {
                for (p in vm.paired) InfoRow(p.name, "iOS ${p.ios}", end = p.time, endColor = PairColors.ok)
            }
        }
        var scenario by remember { mutableIntStateOf(0) }
        MockRow(vm) {
            MockButton(scenarioLabel(SCENARIOS[scenario])) { scenario = (scenario + 1) % SCENARIOS.size }
            MockButton(stringResource(R.string.mock_plug)) { vm.core.mockPlug(SCENARIOS[scenario]) }
            MockButton(stringResource(R.string.mock_batch)) { vm.core.mockBatch() }
            MockButton(stringResource(R.string.mock_reset), vm::resetDemo)
        }
    }
}

/** The bar under the list: what is going on, and the one button that moves it on. */
@Composable
fun PairBar(vm: PairViewModel) {
    val stage = vm.stage
    val list = vm.shown
    Row(
        Modifier.fillMaxWidth().background(MiuixTheme.colorScheme.surface).navigationBarsPadding()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.weight(1f)) {
            when {
                stage == Stage.Running -> BarNote(stringResource(R.string.home_running_note))
                stage == Stage.Finished -> BarNote(stringResource(R.string.home_done_note, vm.paired.size))
                list.isEmpty() -> Waiting(stringResource(R.string.home_waiting))
                vm.ready.isNotEmpty() -> BarNote(stringResource(R.string.home_ready_n, vm.ready.size))
                list.any { it.info == null } -> Waiting(stringResource(R.string.home_detecting))
                else -> BarNote(stringResource(R.string.home_none_ready))
            }
        }
        when (stage) {
            Stage.Idle -> PrimaryButton(
                if (vm.ready.size > 1) stringResource(R.string.home_start_n, vm.ready.size) else stringResource(R.string.home_start),
                vm::start,
                enabled = vm.ready.isNotEmpty() && vm.envOk,
            )
            Stage.Running -> SecondaryButton(stringResource(R.string.home_stop), vm::stop)
            Stage.Finished -> PrimaryButton(stringResource(R.string.home_finish), vm::finish)
        }
    }
}

@Composable
private fun BarNote(text: String) {
    Text(text, style = MiuixTheme.textStyles.footnote1, color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
}

@Composable
private fun EnvBanner(vm: PairViewModel) {
    val err = errorText(ErrorCode.NoUsbmux, noHost = !vm.usbHostSupported)
    Row(
        Modifier.padding(horizontal = 12.dp).padding(bottom = 12.dp).fillMaxWidth().clip(RoundedCornerShape(16.dp))
            .background(MiuixTheme.colorScheme.error.copy(alpha = 0.10f)).padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(err.title, color = MiuixTheme.colorScheme.error, fontWeight = FontWeight.SemiBold, style = MiuixTheme.textStyles.body2)
            Text(err.body, color = MiuixTheme.colorScheme.onSurfaceVariantSummary, style = MiuixTheme.textStyles.footnote1)
        }
        MockButton(stringResource(R.string.home_how_to_fix)) { vm.envDialog = true }
    }
}

@Composable
private fun DoneCard() {
    Card(Modifier.padding(horizontal = 12.dp).padding(bottom = 12.dp)) {
        Row(Modifier.fillMaxWidth().padding(18.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(52.dp).clip(CircleShape).background(PairColors.ok.copy(alpha = 0.14f)),
                contentAlignment = Alignment.Center,
            ) { Icon(MiuixIcons.Ok, contentDescription = null, tint = PairColors.ok, modifier = Modifier.size(28.dp)) }
            Spacer(Modifier.width(16.dp))
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(stringResource(R.string.home_later), style = MiuixTheme.textStyles.footnote1, color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
                LaterLine(stringResource(R.string.home_after_reboot), stringResource(R.string.home_after_reboot_summary))
                LaterLine(stringResource(R.string.home_no_more), stringResource(R.string.home_no_more_summary))
            }
        }
    }
}

@Composable
private fun LaterLine(title: String, summary: String) {
    Column {
        Text(title, style = MiuixTheme.textStyles.body2, fontWeight = FontWeight.Medium)
        Text(summary, style = MiuixTheme.textStyles.footnote1, color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
    }
}

/** One phone. A row that, while pairing, opens to the five steps; what the phone needs from the user is always shown under it. */
@Composable
private fun DeviceCard(vm: PairViewModel, d: DeviceView, solo: Boolean) {
    val started = d.phase != Phase.Detected && !d.unsupported
    val tap = started && !solo
    val expanded = started && (solo || d.udid in vm.open)
    val (kind, label) = chipOf(d, vm.running)
    val info = d.info
    Card(Modifier.padding(horizontal = 12.dp).padding(bottom = 10.dp)) {
        BasicComponent(
            title = d.name,
            summary = (if (info != null) "${info.model} · iOS ${info.ios}" else "…") + " · " + stringResource(R.string.row_port, d.order),
            startAction = { PhoneBadge(d.phase == Phase.Done) },
            endActions = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Chip(kind, label)
                    if (tap) {
                        Icon(
                            MiuixIcons.ChevronForward,
                            contentDescription = null,
                            tint = MiuixTheme.colorScheme.onSurfaceVariantActions,
                            modifier = Modifier.padding(start = 6.dp).size(18.dp).rotate(if (expanded) -90f else 90f),
                        )
                    }
                }
            },
            onClick = if (tap) ({ vm.toggle(d.udid) }) else null,
        )
        if (tap && d.phase != Phase.Done) {
            Box(Modifier.padding(start = 16.dp, end = 16.dp, bottom = 12.dp)) {
                LinearProgress(d.progress, if (d.phase == Phase.Failed) MiuixTheme.colorScheme.error else MiuixTheme.colorScheme.primary)
            }
        }
        if (expanded) {
            Stepper(d)
            if (solo && d.phase != Phase.Failed) Box(Modifier.padding(horizontal = 16.dp).padding(bottom = 12.dp)) { LinearProgress(d.progress) }
        }
        if (started || d.phase == Phase.Failed) Guide(vm, d, solo)
    }
}

@Composable
private fun PhoneBadge(done: Boolean) {
    val tint = if (done) PairColors.ok else MiuixTheme.colorScheme.onSurfaceVariantActions
    Box(
        Modifier.padding(end = 12.dp).size(36.dp).clip(RoundedCornerShape(10.dp)).background(tint.copy(alpha = 0.10f)),
        contentAlignment = Alignment.Center,
    ) { Icon(if (done) MiuixIcons.Ok else MiuixIcons.Phone, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp)) }
}

private enum class StepLook { Wait, Run, Act, Ok, Bad }

@Composable
private fun Stepper(d: DeviceView) {
    val at = stepOf(d)
    val names = stringArrayResource(R.array.steps)
    val primary = MiuixTheme.colorScheme.primary
    val track = MiuixTheme.colorScheme.secondaryContainer
    Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp).padding(bottom = 12.dp)) {
        names.forEachIndexed { i, name ->
            val look = when {
                i < at || d.phase == Phase.Done -> StepLook.Ok
                i == at -> if (d.phase == Phase.Failed) StepLook.Bad else if (d.needsUser) StepLook.Act else StepLook.Run
                else -> StepLook.Wait
            }
            Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                Box(Modifier.fillMaxWidth().height(24.dp), contentAlignment = Alignment.Center) {
                    // The track reaches each step from the left; done steps light it up.
                    if (i > 0) {
                        Box(
                            Modifier.align(Alignment.CenterStart).fillMaxWidth(0.5f).height(2.dp)
                                .background(if (look == StepLook.Wait) track else primary),
                        )
                    }
                    if (i < names.lastIndex) {
                        Box(
                            Modifier.align(Alignment.CenterEnd).fillMaxWidth(0.5f).height(2.dp)
                                .background(if (i < at || d.phase == Phase.Done) primary else track),
                        )
                    }
                    StepDot(look, i + 1)
                }
                Spacer(Modifier.height(4.dp))
                Text(
                    name,
                    fontSize = 11.sp,
                    fontWeight = if (look == StepLook.Wait || look == StepLook.Ok) FontWeight.Normal else FontWeight.Medium,
                    color = if (look == StepLook.Wait) MiuixTheme.colorScheme.onSurfaceVariantActions else MiuixTheme.colorScheme.onSurfaceVariantSummary,
                )
            }
        }
    }
}

@Composable
private fun StepDot(look: StepLook, n: Int) {
    val (bg, fg) = when (look) {
        StepLook.Ok -> MiuixTheme.colorScheme.primary to MiuixTheme.colorScheme.onPrimary
        StepLook.Run -> MiuixTheme.colorScheme.secondaryContainer to MiuixTheme.colorScheme.primary
        StepLook.Act -> PairColors.warn to Color.White
        StepLook.Bad -> MiuixTheme.colorScheme.error to Color.White
        StepLook.Wait -> MiuixTheme.colorScheme.secondaryContainer to MiuixTheme.colorScheme.onSurfaceVariantActions
    }
    Box(Modifier.size(24.dp).clip(CircleShape).background(bg), contentAlignment = Alignment.Center) {
        when (look) {
            StepLook.Ok -> Icon(MiuixIcons.Ok, contentDescription = null, tint = fg, modifier = Modifier.size(14.dp))
            StepLook.Run -> InfiniteProgressIndicator(color = fg, size = 14.dp)
            StepLook.Bad, StepLook.Act -> Text("!", color = fg, fontWeight = FontWeight.Bold, fontSize = 13.sp)
            StepLook.Wait -> Text("$n", color = fg, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

private enum class GuideKind { Trust, DevOff, Reboot, Unlock, Unplugged, Error }

/** What this phone needs from the user right now: the prompt to answer on the iPhone, or an error with its fix. */
@Composable
private fun Guide(vm: PairViewModel, d: DeviceView, big: Boolean) {
    val kind = when {
        d.phase == Phase.Failed -> GuideKind.Error
        !d.connected && d.phase != Phase.Rebooting && d.phase != Phase.Detected && d.phase != Phase.Done -> GuideKind.Unplugged
        d.phase == Phase.Trusting -> GuideKind.Trust
        d.phase == Phase.DevModeGuide -> GuideKind.DevOff
        d.phase == Phase.Rebooting -> GuideKind.Reboot
        d.phase == Phase.ConfirmingDevMode -> GuideKind.Unlock
        else -> null
    } ?: return
    val err = if (kind == GuideKind.Error) errorText(d.error?.code) else null
    val (title, body) = when (kind) {
        GuideKind.Trust -> if (d.locked) stringResource(R.string.guide_locked_title) to stringResource(R.string.guide_locked_body)
        else stringResource(R.string.guide_trust_title) to stringResource(R.string.guide_trust_body)
        GuideKind.DevOff -> stringResource(R.string.guide_dev_off_title) to stringResource(R.string.guide_dev_off_body)
        GuideKind.Reboot -> stringResource(R.string.guide_reboot_title) to stringResource(R.string.guide_reboot_body)
        GuideKind.Unlock -> stringResource(R.string.guide_unlock_title) to stringResource(R.string.guide_unlock_body)
        GuideKind.Unplugged -> stringResource(R.string.guide_unplugged_title) to stringResource(R.string.guide_unplugged_body)
        GuideKind.Error -> err!!.title to err.body
    }
    val tone = when (kind) {
        GuideKind.Error -> MiuixTheme.colorScheme.error
        GuideKind.Reboot -> MiuixTheme.colorScheme.onSurfaceVariantSummary
        else -> MiuixTheme.colorScheme.primary
    }
    val icon: ImageVector? = when (kind) {
        GuideKind.Trust -> MiuixIcons.Lock
        GuideKind.Reboot -> MiuixIcons.Refresh
        GuideKind.Unlock -> MiuixIcons.Unlock
        GuideKind.Unplugged -> MiuixIcons.Phone
        else -> null
    }
    var showDetail by remember(d.udid, d.error?.code) { mutableStateOf(false) }

    Column(
        Modifier.padding(horizontal = 12.dp).padding(bottom = 12.dp).fillMaxWidth().clip(RoundedCornerShape(14.dp))
            .background(tone.copy(alpha = 0.08f)).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (big && icon != null) {
            Box(
                Modifier.padding(bottom = 4.dp).size(56.dp).clip(CircleShape).background(tone.copy(alpha = 0.12f)).align(Alignment.CenterHorizontally),
                contentAlignment = Alignment.Center,
            ) { Icon(icon, contentDescription = null, tint = tone, modifier = Modifier.size(28.dp)) }
        }
        Text(
            title,
            fontWeight = FontWeight.SemiBold,
            color = if (kind == GuideKind.Error) MiuixTheme.colorScheme.error else MiuixTheme.colorScheme.onSurface,
            style = if (big) MiuixTheme.textStyles.title4 else MiuixTheme.textStyles.body1,
        )
        Text(body, style = MiuixTheme.textStyles.body2, color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
        if (kind == GuideKind.DevOff) {
            stringArrayResource(R.array.guide_dev_steps).forEachIndexed { i, s ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        Modifier.size(22.dp).clip(CircleShape).background(MiuixTheme.colorScheme.primary),
                        contentAlignment = Alignment.Center,
                    ) { Text("${i + 1}", color = MiuixTheme.colorScheme.onPrimary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold) }
                    Spacer(Modifier.width(10.dp))
                    Text(s, style = MiuixTheme.textStyles.body2)
                }
            }
        }
        if (err != null) {
            err.steps.forEachIndexed { i, s -> Text("${i + 1}. $s", style = MiuixTheme.textStyles.body2) }
            if (err.hint != null) Text(err.hint, style = MiuixTheme.textStyles.footnote1, color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
            val detail = d.error?.detail
            if (!detail.isNullOrEmpty()) {
                if (showDetail) Text(detail, style = MiuixTheme.textStyles.footnote2, color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
                else TextButton(stringResource(R.string.dialog_detail), { showDetail = true }, minHeight = 30.dp, insideMargin = PaddingValues(horizontal = 0.dp, vertical = 4.dp))
            }
        }
        if (kind == GuideKind.Reboot) Text(stringResource(R.string.guide_no_unplug), color = PairColors.warn, style = MiuixTheme.textStyles.body2, fontWeight = FontWeight.Medium)

        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.weight(1f)) {
                when {
                    kind == GuideKind.Trust || kind == GuideKind.Unlock || kind == GuideKind.DevOff -> Waiting(stringResource(R.string.guide_waiting))
                    kind == GuideKind.Reboot -> Waiting(stringResource(R.string.guide_elapsed, elapsed(d.phaseSince)))
                    d.unsupported -> Text(stringResource(R.string.guide_skipped), style = MiuixTheme.textStyles.footnote1, color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
                }
            }
            when {
                kind == GuideKind.Unlock -> MockButton(stringResource(R.string.guide_no_prompt)) { vm.command(d.udid, "recheck") }
                kind != GuideKind.Error || d.unsupported -> Unit
                d.error?.code == ErrorCode.DevModeCancelled -> PrimaryButton(stringResource(R.string.dialog_recheck), { vm.command(d.udid, "retry") })
                d.error?.code == ErrorCode.RebootTimeout -> {
                    SecondaryButton(stringResource(R.string.dialog_recheck), { vm.command(d.udid, "recheck") })
                    PrimaryButton(stringResource(R.string.dialog_keep_waiting), { vm.command(d.udid, "retry") })
                }
                else -> PrimaryButton(stringResource(R.string.dialog_retry), { vm.command(d.udid, "retry") })
            }
        }
        if (!big && vm.shown.size > 1 && kind != GuideKind.Reboot && !d.unsupported) {
            Text(stringResource(R.string.guide_other), style = MiuixTheme.textStyles.footnote1, color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
        }
        if (vm.mock && kind != GuideKind.Reboot && !d.unsupported) {
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                when {
                    kind == GuideKind.Trust -> {
                        if (d.locked) MockButton(stringResource(R.string.mock_unlock)) { vm.core.mockPhone(d.udid, "unlock") }
                        MockButton(stringResource(R.string.mock_trust)) { vm.core.mockPhone(d.udid, "trust") }
                        MockButton(stringResource(R.string.mock_dont_trust)) { vm.core.mockPhone(d.udid, "dontTrust") }
                    }
                    kind == GuideKind.DevOff -> MockButton(stringResource(R.string.mock_restart)) { vm.core.mockPhone(d.udid, "restart") }
                    kind == GuideKind.Unlock -> {
                        MockButton(stringResource(R.string.mock_turn_on)) { vm.core.mockPhone(d.udid, "turnOn") }
                        MockButton(stringResource(R.string.mock_cancel)) { vm.core.mockPhone(d.udid, "cancel") }
                    }
                    kind == GuideKind.Unplugged || d.error?.code == ErrorCode.Disconnected ->
                        MockButton(stringResource(R.string.mock_plug)) { vm.core.mockPhone(d.udid, "plug") }
                    d.error?.code == ErrorCode.AppNotFound -> MockButton(stringResource(R.string.mock_install)) { vm.core.mockPhone(d.udid, "installApp") }
                }
            }
        }
    }
}

/** m:ss since `since`, ticking every second. */
@Composable
private fun elapsed(since: Long): String {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(since) {
        while (true) {
            now = System.currentTimeMillis()
            delay(1000)
        }
    }
    val s = ((now - since) / 1000).coerceAtLeast(0)
    return "%d:%02d".format(s / 60, s % 60)
}

/** What the environment check found. */
@Composable
private fun EnvSheet(vm: PairViewModel, show: Boolean, onDismiss: () -> Unit) {
    OverlayBottomSheet(show = show, title = stringResource(R.string.env_title), onDismissRequest = onDismiss) {
        val ok = stringResource(R.string.env_normal)
        val bad = stringResource(R.string.env_unavailable)
        val muxOk = vm.env?.usbmuxOk ?: false
        Column(Modifier.padding(bottom = 16.dp)) {
            Card(Modifier.padding(bottom = 12.dp)) {
                InfoRow(
                    stringResource(R.string.env_usb_host), stringResource(R.string.env_usb_host_summary),
                    end = if (vm.usbHostSupported) ok else bad,
                    endColor = if (vm.usbHostSupported) PairColors.ok else MiuixTheme.colorScheme.error,
                )
                InfoRow(
                    stringResource(R.string.env_mux), stringResource(R.string.env_mux_summary),
                    end = if (vm.env == null) stringResource(R.string.env_checking) else if (muxOk) ok else bad,
                    endColor = if (vm.env == null) null else if (muxOk) PairColors.ok else MiuixTheme.colorScheme.error,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                SecondaryButton(stringResource(R.string.dialog_close), onDismiss, Modifier.weight(1f))
                PrimaryButton(stringResource(R.string.dialog_redetect), vm::redetect, Modifier.weight(1f))
            }
        }
    }
}
