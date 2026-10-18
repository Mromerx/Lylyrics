package com.lylyrics.lylyrics

import android.content.ComponentName
import android.service.notification.NotificationListenerService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        const val MEDIA_CHANNEL = "lylyrics/media"
        const val CONTROL_CHANNEL = "lylyrics/control"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Snapshots de sesiones multimedia (pista + estado) hacia Dart.
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MEDIA_CHANNEL,
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, events: EventChannel.EventSink?) {
                MediaEvents.sink = events
                // Estado inmediato: si el servicio ya vive, su snapshot; si
                // no, intentamos reengancharlo y mandamos el permiso real para
                // que la UI no se quede en el panel de "activar permiso".
                val service = MediaListenerService.instance
                if (service != null) {
                    service.pushSnapshot()
                } else {
                    try {
                        NotificationListenerService.requestRebind(
                            ComponentName(this@MainActivity, MediaListenerService::class.java),
                        )
                    } catch (_: Exception) {
                    }
                    events?.success(
                        mapOf(
                            "hasAccess" to
                                MediaControlHelper.hasAccess(this@MainActivity),
                        ),
                    )
                }
            }

            override fun onCancel(args: Any?) {
                MediaEvents.sink = null
            }
        })

        // Órdenes de Dart: permiso, ajustes, seek y play/pausa.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CONTROL_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasAccess" ->
                    result.success(MediaControlHelper.hasAccess(this))
                "openListenerSettings" -> {
                    MediaControlHelper.openSettings(this)
                    result.success(true)
                }
                "seekTo" -> {
                    val pkg: String? = call.argument("package")
                    val ms = (call.argument<Number>("positionMs")?.toLong() ?: 0L)
                    result.success(MediaControlHelper.seekTo(this, pkg, ms))
                }
                "togglePlayPause" -> {
                    val pkg: String? = call.argument("package")
                    result.success(MediaControlHelper.togglePlayPause(this, pkg))
                }
                else -> result.notImplemented()
            }
        }
    }
}
