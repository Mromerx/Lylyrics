import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/interfaces/lyrics_provider.dart';
import '../../core/interfaces/media_source.dart';
import '../../core/models/lyrics.dart';
import '../../core/models/playback_state.dart';
import '../../core/models/track_info.dart';
import '../../platform/android/android_media_source.dart';
import '../../platform/linux/mpris_media_source.dart';
import '../../services/genius_scraper.dart';
import '../../services/lyrics_cache.dart';
import '../../services/lyrics_search.dart';
import '../../services/lrclib_provider.dart';
import '../../services/netease_provider.dart';
import '../../services/sync_engine.dart';
import '../../services/token_alignment.dart';
import '../../services/translation_service.dart';

/// Ruta de la caché. Usa el directorio de datos de la app.
///
/// En Linux sigue la convención XDG: `$XDG_DATA_HOME/lylyrics/...` y, si la
/// variable no está definida, `$HOME/.local/share/lylyrics/...`. Se usa
/// siempre `HOME` (ruta absoluta), nunca `USER`/`LOGNAME`, que son el nombre
/// de usuario y darían una ruta relativa al directorio de trabajo.
String _defaultCachePath() {
  final xdg = Platform.environment['XDG_DATA_HOME'];
  if (xdg != null && xdg.isNotEmpty) {
    return '$xdg/lylyrics/lylyrics_cache.db';
  }
  final home = Platform.environment['HOME'];
  if (home != null && home.isNotEmpty) {
    return '$home/.local/share/lylyrics/lylyrics_cache.db';
  }
  // Sin HOME no hay un sitio estable al que recurrir.
  return '/tmp/lylyrics/lylyrics_cache.db';
}

/// Ruta de la caché según la plataforma. En Android el directorio propio
/// solo se resuelve de forma asíncrona (`path_provider`); en Linux vale la
/// ruta XDG de siempre.
Future<String> resolveCachePath() async {
  if (Platform.isAndroid) {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/lylyrics_cache.db';
  }
  return _defaultCachePath();
}

/// Fuente de medios según la plataforma: sesiones multimedia en Android y
/// MPRIS sobre Linux.
final mediaSourceProvider = Provider<MediaSource>((ref) {
  final MediaSource source =
      Platform.isAndroid ? AndroidMediaSource() : MprisMediaSource();
  ref.onDispose(source.dispose);
  return source;
});

