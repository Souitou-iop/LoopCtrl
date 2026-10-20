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

/** How to fix the environment (no OTG, or the built-in USB service is down). Phone errors are shown in the phone's own card. */
@Composable
fun ErrorDialog(vm: PairViewModel) {
    val noHost = !vm.usbHostSupported && !vm.mock
    val text = errorText(ErrorCode.NoUsbmux, noHost = noHost)
    val detail = vm.env?.detail
    var showDetail by remember { mutableStateOf(false) }

    OverlayDialog(show = vm.envDialog, title = text.title, summary = text.body, onDismissRequest = { vm.envDialog = false }) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            text.steps.forEachIndexed { i, s -> Text("${i + 1}. $s", style = MiuixTheme.textStyles.body2) }
            if (!detail.isNullOrEmpty()) {
                if (showDetail) {
                    Text(detail, style = MiuixTheme.textStyles.footnote2, color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
                } else {
                    TextButton(stringResource(R.string.dialog_detail), { showDetail = true }, minHeight = 32.dp)
                }
            }
            Row(Modifier.fillMaxWidth().padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                if (noHost) {
                    PrimaryButton(stringResource(R.string.dialog_ok), { vm.envDialog = false }, Modifier.weight(1f))
                } else {
                    SecondaryButton(stringResource(R.string.dialog_cancel), { vm.envDialog = false }, Modifier.weight(1f))
                    PrimaryButton(stringResource(R.string.dialog_redetect), vm::redetect, Modifier.weight(1f))
                }
            }
        }
    }
}
