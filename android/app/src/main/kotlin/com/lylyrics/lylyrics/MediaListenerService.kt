package com.lylyrics.lylyrics

import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import io.flutter.plugin.common.EventChannel

// ---------------------------------------------------------------------------
// Bus de snapshots hacia Dart (un solo suscriptor: AndroidMediaSource).
// ---------------------------------------------------------------------------

/** Último sumidero del EventChannel `lylyrics/media`, si hay UI escuchando. */
object MediaEvents {
    var sink: EventChannel.EventSink? = null

    fun emit(snapshot: Map<String, Any?>) {
        try {
            sink?.success(snapshot)
        } catch (e: Exception) {
            Log.w(MediaListenerService.TAG, "No se pudo emitir snapshot: $e")
        }
    }
}

// ---------------------------------------------------------------------------
// Servicio: lee sesiones multimedia activas y las publica.
// ---------------------------------------------------------------------------

/**
 * Escucha notificaciones + sesiones multimedia del sistema.
 *
 * Android no tiene MPRIS: la forma oficial de saber qué suena en otra app es
 * [MediaSessionManager], que exige tener un NotificationListenerService
 * activo. Este servicio sondea las sesiones activas cada segundo y empuja un
 * snapshot a Dart; la selección del
 * reproductor, la deduplicación y la interpolación viven en Dart
 * (igual que con MPRIS en Linux).
 */
class MediaListenerService : NotificationListenerService() {

    companion object {
        var instance: MediaListenerService? = null
            private set
        const val TAG = "LylyricsMedia"
        const val POLL_MS = 1000L
    }

    private val handler = Handler(Looper.getMainLooper())
    private var polling = false
    private val controllers = mutableMapOf<String, MediaController>()

    private val poller = object : Runnable {
        override fun run() {
            pushSnapshot()
            if (polling) handler.postDelayed(this, POLL_MS)
        }
    }

    private val sessionCallback = object : MediaController.Callback() {
        override fun onPlaybackStateChanged(state: PlaybackState?) = pushSnapshot()
        override fun onMetadataChanged(metadata: MediaMetadata?) = pushSnapshot()
        override fun onSessionDestroyed() = pushSnapshot()
    }

    override fun onListenerConnected() {
        Log.i(TAG, "Listener de notificaciones conectado")
        instance = this
        startPolling()
    }

    override fun onListenerDisconnected() {
        Log.i(TAG, "Listener de notificaciones desconectado; se solicita reenganche")
        stopPolling()
        if (instance === this) instance = null
        // En varios fabricantes el servicio no vuelve solo tras desconectarse
        // (sobre todo por gestión agresiva de batería). Sin este reenganche la
        // app se queda sin ver ninguna sesión hasta reiniciar el dispositivo.
        scheduleRebind()
    }

    /** Pide al sistema que vuelva a enganchar este listener. */
    private fun scheduleRebind() {
        try {
            // Llamada estática sobre la clase base: los estáticos de Java no
            // se heredan en Kotlin, así que no vale MediaListenerService.xxx.
            NotificationListenerService.requestRebind(component())
        } catch (e: Exception) {
            Log.w(TAG, "No se pudo solicitar reenganche: $e")
        }
    }

    override fun onDestroy() {
        stopPolling()
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) = pushSnapshot()

    override fun onNotificationRemoved(sbn: StatusBarNotification?) = pushSnapshot()

    /** Envía el snapshot actual a Dart, si hay alguien escuchando. */
    fun pushSnapshot() {
        try {
            MediaEvents.emit(buildSnapshot())
        } catch (e: Exception) {
            Log.w(TAG, "Snapshot fallido: $e")
        }
    }

    private fun startPolling() {
        if (polling) return
        polling = true
        handler.post(poller)
    }

    private fun stopPolling() {
        polling = false
        handler.removeCallbacks(poller)
        synchronized(controllers) {
            for ((_, controller) in controllers) {
                try {
                    controller.unregisterCallback(sessionCallback)
                } catch (_: Exception) {
                }
            }
            controllers.clear()
        }
    }

    private fun sessionManager(): MediaSessionManager? =
        getSystemService(MediaSessionManager::class.java)

    private fun component(): ComponentName =
        ComponentName(this, MediaListenerService::class.java)

    private fun activeSessions(): List<MediaController> {
        return try {
            sessionManager()?.getActiveSessions(component()) ?: emptyList()
        } catch (e: SecurityException) {
            Log.w(TAG, "Sin permiso para leer sesiones: $e")
            emptyList()
        }
    }

    /** Da de alta/baja controladores según las sesiones vivas. */
    private fun reconcile(sessions: List<MediaController>) {
        synchronized(controllers) {
            val alive = sessions.map { it.packageName }.toSet()
            val gone = controllers.keys.filter { it !in alive }
            for (pkg in gone) {
                try {
                    controllers.remove(pkg)?.unregisterCallback(sessionCallback)
                } catch (_: Exception) {
                }
            }
            for (session in sessions) {
                if (controllers.containsKey(session.packageName)) continue
                try {
                    val controller =
                        MediaController(this, session.sessionToken)
                    controller.registerCallback(sessionCallback, handler)
                    controllers[session.packageName] = controller
                } catch (e: Exception) {
                    Log.w(TAG, "Sesión ilegible ${session.packageName}: $e")
                }
            }
        }
    }

