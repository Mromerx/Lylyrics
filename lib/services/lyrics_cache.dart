import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/models/lyrics.dart';

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

  /// Una entrada negativa caducada deja de ser válida.
  bool isValidAt(DateTime now) =>
      isNegative ? (expiresAt != null && expiresAt!.isAfter(now)) : true;
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

  /// Duración por defecto de la caché negativa.
  static const Duration negativeTtl = Duration(hours: 24);

  /// Abre la base y crea el esquema. Es idempotente.
  Future<void> init() async {
    if (_db != null) return;
    // sqfliteFfiInit() solo hace falta si nadie lo llamó antes; es seguro
    // llamarlo más de una vez.
    sqfliteFfiInit();
    _db = await _factory.openDatabase(
      _path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
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
        },
      ),
    );
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

  /// Cachea "sin letra" durante [ttl].
  Future<void> putNegative(String cacheKey, {Duration ttl = negativeTtl}) {
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

  /// Vacía la caché (útil para el botón "limpiar caché").
  Future<void> clear() async {
    final db = await _require;
    await db.delete(table);
  }

  /// Cierra la base. Idempotente.
  Future<void> close() async {
    final db = _db;
    _db = null;
    await db?.close();
  }

  /// `true` si la base está abierta.
  bool get isOpen => _db != null;
}