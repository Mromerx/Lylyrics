import 'dart:async';
import 'dart:developer' as developer;

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

import '../../core/interfaces/media_source.dart';
import '../../core/models/playback_state.dart';
import '../../core/models/track_info.dart';

// ---------------------------------------------------------------------------
// Constantes del protocolo
// ---------------------------------------------------------------------------

/// Prefijo de los nombres de bus que implementan MPRIS.
const String kMprisBusPrefix = 'org.mpris.MediaPlayer2.';

/// Interfaz raíz de MPRIS (Identity, DesktopEntry, CanQuit...).
const String kMprisRootInterface = 'org.mpris.MediaPlayer2';

/// Interfaz de reproducción de MPRIS (Metadata, PlaybackStatus, Position...).
const String kMprisPlayerInterface = 'org.mpris.MediaPlayer2.Player';

/// Interfaz estándar de D-Bus para leer propiedades.
const String kDBusPropertiesInterface = 'org.freedesktop.DBus.Properties';

/// Objeto sobre el que se publican todas las propiedades MPRIS.
const DBusObjectPath kMprisObjectPath =
    DBusObjectPath.unchecked('/org/mpris/MediaPlayer2');

// Claves de `Metadata`. Los nombres son los que fija la especificación MPRIS,
// por eso van en inglés aunque el resto del código esté comentado en español.
const String kTitleKey = 'xesam:title';
const String kArtistKey = 'xesam:artist';
const String kAlbumKey = 'xesam:album';
const String kLengthKey = 'mpris:length';
const String kTrackIdKey = 'mpris:trackid';

// Nombres de `PlaybackStatus`.
const String kStatusPlaying = 'Playing';
const String kStatusPaused = 'Paused';
const String kStatusStopped = 'Stopped';

// Puntuaciones usadas por [mprisPlayerScore]. Son magnitudes relativas: solo
// importa el orden, no el valor absoluto.
const int _scoreSpotify = 400;
const int _scoreYouTubeMusic = 350;
const int _scoreYouTube = 300;
const int _scoreKnownPlayer = 200;
const int _scoreGenericChromium = 20;
const int _scoreUnknown = 0;

/// Reproductores conocidos que no son navegadores: preferimos un reproductor
/// dedicado antes que un `chromium.instanceN` genérico.
const List<String> _knownPlayerHints = <String>[
  'vlc',
  'rhythmbox',
  'audacious',
  'deadbeef',
  'mpv',
  'elisa',
  'quodlibet',
  'clementine',
  'strawberry',
  'banshee',
  'amarok',
  'celluloid',
];

/// Rutas que usan algunos reproductores para decir "no hay pista".
const List<String> _noTrackMarkers = <String>[
  '/org/mpris/MediaPlayer2/TrackList/NoTrack',
];

/// Cada cuánto se lee `Position`. Solo se hace polling mientras el
/// reproductor está en Playing.
const Duration kDefaultPositionPollInterval = Duration(milliseconds: 1000);

// ---------------------------------------------------------------------------
// Lógica pura (testeable sin D-Bus)
// ---------------------------------------------------------------------------

/// Convierte microsegundos MPRIS a [Duration] de forma defensiva.
///
/// La especificación dice que un valor `<= 0` significa "duración desconocida";
/// aquí se recorta a [Duration.zero] para que ningún llamante tenga que
/// comprobar el signo. Usa [trackInfoFromRaw] si necesitas distinguir
/// "desconocida" de "instantánea".
@visibleForTesting
Duration positionFromMicros(int? micros) {
  if (micros == null || micros <= 0) return Duration.zero;
  return Duration(microseconds: micros);
}

/// Normaliza un título para poder compararlo: minúsculas y espacios colapsados.
///
/// Devuelve `null` si la cadena está vacía o es solo espacios. Ojo: esto es
/// solo para comparar, el título que se muestra conserva su capitalización
/// original (ver [trackInfoFromRaw]).
@visibleForTesting
String? normalizeTitle(String? raw) {
  if (raw == null) return null;
  final collapsed = raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  return collapsed.isEmpty ? null : collapsed;
}