    private fun buildSnapshot(): Map<String, Any?> {
        val sessions = activeSessions()
        reconcile(sessions)
        val players = sessions.map { session ->
            val controller =
                synchronized(controllers) { controllers[session.packageName] }
                    ?: session
            mapOf<String, Any?>(
                "package" to session.packageName,
                "status" to statusOf(controller),
                "playing" to (statusOf(controller) == "playing"),
                "title" to metaString(controller, MediaMetadata.METADATA_KEY_TITLE),
                "artist" to metaString(controller, MediaMetadata.METADATA_KEY_ARTIST),
                "album" to metaString(controller, MediaMetadata.METADATA_KEY_ALBUM),
                "durationMs" to metaLong(controller, MediaMetadata.METADATA_KEY_DURATION),
                "positionMs" to positionOf(controller),
                "speed" to speedOf(controller),
            )
        }
        return mapOf("hasAccess" to true, "players" to players)
    }

    private fun metaString(controller: MediaController, key: String): String? {
        return try {
            controller.metadata?.getString(key)?.trim()?.takeIf { it.isNotEmpty() }
        } catch (_: Exception) {
            null
        }
    }

    private fun metaLong(controller: MediaController, key: String): Long? {
        return try {
            val v = controller.metadata?.getLong(key) ?: return null
            if (v <= 0) null else v
        } catch (_: Exception) {
            null
        }
    }

    private fun statusOf(controller: MediaController): String {
        return when (controller.playbackState?.state) {
            PlaybackState.STATE_PLAYING,
            PlaybackState.STATE_BUFFERING -> "playing"
            PlaybackState.STATE_PAUSED -> "paused"
            else -> "stopped"
        }
    }

    private fun positionOf(controller: MediaController): Long {
        return try {
            val p = controller.playbackState?.position ?: 0L
            if (p < 0) 0L else p
        } catch (_: Exception) {
            0L
        }
    }

    private fun speedOf(controller: MediaController): Double {
        return try {
            val s = controller.playbackState?.playbackSpeed ?: 1.0f
            if (s.isFinite()) s.toDouble() else 1.0
        } catch (_: Exception) {
            1.0
        }
    }
}

// ---------------------------------------------------------------------------
// Órdenes de control (seek, play/pausa) + permiso.
// ---------------------------------------------------------------------------

/** Lógica de control sobre sesiones activas, invocada desde el MethodChannel. */
object MediaControlHelper {

    fun hasAccess(context: Context): Boolean {
        return try {
            val component = ComponentName(context, MediaListenerService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                // API correcta: refleja el permiso real del usuario. La variante
                // getEnabledListenerPackages se queda obsoleta y devuelve
                // "sin permiso" aunque esté concedido.
                context.getSystemService(NotificationManager::class.java)
                    ?.isNotificationListenerAccessGranted(component) == true
            } else {
                NotificationManagerCompat.getEnabledListenerPackages(context)
                    .contains(context.packageName)
            }
        } catch (_: Exception) {
            false
        }
    }

    fun openSettings(context: Context) {
        try {
            val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
        } catch (e: Exception) {
            Log.w(MediaListenerService.TAG, "No se pudo abrir ajustes: $e")
        }
    }

    private fun controllerFor(context: Context, pkg: String?): MediaController? {
        if (pkg.isNullOrEmpty()) return null
        return try {
            val manager =
                context.getSystemService(MediaSessionManager::class.java)
                    ?: return null
            val component =
                ComponentName(context, MediaListenerService::class.java)
            manager.getActiveSessions(component).firstOrNull {
                it.packageName == pkg
            }?.let { MediaController(context, it.sessionToken) }
        } catch (_: Exception) {
            null
        }
    }

    fun seekTo(context: Context, pkg: String?, positionMs: Long): Boolean {
        val controller = controllerFor(context, pkg) ?: return false
        return try {
            controller.transportControls.seekTo(positionMs.coerceAtLeast(0L))
            true
        } catch (e: Exception) {
            Log.w(MediaListenerService.TAG, "Seek fallido en $pkg: $e")
            false
        }
    }

    fun togglePlayPause(context: Context, pkg: String?): Boolean {
        val controller = controllerFor(context, pkg) ?: return false
        return try {
            val playing =
                controller.playbackState?.state == PlaybackState.STATE_PLAYING ||
                    controller.playbackState?.state == PlaybackState.STATE_BUFFERING
            if (playing) controller.transportControls.pause()
            else controller.transportControls.play()
            true
        } catch (e: Exception) {
            Log.w(MediaListenerService.TAG, "PlayPause fallido en $pkg: $e")
            false
        }
    }
}
