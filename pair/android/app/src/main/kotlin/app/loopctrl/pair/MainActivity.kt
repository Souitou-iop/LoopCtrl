package app.loopctrl.pair

import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.DisposableEffect
import app.loopctrl.pair.ui.PairRoot
import app.loopctrl.pair.ui.PairTheme
import java.util.Locale

class MainActivity : ComponentActivity() {
    /** Applies the language picked in Settings (the system's when unset). */
    override fun attachBaseContext(base: Context) {
        val lang = base.getSharedPreferences("prefs", MODE_PRIVATE).getString("lang", Prefs.LANG_SYSTEM)
        if (lang == null || lang == Prefs.LANG_SYSTEM) {
            super.attachBaseContext(base)
            return
        }
        val config = Configuration(base.resources.configuration)
        config.setLocale(Locale.forLanguageTag(lang))
        super.attachBaseContext(base.createConfigurationContext(config))
    }

    override fun onResume() {
        super.onResume()
        // An iPhone plugged in while the app was in the background.
        (application as PairApp).usbHost?.rescan()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val prefs = (application as PairApp).prefs
        setContent {
            val dark = when (prefs.theme) {
                Prefs.THEME_LIGHT -> false
                Prefs.THEME_DARK -> true
                else -> isSystemInDarkTheme()
            }
            DisposableEffect(dark) {
                enableEdgeToEdge(
                    statusBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT) { dark },
                    navigationBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT) { dark },
                )
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) window.isNavigationBarContrastEnforced = false
                onDispose {}
            }
            PairTheme(dark) { PairRoot() }
        }
    }
}
