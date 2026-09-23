package com.lantransfer.lan_transfer_client

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var discovery: NativeDiscovery? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val methods = MethodChannel(messenger, "lan_transfer/discover")
        val events = EventChannel(messenger, "lan_transfer/discover_events")
        val disc = NativeDiscovery(applicationContext, methods, events)
        disc.attach()
        discovery = disc
        try {
            disc.start(5000)
            log("native discover listening")
        } catch (e: Exception) {
            log("native discover fail: ${e.javaClass.simpleName}: ${e.message}")
        }
    }

    override fun onStart() {
        super.onStart()
        acquireMulticastLock()
    }

    override fun onStop() {
        releaseMulticastLock()
        super.onStop()
    }

    override fun onDestroy() {
        try {
            discovery?.stop()
        } catch (_: Exception) {
        }
        discovery = null
        super.onDestroy()
    }

    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            ?: return
        multicastLock = wifi.createMulticastLock("lant_discover").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseMulticastLock() {
        try {
            if (multicastLock?.isHeld == true) multicastLock?.release()
        } catch (_: Exception) {
        }
        multicastLock = null
    }

    private fun log(msg: String) {
        try {
            File(filesDir, "discover.log").appendText("${System.currentTimeMillis()} $msg\n")
        } catch (_: Exception) {
        }
    }
}
