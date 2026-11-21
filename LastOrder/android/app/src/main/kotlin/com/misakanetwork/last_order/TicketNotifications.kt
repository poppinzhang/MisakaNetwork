package com.misakanetwork.last_order

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class TicketNotifications(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val activityVisible: () -> Boolean,
) {
    private val manager = requireNotNull(activity.getSystemService(NotificationManager::class.java))
    private val channel = MethodChannel(messenger, "misaka/notifications")
    private var permissionRequest: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermission" -> requestPermission(result)
                "showSuccess" -> showSuccess(call, result)
                "setBackgroundMonitoring" -> setBackgroundMonitoring(call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun createChannel() {
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "抢票成功", NotificationManager.IMPORTANCE_HIGH),
        )
    }

    private fun hasPermission(): Boolean =
        activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun canNotify(): Boolean = hasPermission() && manager.areNotificationsEnabled() &&
        (manager.getNotificationChannel(CHANNEL_ID)?.importance ?: NotificationManager.IMPORTANCE_NONE) !=
            NotificationManager.IMPORTANCE_NONE

    private fun requestPermission(result: MethodChannel.Result) {
        createChannel()
        if (hasPermission()) {
            result.success(canNotify())
        } else if (permissionRequest != null) {
            result.error("request_pending", "正在等待通知授权", null)
        } else {
            permissionRequest = result
            try {
                activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST)
            } catch (error: RuntimeException) {
                permissionRequest = null
                throw error
            }
        }
    }

    fun onPermissionResult(requestCode: Int) {
        if (requestCode != PERMISSION_REQUEST) return
        val result = permissionRequest ?: return
        permissionRequest = null
        result.success(canNotify())
    }

    private fun setBackgroundMonitoring(call: MethodCall, result: MethodChannel.Result) {
        val enabled = call.arguments as? Boolean
        if (enabled == null) {
            result.error("invalid_arguments", "后台监控参数无效", null)
            return
        }
        if (enabled) createChannel()
        if (!enabled || !canNotify()) {
            TicketMonitorService.stop()
            result.success(false)
            return
        }
        if (!activityVisible()) {
            result.success(TicketMonitorService.isRunning)
            return
        }
        TicketMonitorService.start(activity) { result.success(it) }
    }

    private fun showSuccess(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val id = args?.get("id") as? String
        val title = args?.get("title") as? String
        val body = args?.get("body") as? String
        if (id.isNullOrEmpty() || title.isNullOrEmpty() || body.isNullOrEmpty()) {
            result.error("invalid_arguments", "通知参数无效", null)
            return
        }
        createChannel()
        if (!canNotify()) {
            TicketMonitorService.stop()
            result.success(false)
            return
        }
        val launch = Intent.makeMainActivity(activity.componentName).apply {
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val notification = Notification.Builder(activity, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_ticket_notification)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(PendingIntent.getActivity(activity, 0, launch, PendingIntent.FLAG_IMMUTABLE))
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            .build()
        val accepted = try {
            manager.notify(id, 1, notification)
            true
        } catch (_: SecurityException) {
            false
        }
        result.success(accepted)
    }

    fun close() {
        TicketMonitorService.stop()
        channel.setMethodCallHandler(null)
        permissionRequest?.success(false)
        permissionRequest = null
    }

    private companion object {
        const val CHANNEL_ID = "ticket_success"
        const val PERMISSION_REQUEST = 20002
    }
}
