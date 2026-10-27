package app.loopctrl.pair.core

import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import org.junit.Test

/** The JSON shapes are pair-core's serde output (ui/src/lib/api.ts mirrors them too). */
class JsonTest {
    private val failed = """
        {"type":"device","device":{"udid":"00008150-000878A02699401C","order":2,"connected":true,
        "info":{"udid":"00008150-000878A02699401C","name":"测试机","model":"iPhone 17","productType":"iPhone18,3","ios":"27.2"},
        "phase":"failed","error":{"code":"appNotFound","detail":"no LoopCtrl among user apps"},"failedAt":"findApp",
        "progress":0.6,"attention":true,"devModeWasOff":false,"recordKind":"remotePairing","rpVia":"lockdownService",
        "app":null,"writeVia":null,"locked":false,"phaseSince":1760000000000,"doneAt":null}}
    """.trimIndent()

    @Test
    fun parsesAFailedDevice() {
        val e = assertIs<CoreEvent.Device>(Json.event(failed))
        val d = e.device
        assertEquals("00008150-000878A02699401C", d.udid)
        assertEquals(Phase.Failed, d.phase)
        assertEquals(Step.FindApp, d.failedAt)
        assertEquals(ErrorCode.AppNotFound, d.error?.code)
        assertEquals("iPhone 17", d.info?.model)
        assertEquals("remotePairing", d.recordKind)
        assertEquals(1760000000000, d.phaseSince)
        assertNull(d.doneAt)
        assertNull(d.app)
    }

    @Test
    fun parsesOtherEventsAndEnv() {
        assertEquals(CoreEvent.Removed("U1"), Json.event("""{"type":"removed","udid":"U1"}"""))
        assertEquals(CoreEvent.Watch(false, "socket"), Json.event("""{"type":"watch","ok":false,"detail":"socket"}"""))
        assertNull(Json.event("""{"type":"later"}"""))
        val env = Json.env("""{"os":"android","osVersion":"16","usbmuxOk":true,"usbmuxAddr":"/data/x.sock","detail":null}""")
        assertEquals(EnvReport("android", "16", true, "/data/x.sock", null), env)
    }

    @Test
    fun wireNamesMatchPairCore() {
        assertEquals("confirmingDevMode", Phase.ConfirmingDevMode.wire)
        assertEquals(Phase.DevModeGuide, Phase.of("devModeGuide"))
        assertEquals(ErrorCode.Internal, ErrorCode.of("somethingNew"))
    }
}
