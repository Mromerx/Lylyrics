import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/interfaces/lyrics_provider.dart';
import '../../core/interfaces/media_source.dart';
import '../../core/models/lyrics.dart';
import '../../core/models/playback_state.dart';
import '../../core/models/track_info.dart';
import '../../platform/linux/mpris_media_source.dart';
import '../../services/lyrics_cache.dart';
import '../../services/lrclib_provider.dart';
import '../../services/sync_engine.dart';

/// Ruta de la caché. Usa el directorio de datos de la app.
String _defaultCachePath() {
  final home = Platform.environment['XDG_DATA_HOME'];
  if (home != null && home.isNotEmpty) {
    return '$home/lylyrics/lylyrics_cache.db';
  }
  final user = Platform.environment['USER'] ??
      Platform.environment['LOGNAME'] ??
      Platform.environment['HOME'] ??
      '/tmp';
  return '$user/.local/share/lylyrics/lylyrics_cache.db';
}

/// Fuente de medios. En esta fase es MPRIS sobre Linux.
final mediaSourceProvider = Provider<MediaSource>((ref) {
  final source = MprisMediaSource();
  ref.onDispose(source.dispose);
  return source;
});

/// Pista actual. `null` = nada reproduciéndose.
final currentTrackProvider = StreamProvider<TrackInfo?>((ref) {
  return ref.watch(mediaSourceProvider).trackStream;
});

/// Estado de reproducción interpolado.
final playbackStateProvider = StreamProvider<PlaybackState>((ref) {
  return ref.watch(mediaSourceProvider).playbackStream;
});

/// Resumen del reproductor seleccionado y de los disponibles.
class PlayerSelection {
  const PlayerSelection({
    this.available = const [],
    this.selected,
    this.active,
    this.activeLabel,
    this.lastError,
  });

  final List<String> available;
  final String? selected;
  final String? active;
  final String? activeLabel;
  final String? lastError;

  bool get hasAny => available.isNotEmpty;
}

/// Reproductores detectados. Latido de 2 s: la lista de MPRIS es mutable y no
/// emite un evento dedicated, así que un latido basta para el selector.
final playerSelectionProvider = StreamProvider<PlayerSelection>((ref) {
  final source = ref.watch(mediaSourceProvider);
  if (source is! MprisMediaSource) {
    return Stream.value(const PlayerSelection());
  }

  final controller = StreamController<PlayerSelection>();
  PlayerSelection? last;
  Timer? timer;

  void emit() {
    final next = PlayerSelection(
      available: source.availablePlayers,
      selected: source.selectedPlayer,
      active: source.activePlayer,
      activeLabel: source.activePlayerInfo?.label,
      lastError: source.lastError,
    );
    if (next.available.join('|') == last?.available.join('|') &&
        next.selected == last?.selected &&
        next.active == last?.active &&
        next.lastError == last?.lastError) {
      return;
    }
    last = next;
    if (!controller.isClosed) controller.add(next);
  }

  controller.onListen = () {
    emit();
    timer = Timer.periodic(const Duration(seconds: 2), (_) => emit());
  };
  controller.onCancel = () {
    timer?.cancel();
    timer = null;
  };

  return controller.stream;
});

/// Caché local. Se cierra con el contenedor.
final lyricsCacheProvider = Provider<LyricsCache>((ref) {
  final cache = LyricsCache(path: _defaultCachePath());
  ref.onDispose(cache.close);
  return cache;
});

/// Proveedor de letras. Sustituir aquí para usar otra fuente.
final lyricsProviderProvider = Provider<LyricsProvider>((ref) {
  final provider = LrclibProvider(
    cache: ref.watch(lyricsCacheProvider),
    userAgent: kUserAgent,
  );
  ref.onDispose(provider.dispose);
  return provider;
});

/// `User-Agent` con el que se identifica la app ante LRCLIB.
///
/// LRCLIB es un servicio público, sin API key ni registro: lo único que pide es
/// que el cliente se identifique para poderlocalizarlo si hay que contactar.
/// Cámbialo por tu correo si publicas la app.
const String kUserAgent =
    'Lylyrics/0.1.0 (+https://github.com/maxi/lylyrics; visor de letras '
    'sincronizadas MPRIS para Linux)';

