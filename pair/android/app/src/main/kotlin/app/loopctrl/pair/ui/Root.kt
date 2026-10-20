package app.loopctrl.pair.ui

import android.app.Activity
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import app.loopctrl.pair.BuildConfig
import app.loopctrl.pair.Prefs
import app.loopctrl.pair.R
import top.yukonga.miuix.kmp.basic.BasicComponent
import top.yukonga.miuix.kmp.basic.Icon
import top.yukonga.miuix.kmp.basic.IconButton
import top.yukonga.miuix.kmp.basic.Scaffold
import top.yukonga.miuix.kmp.basic.Switch
import top.yukonga.miuix.kmp.basic.TabRow
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.overlay.OverlayBottomSheet
import top.yukonga.miuix.kmp.theme.MiuixTheme
import top.yukonga.miuix.kmp.icon.MiuixIcons
import top.yukonga.miuix.kmp.icon.extended.Back

const val SOURCE_URL = "https://github.com/Souitou-iop/LoopCtrl-Pair"

@Composable
fun PairRoot(vm: PairViewModel = viewModel()) {
    BackHandler(enabled = vm.view == View.Settings) { vm.view = View.Pair }
    Scaffold(
        bottomBar = { if (vm.view == View.Pair) PairBar(vm) },
    ) { inner ->
        val bottom = PaddingValues(bottom = inner.calculateBottomPadding())
        Box(Modifier.fillMaxSize()) {
            when (vm.view) {
                View.Pair -> PairScreen(vm, bottom)
                View.Settings -> SettingsScreen(vm, bottom)
            }
        }
        ErrorDialog(vm)
    }
}

@Composable
private fun SettingsScreen(vm: PairViewModel, bottom: PaddingValues) {
    val context = LocalContext.current
    val prefs = vm.prefs
    val themes = listOf(Prefs.THEME_AUTO, Prefs.THEME_LIGHT, Prefs.THEME_DARK)
    val langs = listOf(Prefs.LANG_SYSTEM, Prefs.LANG_ZH, Prefs.LANG_EN)
    var showLicenses by remember { mutableStateOf(false) }
    LicensesSheet(showLicenses) { showLicenses = false }
    Page(
        stringResource(R.string.settings_title),
        bottom = bottom,
        navigationIcon = {
            IconButton(onClick = { vm.view = View.Pair }, modifier = Modifier.padding(start = 8.dp)) {
                Icon(MiuixIcons.Back, contentDescription = stringResource(R.string.nav_back))
            }
        },
    ) {
        Section(stringResource(R.string.settings_about)) {
            BasicComponent(
                title = stringResource(R.string.app_name),
                summary = stringResource(R.string.settings_version, BuildConfig.VERSION_NAME),
                startAction = { AppLogo() },
            )
            InfoRow(stringResource(R.string.settings_source), stringResource(R.string.settings_source_summary), end = "›", onClick = {
                runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(SOURCE_URL))) }
            })
            InfoRow(stringResource(R.string.settings_licenses), stringResource(R.string.settings_licenses_summary), end = "›", onClick = { showLicenses = true })
        }
        Section(stringResource(R.string.settings_appearance)) {
            BasicComponent(title = stringResource(R.string.settings_theme))
            TabRow(
                listOf(R.string.settings_theme_auto, R.string.settings_theme_light, R.string.settings_theme_dark).map { stringResource(it) },
                themes.indexOf(prefs.theme).coerceAtLeast(0),
                { prefs.chooseTheme(themes[it]) },
                Modifier.padding(horizontal = 16.dp).padding(bottom = 12.dp),
            )
            BasicComponent(title = stringResource(R.string.settings_language))
            TabRow(
                listOf(stringResource(R.string.settings_lang_system), "简体中文", "English"),
                langs.indexOf(prefs.lang).coerceAtLeast(0),
                {
                    if (langs[it] != prefs.lang) {
                        prefs.chooseLang(langs[it])
                        (context as? Activity)?.recreate()
                    }
                },
                Modifier.padding(horizontal = 16.dp).padding(bottom = 12.dp),
            )
        }
        if (BuildConfig.DEBUG || vm.mock) {
            Section(stringResource(R.string.settings_developer)) {
                BasicComponent(
                    title = stringResource(R.string.settings_mock),
                    summary = stringResource(R.string.settings_mock_summary),
                    endActions = { Switch(vm.mock, { vm.switchMock(it) }) },
                )
                InfoRow(stringResource(R.string.settings_cache_dir), vm.core.cacheDir)
            }
        }
    }
}

/** THIRD_PARTY_NOTICES.md, copied into the assets by `bun run licenses`. */
@Composable
private fun LicensesSheet(show: Boolean, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val text = remember(show) {
        if (!show) "" else runCatching { context.assets.open("THIRD_PARTY_NOTICES.md").bufferedReader().use { it.readText() } }.getOrDefault("")
    }
    OverlayBottomSheet(show = show, title = stringResource(R.string.settings_licenses), onDismissRequest = onDismiss) {
        Text(
            text,
            style = MiuixTheme.textStyles.footnote2,
            modifier = Modifier.heightIn(max = 560.dp).verticalScroll(rememberScrollState()).padding(bottom = 16.dp),
        )
    }
}
