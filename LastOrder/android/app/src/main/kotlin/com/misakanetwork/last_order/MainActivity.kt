package com.misakanetwork.last_order

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var embedded: EmbeddedBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        embedded = EmbeddedBridge(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "misaka/embedded")
            .setMethodCallHandler { call, result -> embedded!!.handle(call, result) }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "misaka/embedded")
            .setMethodCallHandler(null)
        embedded?.close()
        embedded = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
