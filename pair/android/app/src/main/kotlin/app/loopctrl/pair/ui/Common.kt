package app.loopctrl.pair.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.loopctrl.pair.R
import top.yukonga.miuix.kmp.basic.BasicComponent
import top.yukonga.miuix.kmp.basic.ButtonDefaults
import top.yukonga.miuix.kmp.basic.Card
import top.yukonga.miuix.kmp.basic.Icon
import top.yukonga.miuix.kmp.basic.InfiniteProgressIndicator
import top.yukonga.miuix.kmp.basic.MiuixScrollBehavior
import top.yukonga.miuix.kmp.basic.Scaffold
import top.yukonga.miuix.kmp.basic.SmallTitle
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.basic.TextButton
import top.yukonga.miuix.kmp.basic.TopAppBar
import top.yukonga.miuix.kmp.icon.MiuixIcons
import top.yukonga.miuix.kmp.icon.extended.Ok
import top.yukonga.miuix.kmp.theme.ColorSchemeMode
import top.yukonga.miuix.kmp.theme.MiuixTheme
import top.yukonga.miuix.kmp.theme.ThemeController
import top.yukonga.miuix.kmp.utils.overScrollVertical

/** miuix default colors (no Monet), light or dark as chosen in Settings. */
@Composable
fun PairTheme(dark: Boolean, content: @Composable () -> Unit) {
    val controller = androidx.compose.runtime.remember(dark) { ThemeController(ColorSchemeMode.System, isDark = dark) }
    MiuixTheme(controller = controller, content = content)
}

/** Status colors not in the miuix scheme (same values as the desktop CSS). */
object PairColors {
    val ok = Color(0xFF2FB36B)
    val warn = Color(0xFFE8912D)
}

/** A page: collapsing large title (HyperOS style) over a scrolling column. */
@Composable
fun Page(
    title: String,
    subtitle: String = "",
    bottom: PaddingValues = PaddingValues(0.dp),
    navigationIcon: @Composable () -> Unit = {},
    actions: @Composable RowScope.() -> Unit = {},
    content: @Composable ColumnScope.() -> Unit,
) {
    val scroll = MiuixScrollBehavior()
    Scaffold(
        topBar = { TopAppBar(title = title, subtitle = subtitle, navigationIcon = navigationIcon, actions = actions, scrollBehavior = scroll) },
        contentWindowInsets = WindowInsets(0),
    ) { inner ->
        Column(
            Modifier.fillMaxHeight()
                .overScrollVertical()
                .nestedScroll(scroll.nestedScrollConnection)
                .verticalScroll(rememberScrollState())
                .padding(top = inner.calculateTopPadding(), bottom = bottom.calculateBottomPadding() + 24.dp),
            content = content,
        )
    }
}

/** A titled card of rows. */
@Composable
fun Section(title: String?, content: @Composable ColumnScope.() -> Unit) {
    if (title != null) SmallTitle(title)
    Card(Modifier.padding(horizontal = 12.dp).padding(bottom = 12.dp), content = content)
}

@Composable
fun EndText(text: String, color: Color = MiuixTheme.colorScheme.onSurfaceVariantActions) {
    Text(text, color = color, style = MiuixTheme.textStyles.body2)
}

/** A plain row: title, summary, value on the right. */
@Composable
fun InfoRow(title: String, summary: String? = null, end: String? = null, endColor: Color? = null, onClick: (() -> Unit)? = null) {
    BasicComponent(
        title = title,
        summary = summary,
        endActions = end?.let { { EndText(it, endColor ?: MiuixTheme.colorScheme.onSurfaceVariantActions) } },
        onClick = onClick,
    )
}

@Composable
fun Waiting(text: String, modifier: Modifier = Modifier) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        InfiniteProgressIndicator(color = MiuixTheme.colorScheme.primary, size = 16.dp)
        Spacer(Modifier.width(8.dp))
        Text(text, style = MiuixTheme.textStyles.body2, color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
    }
}

/** The centered illustration card used while waiting on the iPhone. */
@Composable
fun Hero(icon: ImageVector?, heading: String, body: String, warn: String? = null, waiting: String? = null, ok: Boolean = false) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        val tint = if (ok) PairColors.ok else MiuixTheme.colorScheme.primary
        if (icon != null) {
            Box(
                Modifier.size(72.dp).clip(CircleShape).background(tint.copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center,
            ) { Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(36.dp)) }
        }
        Text(heading, style = MiuixTheme.textStyles.title4, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
        Text(body, style = MiuixTheme.textStyles.body2, color = MiuixTheme.colorScheme.onSurfaceVariantSummary, textAlign = TextAlign.Center)
        if (warn != null) Text(warn, style = MiuixTheme.textStyles.body2, color = PairColors.warn, textAlign = TextAlign.Center)
        if (waiting != null) Waiting(waiting, Modifier.padding(top = 4.dp))
    }
}

@Composable
fun PrimaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    TextButton(text = text, onClick = onClick, modifier = modifier, enabled = enabled, colors = ButtonDefaults.textButtonColorsPrimary())
}

@Composable
fun SecondaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    TextButton(text = text, onClick = onClick, modifier = modifier, enabled = enabled)
}

/** Simulated phone actions, only in mock mode. */
@Composable
fun MockRow(vm: PairViewModel, content: @Composable RowScope.() -> Unit) {
    if (!vm.mock) return
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 12.dp).padding(bottom = 12.dp)
            .clip(RoundedCornerShape(16.dp)).background(PairColors.warn.copy(alpha = 0.10f))
            .horizontalScroll(rememberScrollState()).padding(8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(stringResource(R.string.mock_tag), color = PairColors.warn, style = MiuixTheme.textStyles.footnote1, modifier = Modifier.padding(horizontal = 6.dp))
        content()
    }
}

@Composable
fun MockButton(text: String, onClick: () -> Unit) {
    TextButton(text = text, onClick = onClick, minWidth = 0.dp, minHeight = 34.dp, insideMargin = PaddingValues(horizontal = 10.dp, vertical = 6.dp))
}

@Composable
fun AppLogo(size: Int = 44) {
    Image(
        painterResource(R.drawable.app_logo),
        contentDescription = null,
        modifier = Modifier.padding(end = 12.dp).size(size.dp).clip(RoundedCornerShape((size * 0.23).dp)),
    )
}

@Composable
fun LinearProgress(fraction: Float, color: Color = MiuixTheme.colorScheme.primary) {
    Box(
        Modifier.fillMaxWidth().height(6.dp).clip(RoundedCornerShape(3.dp)).background(MiuixTheme.colorScheme.secondaryContainer),
    ) {
        Box(Modifier.fillMaxWidth(fraction.coerceIn(0f, 1f)).height(6.dp).clip(RoundedCornerShape(3.dp)).background(color))
    }
}
