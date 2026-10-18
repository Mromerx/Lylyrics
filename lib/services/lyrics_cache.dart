import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/models/lyrics.dart';
import 'translation_service.dart';

/// Resultado de una consulta a la caché.
class CachedLyrics {
  const CachedLyrics({
    this.lyrics,
    this.isNegative = false,
    this.expiresAt,
  });

  /// Letra almacenada. `null` cuando la entrada es negativa.
  final Lyrics? lyrics;

  /// `true` si se cacheó un "esta canción no tiene letra".
  final bool isNegative;

  /// Vencimiento de la entrada negativa. `null` en entradas positivas.
  final DateTime? expiresAt;
}

/// Serializa una [Lyrics] al formato guardado en la columna `payload`.
///
/// Vive aquí y no en `Lyrics` para no depender de cambios en el modelo.
Map<String, dynamic> lyricsToJson(Lyrics lyrics) => {
      'isSynced': lyrics.isSynced,
      'instrumental': lyrics.instrumental,
      'plainText': lyrics.plainText,
      'lines': [
        for (final l in lyrics.lines)
          {'t': l.time.inMilliseconds, 'x': l.text},
      ],
    };

/// Inversa de [lyricsToJson].
///
/// Lanza [FormatException] si el JSON no tiene la forma esperada, que
/// [LyricsCache.get] traduce a "entrada corrupta descartada".
Lyrics lyricsFromJson(Map<String, dynamic> json) {
  final rawLines = json['lines'];
  if (rawLines is! List) {
    throw FormatException('payload sin lista de líneas');
  }
  final lines = <LyricLine>[];
  for (final item in rawLines) {
    if (item is! Map) {
      throw const FormatException('línea con formato inválido');
    }
    final t = item['t'];
    final x = item['x'];
    if (t is! num || x is! String) {
      throw const FormatException('línea sin tiempo o texto');
    }
    lines.add(LyricLine(
      time: Duration(milliseconds: t.toInt()),
      text: x,
    ));
  }
  final plain = json['plainText'];
  return Lyrics(
    lines: lines,
    isSynced: json['isSynced'] == true,
    instrumental: json['instrumental'] == true,
    plainText: plain is String ? plain : null,
  );
}

/// Serializa una [SongTranslation] al formato guardado en la columna
/// `payload` de la tabla `translations`.
///
/// Las claves de los mapas son enteros (índice de línea) pero JSON exige
/// claves de texto, así que se convierten con `.toString()`.
Map<String, dynamic> songTranslationToJson(SongTranslation song) => {
      'translations': {
        for (final entry in song.translations.entries)
          entry.key.toString(): entry.value,
      },
      'segments': {
        for (final entry in song.segmentPairs.entries)
          entry.key.toString(): [
            for (final seg in entry.value)
              {'s': seg.source, 't': seg.target},
          ],
      },
    };

/// Inversa de [songTranslationToJson].
///
/// Lanza [FormatException] si el JSON no tiene la forma esperada, que
/// [LyricsCache.getTranslation] traduce a "entrada corrupta descartada".
SongTranslation songTranslationFromJson(Map<String, dynamic> json) {
  final rawTranslations = json['translations'];
  if (rawTranslations is! Map) {
    throw const FormatException('payload sin traducciones');
  }
  final translations = <int, String>{};
  for (final entry in rawTranslations.entries) {
    final key = entry.key;
    final value = entry.value;
    if (key is! String || value is! String) {
      throw const FormatException('traducción con formato inválido');
    }
    final index = int.tryParse(key);
    if (index == null) {
      throw const FormatException('clave de traducción no numérica');
    }
    translations[index] = value;
  }

  final rawSegments = json['segments'];
  if (rawSegments is! Map) {
    throw const FormatException('payload sin segmentos');
  }
  final segmentPairs = <int, List<TextSegment>>{};
  for (final entry in rawSegments.entries) {
    final key = entry.key;
    final value = entry.value;
    if (key is! String || value is! List) {
      throw const FormatException('segmentos con formato inválido');
    }
    final index = int.tryParse(key);
    if (index == null) {
      throw const FormatException('clave de segmentos no numérica');
    }
    final segments = <TextSegment>[];
    for (final item in value) {
      if (item is! Map) {
        throw const FormatException('segmento con formato inválido');
      }
      final source = item['s'];
      final target = item['t'];
      if (source is! String || target is! String) {
        throw const FormatException('segmento sin source o target');
      }
      segments.add(TextSegment(source: source, target: target));
    }
    segmentPairs[index] = segments;
  }

  return SongTranslation(
    translations: translations,
    segmentPairs: segmentPairs,
  );
}

