import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/interfaces/media_source.dart';
import '../../core/models/playback_state.dart';
import '../../core/models/track_info.dart';

// ---------------------------------------------------------------------------
// Lógica pura (testeable sin Android)
// ---------------------------------------------------------------------------

/// Canal de snapshots del servicio nativo.
const String kAndroidMediaChannel = 'lylyrics/media';

/// Canal de órdenes (seek, play/pausa, permiso).
const String kAndroidControlChannel = 'lylyrics/control';

// Puntuaciones de reproductores (mismo orden que en MPRIS).
const int _scoreSpotify = 400;
const int _scoreYouTubeMusic = 350;
const int _scoreYouTube = 300;
const int _scoreKnownMusic = 200;
const int _scoreUnknown = 0;

/// Reproductores de música conocidos (no navegadores).
const List<String> _knownMusicHints = <String>[
  'spotify',
  'deezer',
  'tidal',
  'vlc',
  'poweramp',
  'phonograph',
  'retro',
  'auxio',
  'samsungmusic',
  'huawei music',
  'miuimusic',
];

/// Normaliza un título para comparar (minúsculas, espacios colapsados).
@visibleForTesting
String? androidNormalizeTitle(String? raw) {
  if (raw == null) return null;
  final collapsed = raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  return collapsed.isEmpty ? null : collapsed;
}

/// Clave estable de la pista: paquete + título normalizado.
@visibleForTesting
String? androidTrackKey({String? package, String? title}) {
  final normalized = androidNormalizeTitle(title);
  if (normalized == null) return null;
  return '${package ?? 'unknown'}|$normalized';
}

/// ¿Cambió de pista? `null -> null` no es cambio.
@visibleForTesting
bool androidTrackKeyChanged({String? previous, String? next}) {
  if (previous == null && next == null) return false;
  return previous != next;
}

/// Traduce el estado que manda el servicio nativo a nuestro enum.
@visibleForTesting
PlaybackStatus androidStatusFromRaw(String? raw) {
  switch ((raw ?? '').trim()) {
    case 'playing':
      return PlaybackStatus.playing;
    case 'paused':
      return PlaybackStatus.paused;
    default:
      return PlaybackStatus.stopped;
  }
}

/// Puntuación de un paquete: Spotify y YouTube Music por encima de YouTube
/// genérico, y los reproductores de música conocidos por encima del resto.
@visibleForTesting
int androidPlayerScore(String packageName) {
  final haystack = packageName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (haystack.contains('spotify')) return _scoreSpotify;
  if (haystack.contains('youtubemusic') || haystack.contains('ytmusic')) {
    return _scoreYouTubeMusic;
  }
  if (haystack.contains('youtube')) return _scoreYouTube;
  for (final hint in _knownMusicHints) {
    if (haystack.contains(hint.replaceAll(' ', ''))) return _scoreKnownMusic;
  }
  return _scoreUnknown;
}

/// Lo que sabemos de una sesión multimedia activa.
@immutable
class AndroidPlayerInfo {
  const AndroidPlayerInfo({
    required this.packageName,
    this.status = PlaybackStatus.stopped,
    this.score = _scoreUnknown,
  });

  final String packageName;
  final PlaybackStatus status;
  final int score;

  bool get isPlaying => status == PlaybackStatus.playing;

  /// Etiqueta corta para el selector (`com.spotify.music` -> `music`).
  String get label {
    final parts = packageName.split('.');
    return parts.isEmpty ? packageName : parts.last;
  }
}

/// Orden: reproduciendo primero, luego puntuación, luego nombre.
@visibleForTesting
int compareAndroidPlayers(AndroidPlayerInfo a, AndroidPlayerInfo b) {
  int rank(PlaybackStatus s) => switch (s) {
        PlaybackStatus.playing => 0,
        PlaybackStatus.paused => 1,
        PlaybackStatus.stopped => 2,
      };
  final byStatus = rank(a.status).compareTo(rank(b.status));
  if (byStatus != 0) return byStatus;
  final byScore = b.score.compareTo(a.score);
  if (byScore != 0) return byScore;
  return a.packageName.compareTo(b.packageName);
}

