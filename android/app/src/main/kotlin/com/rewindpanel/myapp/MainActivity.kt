package com.rewindpanel.myapp

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// One method, "isVpnActive" — used by the CFG > Admin server list to know
// whether to even attempt reaching a Tailscale-range saved server (no
// point probing a 100.64.0.0/10 host if there's no VPN carrying it right
// now) versus which ones are worth checking. ACCESS_NETWORK_STATE is
// already declared in the manifest for other features, so this needs no
// new permission.
private const val CHANNEL = "rewind/network"

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isVpnActive" -> result.success(isVpnActive())
                else -> result.notImplemented()
            }
        }
    }

    private fun isVpnActive(): Boolean {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return false
        val network = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(network) ?: return false
        return caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
    }
}
