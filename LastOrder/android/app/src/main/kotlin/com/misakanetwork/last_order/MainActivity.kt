package com.misakanetwork.last_order

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var embedded: EmbeddedBridge? = null
    private var notifications: TicketNotifications? = null
    private var activityStarted = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        embedded = EmbeddedBridge(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "misaka/embedded")
            .setMethodCallHandler { call, result -> embedded!!.handle(call, result) }
        notifications = TicketNotifications(this, flutterEngine.dartExecutor.binaryMessenger) { activityStarted }
    }

    override fun onStart() {
        super.onStart()
        activityStarted = true
    }

    override fun onStop() {
        activityStarted = false
        super.onStop()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        notifications?.onPermissionResult(requestCode)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        notifications?.close()
        notifications = null
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "misaka/embedded")
            .setMethodCallHandler(null)
        embedded?.close()
        embedded = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
