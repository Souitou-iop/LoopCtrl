package app.loopctrl.pair

import android.app.Application
import android.content.pm.PackageManager
import app.loopctrl.pair.core.PairCore
import app.loopctrl.pair.platform.UsbHost

class PairApp : Application() {
    lateinit var prefs: Prefs
        private set
    lateinit var core: PairCore
        private set
    var usbHost: UsbHost? = null
        private set

    /** Can this phone be a USB host (OTG) at all? */
    val usbHostSupported: Boolean by lazy { packageManager.hasSystemFeature(PackageManager.FEATURE_USB_HOST) }

    override fun onCreate() {
        super.onCreate()
        prefs = Prefs(this)
        val version = packageManager.getPackageInfo(packageName, 0).versionName ?: "0"
        core = PairCore(this, version, BuildConfig.START_MOCK)
        if (usbHostSupported) usbHost = UsbHost(this, core).also { it.start() }
    }
}