/// Elige el reproductor activo. [forced] gana si sigue existiendo.
@visibleForTesting
String? selectBestAndroidPlayer({
  required Map<String, AndroidPlayerInfo> players,
  String? forced,
}) {
  if (players.isEmpty) return null;
  if (forced != null && players.containsKey(forced)) return forced;
  final sorted = players.values.toList()..sort(compareAndroidPlayers);
  return sorted.first.packageName;
}

/// Acota la posición a `[0, duración]` cuando se conoce la duración.
@visibleForTesting
Duration androidClampPosition(Duration position, Duration? total) {
  var micros = position.inMicroseconds;
  if (micros < 0) micros = 0;
  final totalMicros = total?.inMicroseconds ?? 0;
  if (totalMicros > 0 && micros > totalMicros) micros = totalMicros;
  return Duration(microseconds: micros);
}

/// Construye el [TrackInfo] desde el mapa de sesión que manda el nativo.
///
/// `null` si no hay nada real que mostrar (sin título y sin artista).
@visibleForTesting
TrackInfo? androidTrackInfoFromSession(Map<String, Object?> session) {
  String? clean(Object? v) {
    if (v is! String) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  final title = clean(session['title']);
  final artistRaw = clean(session['artist']) ?? '';
  final artists = artistRaw
      .split(RegExp(r'\s*[,&;]\s*|\s+feat\.?\s+|\s+x\s+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  final artist = artists.join(', ');
  final resolvedTitle = title ?? (artist.isEmpty ? null : artist);
  if (resolvedTitle == null) return null;

  Duration? duration;
  final durationMs = session['durationMs'];
  if (durationMs is num && durationMs > 0) {
    duration = Duration(milliseconds: durationMs.toInt());
  }

  final album = clean(session['album']);
  final package = clean(session['package']);
  return TrackInfo(
    title: resolvedTitle,
    artist: artist,
    album: album,
    duration: duration,
    sourceApp: package,
  );
}

// ---------------------------------------------------------------------------
// Fuente de medios Android (sesiones multimedia vía MediaSession)
// ---------------------------------------------------------------------------

/// Implementación de [MediaSource] sobre sesiones multimedia de Android.
///
/// El servicio nativo (`MediaListenerService`) empuja snapshots por el
/// EventChannel; aquí se resuelve el reproductor activo, se deduplica la
/// pista y se publica el estado. Estructura gemela de `MprisMediaSource`.
class AndroidMediaSource implements MediaSource {
  AndroidMediaSource({
    EventChannel? eventChannel,
    MethodChannel? methodChannel,
  })  : _events = eventChannel ?? const EventChannel(kAndroidMediaChannel),
        _control = methodChannel ?? const MethodChannel(kAndroidControlChannel) {
    _subscription = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (_) {
        _lastError = 'Canal multimedia caído';
      },
    );
  }

  final EventChannel _events;
  final MethodChannel _control;
  late final StreamSubscription<Object?> _subscription;

  final StreamController<TrackInfo?> _trackController =
      StreamController<TrackInfo?>.broadcast();
  final StreamController<PlaybackState> _playbackController =
      StreamController<PlaybackState>.broadcast();

  final Map<String, AndroidPlayerInfo> _players = <String, AndroidPlayerInfo>{};
  final Map<String, Map<String, Object?>> _sessions =
      <String, Map<String, Object?>>{};

  String? _forcedPlayer;
  String? _activePlayer;

  String? _lastTrackKey;
  bool _trackEmitted = false;
  TrackInfo? _lastTrack;
  PlaybackState? _lastPlayback;
  bool _lastWasEmpty = true;

  bool _playing = false;
  double _speed = 1.0;
  PlaybackStatus _status = PlaybackStatus.stopped;
  Duration _positionBase = Duration.zero;
  DateTime _positionAt = DateTime.now();

  String? _lastError;
  bool _disposed = false;

  @override
  Stream<TrackInfo?> get trackStream async* {
    if (_trackEmitted) yield _lastTrack;
    yield* _trackController.stream;
  }

  @override
  Stream<PlaybackState> get playbackStream async* {
    final last = _lastPlayback;
    if (last != null) yield last;
    yield* _playbackController.stream;
  }

  /// Último error registrado, o `null` si todo va bien.
  String? get lastError => _lastError;

  /// Paquete activo resuelto (puede diferir de [selectedPlayer] en auto).
  String? get activePlayer => _activePlayer;

  /// Etiqueta del reproductor activo para el selector de la UI.
  String? get activePlayerLabel =>
      _activePlayer == null ? null : _players[_activePlayer]?.label;

  @override
  List<String> get availablePlayers {
    final sorted = _players.values.toList()..sort(compareAndroidPlayers);
    return sorted.map((p) => p.packageName).toList(growable: false);
  }

  @override
  String? get selectedPlayer => _forcedPlayer;

  @override
  void selectPlayer(String? packageName) {
    if (_disposed) return;
    final next =
        (packageName == null || packageName.isEmpty) ? null : packageName;
    if (next == _forcedPlayer) return;
    _forcedPlayer = next;
    _applySelection();
  }

  /// ¿Tiene la app acceso a notificaciones? (imprescindible para leer
  /// sesiones). En no-Android devuelve `true` para no bloquear nada.
  Future<bool> hasListenerAccess() async {
    try {
      final ok = await _control.invokeMethod<bool>('hasAccess');
      return ok ?? false;
    } catch (_) {
      // Sin canal nativo (tests, Linux): no bloquear.
      return true;
    }
  }

  /// Acceso a notificaciones, reevaluado periódicamente.
  ///
  /// El permiso (y el propio servicio) cambian en caliente: el sistema tarda
  /// en reflejar la concesión y algunos fabricantes desconectan el listener
  /// al rato. Un único chequeo cacheado dejaría la UI atascada pidiendo un
  /// permiso que ya está dado, así que se sondea mientras haya suscriptor.
  Stream<bool> get accessStream async* {
    yield await hasListenerAccess();
    yield* Stream<Future<bool>>.periodic(
      const Duration(seconds: 3),
      (_) => hasListenerAccess(),
    ).asyncMap((future) => future);
  }

  /// Abre los ajustes de "Acceso a notificaciones" del sistema.
  Future<void> openListenerSettings() async {
    try {
      await _control.invokeMethod<bool>('openListenerSettings');
    } catch (_) {
      // Sin canal nativo no hay nada que abrir.
    }
  }

  @override
  Future<bool> seek(Duration position) async {
    final pkg = _activePlayer;
    if (_disposed || pkg == null) return false;
    var ms = position.inMilliseconds;
    if (ms < 0) ms = 0;
    bool ok = false;
    try {
      ok = await _control.invokeMethod<bool>('seekTo', {
            'package': pkg,
            'positionMs': ms,
          }) ??
          false;
    } catch (_) {
      ok = false;
    }
    if (!ok) return false;
    // Recalibración optimista como en MPRIS.
    final duration = _sessionDuration(pkg);
    _positionBase =
        androidClampPosition(Duration(milliseconds: ms), duration);
    _positionAt = DateTime.now();
    _emitPlayback();
    return true;
  }

  @override
  Future<bool> togglePlayPause() async {
    final pkg = _activePlayer;
    if (_disposed || pkg == null) return false;
    try {
      return await _control.invokeMethod<bool>('togglePlayPause', {
            'package': pkg,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    _players.clear();
    _sessions.clear();
    _activePlayer = null;
    for (final controller in <StreamController<Object?>>[
      _trackController,
      _playbackController,
    ]) {
      if (!controller.isClosed) await controller.close();
    }
  }

  // -- Snapshots -----------------------------------------------------------

  void _onEvent(Object? event) {
    if (_disposed) return;
    if (event is! Map) return;
    final rawPlayers = event['players'];
    if (rawPlayers is! List) return;

    _players.clear();
    _sessions.clear();
    for (final item in rawPlayers) {
      if (item is! Map) continue;
      final session = <String, Object?>{};
      item.forEach((k, v) => session[k.toString()] = v);
      final pkg = session['package'];
      if (pkg is! String || pkg.isEmpty) continue;
      final status =
          androidStatusFromRaw(session['status']?.toString());
      _players[pkg] = AndroidPlayerInfo(
        packageName: pkg,
        status: status,
        score: androidPlayerScore(pkg),
      );
      _sessions[pkg] = session;
    }

    _applySelection();
  }

  void _applySelection() {
    if (_disposed) return;
    final best =
        selectBestAndroidPlayer(players: _players, forced: _forcedPlayer);
    if (best != _activePlayer) {
      // Cambio de fuente: la pista se reemite aunque sea la misma canción.
      _activePlayer = best;
      _trackEmitted = false;
      _lastTrackKey = null;
      _lastTrack = null;
    }
    _emitTrack();
    _emitPlayback();
  }

  Map<String, Object?>? get _activeSession =>
      _activePlayer == null ? null : _sessions[_activePlayer];

  Duration? _sessionDuration(String? pkg) {
    final session = pkg == null ? null : _sessions[pkg];
    final ms = session?['durationMs'];
    if (ms is num && ms > 0) return Duration(milliseconds: ms.toInt());
    return null;
  }

  void _emitTrack() {
    if (_disposed) return;
    final session = _activeSession;
    final info = session == null
        ? null
        : (androidStatusFromRaw(session['status']?.toString()) ==
                PlaybackStatus.stopped
            ? null
            : androidTrackInfoFromSession(session));
    final key = info == null
        ? null
        : androidTrackKey(package: _activePlayer, title: info.title);

    if (_trackEmitted &&
        !androidTrackKeyChanged(previous: _lastTrackKey, next: key)) {
      return;
    }
    _lastTrackKey = key;
    _trackEmitted = true;
    _lastTrack = info;
    _trackController.add(info);
  }

  void _emitPlayback() {
    if (_disposed) return;
    final session = _activeSession;
    if (session == null) {
      // Sin sesión: un único estado parado y silencio (igual que MPRIS).
      if (_lastWasEmpty) return;
      _lastWasEmpty = true;
      _playing = false;
      _status = PlaybackStatus.stopped;
      final state = PlaybackState(
        isPlaying: false,
        position: Duration.zero,
        timestamp: DateTime.now(),
        speed: 1.0,
        status: PlaybackStatus.stopped,
      );
      _lastPlayback = state;
      _playbackController.add(state);
      return;
    }
    _lastWasEmpty = false;

    _status = androidStatusFromRaw(session['status']?.toString());
    _playing = _status == PlaybackStatus.playing;
    final speed = session['speed'];
    _speed = (speed is num && speed.toDouble().isFinite)
        ? speed.toDouble()
        : 1.0;
    final posMs = session['positionMs'];
    final reported = (posMs is num && posMs > 0)
        ? Duration(milliseconds: posMs.toInt())
        : Duration.zero;
    _positionBase =
        androidClampPosition(reported, _sessionDuration(_activePlayer));
    _positionAt = DateTime.now();

    final state = PlaybackState(
      isPlaying: _playing,
      position: _positionBase,
      timestamp: _positionAt,
      speed: _speed,
      status: _status,
    );
    _lastPlayback = state;
    _playbackController.add(state);
  }
}
