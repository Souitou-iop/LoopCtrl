package app.loopctrl.pair.core

import android.content.Context
import android.util.Log
import app.loopctrl.pair.bridge.PairBridge
import app.loopctrl.pair.bridge.PairListener
import app.loopctrl.pair.platform.UsbSink
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow

/**
 * The Rust side (pair-core + built-in usbmuxd) behind a small Kotlin API.
 * Events arrive on the manager thread; [events] replays nothing, so the UI
 * reads [devices] once and then follows the events.
 */
class PairCore(context: Context, version: String, startMock: Boolean) : UsbSink {
    private val _events = MutableSharedFlow<CoreEvent>(extraBufferCapacity = 256)
    val events: SharedFlow<CoreEvent> = _events

    private val bridge = PairBridge(
        context.filesDir.absolutePath,
        "LoopCtrl Pair $version (Android)",
        startMock,
        object : PairListener {
            override fun onEvent(json: String) {
                runCatching { Json.event(json) }
                    .onFailure { Log.w(TAG, "bad event $json", it) }
                    .getOrNull()
                    ?.let { _events.tryEmit(it) }
            }
        },
    )

    suspend fun devices(): List<DeviceView> = Json.devices(bridge.devices())
    suspend fun envCheck(): EnvReport = Json.env(bridge.envCheck())

    fun command(udid: String, cmd: String) = runCatching { bridge.command(udid, cmd) }.let { }
    fun setAutoBegin(on: Boolean) = bridge.setAutoBegin(on)
    fun forget(udid: String) = bridge.forget(udid)
    val cacheDir: String get() = bridge.cacheDir()

    val isMock: Boolean get() = bridge.isMock()
    fun setMock(on: Boolean) = bridge.setMock(on)
    fun mockPlug(scenario: String) = runCatching { bridge.mockPlug(scenario) }.let { }
    fun mockBatch() = runCatching { bridge.mockBatch() }.let { }
    fun mockPhone(udid: String, action: String) = runCatching { bridge.mockPhone(udid, action) }.let { }
    fun mockReset() = runCatching { bridge.mockReset() }.let { }

    override suspend fun attachUsbDevice(
        fd: Int,
        serial: String,
        productId: Int,
        epIn: Int,
        epOut: Int,
        maxPacketOut: Int,
        name: String,
    ) {
        bridge.attachUsbDevice(fd, serial, productId.toUShort(), epIn.toUByte(), epOut.toUByte(), maxPacketOut.toUInt(), name)
    }

    override fun detachUsbDevice(name: String) = bridge.detachUsbDevice(name)

    private companion object {
        const val TAG = "LoopCtrlPair"
    }
}