/// ¿Tiene la app acceso a notificaciones? Solo relevante en Android: sin ese
/// permiso el servicio nativo no puede leer sesiones multimedia. En el resto
/// de plataformas siempre es `true`.
///
/// Es un `StreamProvider` a propósito: el permiso se concede en los ajustes
/// del sistema y el servicio puede desconectarse y reconectarse, así que un
/// valor cacheado dejaría la UI atascada pidiendo un permiso ya concedido.
final androidAccessProvider = StreamProvider<bool>((ref) {
  final source = ref.watch(mediaSourceProvider);
  if (source is AndroidMediaSource) return source.accessStream;
  return Stream<bool>.value(true);
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

/// Foto del reproductor activo para el selector de la UI.
PlayerSelection readPlayerSelection(MediaSource source) {
  if (source is MprisMediaSource) {
    return PlayerSelection(
      available: source.availablePlayers,
      selected: source.selectedPlayer,
      active: source.activePlayer,
      activeLabel: source.activePlayerInfo?.label,
      lastError: source.lastError,
    );
  }
  if (source is AndroidMediaSource) {
    return PlayerSelection(
      available: source.availablePlayers,
      selected: source.selectedPlayer,
      active: source.activePlayer,
      activeLabel: source.activePlayerLabel,
      lastError: source.lastError,
    );
  }
  return const PlayerSelection();
}

/// Reproductores detectados. Latido de 2 s: las listas (MPRIS y sesiones
/// Android) son mutables y no emiten un evento dedicado, así que un latido
/// basta para el selector.
final playerSelectionProvider = StreamProvider<PlayerSelection>((ref) {
  final source = ref.watch(mediaSourceProvider);

  final controller = StreamController<PlayerSelection>();
  PlayerSelection? last;
  Timer? timer;

  void emit() {
    final next = readPlayerSelection(source);
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

/// Proveedor LRCLIB concreto, con acceso a la búsqueda abierta de la lupa.
final lrclibProviderProvider = Provider<LrclibProvider>((ref) {
  final provider = LrclibProvider(
    cache: ref.watch(lyricsCacheProvider),
    userAgent: kUserAgent,
  );
  ref.onDispose(provider.dispose);
  return provider;
});

/// Proveedor de letras. Sustituir aquí para usar otra fuente.
final lyricsProviderProvider = Provider<LyricsProvider>(
  (ref) => ref.watch(lrclibProviderProvider),
);

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
    this.manual = false,
  });

  final LyricsPhase phase;
  final Lyrics? lyrics;
  final String? errorMessage;
  final TrackInfo? track;

  /// `true` cuando la letra la eligió el usuario en la lupa y NO es la que
  /// corresponde a la pista que suena: se muestra como texto libre, sin
  /// sincronizar por tiempo. El selector de reproductor permite volver al
  /// modo automático (sincronizado) en cualquier momento.
  final bool manual;

  bool get isLoading => phase == LyricsPhase.loading;
  bool get hasLyrics => lyrics != null && !lyrics!.instrumental;
  bool get isInstrumental => lyrics?.instrumental ?? false;

  LyricsState copyWith({
    LyricsPhase? phase,
    Lyrics? lyrics,
    String? errorMessage,
    TrackInfo? track,
    bool? manual,
  }) {
    return LyricsState(
      phase: phase ?? this.phase,
      lyrics: lyrics ?? this.lyrics,
      errorMessage: errorMessage ?? this.errorMessage,
      track: track ?? this.track,
      manual: manual ?? this.manual,
    );
  }
}

/// Respaldo Genius cuando LRCLIB no tiene la canción (scraping sin API key).
final geniusScraperProvider = Provider<GeniusScraper>((ref) {
  return GeniusScraper(client: ref.watch(httpClientProvider));
});

/// Respaldo NetEase Cloud Music entre LRCLIB y Genius (sin API key).
final neteaseProviderProvider = Provider<NeteaseProvider>((ref) {
  return NeteaseProvider(client: ref.watch(httpClientProvider));
});

/// Búsqueda unificada LRCLIB + NetEase + Genius para la lupa de la barra
/// superior.
final lyricsSearchServiceProvider = Provider<LyricsSearchService>((ref) {
  return LyricsSearchService(
    lrclib: ref.watch(lrclibProviderProvider),
    netease: ref.watch(neteaseProviderProvider),
    genius: ref.watch(geniusScraperProvider),
  );
});

/// Orquestador de la búsqueda de letra: escucha la pista y dispara consultas.
final lyricsStateProvider = StreamProvider<LyricsState>((ref) {
  final provider = ref.watch(lyricsProviderProvider);
  final engine = ref.watch(syncEngineProvider);
  final genius = ref.watch(geniusScraperProvider);
  final netease = ref.watch(neteaseProviderProvider);

  return _lyricsPipeline(
    provider,
    engine,
    ref.watch(mediaSourceProvider),
    genius: genius,
    netease: netease,
  );
});

Stream<LyricsState> _lyricsPipeline(
  LyricsProvider provider,
  SyncEngine engine,
  MediaSource source, {
  GeniusScraper? genius,
  NeteaseProvider? netease,
}) async* {
  // `engine` es una dependencia del pipeline, no de su salida: pasarlo como
  // argumento evita que la UI tenga que reconstruirlo.

  // Suscripción paralela para conocer SIEMPRE la última pista emitida: si el
  // usuario salta de canción mientras una búsqueda está en vuelo, la pista
  // vieja no debe pintar letra ni alimentar al motor. [source.trackStream] es
  // un `async*` sobre un controller broadcast: una segunda suscripción es
  // segura.
  TrackInfo? latest;
  final latestSub = source.trackStream.listen((t) => latest = t);
  try {
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
        error = 'Unexpected error: $e';
      }

      // Ni LRCLIB ni NetEase la tienen: probamos con Genius antes de rendirnos.
      // Genius devuelve letra plana (sin tiempos), pero mejor que nada.
      if (result == null && error == null && netease != null) {
        try {
          result = await netease.fetch(track);
        } catch (_) {
          result = null;
        }
      }
      if (result == null && error == null && genius != null) {
        try {
          result = await genius.fetch(track);
        } catch (_) {
          result = null;
        }
      }

      // Si mientras buscábamos llegó otra pista, el resultado ya no vale: no
      // tocamos el motor ni emitimos estado para una canción que ya no suena.
      // (`latest == null` no descarta la primera pista válida.)
      if (latest != null && latest!.cacheKey != track.cacheKey) continue;

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
  } finally {
    await latestSub.cancel();
  }
}

String _describeLrclibError(LrclibException e) => switch (e.kind) {
      LrclibKind.timeout => 'LRCLIB took too long to respond',
      LrclibKind.network => 'No connection to lrclib.net',
      LrclibKind.server => 'lrclib.net is having problems',
      LrclibKind.notFound => 'No lyrics in LRCLIB',
      LrclibKind.badResponse => 'lrclib.net returned an invalid response',
      LrclibKind.client => 'LRCLIB rejected the request',
    };

/// Letra elegida a mano en la lupa, junto a la canción a la que pertenece.
class ManualLyrics {
  const ManualLyrics({required this.trackKey, required this.lyrics});

  final String trackKey;
  final Lyrics lyrics;
}

/// Letra seleccionada por el usuario en la lupa.
///
/// Se descarta sola al cambiar de canción (`ref.listen`) para no dejar una
/// letra pegada que ya no corresponde a lo que suena. El estado de la
/// búsqueda automática se conserva intacto por debajo.
final manualLyricsProvider =
    NotifierProvider<ManualLyricsNotifier, ManualLyrics?>(
        ManualLyricsNotifier.new);

class ManualLyricsNotifier extends Notifier<ManualLyrics?> {
  @override
  ManualLyrics? build() {
    ref.listen(currentTrackProvider, (_, next) {
      final key = next.value?.cacheKey;
      final current = state;
      if (current != null && current.trackKey != key) state = null;
    });
    return null;
  }

  /// Fija la letra que el usuario eligió en la lupa para [track].
  void apply(TrackInfo track, Lyrics lyrics) {
    state = ManualLyrics(trackKey: track.cacheKey, lyrics: lyrics);
  }

  /// Vuelve a la letra de la búsqueda automática.
  void clear() => state = null;
}

/// Estado que la UI debe pintar.
///
/// Es el de la búsqueda automática salvo que el usuario haya elegido una letra
/// concreta en la lupa para la canción actual: en ese caso manda la suya.
final displayLyricsStateProvider = Provider<LyricsState?>((ref) {
  final manual = ref.watch(manualLyricsProvider);
  final track = ref.watch(currentTrackProvider).value;
  final automatic = ref.watch(lyricsStateProvider).value;
  if (manual != null && track != null && manual.trackKey == track.cacheKey) {
    return LyricsState(
      phase: LyricsPhase.found,
      lyrics: manual.lyrics,
      track: track,
      manual: true,
    );
  }
  return automatic;
});

/// Clave de caché de la letra que se está pintando (traducciones y enlaces).
///
/// Siempre incluye una huella del contenido de la letra mostrada, además del
/// prefijo de la pista y el modo (automático o manual): una misma pista puede
/// resolver a letras distintas (p. ej. primero texto plano de un fallback y
/// luego letra sincronizada de LRCLIB), y las traducciones/enlaces —que están
/// indexados por posición— no deben reutilizarse contra las nuevas líneas.
/// El modo forma parte de la clave para que una letra manual no colisione con
/// una automática de contenido idéntico.
String displayLyricsCacheKey(LyricsState? state, TrackInfo track) {
  final lyrics = state?.lyrics;
  if (lyrics == null) return track.cacheKey;
  final mode = state?.manual == true ? 'manual' : 'auto';
  var hash = 17;
  for (final line in lyrics.lines) {
    hash = (hash * 31 + line.time.inMilliseconds) & 0x7fffffff;
    for (final code in line.text.codeUnits) {
      hash = (hash * 31 + code) & 0x7fffffff;
    }
  }
  final synced = lyrics.isSynced ? 1 : 0;
  final instrumental = lyrics.instrumental ? 1 : 0;
  return '${track.cacheKey}#$mode#${lyrics.lines.length}#'
      '${synced}_${instrumental}_$hash';
}

// ---------------------------------------------------------------------------
// Preferencias de interfaz
// ---------------------------------------------------------------------------

/// Idioma destino ofrecido en la configuración de traducción.
class TranslationLanguage {
  const TranslationLanguage(this.code, this.label);

  /// Código ISO que entiende Google Translate (`tl`), p. ej. `en`.
  final String code;

  /// Nombre mostrado en el desplegable (en inglés, como la interfaz).
  final String label;
}

/// Idiomas destino entre los que el usuario puede elegir.
///
/// No controlan el idioma de la app (siempre en inglés): solo a qué idioma se
/// traduce cada canción, sea cual sea el idioma original.
const List<TranslationLanguage> kTranslationLanguages = [
  TranslationLanguage('en', 'English'),
  TranslationLanguage('es', 'Spanish'),
  TranslationLanguage('fr', 'French'),
  TranslationLanguage('de', 'German'),
  TranslationLanguage('it', 'Italian'),
  TranslationLanguage('pt', 'Portuguese'),
  TranslationLanguage('ru', 'Russian'),
  TranslationLanguage('ja', 'Japanese'),
  TranslationLanguage('ko', 'Korean'),
  TranslationLanguage('zh-CN', 'Chinese (Simplified)'),
  TranslationLanguage('ar', 'Arabic'),
  TranslationLanguage('hi', 'Hindi'),
];

/// Etiqueta legible de un código de idioma destino.
String translationLanguageLabel(String code) {
  for (final lang in kTranslationLanguages) {
    if (lang.code == code) return lang.label;
  }
  return code;
}

/// Definición de un ajuste de la aplicación.
///
/// Cada ajuste se declara UNA sola vez aquí: su clave de persistencia, su
/// valor por defecto y, opcionalmente, cómo normalizar el valor antes de
/// aplicarlo (p. ej. acotar un rango). El tipo [T] debe ser uno de los que
/// entiende `shared_preferences` (`bool`, `double`, `int` o `String`).
class SettingDef<T> {
  const SettingDef({
    required this.key,
    required this.defaultValue,
    this.persist = true,
    this.normalize,
  });

  /// Clave con la que se guarda en `SharedPreferences`.
  final String key;

  /// Valor que se usa mientras no haya nada guardado.
  final T defaultValue;

  /// Si es `false`, el ajuste vive solo mientras la app está abierta.
  final bool persist;

  /// Ajusta el valor antes de aplicarlo y guardarlo (p. ej. acotarlo).
  final T Function(T value)? normalize;

  /// Aplica [normalize] si existe.
  T clean(T value) => normalize?.call(value) ?? value;
}

/// Acota el tamaño de fuente al rango que admite la vista.
double _clampFontSize(double size) => size.clamp(14.0, 56.0);

/// Catálogo de ajustes de la aplicación.
///
/// Añadir una opción nueva = una constante aquí, una entrada en [all] y una
/// fila en el panel de ajustes.
abstract final class Settings {
  static const SettingDef<double> fontSize = SettingDef<double>(
    key: 'ui.fontSize',
    defaultValue: 26,
    normalize: _clampFontSize,
  );

  static const SettingDef<bool> themeIsDark = SettingDef<bool>(
    key: 'ui.themeIsDark',
    defaultValue: false,
  );

  /// Colorea cada palabra con el color pastel de la parte que le corresponde
  /// (original ↔ traducción).
  static const SettingDef<bool> showWordColors = SettingDef<bool>(
    key: 'ui.showWordColors',
    defaultValue: false,
  );

  /// Código del idioma al que se traduce cada canción (no el de la app).
  static const SettingDef<String> translationTarget = SettingDef<String>(
    key: 'ui.translationTarget',
    defaultValue: 'es',
  );

  /// Todos los ajustes, para cargarlos de una sola pasada.
  static const List<SettingDef<dynamic>> all = [
    fontSize,
    themeIsDark,
    showWordColors,
    translationTarget,
  ];
}

/// Valores actuales de los ajustes. Inmutable: se lee con [get] y se cambia
/// con [AppSettingsNotifier.set].
class AppSettings {
  const AppSettings(this._values);

  final Map<String, Object?> _values;

  /// Valor actual de [def] (o su valor por defecto si nunca se cambió).
  T get<T>(SettingDef<T> def) => (_values[def.key] as T?) ?? def.defaultValue;

  /// Copia con [def] cambiado a [value].
  AppSettings withValue<T>(SettingDef<T> def, T value) =>
      AppSettings({..._values, def.key: value});
}

/// Ajustes de interfaz. Todos se persisten entre sesiones.
final appSettingsProvider =
    NotifierProvider<AppSettingsNotifier, AppSettings>(AppSettingsNotifier.new);

/// Preferencias persistentes del sistema (`shared_preferences`).
///
/// Se sobreescribe en `main` con la instancia ya cargada antes de montar la
/// app, para que los valores guardados estén disponibles en el primer frame.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError(
    'sharedPreferencesProvider debe sobreescribirse en main().',
  ),
);

