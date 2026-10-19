package app.loopctrl.pair.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.background
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringArrayResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.loopctrl.pair.R
import app.loopctrl.pair.core.DeviceView
import app.loopctrl.pair.core.Phase
import app.loopctrl.pair.core.Step
import top.yukonga.miuix.kmp.basic.BasicComponent
import top.yukonga.miuix.kmp.basic.Card
import top.yukonga.miuix.kmp.basic.SmallTitle
import top.yukonga.miuix.kmp.basic.TabRow
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.overlay.OverlayBottomSheet
import top.yukonga.miuix.kmp.theme.MiuixTheme

enum class ChipKind { Wait, Run, Act, Ok, Bad, Off }

@Composable
fun chipOf(d: DeviceView): Pair<ChipKind, String> {
    if (!d.connected && d.phase != Phase.Done && d.phase != Phase.Rebooting && d.phase != Phase.Failed) {
        return ChipKind.Off to stringResource(R.string.batch_disconnected)
    }
    return when {
        d.phase == Phase.Trusting -> if (d.locked) ChipKind.Act to stringResource(R.string.chip_locked) else ChipKind.Wait to stringResource(R.string.chip_trusting)
        d.phase == Phase.Done -> ChipKind.Ok to stringResource(R.string.chip_done)
        d.phase == Phase.Failed -> ChipKind.Bad to stringResource(R.string.chip_failed)
        d.phase == Phase.Detected -> ChipKind.Wait to stringResource(R.string.chip_detected)
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
}

/** Index into the five sheet steps (信任 / 开发者模式 / 生成 / 写入 / 校验). */
fun sheetStep(d: DeviceView): Int = if (d.phase == Phase.Failed) {
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
        ChipKind.Run -> MiuixTheme.colorScheme.primary
        ChipKind.Act -> PairColors.warn
        ChipKind.Ok -> PairColors.ok
        ChipKind.Bad -> MiuixTheme.colorScheme.error
        ChipKind.Wait, ChipKind.Off -> MiuixTheme.colorScheme.onSurfaceVariantSummary
    }
    Text(
        label,
        color = color,
        fontSize = 12.sp,
        fontWeight = FontWeight.Medium,
        modifier = Modifier.clip(RoundedCornerShape(10.dp)).background(color.copy(alpha = 0.12f)).padding(horizontal = 8.dp, vertical = 3.dp),
    )
}

@Composable
fun BatchScreen(vm: PairViewModel, bottom: PaddingValues) {
    var filter by remember { mutableIntStateOf(0) }
    val devs = vm.devices
    val doneN = devs.count { it.phase == Phase.Done }
    val actN = devs.count { it.attention }
    val connected = devs.count { it.connected }
    val avg = if (devs.isEmpty()) 0f else devs.sumOf { it.progress.toDouble() }.toFloat() / devs.size
    val list = devs.filter {
        when (filter) {
            1 -> it.attention
            2 -> !it.attention && it.phase != Phase.Done
            3 -> it.phase == Phase.Done
            else -> true
        }
    }.sortedWith(compareByDescending<DeviceView> { it.attention }.thenBy { it.order })
    val tabs = listOf(
        stringResource(R.string.batch_all), stringResource(R.string.batch_act, actN),
        stringResource(R.string.batch_run), stringResource(R.string.batch_ok),
    )

    Page(stringResource(R.string.batch_title), stringResource(R.string.batch_meta, connected, actN), bottom) {
        Card(Modifier.padding(horizontal = 12.dp).padding(bottom = 12.dp)) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.batch_done, doneN, devs.size), fontSize = 22.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                    if (vm.mock) {
                        MockButton(stringResource(R.string.batch_reset_demo), vm::resetDemo)
                    } else if (devs.any { it.phase == Phase.Done || !it.connected }) {
                        MockButton(stringResource(R.string.batch_clear_done), vm::clearDone)
                    }
                }
                LinearProgress(avg)
            }
        }
        Block { Note(text = stringResource(R.string.batch_hub)) }
        TabRow(tabs, filter, { filter = it }, Modifier.padding(horizontal = 12.dp).padding(bottom = 12.dp))
        if (list.isEmpty()) {
            Text(
                stringResource(if (devs.isEmpty()) R.string.batch_none else R.string.batch_empty),
                color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                style = MiuixTheme.textStyles.body2,
                modifier = Modifier.fillMaxWidth().padding(24.dp),
            )
        } else {
            Section(null) {
                for (d in list) {
                    val (kind, label) = chipOf(d)
                    BasicComponent(
                        title = d.name,
                        summary = "${d.info?.model ?: "…"} · iOS ${d.info?.ios ?: "…"} · ${stringResource(R.string.batch_port, d.order)}",
                        endActions = { Chip(kind, label) },
                        onClick = { vm.sheet = d.udid },
                    )
                }
            }
        }
        if (vm.mock && devs.isEmpty()) MockRow(vm) { MockButton(stringResource(R.string.mock_batch)) { vm.core.mockBatch() } }
    }
    DeviceSheet(vm)
}