/// Motor de sincronización, alimentado por [playbackStateProvider].
final syncEngineProvider = Provider<SyncEngine>((ref) {
  final engine = SyncEngine();

  // OJO: aquí NO se hace `ref.watch(playbackStateProvider)`. Ese provider emite
  // ~1 vez por segundo (el polling de posición de MPRIS), y hacer `watch`
  // reconstruiría el motor cada segundo: el motor nuevo empieza sin letra, el
  // `lineIndexStream` se corta, y como `lyricsStateProvider` también lo
  // observa, la búsqueda de LRCLIB se reinicia eternamente (spinner infinito).
  // Nos suscribimos directamente al stream, que es lo único que necesitamos.
  final subscription = ref
      .watch(mediaSourceProvider)
      .playbackStream
      .listen(engine.update);
  ref.onDispose(() {
    subscription.cancel();
    engine.dispose();
  });

  return engine;
});

/// Índice de la línea actual. `null` si la letra no está sincronizada.
final currentLineIndexProvider = StreamProvider<int?>((ref) {
  return ref.watch(syncEngineProvider).lineIndexStream;
});

/// Fase de resolución de la letra para la pista actual.
enum LyricsPhase {
  /// No hay nada reproduciéndose.
  idle,

  /// Buscando en LRCLIB.
  loading,

  /// Letra encontrada.
  found,

  /// Sin letra en LRCLIB.
  notFound,

  /// Fallo de red u otro error.
  error,
}

/// Estado completo de la letra para la UI.
class LyricsState {
  const LyricsState({
    this.phase = LyricsPhase.idle,
    this.lyrics,
    this.errorMessage,
    this.track,
  });

  final LyricsPhase phase;
  final Lyrics? lyrics;
  final String? errorMessage;
  final TrackInfo? track;

  bool get isLoading => phase == LyricsPhase.loading;
  bool get hasLyrics => lyrics != null && !lyrics!.instrumental;
  bool get isInstrumental => lyrics?.instrumental ?? false;

  LyricsState copyWith({
    LyricsPhase? phase,
    Lyrics? lyrics,
    String? errorMessage,
    TrackInfo? track,
  }) {
    return LyricsState(
      phase: phase ?? this.phase,
      lyrics: lyrics ?? this.lyrics,
      errorMessage: errorMessage ?? this.errorMessage,
      track: track ?? this.track,
    );
  }
}

/// Orquestador de la búsqueda de letra: escucha la pista y dispara consultas.
final lyricsStateProvider = StreamProvider<LyricsState>((ref) {
  final provider = ref.watch(lyricsProviderProvider);
  final engine = ref.watch(syncEngineProvider);

  return _lyricsPipeline(provider, engine, ref.watch(mediaSourceProvider));
});

Stream<LyricsState> _lyricsPipeline(
  LyricsProvider provider,
  SyncEngine engine,
  MediaSource source,
) async* {
  // `engine` es una dependencia del pipeline, no de su salida: pasarlo como
  // argumento evita que la UI tenga que reconstruirlo.
  await for (final track in source.trackStream) {
    if (track == null) {
      engine.setLyrics(null);
      yield const LyricsState();
      continue;
    }

    yield LyricsState(phase: LyricsPhase.loading, track: track);

    final lrc = provider;
    Lyrics? result;
    String? error;
    try {
      // Si el proveedor sabe debouncear (LRCLIB), lo usamos; si no, directo.
      result = lrc is LrclibProvider
          ? await lrc.fetchDebounced(track)
          : await lrc.fetch(track);
    } on LrclibException catch (e) {
      error = _describeLrclibError(e);
    } catch (e) {
      error = 'Error inesperado: $e';
    }

    // Si mientras buscábamos llegó otra pista, el resultado ya no vale.
    engine.setLyrics(result);

    if (error != null) {
      yield LyricsState(
        phase: LyricsPhase.error,
        errorMessage: error,
        track: track,
      );
    } else if (result == null) {
      yield LyricsState(phase: LyricsPhase.notFound, track: track);
    } else {
      yield LyricsState(
        phase: LyricsPhase.found,
        lyrics: result,
        track: track,
      );
    }
  }
}

