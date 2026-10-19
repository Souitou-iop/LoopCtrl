package app.loopctrl.pair

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** Appearance and language, kept in SharedPreferences and observable from Compose. */
class Prefs(context: Context) {
    private val sp = context.getSharedPreferences("prefs", Context.MODE_PRIVATE)

    var theme by mutableStateOf(sp.getString(KEY_THEME, THEME_AUTO) ?: THEME_AUTO)
        private set
    var lang by mutableStateOf(sp.getString(KEY_LANG, LANG_SYSTEM) ?: LANG_SYSTEM)
        private set

    fun chooseTheme(value: String) {
        theme = value
        sp.edit().putString(KEY_THEME, value).apply()
    }

    fun chooseLang(value: String) {
        lang = value
        sp.edit().putString(KEY_LANG, value).apply()
    }

    companion object {
        private const val KEY_THEME = "theme"
        private const val KEY_LANG = "lang"
        const val THEME_AUTO = "auto"
        const val THEME_LIGHT = "light"
        const val THEME_DARK = "dark"
        const val LANG_SYSTEM = "system"
        const val LANG_ZH = "zh-CN"
        const val LANG_EN = "en"
    }
}