@Composable
private fun DeviceSheet(vm: PairViewModel) {
    val d = vm.devices.firstOrNull { it.udid == vm.sheet }
    OverlayBottomSheet(show = d != null, title = d?.name, onDismissRequest = { vm.sheet = null }) {
        if (d == null) return@OverlayBottomSheet
        val at = sheetStep(d)
        val (_, chipLabel) = chipOf(d)
        val steps = stringArrayResource(R.array.batch_steps)
        val err = if (d.phase == Phase.Failed) errorText(d.error?.code) else null
        val hint: Pair<String, String>? = when (d.phase) {
            Phase.Trusting -> if (d.locked) stringResource(R.string.hint_locked_title) to stringResource(R.string.hint_locked)
            else stringResource(R.string.hint_trust_title) to stringResource(R.string.hint_trust)
            Phase.DevModeGuide -> stringResource(R.string.hint_dev_off_title) to stringResource(R.string.hint_dev_off)
            Phase.Rebooting -> stringResource(R.string.hint_reboot_title) to stringResource(R.string.hint_reboot)
            Phase.ConfirmingDevMode -> stringResource(R.string.hint_unlock_title) to stringResource(R.string.hint_unlock)
            Phase.Failed -> err!!.title to (err.body + " " + err.steps.joinToString("；"))
            else -> null
        }
        Column(Modifier.padding(bottom = 16.dp)) {
            Text(
                "${d.info?.model ?: ""} · iOS ${d.info?.ios ?: ""} · ${stringResource(R.string.batch_port, d.order)}",
                style = MiuixTheme.textStyles.body2,
                color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                modifier = Modifier.padding(bottom = 12.dp),
            )
            Card(Modifier.padding(bottom = 12.dp)) {
                steps.forEachIndexed { i, name ->
                    val st = when {
                        i < at -> StepState.Ok
                        i == at -> if (d.phase == Phase.Done) StepState.Ok else if (d.attention) StepState.Bad else StepState.Run
                        else -> StepState.Wait
                    }
                    StepRow(st, name, end = when (st) {
                        StepState.Ok -> stringResource(if (i == 1) R.string.step_on else R.string.step_done)
                        StepState.Wait -> stringResource(R.string.step_wait)
                        else -> chipLabel
                    })
                }
            }
            if (hint != null) {
                SmallTitle(stringResource(R.string.batch_need_you), insideMargin = PaddingValues(horizontal = 2.dp, vertical = 8.dp))
                Note(hint.first, hint.second)
                Row(Modifier.padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (d.phase == Phase.Failed && d.error?.code != app.loopctrl.pair.core.ErrorCode.Unsupported) {
                        MockButton(stringResource(R.string.dialog_retry)) { vm.command(d.udid, "retry") }
                    }
                    if (vm.mock) {
                        when {
                            d.phase == Phase.Trusting -> MockButton(stringResource(if (d.locked) R.string.mock_unlock else R.string.mock_trust)) {
                                vm.core.mockPhone(d.udid, if (d.locked) "unlock" else "trust")
                            }
                            d.phase == Phase.DevModeGuide -> MockButton(stringResource(R.string.mock_restart)) { vm.core.mockPhone(d.udid, "restart") }
                            d.phase == Phase.ConfirmingDevMode -> MockButton(stringResource(R.string.mock_turn_on)) { vm.core.mockPhone(d.udid, "turnOn") }
                            d.error?.code == app.loopctrl.pair.core.ErrorCode.AppNotFound -> MockButton(stringResource(R.string.mock_install)) { vm.core.mockPhone(d.udid, "installApp") }
                        }
                    }
                }
            }
            Row(Modifier.fillMaxWidth().padding(top = 12.dp)) {
                SecondaryButton(stringResource(R.string.dialog_close), { vm.sheet = null }, Modifier.weight(1f))
            }
        }
    }
}