String _describeLrclibError(LrclibException e) => switch (e.kind) {
      LrclibKind.timeout => 'LRCLIB tardó demasiado en responder',
      LrclibKind.network => 'Sin conexión con lrclib.net',
      LrclibKind.server => 'lrclib.net está teniendo problemas',
      LrclibKind.notFound => 'No hay letra en LRCLIB',
      LrclibKind.badResponse => 'lrclib.net devolvió una respuesta inválida',
      LrclibKind.client => 'LRCLIB rechazó la petición',
    };

/// Búsqueda manual de letra con artista y título escritos por el usuario.
///
/// Se declara como `Notifier` con una callable en lugar de `family` porque no
/// queremos estado por argumento: la función solo necesita el proveedor.
final manualSearchProvider = Provider<ManualSearchAction>(
  ManualSearchAction.new,
);

/// Acción de búsqueda manual.
class ManualSearchAction {
  ManualSearchAction(this._ref);

  final Ref _ref;

  Future<Lyrics?> call(String title, String artist) {
    final provider = _ref.read(lyricsProviderProvider);
    final duration = _ref.read(currentTrackProvider).value?.duration;
    return provider.fetch(
      TrackInfo(
        title: title.trim(),
        artist: artist.trim(),
        duration: duration,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Preferencias de interfaz
// ---------------------------------------------------------------------------

/// Ajustes que el usuario puede cambiar y que se guardan en memoria.
class UiSettings {
  const UiSettings({
    this.fontSize = 26,
    this.themeModeIsDark = true,
    this.alwaysOnTop = false,
  });

  final double fontSize;
  final bool themeModeIsDark;
  final bool alwaysOnTop;

  UiSettings copyWith({
    double? fontSize,
    bool? themeModeIsDark,
    bool? alwaysOnTop,
  }) {
    return UiSettings(
      fontSize: fontSize ?? this.fontSize,
      themeModeIsDark: themeModeIsDark ?? this.themeModeIsDark,
      alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
    );
  }
}

final uiSettingsProvider =
    NotifierProvider<UiSettingsNotifier, UiSettings>(UiSettingsNotifier.new);

/// Ajustes de interfaz en memoria. El offset sí se guarda por canción, que
/// es el único ajuste que de verdad merece persistir entre sesiones.
class UiSettingsNotifier extends Notifier<UiSettings> {
  @override
  UiSettings build() => const UiSettings();

  void setFontSize(double size) {
    final clamped = size.clamp(14.0, 56.0);
    state = state.copyWith(fontSize: clamped);
  }

  void toggleTheme() {
    state = state.copyWith(themeModeIsDark: !state.themeModeIsDark);
  }

  void setAlwaysOnTop(bool value) {
    state = state.copyWith(alwaysOnTop: value);
  }
}

/// Ajuste de desfase por canción (offset manual de sincronización).
final offsetByTrackProvider =
    NotifierProvider<OffsetByTrackNotifier, Map<String, Duration>>(
        OffsetByTrackNotifier.new);

/// Mapa `cacheKey -> offset` aplicado a cada canción.
class OffsetByTrackNotifier extends Notifier<Map<String, Duration>> {
  @override
  Map<String, Duration> build() => {};

  /// Aplica un offset a la canción actual y lo recuerda.
  void adjust(String trackKey, Duration current, Duration delta) {
    final next = current + delta;
    // Acotamos a ±10 s, el mismo límite del motor.
    final clamped = next.abs() > SyncEngine.maxOffset
        ? Duration(
            milliseconds: next.inMilliseconds.clamp(
              -SyncEngine.maxOffset.inMilliseconds,
              SyncEngine.maxOffset.inMilliseconds,
            ),
          )
        : next;

    state = {...state, trackKey: clamped};
  }

  void reset(String trackKey) {
    final next = {...state}..remove(trackKey);
    state = next;
  }
}

/// Cliente HTTP compartido, por si hace falta en el futuro.
///
/// Se expone para que la UI pueda limpiar la caché cerrando el proveedor.
final httpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});