/// Caché local de letras sobre SQLite (sqflite_common_ffi, sin dependencias
/// nativas extra aparte de libsqlite3 del sistema).
///
/// Guarda dos cosas:
///   * letras reales (positivo), que nunca caducan;
///   * "esta canción no tiene letra" (negativo), con TTL de 24 h para no
///     machacar LRCLIB con consultas inútiles.
class LyricsCache {
  LyricsCache({
    DatabaseFactory? factory,
    String? path,
    DateTime Function()? clock,
  })  : _factory = factory ?? databaseFactoryFfi,
        _path = path ?? inMemoryDatabasePath,
        _clock = clock ?? DateTime.now;

  final DatabaseFactory _factory;

  /// Ruta del fichero SQLite. `inMemoryDatabasePath` en tests.
  final String _path;

  final DateTime Function() _clock;

  Database? _db;

  static const String table = 'lyrics';

  /// Tabla de traducciones persistentes (`cacheKey -> SongTranslation`).
  static const String translationsTable = 'translations';

  /// Tiempo de vida de CUALQUIER entrada de la caché, positiva o negativa.
  ///
  /// Se comprueba al arrancar la app con [purgeExpired] y en cada lectura con
  /// [get]. No hay ningún temporizador en segundo plano: la app solo mira la
  /// edad de lo guardado cuando se abre o cuando consulta una clave.
  static const Duration ttl = Duration(hours: 24);