/// Limpia un texto que sí se va a mostrar: recorta los bordes pero respeta las
/// mayúsculas y los espacios internos de la cadena original.
@visibleForTesting
String? cleanText(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Construye la clave que identifica la pista actual.
///
/// Se combinan `mpris:trackid` y el título normalizado porque hay
/// reproductores que reutilizan el mismo `trackid` para toda la sesión (por
/// ejemplo los basados en Chromium) y otros que lo cambian en cada canción
/// pero no cuando solo cambia el portada. Si algún reproductor usa un
/// `trackid` centinela ("sin pista") se descarta y nos quedamos con el título.
@visibleForTesting
String? trackKeyFromRaw({String? trackId, String? title}) {
  final normalized = normalizeTitle(title);
  final id = trackId?.trim();
  final usableId = id != null &&
      id.isNotEmpty &&
      id != '/' &&
      !_noTrackMarkers.any(id.endsWith) &&
      !id.toLowerCase().contains('notrack');
  if (usableId) {
    return normalized == null ? id : '$id|$normalized';
  }
  return normalized;
}

/// ¿Ha cambiado de pista respecto a la última clave conocida?
///
/// `null -> null` no es cambio: así no emitimos `null` en bucle cuando el
/// reproductor está parado desde el principio.
@visibleForTesting
bool trackKeyChanged({String? previous, String? next}) {
  if (previous == null && next == null) return false;
  return previous != next;
}

/// Traduce el `PlaybackStatus` crudo a nuestro enum, tolerando basura.
@visibleForTesting
PlaybackStatus playbackStatusFromRaw(String? raw) {
  return PlaybackStatus.fromMpris((raw ?? '').trim());
}

/// Extrae una cadena de un valor ya deserializado por D-Bus.
///
/// Recorta los bordes y devuelve `null` si no queda nada: así los
/// reproductores que mandan `""` en `xesam:album` no ensucian el modelo.
@visibleForTesting
String? valueAsString(Object? value) {
  final native = value is DBusValue ? nativeValueOf(value) : value;
  if (native is String) return cleanText(native);
  return null;
}

/// Extrae una lista de cadenas (`as`) de un valor ya deserializado.
@visibleForTesting
List<String> valueAsStringList(Object? value) {
  if (value is Iterable) {
    final out = <String>[];
    for (final item in value) {
      final s = valueAsString(item);
      if (s == null) continue;
      if (out.any((existing) => existing.toLowerCase() == s.toLowerCase())) {
        continue; // deduplicamos, algunos reproductores repiten artistas
      }
      out.add(s);
    }
    return out;
  }
  final single = valueAsString(value);
  return single == null ? <String>[] : <String>[single];
}

/// Extrae un entero (`x`, `i`, `n`...) de un valor ya deserializado.
@visibleForTesting
int? valueAsInt(Object? value) {
  final native = value is DBusValue ? nativeValueOf(value) : value;
  if (native is int) return native;
  if (native is num) {
    final n = native.toDouble();
    return n.isFinite ? n.round() : null;
  }
  if (native is String) return int.tryParse(native.trim());
  return null;
}

/// Extrae un double (`d`) de un valor ya deserializado.
@visibleForTesting
double? valueAsDouble(Object? value) {
  final native = value is DBusValue ? nativeValueOf(value) : value;
  if (native is double) return native;
  if (native is num) return native.toDouble();
  if (native is String) return double.tryParse(native.trim());
  return null;
}

/// Lectura de una clave de texto del dict `Metadata` ya deserializado.
@visibleForTesting
String? metadataString(Map<String, dynamic> metadata, String key) =>
    valueAsString(metadata[key]);

/// Lectura de una clave `as` del dict `Metadata` ya deserializado.
@visibleForTesting
List<String> metadataStringList(Map<String, dynamic> metadata, String key) =>
    valueAsStringList(metadata[key]);

/// Lectura de una clave numérica del dict `Metadata` ya deserializado.
@visibleForTesting
int? metadataInt(Map<String, dynamic> metadata, String key) =>
    valueAsInt(metadata[key]);

/// Puntuación de un reproductor: cuanto más alto, más nos interesa.
///
/// Los servicios de música conocidos ganan por encima del resto, después
/// vienen los reproductores conocidos y, al final, los `chromium.instanceN`
/// sin identificar, que suelen ser una app de electron genérica.
@visibleForTesting
int mprisPlayerScore({
  required String busName,
  String? identity,
  String? desktopEntry,
  List<String> hints = const <String>[],
}) {
  final haystack = _compactHaystack(<String?>[
    busName,
    identity,
    desktopEntry,
    ...hints,
  ]);
  if (haystack.contains('spotify')) return _scoreSpotify;
  if (haystack.contains('youtubemusic') ||
      haystack.contains('ytmusic') ||
      haystack.contains('googlemusic')) {
    return _scoreYouTubeMusic;
  }
  if (haystack.contains('youtube')) return _scoreYouTube;
  for (final known in _knownPlayerHints) {
    if (haystack.contains(known)) return _scoreKnownPlayer;
  }
  if (haystack.contains('chromium') ||
      haystack.contains('electron') ||
      haystack.contains('googlechrome') ||
      haystack.contains('brave')) {
    return _scoreGenericChromium;
  }
  return _scoreUnknown;
}

/// Convierte a minúsculas y quita todo lo que no sea alfanumérico para que
/// "VLC" y `org.mpris.MediaPlayer2.vlc` colisionen.
String _compactHaystack(Iterable<String?> parts) {
  final buf = StringBuffer();
  for (final part in parts) {
    if (part == null) continue;
    for (final rune in part.toLowerCase().runes) {
      final isDigit = rune >= 0x30 && rune <= 0x39;
      final isLower = rune >= 0x61 && rune <= 0x7a;
      if (isDigit || isLower) buf.writeCharCode(rune);
    }
  }
  return buf.toString();
}

/// Compara dos reproductores: primero el que está reproduciendo, luego el de
/// mayor puntuación y, por último, el nombre (para que sea determinista).
@visibleForTesting
int compareMprisPlayers(MprisPlayerInfo a, MprisPlayerInfo b) {
  final byStatus = a.status.index.compareTo(b.status.index);
  if (byStatus != 0) return byStatus;
  final byScore = b.score.compareTo(a.score);
  if (byScore != 0) return byScore;
  return a.busName.compareTo(b.busName);
}

/// Elige el reproductor activo.
///
/// [forced] gana si sigue existiendo en el bus; si ya no existe se cae al
/// modo automático (para no quedarnos mudos cuando el reproductor se cierra
/// justo después de que el usuario lo eligiera).
@visibleForTesting
String? selectBestPlayer({
  required Map<String, MprisPlayerInfo> players,
  String? forced,
}) {
  if (players.isEmpty) return null;
  if (forced != null && players.containsKey(forced)) return forced;
  final sorted = players.values.toList()..sort(compareMprisPlayers);
  return sorted.first.busName;
}

/// Acota la posición a `[0, duración]` cuando la duración es conocida.
@visibleForTesting
Duration clampPosition(Duration position, Duration? total) {
  var micros = position.inMicroseconds;
  if (micros < 0) micros = 0;
  final totalMicros = total?.inMicroseconds ?? 0;
  if (totalMicros > 0 && micros > totalMicros) micros = totalMicros;
  return Duration(microseconds: micros);
}

/// Proyecta la posición conocida a [now].
///
/// MPRIS no emite señales de `Position`, así que extrapolamos con el reloj de
/// la sesión. Devuelve [position] tal cual si no estamos reproduciendo o si el
/// tiempo no ha avanzado.
@visibleForTesting
Duration interpolatePosition({
  required DateTime now,
  required Duration position,
  required DateTime timestamp,
  required double rate,
  required bool isPlaying,
}) {
  if (!isPlaying) return position;
  final elapsedMs = now.difference(timestamp).inMilliseconds;
  if (elapsedMs <= 0) return position;
  final safeRate = rate.isFinite ? rate : 1.0;
  final micros = position.inMicroseconds + (elapsedMs * safeRate * 1000).round();
  return Duration(microseconds: micros < 0 ? 0 : micros);
}

/// Construye el [TrackInfo] a partir de los campos sueltos de `Metadata`.
///
/// Devuelve `null` si no hay nada real que mostrar (sin título y sin
/// artistas), que es lo que hace que el reproductor se considere "sin pista".
@visibleForTesting
TrackInfo? trackInfoFromRaw({
  String? title,
  List<String> artists = const <String>[],
  String? album,
  int? lengthMicros,
  String? app,
}) {
  // Ojo: el título y el álbum conservan las mayúsculas que publica el
  // reproductor; [normalizeTitle] solo se usa para comparar pistas.
  final cleanTitle = cleanText(title);
  final cleanArtists = valueAsStringList(artists);
  final artist = cleanArtists.join(', ');
  // Sin título usamos el artista: mejor "Daft Punk" que una tarjeta vacía.
  final resolvedTitle = cleanTitle ?? (artist.isEmpty ? null : artist);
  if (resolvedTitle == null) return null;

  // mpris:length <= 0 significa "duración desconocida" según la spec, así que
  // lo dejamos en null en vez de inventar una duración de cero.
  final duration = (lengthMicros == null || lengthMicros <= 0)
      ? null
      : Duration(microseconds: lengthMicros);

  return TrackInfo(
    title: resolvedTitle,
    artist: artist,
    album: valueAsString(album),
    duration: duration,
    sourceApp: valueAsString(app),
  );
}

/// Construye el [TrackInfo] leyendo directamente el dict `Metadata` ya
/// deserializado (`Map<String, dynamic>` con valores nativos de Dart).
@visibleForTesting
TrackInfo? trackInfoFromMetadata(Map<String, dynamic> metadata,
    {String? app}) {
  if (metadata.isEmpty) return null;
  return trackInfoFromRaw(
    title: metadataString(metadata, kTitleKey),
    artists: metadataStringList(metadata, kArtistKey),
    album: metadataString(metadata, kAlbumKey),
    lengthMicros: metadataInt(metadata, kLengthKey),
    app: app,
  );
}

/// Lo que sabemos de un reproductor concreto del bus.
@immutable
class MprisPlayerInfo {
  const MprisPlayerInfo({
    required this.busName,
    this.identity,
    this.desktopEntry,
    this.status = PlaybackStatus.stopped,
    this.score = _scoreUnknown,
  });

  /// Construye la ficha leyendo lo publicado en la interfaz raíz.
  factory MprisPlayerInfo.probed({
    required String busName,
    String? identity,
    String? desktopEntry,
    PlaybackStatus status = PlaybackStatus.stopped,
    List<String> hints = const <String>[],
  }) {
    return MprisPlayerInfo(
      busName: busName,
      identity: identity,
      desktopEntry: desktopEntry,
      status: status,
      score: mprisPlayerScore(
        busName: busName,
        identity: identity,
        desktopEntry: desktopEntry,
        hints: hints,
      ),
    );
  }

  /// Nombre de bus completo, p. ej. `org.mpris.MediaPlayer2.vlc`.
  final String busName;

  /// `Identity` de la interfaz raíz: nombre visible de la app.
  final String? identity;

  /// `DesktopEntry` de la interfaz raíz: nombre del `.desktop`.
  final String? desktopEntry;

  /// Último `PlaybackStatus` conocido.
  final PlaybackStatus status;

  /// Resultado de [mprisPlayerScore] con los datos de este reproductor.
  final int score;

  /// Atajo al nombre corto (lo que va tras `org.mpris.MediaPlayer2.`).
  String get shortName =>
      busName.startsWith(kMprisBusPrefix)
          ? busName.substring(kMprisBusPrefix.length)
          : busName;

  /// Etiqueta legible para el selector de la UI.
  String get label {
    final id = identity?.trim();
    return (id == null || id.isEmpty) ? shortName : id;
  }

  MprisPlayerInfo copyWith({
    String? identity,
    String? desktopEntry,
    PlaybackStatus? status,
    int? score,
  }) {
    return MprisPlayerInfo(
      busName: busName,
      identity: identity ?? this.identity,
      desktopEntry: desktopEntry ?? this.desktopEntry,
      status: status ?? this.status,
      score: score ?? this.score,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MprisPlayerInfo &&
      other.busName == busName &&
      other.identity == identity &&
      other.desktopEntry == desktopEntry &&
      other.status == status &&
      other.score == score;

  @override
  int get hashCode =>
      Object.hash(busName, identity, desktopEntry, status, score);

  @override
  String toString() => 'MprisPlayerInfo($busName, identity: $identity, '
      'desktopEntry: $desktopEntry, status: ${status.name}, score: $score)';
}

// ---------------------------------------------------------------------------
// Transporte D-Bus (todo lo que habla D-Bus vive aquí)
// ---------------------------------------------------------------------------

/// Envoltura fina sobre [DBusClient] con las operaciones MPRIS que usamos.
///
/// Existe para separar el "transporte" de la lógica: [MprisMediaSource] no
/// toca nunca tipos de D-Bus, y esta clase no decide nada.
class MprisBus {
  MprisBus(this.client, {this.callTimeout = const Duration(seconds: 3)});

  final DBusClient client;

  /// Tope de espera de cada llamada. Un reproductor que posesiona el nombre
  /// pero no contesta (zombi o medio colgado) no puede bloquear la fuente
  /// más de este tiempo.
  final Duration callTimeout;

  /// Nombres de bus MPRIS presentes ahora mismo en el bus de sesión.
  Future<List<String>> listPlayerNames() async {
    final names = await client.listNames();
    return names.where((n) => n.startsWith(kMprisBusPrefix)).toList();
  }

  /// Cambios de propietario de nombres MPRIS (altas y bajas en caliente).
  Stream<DBusNameOwnerChangedEvent> get nameOwnerChanged =>
      client.nameOwnerChanged
          .where((e) => e.name.startsWith(kMprisBusPrefix));

  /// Lee una propiedad cualquiera vía `org.freedesktop.DBus.Properties.Get`.
  ///
  /// Devuelve el valor ya deserializado a tipos nativos de Dart (`String`,
  /// `int`, `double`, `List<Object?>`, `Map<String, Object?>`...). Lanza la
  /// excepción de D-Bus si el reproductor muere durante la llamada, o
  /// `TimeoutException` si no contesta en [callTimeout]; el llamante la
  /// captura.
  Future<Object?> getProperty(
    String busName,
    String interface,
    String property,
  ) async {
    final response = await client
        .callMethod(
          destination: busName,
          path: kMprisObjectPath,
          interface: kDBusPropertiesInterface,
          name: 'Get',
          values: <DBusValue>[DBusString(interface), DBusString(property)],
          replySignature: DBusSignature('v'),
        )
        .timeout(callTimeout);
    if (response.returnValues.isEmpty) return null;
    return response.returnValues.first.asVariant().toNative();
  }

  /// Igual que [getProperty] pero devolviendo `String` o `null`.
  Future<String?> getString(
    String busName,
    String interface,
    String property,
  ) async {
    return valueAsString(await getProperty(busName, interface, property));
  }

  /// Igual que [getProperty] pero devolviendo `int` o `null`.
  Future<int?> getInt(
    String busName,
    String interface,
    String property,
  ) async {
    return valueAsInt(await getProperty(busName, interface, property));
  }

  /// Igual que [getProperty] pero devolviendo `double` o `null`.
  Future<double?> getDouble(
    String busName,
    String interface,
    String property,
  ) async {
    return valueAsDouble(await getProperty(busName, interface, property));
  }

  /// Lee `Metadata` de la interfaz Player como `Map<String, dynamic>`.
  Future<Map<String, dynamic>> getMetadata(String busName) async {
    final raw = await getProperty(busName, kMprisPlayerInterface, 'Metadata');
    return metadataFromNative(raw);
  }

  /// Lee `PlaybackStatus` de la interfaz Player.
  Future<PlaybackStatus> getPlaybackStatus(String busName) async {
    return playbackStatusFromRaw(
        await getString(busName, kMprisPlayerInterface, 'PlaybackStatus'));
  }

  /// Escucha `PropertiesChanged` del reproductor indicado.
  StreamSubscription<DBusSignal> listenPropertiesChanged(
    String busName,
    void Function(Map<String, dynamic> changed) onChanged,
  ) {
    return DBusSignalStream(
      client,
      sender: busName,
      interface: kDBusPropertiesInterface,
      name: 'PropertiesChanged',
      path: kMprisObjectPath,
    ).listen(
      (signal) {
        try {
          final changed = propertiesChangedValues(signal.values);
          if (changed.isEmpty) return;
          onChanged(changed);
        } catch (e) {
          developer.log('PropertiesChanged ilegible de $busName: $e',
              name: 'lylyrics.mpris');
        }
      },
      onError: (Object error) {
        developer.log('Suscripción PropertiesChanged de $busName caída: $error',
            name: 'lylyrics.mpris');
      },
    );
  }

  /// Escucha la señal `Seeked` (posición en microsegundos).
  StreamSubscription<DBusSignal> listenSeeked(
    String busName,
    void Function(int positionMicros) onSeeked,
  ) {
    return DBusSignalStream(
      client,
      sender: busName,
      interface: kMprisPlayerInterface,
      name: 'Seeked',
      path: kMprisObjectPath,
    ).listen(
      (signal) {
        try {
          if (signal.values.isEmpty) return;
          final micros = valueAsInt(signal.values.first);
          if (micros != null) onSeeked(micros);
        } catch (e) {
          developer.log('Señal Seeked ilegible de $busName: $e',
              name: 'lylyrics.mpris');
        }
      },
      onError: (Object error) {
        developer.log('Suscripción Seeked de $busName caída: $error',
            name: 'lylyrics.mpris');
      },
    );
  }

  /// Salta a [positionMicros] en la pista [trackId] (MPRIS `SetPosition`).
  ///
  /// Devuelve `true` si el reproductor contestó sin error.
  Future<bool> setPosition(
    String busName,
    String trackId,
    int positionMicros,
  ) async {
    try {
      await client
          .callMethod(
            destination: busName,
            path: kMprisObjectPath,
            interface: kMprisPlayerInterface,
            name: 'SetPosition',
            values: <DBusValue>[
              DBusObjectPath.unchecked(trackId),
              DBusInt64(positionMicros),
            ],
          )
          .timeout(callTimeout);
      return true;
    } catch (e) {
      developer.log('SetPosition falló en $busName: $e',
          name: 'lylyrics.mpris');
      return false;
    }
  }

  /// Alterna pausa/reproducción (MPRIS `PlayPause`).
  ///
  /// Devuelve `true` si el reproductor contestó sin error.
  Future<bool> playPause(String busName) async {
    try {
      await client
          .callMethod(
            destination: busName,
            path: kMprisObjectPath,
            interface: kMprisPlayerInterface,
            name: 'PlayPause',
          )
          .timeout(callTimeout);
      return true;
    } catch (e) {
      developer.log('PlayPause falló en $busName: $e',
          name: 'lylyrics.mpris');
      return false;
    }
  }

  /// Cierra la conexión con el bus de sesión.
  Future<void> close() async {
    await client.close();
  }
}

/// Normaliza cualquier valor de D-Bus a algo utilizable por la lógica pura.
///
/// Acepta el `Map<String, DBusValue>` que devuelve `asStringVariantDict()` (los
/// valores ya vienen sin envolver en su variante), el `Map<String, dynamic>`
/// que produce un `toNative()` previo, y devuelve siempre
/// `Map<String, dynamic>` con valores nativos de Dart.
@visibleForTesting
Map<String, dynamic> metadataFromNative(Object? raw) {
  if (raw is DBusVariant) raw = raw.asVariant();
  if (raw is DBusDict) {
    // Un a{sv} tal cual lo entrega el bus, sin pasar por toNative().
    final out = <String, dynamic>{};
    raw.children.forEach((key, value) {
      final name = valueAsString(nativeValueOf(key));
      if (name == null) return;
      out[name] = nativeValueOf(value);
    });
    return out;
  }
  if (raw is Map<String, DBusValue>) {
    // asStringVariantDict(): claves `s`, valores ya desenvueltos.
    final out = <String, dynamic>{};
    raw.forEach((key, value) => out[key] = nativeValueOf(value));
    return out;
  }
  if (raw is Map) {
    // Dict ya pasado por toNative(), o de otra firma (a{ss}, a{is}...).
    final out = <String, dynamic>{};
    raw.forEach((key, value) {
      final name = valueAsString(key is DBusValue ? nativeValueOf(key) : key);
      if (name == null) return;
      out[name] = value is DBusValue ? nativeValueOf(value) : value;
    });
    return out;
  }
  return <String, dynamic>{};
}

/// Saca el diccionario de propiedades cambiadas de los valores de la señal
/// `org.freedesktop.DBus.Properties.PropertiesChanged`.
///
/// La firma que manda la especificación es `sa{sv}as`, o sea que el dict de
/// cambios es el **segundo** valor (el primero es el nombre de la interfaz).
/// Por robustez también se acepta el dict envuelto en un `variant` y la forma
/// corta de una sola propiedad, que emiten algunas implementaciones.
Map<String, dynamic> propertiesChangedValues(List<Object?> values) {
  if (values.isEmpty) return <String, dynamic>{};
  var raw = values.length > 1 ? values[1] : values.first;
  if (raw is DBusVariant) raw = raw.asVariant();
  return metadataFromNative(raw);
}

/// Convierte un [DBusValue] a su equivalente nativo de Dart.
///
/// [DBusObjectPath.toNative] devuelve el propio objeto y no el `String`, así
/// que sin esto `mpris:trackid` (una object path) llegaría sin deserializar.
Object? nativeValueOf(DBusValue value) {
  try {
    if (value is DBusObjectPath) return value.value;
    if (value is DBusVariant) return nativeValueOf(value.value);
    final native = value.toNative();
    return native is DBusValue ? nativeValueOf(native) : native;
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Fuente de medios
// ---------------------------------------------------------------------------

/// Implementación de [MediaSource] sobre MPRIS/D-Bus.
///
/// Descubre todos los reproductores del bus de sesión, elige uno y publica la
/// pista y el estado de reproducción. La posición se reconstruye con un
/// polling de `Position` **solo** mientras el reproductor está en Playing,
/// porque MPRIS no emite señales de posición.
class MprisMediaSource implements MediaSource {
  /// Crea la fuente y empieza a hablar con el bus en segundo plano.
  ///
  /// [client] existe para poder inyectar un cliente ya conectado (tests de
  /// integración); si es `null` se usa `DBusClient.session()`. Los errores de
  /// arranque nunca se propagan: se loguean, se emiten como estado parado y
  /// se reintenta una vez.
  MprisMediaSource({
    DBusClient? client,
    this.pollInterval = kDefaultPositionPollInterval,
  }) : _injectedClient = client {
    _ready = _bootstrap();
  }

  /// Intervalo entre lecturas de `Position` mientras se reproduce.
  final Duration pollInterval;

  final DBusClient? _injectedClient;

  final StreamController<TrackInfo?> _trackController =
      StreamController<TrackInfo?>.broadcast();
  final StreamController<PlaybackState> _playbackController =
      StreamController<PlaybackState>.broadcast();

  /// Suscripciones de ciclo de vida (nameOwnerChanged...).
  final List<StreamSubscription<Object?>> _globalSubscriptions =
      <StreamSubscription<Object?>>[];

  /// Suscripciones del reproductor activo (PropertiesChanged, Seeked).
  final List<StreamSubscription<DBusSignal>> _playerSubscriptions =
      <StreamSubscription<DBusSignal>>[];

  /// Reproductores conocidos, indexados por nombre de bus.
  final Map<String, MprisPlayerInfo> _players = <String, MprisPlayerInfo>{};

  MprisBus? _bus;

  /// Elección forzada por el usuario (`null` = automático).
  String? _forcedPlayer;

  /// Reproductor con el que estamos hablando ahora mismo.
  String? _activePlayer;

  /// Último `Metadata` leído del reproductor activo.
  Map<String, dynamic> _metadata = <String, dynamic>{};

  PlaybackStatus _status = PlaybackStatus.stopped;
  double _rate = 1.0;

  /// Último `Volume` leído (0.0-1.0, o el máximo del reproductor si lo dice).
  double? _volume;

  /// Última posición conocida: es la base de la interpolación.
  PlaybackState _lastState = PlaybackState(
    isPlaying: false,
    position: Duration.zero,
    timestamp: DateTime.now(),
    status: PlaybackStatus.stopped,
  );

  String? _lastTrackKey;
  bool _trackEmitted = false;

  /// Última pista emitida (para repetirla a quien se suscriba tarde).
  TrackInfo? _lastTrack;

  /// Último estado de reproducción emitido (idem).
  PlaybackState? _lastPlayback;

  Timer? _positionTimer;
  Timer? _retryTimer;
  bool _readingPosition = false;
  bool _disposed = false;
  bool _retryScheduled = false;
  String? _lastError;

  /// Generaciones usadas para invalidar lecturas asíncronas obsoletas.
  int _listToken = 0;
  int _activeToken = 0;

  late final Future<void> _ready;

  /// Termina de conectar y descubrir reproductores. Seguro deawaitar varias
  /// veces: siempre devuelve la misma operación.
  Future<void> get ready => _ready;

  /// Pista actual. Al suscribirse se repite la última pista conocida (si ya
  /// se evaluó alguna): el arranque lee el reproductor ANTES de que la UI se
  /// suscriba, y sin esta repetición una canción que ya sonaba al abrir la
  /// app no se detectaría nunca (los broadcast no guardan historial).
  @override
  Stream<TrackInfo?> get trackStream async* {
    if (_trackEmitted) yield _lastTrack;
    yield* _trackController.stream;
  }

  /// Estado de reproducción, con la misma repetición inicial que
  /// [trackStream] por el mismo motivo.
  @override
  Stream<PlaybackState> get playbackStream async* {
    final last = _lastPlayback;
    if (last != null) yield last;
    yield* _playbackController.stream;
  }

  /// Último error registrado, o `null` si todo va bien.
  String? get lastError => _lastError;

  /// Reproductor con el que estamos hablando (resuelto), que puede ser
  /// distinto de [selectedPlayer] si este está en modo automático.
  String? get activePlayer => _activePlayer;

  /// Ficha del reproductor activo, si lo hay.
  MprisPlayerInfo? get activePlayerInfo =>
      _activePlayer == null ? null : _players[_activePlayer];

  /// Último `Volume` leído, o `null` si el reproductor no lo expone.
  double? get volume => _volume;

  /// Nombres de bus de los reproductores detectados, mejor primero
  /// (reproduciendo y con mayor puntuación).
  @override
  List<String> get availablePlayers {
    final sorted = _players.values.toList()..sort(compareMprisPlayers);
    return sorted.map((p) => p.busName).toList(growable: false);
  }

  /// Reproductor forzado por el usuario; `null` = automático.
  @override
  String? get selectedPlayer => _forcedPlayer;

  @override
  void selectPlayer(String? busName) {
    if (_disposed) return;
    final next = (busName == null || busName.isEmpty) ? null : busName;
    if (next == _forcedPlayer) return;
    _forcedPlayer = next;
    unawaited(_applySelection());
  }

  /// Salta a [position] con MPRIS `SetPosition` sobre el `trackid` actual.
  ///
  /// Es lo que permite que un clic (o toque) en una línea de letra mueva la
  /// canción a ese segundo. Devuelve `false` sin lanzar si no hay
  /// reproductor activo, no hay `trackid` o el reproductor rechaza el salto.
  @override
  Future<bool> seek(Duration position) async {
    final bus = _bus;
    final busName = _activePlayer;
    if (_disposed || bus == null || busName == null) return false;
    final trackId = metadataString(_metadata, kTrackIdKey);
    if (trackId == null || trackId.isEmpty) return false;
    var micros = position.inMicroseconds;
    if (micros < 0) micros = 0;
    final ok = await bus.setPosition(busName, trackId, micros);
    if (!ok) return false;
    // Recalibración optimista: no esperamos al siguiente polling para que la
    // línea resaltada salte ya.
    final now = DateTime.now();
    _lastState = _lastState.copyWith(
      isPlaying: _status == PlaybackStatus.playing,
      position: clampPosition(Duration(microseconds: micros), _currentDuration),
      timestamp: now,
      speed: _rate,
      status: _status,
    );
    _emitPlayback();
    return true;
  }

  /// Alterna pausa/reproducción con MPRIS `PlayPause`.
  ///
  /// El estado real llega solo por `PropertiesChanged`/polling, así que aquí
  /// solo se envía la orden. Devuelve `false` sin lanzar si no hay
  /// reproductor activo.
  @override
  Future<bool> togglePlayPause() async {
    final bus = _bus;
    final busName = _activePlayer;
    if (_disposed || bus == null || busName == null) return false;
    return bus.playPause(busName);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return; // idempotente
    _disposed = true;
    _listToken++;
    _activeToken++;

    _positionTimer?.cancel();
    _positionTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;

    final subscriptions = <StreamSubscription<Object?>>[
      ..._globalSubscriptions,
      ..._playerSubscriptions,
    ];
    _globalSubscriptions.clear();
    _playerSubscriptions.clear();
    for (final sub in subscriptions) {
      try {
        await sub.cancel();
      } catch (e) {
        developer.log('No se pudo cancelar una suscripción: $e',
            name: 'lylyrics.mpris');
      }
    }

    final bus = _bus;
    _bus = null;
    if (bus != null) {
      try {
        await bus.close();
      } catch (e) {
        developer.log('Error cerrando el cliente D-Bus: $e',
            name: 'lylyrics.mpris');
      }
    }

    _players.clear();
    _activePlayer = null;

    for (final controller in <StreamController<Object?>>[
      _trackController,
      _playbackController,
    ]) {
      if (!controller.isClosed) await controller.close();
    }
  }

  // -- Arranque ------------------------------------------------------------

  Future<void> _bootstrap() async {
    DBusClient? client;
    try {
      client = _injectedClient ?? DBusClient.session();
      final bus = MprisBus(client);
      _bus = bus;
      _retryScheduled = false;

      _listToken++;
      final token = _listToken;

      await _refreshPlayers(token);

      _globalSubscriptions.add(bus.nameOwnerChanged.listen(
        (event) => _onNameOwnerChanged(event, token),
        onError: (Object error) =>
            _reportError('nameOwnerChanged', error),
      ));
    } catch (error, stack) {
      // D-Bus no disponible (falta DBUS_SESSION_BUS_ADDRESS) o el bus no
      // acepta la conexión: lo reportamos sin romper la app.
      if (client != null && _injectedClient == null) {
        try {
          await client.close();
        } catch (_) {
          // nada que hacer
        }
      }
      _bus = null;
      _reportError('init', error, stack);
      _emitStopped();
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (_disposed || _retryScheduled || _injectedClient != null) return;
    if (_bus != null) return; // ya estamos conectados
    _retryScheduled = true;
    _retryTimer = Timer(const Duration(seconds: 5), () {
      _retryTimer = null;
      if (_disposed) return;
      unawaited(_bootstrap());
    });
  }

  // -- Descubrimiento ------------------------------------------------------

  Future<void> _refreshPlayers(int token) async {
    final bus = _bus;
    if (bus == null) return;

    final List<String> names;
    try {
      names = await bus.listPlayerNames();
    } catch (error) {
      _reportError('ListNames', error);
      return;
    }
    if (_disposed || token != _listToken) return;

    // Los reproductores que ya no están en el bus se descartan.
    final gone = _players.keys.where((n) => !names.contains(n)).toList();
    for (final name in gone) {
      _players.remove(name);
      if (_activePlayer == name) await _deactivate(name);
    }

    // Se sondean todos en paralelo y se espera a que terminen: cuando
    // `ready` se completa ya hay un reproductor activo elegido.
    await Future.wait(names.map((name) => _probePlayer(name, token)));
    if (_disposed || token != _listToken) return;
    await _applySelection();
  }

  /// Lee `Identity`, `DesktopEntry` y `PlaybackStatus` de un reproductor para
  /// puntuarlo y saber si está sonando.
  Future<void> _probePlayer(String busName, int token) async {
    final bus = _bus;
    if (bus == null) return;

    // Cada lectura va por separado: si el reproductor no implementa una, las
    // demás siguen siendo útiles.
    String? identity;
    String? desktopEntry;
    PlaybackStatus status = PlaybackStatus.stopped;
    try {
      identity = await bus.getString(busName, kMprisRootInterface, 'Identity');
    } catch (error) {
      _log('Identity ilegible en $busName: $error');
    }
    try {
      desktopEntry =
          await bus.getString(busName, kMprisRootInterface, 'DesktopEntry');
    } catch (error) {
      _log('DesktopEntry ilegible en $busName: $error');
    }
    try {
      status = await bus.getPlaybackStatus(busName);
    } catch (error) {
      _log('PlaybackStatus ilegible en $busName: $error');
    }
    if (_disposed || token != _listToken) return;

    _players[busName] = MprisPlayerInfo.probed(
      busName: busName,
      identity: identity,
      desktopEntry: desktopEntry,
      status: status,
    );
  }

  /// Sondea un reproductor nuevo y vuelve a elegir el activo.
  Future<void> _probeAndSelect(String busName, int token) async {
    await _probePlayer(busName, token);
    if (_disposed || token != _listToken) return;
    await _applySelection();
  }

  void _onNameOwnerChanged(DBusNameOwnerChangedEvent event, int token) {
    if (_disposed) return;
    if (event.newOwner == null) {
      if (_players.remove(event.name) != null) {
        _log('Reproductor desaparecido del bus: ${event.name}');
      }
      unawaited(_handleRemoval(event.name));
    } else {
      _log('Reproductor nuevo en el bus: ${event.name}');
      unawaited(_probeAndSelect(event.name, token));
    }
  }

  /// Un reproductor se ha cerrado: nos desasociamos y elegimos otro.
  Future<void> _handleRemoval(String busName) async {
    if (_activePlayer == busName) await _deactivate(busName);
    if (_disposed) return;
    await _applySelection();
  }

  // -- Selección -----------------------------------------------------------

  Future<void> _applySelection() async {
    if (_disposed) return;
    final best = selectBestPlayer(players: _players, forced: _forcedPlayer);
    if (best == null) {
      if (_activePlayer != null) await _deactivate(_activePlayer!);
      return;
    }
    if (best == _activePlayer) {
      // Mismo reproductor: solo hay que reflejar su nuevo estado.
      final info = _players[best];
      if (info != null && info.status != _status) {
        _status = info.status;
        _syncPolling();
        _emitTrack();
        _emitPlayback();
      }
      return;
    }
    await _activate(best);
  }

  Future<void> _activate(String busName) async {
    final bus = _bus;
    if (bus == null || _disposed) return;

    _activeToken++;
    final token = _activeToken;
    await _cancelPlayerSubscriptions();

    _activePlayer = busName;
    _metadata = <String, dynamic>{};
    _status = PlaybackStatus.stopped;
    _rate = 1.0;
    _volume = null;
    _lastState = PlaybackState(
      isPlaying: false,
      position: Duration.zero,
      timestamp: DateTime.now(),
      status: PlaybackStatus.stopped,
    );
    // Al cambiar de reproductor la pista se vuelve a emitir aunque sea la
    // misma canción: para la UI es un cambio de fuente.
    _lastTrackKey = null;
    _trackEmitted = false;
    _lastTrack = null;
    _lastPlayback = null;

    // Las cuatro propiedades se leen en paralelo: si el reproductor está
    // zombi y no contesta, tardamos un timeout en vez de cuatro.
    final metadataFuture = _safe('Metadata', () => bus.getMetadata(busName),
        <String, dynamic>{}, busName);
    final statusFuture = _safe('PlaybackStatus',
        () => bus.getPlaybackStatus(busName), PlaybackStatus.stopped, busName);
    final rateFuture = _safe('Rate',
        () => bus.getDouble(busName, kMprisPlayerInterface, 'Rate'), null,
        busName);
    final positionFuture = _safe('Position',
        () => bus.getInt(busName, kMprisPlayerInterface, 'Position'), null,
        busName);
    final volumeFuture = _safe('Volume',
        () => bus.getDouble(busName, kMprisPlayerInterface, 'Volume'), null,
        busName);

    await Future.wait<void>([
      metadataFuture,
      statusFuture,
      rateFuture,
      positionFuture,
      volumeFuture,
    ]);
    if (_disposed || token != _activeToken || _activePlayer != busName) return;

    final metadata = await metadataFuture;
    final status = await statusFuture;
    final rate = await rateFuture;
    final positionMicros = await positionFuture;
    final volume = await volumeFuture;

    _metadata = metadata;
    _status = status;
    _rate = (rate ?? 1.0).isFinite ? (rate ?? 1.0) : 1.0;
    _volume = volume;
    final known = _players[busName];
    if (known != null) {
      _players[busName] = known.copyWith(status: _status);
    }
    if (positionMicros != null) {
      _lastState = _lastState.copyWith(
        position: clampPosition(
            positionFromMicros(positionMicros), _currentDuration),
      );
    }

    _emitTrack();
    _emitPlayback();
    _syncPolling();

    // Las suscripciones se crean al final: si algo falla arriba seguimos
    // funcionando con el polling.
    try {
      _playerSubscriptions.add(
        bus.listenPropertiesChanged(busName, _onPropertiesChanged),
      );
      _playerSubscriptions.add(bus.listenSeeked(busName, _onSeeked));
    } catch (error) {
      _reportError('subscribe($busName)', error);
    }
  }

  Future<void> _deactivate(String busName) async {
    if (_activePlayer != busName) return;
    _activeToken++;
    _activePlayer = null;
    await _cancelPlayerSubscriptions();

    _metadata = <String, dynamic>{};
    _status = PlaybackStatus.stopped;
    _rate = 1.0;
    _volume = null;
    _lastTrackKey = null;
    _trackEmitted = false;
    _emitStopped();
  }

  Future<void> _cancelPlayerSubscriptions() async {
    _positionTimer?.cancel();
    _positionTimer = null;
    final subs = _playerSubscriptions.toList();
    _playerSubscriptions.clear();
    for (final sub in subs) {
      try {
        await sub.cancel();
      } catch (error) {
        _log('No se pudo cancelar la suscripción de $_activePlayer: $error');
      }
    }
  }

  // -- Reacciones a señales ------------------------------------------------

  void _onPropertiesChanged(Map<String, dynamic> changed) {
    if (_disposed) return;
    var trackDirty = false;
    var stateDirty = false;

    changed.forEach((key, value) {
      switch (key) {
        case 'Metadata':
          _metadata = metadataFromNative(value);
          trackDirty = true;
        case 'PlaybackStatus':
          _status = playbackStatusFromRaw(valueAsString(value));
          trackDirty = true; // un Stopped implica "no hay pista"
          stateDirty = true;
        case 'Rate':
          final rate = valueAsDouble(value);
          if (rate != null && rate.isFinite) {
            _rate = rate;
            stateDirty = true;
          }
        case 'Position':
          // No debería llegar por PropertiesChanged, pero algunos
          // reproductores lo hacen y así no lo perdemos.
          final micros = valueAsInt(value);
          if (micros != null) {
            _lastState = _lastState.copyWith(
              position: clampPosition(
                  positionFromMicros(micros), _currentDuration),
            );
            stateDirty = true;
          }
        case 'Volume':
          // `PlaybackState` no tiene campo de volumen, pero sí lo leemos y lo
          // exponemos por si otra capa lo necesita sin volver a D-Bus.
          _volume = valueAsDouble(value);
        default:
          break;
      }
    });

    if (stateDirty) _syncPolling();
    if (trackDirty) _emitTrack();
    if (stateDirty) _emitPlayback();
  }

  void _onSeeked(int positionMicros) {
    if (_disposed) return;
    // Seeked es autoritativo: recalibramos sin interpolar para no "corregir"
    // hacia delante un salto hacia atrás.
    _lastState = _lastState.copyWith(
      isPlaying: _status == PlaybackStatus.playing,
      position:
          clampPosition(positionFromMicros(positionMicros), _currentDuration),
      timestamp: DateTime.now(),
      speed: _rate,
      status: _status,
    );
    _emitPlayback();
  }

  // -- Posición ------------------------------------------------------------

  void _syncPolling() {
    final shouldPoll = !_disposed &&
        _activePlayer != null &&
        _status == PlaybackStatus.playing;
    if (shouldPoll && _positionTimer == null) {
      _positionTimer = Timer.periodic(
        pollInterval,
        (_) => unawaited(_readPosition()),
      );
      unawaited(_readPosition()); // no esperamos al primer tick
    } else if (!shouldPoll) {
      _positionTimer?.cancel();
      _positionTimer = null;
    }
  }

  Future<void> _readPosition() async {
    final bus = _bus;
    final busName = _activePlayer;
    if (_disposed || bus == null || busName == null) return;
    if (_readingPosition) return; // la llamada anterior sigue en el bus
    _readingPosition = true;

    try {
      final micros =
          await bus.getInt(busName, kMprisPlayerInterface, 'Position');
      if (_disposed || _activePlayer != busName) return;
      final now = DateTime.now();
      if (micros == null) {
        // Lectura fallida: al menos seguimos contando con el reloj.
        _lastState = _lastState.copyWith(timestamp: now);
      } else {
        final reported =
            clampPosition(positionFromMicros(micros), _currentDuration);
        // El reproductor puede ir por detrás de nuestra interpolación (o al
        // revés por un salto de reloj). Nos quedamos con el más avanzado para
        // que la posición no retroceda entre ticks; los saltos hacia atrás
        // legítimos llegan por `Seeked`, que sí es autoritativo.
        final predicted = clampPosition(
          interpolatePosition(
            now: now,
            position: _lastState.position,
            timestamp: _lastState.timestamp,
            rate: _lastState.speed,
            isPlaying: _lastState.isPlaying,
          ),
          _currentDuration,
        );
        _lastState = _lastState.copyWith(
          isPlaying: _status == PlaybackStatus.playing,
          position: predicted > reported ? predicted : reported,
          timestamp: now,
          speed: _rate,
          status: _status,
        );
      }
      _emitPlayback();
    } catch (error) {
      _reportError('Position($busName)', error);
    } finally {
      _readingPosition = false;
    }
  }

  // -- Emisiones -----------------------------------------------------------

  Duration? get _currentDuration {
    final micros = metadataInt(_metadata, kLengthKey);
    if (micros == null || micros <= 0) return null;
    return Duration(microseconds: micros);
  }

  void _emitTrack() {
    if (_disposed) return;
    final playing = _status != PlaybackStatus.stopped;
    final info =
        playing ? trackInfoFromMetadata(_metadata, app: _activePlayer) : null;
    final key = info == null
        ? null
        : trackKeyFromRaw(
            trackId: metadataString(_metadata, kTrackIdKey),
            title: info.title,
          );

    // La primera evaluación siempre emite (aunque sea null) para que la UI
    // tenga un valor inicial; después solo si la clave cambia de verdad.
    if (_trackEmitted && !trackKeyChanged(previous: _lastTrackKey, next: key)) {
      return;
    }
    _lastTrackKey = key;
    _trackEmitted = true;
    _lastTrack = info;
    _trackController.add(info);
  }

  void _emitPlayback() {
    if (_disposed) return;
    final now = DateTime.now();
    final state = PlaybackState(
      isPlaying: _status == PlaybackStatus.playing,
      position: clampPosition(
        interpolatePosition(
          now: now,
          position: _lastState.position,
          timestamp: _lastState.timestamp,
          rate: _lastState.speed,
          isPlaying: _lastState.isPlaying,
        ),
        _currentDuration,
      ),
      timestamp: now,
      speed: _rate,
      status: _status,
    );
    _lastState = state;
    _lastPlayback = state;
    _playbackController.add(state);
  }

  /// Estado "no hay nada": sin pista, parado en cero.
  void _emitStopped() {
    if (_disposed) return;
    final now = DateTime.now();
    _lastState = PlaybackState(
      isPlaying: false,
      position: Duration.zero,
      timestamp: now,
      speed: _rate,
      status: PlaybackStatus.stopped,
    );
    _trackController.add(null);
    _trackEmitted = true;
    _lastTrackKey = null;
    _lastTrack = null;
    _lastPlayback = _lastState;
    _playbackController.add(_lastState);
  }

  // -- Diagnóstico ---------------------------------------------------------

  /// Ejecuta una llamada D-Bus devolviendo [fallback] si falla, para que una
  /// propiedad ilegible nunca deje al reproductor sin activar.
  Future<T> _safe<T>(
    String property,
    Future<T> Function() call,
    T fallback,
    String busName,
  ) async {
    try {
      return await call();
    } catch (error) {
      _log('$property ilegible en $busName: $error');
      return fallback;
    }
  }

  void _reportError(String where, Object error, [StackTrace? stack]) {
    final message = '$where: $error';
    _lastError = message;
    developer.log(message, name: 'lylyrics.mpris', stackTrace: stack);
  }

  static void _log(String message) {
    developer.log(message, name: 'lylyrics.mpris');
  }
}