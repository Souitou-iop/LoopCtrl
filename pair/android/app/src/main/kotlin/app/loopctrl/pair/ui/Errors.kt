package app.loopctrl.pair.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringArrayResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import app.loopctrl.pair.R
import app.loopctrl.pair.core.DeviceView
import app.loopctrl.pair.core.ErrorCode
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.basic.TextButton
import top.yukonga.miuix.kmp.overlay.OverlayDialog
import top.yukonga.miuix.kmp.theme.MiuixTheme

data class ErrorText(val title: String, val body: String, val steps: List<String>, val hint: String? = null)

/** Copy for an error code; `noHost` is the Android-only "no OTG" case. */
@Composable
fun errorText(code: ErrorCode?, noHost: Boolean = false): ErrorText {
    if (noHost) return ErrorText(stringResource(R.string.err_noHost_title), stringResource(R.string.err_noHost_body), emptyList())
    data class Res(val t: Int, val b: Int, val s: Int, val h: Int? = null)
    val r = when (code) {
        // No Apple Devices on Android: a missing muxer is the same problem.
        ErrorCode.NoDriver, ErrorCode.NoUsbmux -> Res(R.string.err_noUsbmux_title, R.string.err_noUsbmux_body, R.array.err_noUsbmux_steps)
        ErrorCode.Untrusted -> Res(R.string.err_untrusted_title, R.string.err_untrusted_body, R.array.err_untrusted_steps, R.string.err_untrusted_hint)
        ErrorCode.DevModeCancelled -> Res(R.string.err_devModeCancelled_title, R.string.err_devModeCancelled_body, R.array.err_devModeCancelled_steps)
        ErrorCode.RebootTimeout -> Res(R.string.err_rebootTimeout_title, R.string.err_rebootTimeout_body, R.array.err_rebootTimeout_steps)
        ErrorCode.Unsupported -> Res(R.string.err_unsupported_title, R.string.err_unsupported_body, R.array.err_unsupported_steps)
        ErrorCode.RecordFailed -> Res(R.string.err_recordFailed_title, R.string.err_recordFailed_body, R.array.err_recordFailed_steps)
        ErrorCode.AppNotFound -> Res(R.string.err_appNotFound_title, R.string.err_appNotFound_body, R.array.err_appNotFound_steps)
        ErrorCode.WriteFailed -> Res(R.string.err_writeFailed_title, R.string.err_writeFailed_body, R.array.err_writeFailed_steps, R.string.err_writeFailed_hint)
        ErrorCode.VerifyFailed -> Res(R.string.err_verifyFailed_title, R.string.err_verifyFailed_body, R.array.err_verifyFailed_steps)
        ErrorCode.Disconnected -> Res(R.string.err_disconnected_title, R.string.err_disconnected_body, R.array.err_disconnected_steps)
        ErrorCode.Internal, null -> Res(R.string.err_internal_title, R.string.err_internal_body, R.array.err_internal_steps)
    }
    return ErrorText(stringResource(r.t), stringResource(r.b), stringArrayResource(r.s).toList(), r.h?.let { stringResource(it) })
}

private data class Btn(val label: String, val run: () -> Unit)

/** One dialog for every error: a failed phone in single mode, or the environment. */
@Composable
fun ErrorDialog(vm: PairViewModel) {
    val failed: DeviceView? = vm.current?.takeIf {
        vm.page == Page.Single && vm.started && it.phase == app.loopctrl.pair.core.Phase.Failed
    }
    val showEnv = vm.envDialog && failed == null
    val show = failed != null || showEnv
    val code = if (showEnv) ErrorCode.NoUsbmux else failed?.error?.code
    val text = errorText(code, noHost = showEnv && !vm.usbHostSupported)
    val detail = if (showEnv) vm.env?.detail else failed?.error?.detail
    var showDetail by remember(failed?.udid, code) { mutableStateOf(false) }

    val cancel = stringResource(R.string.dialog_cancel)
    val retry = stringResource(R.string.dialog_retry)
    val buttons: Pair<Btn, Btn?> = if (showEnv) {
        if (!vm.usbHostSupported) Btn(stringResource(R.string.dialog_ok)) { vm.envDialog = false } to null
        else Btn(cancel) { vm.envDialog = false } to Btn(stringResource(R.string.dialog_redetect), vm::redetect)
    } else {
        val udid = failed?.udid ?: ""
        when (code) {
            ErrorCode.DevModeCancelled -> Btn(stringResource(R.string.dialog_later)) { vm.cancelToWelcome(udid) } to
                Btn(stringResource(R.string.dialog_recheck)) { vm.command(udid, "retry") }
            ErrorCode.RebootTimeout -> Btn(stringResource(R.string.dialog_recheck)) { vm.command(udid, "recheck") } to
                Btn(stringResource(R.string.dialog_keep_waiting)) { vm.command(udid, "retry") }
            ErrorCode.Unsupported -> Btn(stringResource(R.string.back), vm::finish) to
                Btn(stringResource(R.string.dialog_ok)) { vm.skip(udid) }
            else -> Btn(cancel) { vm.cancelToWelcome(udid) } to Btn(retry) { vm.command(udid, "retry") }
        }
    }

    OverlayDialog(show = show, title = text.title, summary = text.body, onDismissRequest = null) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            text.steps.forEachIndexed { i, s -> Text("${i + 1}. $s", style = MiuixTheme.textStyles.body2) }
            if (text.hint != null) {
                Text(text.hint, style = MiuixTheme.textStyles.footnote1, color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
            }
            if (!detail.isNullOrEmpty()) {
                if (showDetail) {
                    Text(detail, style = MiuixTheme.textStyles.footnote2, color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
                } else {
                    TextButton(stringResource(R.string.dialog_detail), { showDetail = true }, minHeight = 32.dp)
                }
            }
            if (failed != null && vm.mock) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    when (code) {
                        ErrorCode.AppNotFound -> MockButton(stringResource(R.string.mock_install)) { vm.core.mockPhone(failed.udid, "installApp") }
                        ErrorCode.Disconnected -> MockButton(stringResource(R.string.mock_plug)) { vm.core.mockPhone(failed.udid, "plug") }
                        else -> Unit
                    }
                }
            }
            Row(Modifier.fillMaxWidth().padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                val (first, second) = buttons
                if (second == null) {
                    PrimaryButton(first.label, first.run, Modifier.weight(1f))
                } else {
                    SecondaryButton(first.label, first.run, Modifier.weight(1f))
                    PrimaryButton(second.label, second.run, Modifier.weight(1f))
                }
            }
        }
    }
}