  /// Abre la base y crea el esquema. Es idempotente.
  ///
  /// [path] permite resolver la ruta tarde (en Android el directorio de la
  /// app solo se conoce de forma asíncrona).
  Future<void> init({String? path}) async {
    if (_db != null) return;
    // sqfliteFfiInit() solo hace falta si nadie lo llamó antes; es seguro
    // llamarlo más de una vez.
    sqfliteFfiInit();
    _db = await _factory.openDatabase(
      path ?? _path,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, _) async {
          await _createLyricsTable(db);
          await _createTranslationsTable(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await _createTranslationsTable(db);
          }
        },
      ),
    );
  }

  static Future<void> _createLyricsTable(Database db) async {
    await db.execute('''
      CREATE TABLE $table (
        cache_key   TEXT PRIMARY KEY,
        payload     TEXT,
        lrclib_id   INTEGER,
        track_name  TEXT,
        artist_name TEXT,
        duration    INTEGER,
        is_negative INTEGER NOT NULL DEFAULT 0,
        expires_at  INTEGER,
        created_at  INTEGER NOT NULL
      )
    ''');
  }

  static Future<void> _createTranslationsTable(Database db) async {
    await db.execute('''
      CREATE TABLE $translationsTable (
        cache_key  TEXT PRIMARY KEY,
        payload    TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  Future<Database> get _require async {
    if (_db == null) await init();
    return _db!;
  }

  /// Devuelve la entrada cacheada, o `null` si no hay o si la negativa caducó.
  Future<CachedLyrics?> get(String cacheKey) async {
    final db = await _require;
    final rows = await db.query(
      table,
      where: 'cache_key = ?',
      whereArgs: [cacheKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;

    final isNegative = (row['is_negative'] as int? ?? 0) == 1;
    if (isNegative) {
      final expiresMs = row['expires_at'] as int?;
      final expires =
          expiresMs == null ? null : DateTime.fromMillisecondsSinceEpoch(expiresMs);
      final now = _clock();
      if (expires == null || !expires.isAfter(now)) {
        // La negativa caducó: la borramos para permitir una consulta nueva.
        await db.delete(table, where: 'cache_key = ?', whereArgs: [cacheKey]);
        return null;
      }
      return CachedLyrics(isNegative: true, expiresAt: expires);
    }

    // Las entradas positivas también caducan: si superan el TTL se descartan
    // y se trata como si no estuvieran, para volver a preguntar a LRCLIB.
    final createdAt = row['created_at'] as int?;
    if (createdAt == null || _isExpired(createdAt)) {
      await db.delete(table, where: 'cache_key = ?', whereArgs: [cacheKey]);
      return null;
    }

    final payload = row['payload'];
    if (payload is! String) return null;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) {
        await db.delete(table, where: 'cache_key = ?', whereArgs: [cacheKey]);
        return null;
      }
      return CachedLyrics(
        lyrics: lyricsFromJson(Map<String, dynamic>.from(decoded)),
      );
    } on FormatException {
      // Payload corrupto: lo descartamos en lugar de fallar la app.
      await db.delete(table, where: 'cache_key = ?', whereArgs: [cacheKey]);
      return null;
    }
  }

  /// Guarda una letra real. Sobrescribe cualquier entrada previa de la clave.
  Future<void> put(
    String cacheKey,
    Lyrics lyrics, {
    required int id,
    String? trackName,
    String? artistName,
    int? lrclibDuration,
  }) async {
    final db = await _require;
    await db.insert(table, {
      'cache_key': cacheKey,
      'payload': jsonEncode(lyricsToJson(lyrics)),
      'lrclib_id': id,
      'track_name': trackName,
      'artist_name': artistName,
      'duration': lrclibDuration,
      'is_negative': 0,
      'expires_at': null,
      'created_at': _clock().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Devuelve la traducción cacheada, o `null` si no hay o caducó.
  ///
  /// Mismo TTL que las letras ([ttl]): si la entrada supera las 24 h se borra
  /// y se devuelve `null` para volver a traducir. Un payload corrupto también
  /// se descarta sin romper la app.
  Future<SongTranslation?> getTranslation(String key) async {
    final db = await _require;
    final rows = await db.query(
      translationsTable,
      where: 'cache_key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;

    final createdAt = row['created_at'] as int?;
    if (createdAt == null || _isExpired(createdAt)) {
      await db.delete(
        translationsTable,
        where: 'cache_key = ?',
        whereArgs: [key],
      );
      return null;
    }

    final payload = row['payload'];
    if (payload is! String) {
      await db.delete(
        translationsTable,
        where: 'cache_key = ?',
        whereArgs: [key],
      );
      return null;
    }
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) {
        await db.delete(
          translationsTable,
          where: 'cache_key = ?',
          whereArgs: [key],
        );
        return null;
      }
      return songTranslationFromJson(Map<String, dynamic>.from(decoded));
    } on FormatException {
      // Payload corrupto: lo descartamos en lugar de fallar la app.
      await db.delete(
        translationsTable,
        where: 'cache_key = ?',
        whereArgs: [key],
      );
      return null;
    }
  }

  /// Guarda una [SongTranslation]. Sobrescribe cualquier entrada previa.
  Future<void> putTranslation(String key, SongTranslation song) async {
    final db = await _require;
    await db.insert(translationsTable, {
      'cache_key': key,
      'payload': jsonEncode(songTranslationToJson(song)),
      'created_at': _clock().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Cachea "sin letra" durante [ttl].
  Future<void> putNegative(String cacheKey, {Duration ttl = LyricsCache.ttl}) {
    final now = _clock();
    return _writeNegative(cacheKey, now.add(ttl));
  }

  Future<void> _writeNegative(String cacheKey, DateTime expires) async {
    final db = await _require;
    await db.insert(table, {
      'cache_key': cacheKey,
      'payload': null,
      'lrclib_id': null,
      'track_name': null,
      'artist_name': null,
      'duration': null,
      'is_negative': 1,
      'expires_at': expires.millisecondsSinceEpoch,
      'created_at': _clock().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// `true` si la entrada creada en [createdAtMs] ya superó el [ttl].
  bool _isExpired(int createdAtMs) {
    final created = DateTime.fromMillisecondsSinceEpoch(createdAtMs);
    return _clock().difference(created) >= ttl;
  }

  /// Borra todas las entradas con más de [ttl] de antigüedad.
  ///
  /// Se llama UNA vez al abrir la app, no con un temporizador: así la caché no
  /// crece sin límite y no hay nada "escuchando" en segundo plano. Devuelve
  /// cuántas filas se eliminaron.
  Future<int> purgeExpired() async {
    final db = await _require;
    final cutoff = _clock().subtract(ttl).millisecondsSinceEpoch;
    final removedLyrics =
        await db.delete(table, where: 'created_at <= ?', whereArgs: [cutoff]);
    final removedTranslations = await db.delete(
      translationsTable,
      where: 'created_at <= ?',
      whereArgs: [cutoff],
    );
    return removedLyrics + removedTranslations;
  }

  /// Vacía la caché (útil para el botón "limpiar caché").
  Future<void> clear() async {
    final db = await _require;
    await db.delete(table);
    await db.delete(translationsTable);
  }

  /// Cierra la base. Idempotente.
  Future<void> close() async {
    final db = _db;
    _db = null;
    await db?.close();
  }
}