/// Carga, aplica y persiste los ajustes. Toda escritura pasa por [set], que
/// decide si el ajuste se guarda según su definición ([SettingDef.persist]).
class AppSettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    final prefs = ref.read(sharedPreferencesProvider);
    final values = <String, Object?>{};
    for (final def in Settings.all) {
      final raw = prefs.get(def.key);
      if (raw != null) values[def.key] = raw;
    }
    return AppSettings(values);
  }

  /// Cambia un ajuste y, si es persistente, lo guarda entre sesiones.
  void set<T>(SettingDef<T> def, T value) {
    final next = def.clean(value);
    state = state.withValue(def, next);
    if (def.persist) _persist(def.key, next);
  }

  /// Devuelve un ajuste a su valor por defecto.
  void reset<T>(SettingDef<T> def) => set(def, def.defaultValue);

  void _persist(String key, Object? value) {
    final prefs = ref.read(sharedPreferencesProvider);
    final saved = switch (value) {
      final bool v => prefs.setBool(key, v),
      final double v => prefs.setDouble(key, v),
      final int v => prefs.setInt(key, v),
      final String v => prefs.setString(key, v),
      _ => Future<bool>.value(false),
    };
    saved.ignore();
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

// ---------------------------------------------------------------------------
// Traducción al español (Google Translate, una petición por canción)
// ---------------------------------------------------------------------------

/// Servicio de traducción Google (`sl=auto`, `tl=es`).
final translationServiceProvider = Provider<GoogleTranslationService>((ref) {
  return GoogleTranslationService(client: ref.watch(httpClientProvider));
});

/// Caché en memoria `cacheKey -> traducción de la canción` ([SongTranslation]).
///
/// Guarda el resultado completo de la petición (traducciones por línea y
/// pares de segmentos `dt=bd`) para no repetir la petición al hacer scroll
/// o reconstruir la UI.
final translationCacheProvider = NotifierProvider<TranslationCacheNotifier,
    Map<String, SongTranslation>>(TranslationCacheNotifier.new);

/// Caché simple de traducciones de canción.
class TranslationCacheNotifier
    extends Notifier<Map<String, SongTranslation>> {
  @override
  Map<String, SongTranslation> build() => {};

  /// Guarda la canción traducida bajo [trackKey].
  void put(String trackKey, SongTranslation song) {
    state = {...state, trackKey: song};
  }
}

/// Traducción de la letra actual, línea por línea + segmentos alineados.
///
/// Hace UNA petición con toda la canción junta
/// (`GoogleTranslationService.translateSong`): reparte las traducciones por
/// línea con un `for` y guarda los pares original↔traducción (`dt=bd`) en
/// [SongTranslation.segmentPairs], que el alineador de los enlaces usa como
/// contexto de cada línea. Si la canción ya está en español, emite un
/// `SongTranslation` vacío para que la UI no muestre nada debajo.
final songTranslationProvider = FutureProvider<SongTranslation>((ref) async {
  final lyricsState = ref.watch(displayLyricsStateProvider);
  final lyrics = lyricsState?.lyrics;
  final track = lyricsState?.track ?? ref.watch(currentTrackProvider).value;
  if (lyrics == null || track == null) {
    return const SongTranslation(translations: {});
  }
  if (!lyrics.isSynced && lyrics.visibleLines.isEmpty) {
    return const SongTranslation(translations: {});
  }

  final target = ref.watch(
      appSettingsProvider.select((s) => s.get(Settings.translationTarget)));
  final key = '${displayLyricsCacheKey(lyricsState, track)}|tl:$target';
  final cached = ref.watch(translationCacheProvider)[key];
  if (cached != null) return cached;

  // Caché persistente (SQLite): sobrevive reinicios de la app.
  final persisted = await ref.read(lyricsCacheProvider).getTranslation(key);
  if (persisted != null) {
    ref.read(translationCacheProvider.notifier).put(key, persisted);
    return persisted;
  }

  final service = ref.watch(translationServiceProvider);
  final lines = [for (final l in lyrics.lines) l.text];
  final song = await service.translateSong(lines, target: target);
  // Un resultado vacío puede ser un fallo transitorio de red o "ya está en el
  // idioma destino": no merece disco. Solo persistimos traducciones reales.
  if (song.translations.isNotEmpty) {
    ref.read(translationCacheProvider.notifier).put(key, song);
    await ref.read(lyricsCacheProvider).putTranslation(key, song);
  }
  return song;
});

/// Caché en memoria
/// `cacheKey -> (línea -> (orden traducido -> TokenLink))`.
final wordLinksCacheProvider = NotifierProvider<WordLinksCacheNotifier,
    Map<String, Map<int, Map<int, TokenLink>>>>(WordLinksCacheNotifier.new);

/// Caché simple de emparejamientos palabra-por-palabra por canción.
class WordLinksCacheNotifier
    extends Notifier<Map<String, Map<int, Map<int, TokenLink>>>> {
  @override
  Map<String, Map<int, Map<int, TokenLink>>> build() => {};

  /// Guarda los enlaces de una canción.
  void put(String trackKey, Map<int, Map<int, TokenLink>> byLine) {
    state = {...state, trackKey: byLine};
  }
}

/// Emparejamiento REAL palabra traducida -> palabra original ([TokenLink]),
/// por línea, en DOS pasadas.
///
/// * **Pasada 1**: con el léxico de [songTranslationProvider]
///   (`translateWordList` sobre la frase-vocabulario completa de la canción,
///   DE UNA sola petición), alinea cada línea con
///   [alignLineTokens] usando mapas palabra/frase, sentidos `dt=bd` y los
///   segmentos de la traducción.
/// * **Pasada contextual**: solo si quedaron palabras originales sin enlace,
///   UNA petición más (`translateContextualLines`, truco numerado) sobre las
///   líneas afectadas (deduplicadas, máx. 25) recupera traducciones
///   contextuales; se funden por posición con `??=` (nunca pisan el léxico
///   aislado) y SOLO las líneas con palabras nuevas se realinean.
/// Si la canción ya está en español (sin traducciones) o todo casa a la
/// primera, no hay petición contextual: cero coste extra.
final songWordLinksProvider =
    FutureProvider<Map<int, Map<int, TokenLink>>>((ref) async {
  final lyricsState = ref.watch(displayLyricsStateProvider);
  final lyrics = lyricsState?.lyrics;
  final track = lyricsState?.track ?? ref.watch(currentTrackProvider).value;
  if (lyrics == null || track == null) return {};
  final song = await ref.watch(songTranslationProvider.future);
  if (song.translations.isEmpty) return {};

  final target = ref.watch(
      appSettingsProvider.select((s) => s.get(Settings.translationTarget)));
  final key = '${displayLyricsCacheKey(lyricsState, track)}|tl:$target';
  final cached = ref.watch(wordLinksCacheProvider)[key];
  if (cached != null) return cached;

  final service = ref.watch(translationServiceProvider);

  // Tokens originales SOLO de las líneas con traducción (las que se alinean);
  // todos juntos conforman el vocabulario de frases (unigramas + n-gramas).
  final tokensByLine = <int, List<String>>{};
  final allTokens = <String>[];
  for (var i = 0; i < lyrics.lines.length; i++) {
    final translated = song.translations[i];
    if (translated == null || translated.trim().isEmpty) continue;
    final tokens = wordTokens(lyrics.lines[i].text);
    tokensByLine[i] = tokens;
    allTokens.addAll(tokens);
  }
  if (tokensByLine.isEmpty) return {};

  final vocab = phraseVocabulary(allTokens);
  final lexicon = await service.translateWordList(vocab.toList(), target: target);
  if (lexicon.primary.isEmpty) return {};

  /// Alinea todas las líneas presentes con el mapa de palabras dado.
  Map<int, Map<int, TokenLink>> alignAll(Map<String, String> wordMap) {
    final byLine = <int, Map<int, TokenLink>>{};
    for (final entry in tokensByLine.entries) {
      final links = alignLineTokens(
        originalTokens: entry.value,
        translatedTokens: wordTokens(song.translations[entry.key]!),
        wordMap: wordMap,
        senseMap: lexicon.senses,
        segments: song.segmentPairs[entry.key] ?? const [],
      );
      if (links.isNotEmpty) byLine[entry.key] = links;
    }
    return byLine;
  }

  // PASADA 1: léxico con la traducción aislada de cada palabra/frase.
  final byLine = alignAll(lexicon.primary);

  // Palabras originales sin enlace (por normalizado) en toda la canción.
  final unlinked = <String>{};
  for (final entry in tokensByLine.entries) {
    final linkedIndices =
        {for (final l in (byLine[entry.key] ?? const {}).values) l.originalIndex};
    for (var k = 0; k < entry.value.length; k++) {
      if (linkedIndices.contains(k)) continue;
      final norm = normalizeToken(entry.value[k]);
      if (norm.isNotEmpty) unlinked.add(norm);
    }
  }

  // Sin fallos: nada más que pedir, cero coste extra.
  if (unlinked.isEmpty) {
    ref.read(wordLinksCacheProvider.notifier).put(key, byLine);
    return byLine;
  }

  // PASADA CONTEXTUAL: textos de las líneas presentes con alguna palabra sin
  // enlace, deduplicados y acotados a 25 (cada una cuesta un índice en la
  // petición numerada).
  final contextualLines = <String>[];
  final seenTexts = <String>{};
  for (var i = 0; i < lyrics.lines.length; i++) {
    if (!tokensByLine.containsKey(i)) continue;
    final hasUnlinked = tokensByLine[i]!.any((t) => unlinked.contains(
          normalizeToken(t),
        ));
    if (!hasUnlinked) continue;
    final text = lyrics.lines[i].text;
    if (!seenTexts.add(text)) continue;
    contextualLines.add(text);
    if (contextualLines.length >= 25) break;
  }

  final contextual =
      await service.translateContextualLines(contextualLines, target: target);

  // FUSIÓN con el léxico: cada traducción contextual cubre la palabra en su
  // posición. `??=`: nunca pisa la traducción aislada, solo rellena los
  // huecos de los fallos.
  final merged = {...lexicon.primary};
  final added = <String>{};
  for (final entry in contextual.entries) {
    final contextTokens = wordTokens(contextualLines[entry.key]);
    final list = entry.value;
    final paired = contextTokens.length < list.length
        ? contextTokens.length
        : list.length;
    for (var k = 0; k < paired; k++) {
      final trad = list[k].trim();
      if (trad.isEmpty) continue;
      final norm = normalizeToken(contextTokens[k]);
      if (norm.isEmpty || norm.length < 2) continue;
      if (merged[norm] != null) continue;
      merged[norm] = trad;
      added.add(norm);
    }
  }

  // Si el contexto no aportó nada de nuevo, la realineación no cambiaría
  // nada: paramos aquí.
  if (added.isEmpty) {
    ref.read(wordLinksCacheProvider.notifier).put(key, byLine);
    return byLine;
  }

  // PASADA 2: re-alinear SOLO las líneas con alguna palabra nueva en el
  // mapa, reemplazando su entrada anterior.
  final affected = <int>[];
  for (final entry in tokensByLine.entries) {
    final hasNew = entry.value.any((t) => added.contains(normalizeToken(t)));
    if (hasNew) affected.add(entry.key);
  }
  for (final i in affected) {
    final links = alignLineTokens(
      originalTokens: tokensByLine[i]!,
      translatedTokens: wordTokens(song.translations[i]!),
      wordMap: merged,
      senseMap: lexicon.senses,
      segments: song.segmentPairs[i] ?? const [],
    );
    if (links.isEmpty) {
      byLine.remove(i);
    } else {
      byLine[i] = links;
    }
  }

  ref.read(wordLinksCacheProvider.notifier).put(key, byLine);
  return byLine;
});