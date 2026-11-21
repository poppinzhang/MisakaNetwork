package com.misakanetwork.last_order

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder

/** Keeps the existing Flutter engine's mTLS status polling process foreground while monitoring. */
class TicketMonitorService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        starting = false
        val promoted = try {
            startForeground(STATUS_ID, statusNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            true
        } catch (_: IllegalStateException) {
            false // Android can refuse promotion if visibility or the data-sync quota has changed.
        } catch (_: SecurityException) {
            false
        }
        // A stop can arrive between startForegroundService() and this callback. Always fulfill
        // the promotion contract first, then remove the notification immediately if cancelled.
        if (promoted && waiting.isNotEmpty()) {
            running = this
        } else {
            finishMonitoring()
        }
        replyToStarts(promoted && isRunning)
        return START_NOT_STICKY
    }

    private fun statusNotification(): Notification {
        val manager = requireNotNull(getSystemService(NotificationManager::class.java))
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "后台任务监控", NotificationManager.IMPORTANCE_LOW).apply {
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
            },
        )
        val open = Intent.makeMainActivity(ComponentName(this, MainActivity::class.java)).apply {
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_ticket_notification)
            .setContentTitle("正在监控抢票结果")
            .setContentText("点按打开 LastOrder 查看任务进度。")
            .setContentIntent(PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_IMMUTABLE))
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .build()
    }

    override fun onTimeout(startId: Int, fgsType: Int) = finishMonitoring()

    private fun finishMonitoring() {
        if (running === this) running = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        if (running === this) running = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "ticket_monitoring"
        private const val STATUS_ID = 2
        // Both the platform channel and Service callbacks run on the Android main thread.
        private var running: TicketMonitorService? = null
        private var starting = false
        private val waiting = mutableListOf<(Boolean) -> Unit>()
        internal val isRunning: Boolean get() = running != null

        internal fun start(context: Context, reply: (Boolean) -> Unit) {
            if (isRunning) {
                reply(true)
                return
            }
            waiting.add(reply)
            if (starting) return
            starting = true
            try {
                context.startForegroundService(Intent(context, TicketMonitorService::class.java))
                return
            } catch (_: IllegalStateException) {
                // The activity may have just moved to the background.
            } catch (_: SecurityException) {
                // Foreground service access may be restricted by system policy.
            }
            starting = false
            replyToStarts(false)
        }

        internal fun stop() {
            running?.finishMonitoring()
            replyToStarts(false)
        }

        private fun replyToStarts(active: Boolean) {
            val replies = waiting.toList()
            waiting.clear()
            replies.forEach { it(active) }
        }
    }
}
