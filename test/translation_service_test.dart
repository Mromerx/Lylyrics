import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lylyrics/services/translation_service.dart';

/// Arma un cuerpo JSON gtx-like: `decoded[0]` con pares
/// `[traducción, texto_original]` de `dt=t`, `decoded[1]` con las entradas
/// crudas de `dt=bd` y `decoded[2]` con el idioma detectado.
String cuerpoGtx({
  required List<List<String>> pares,
  List<Object> bd = const <Object>[],
  String idioma = 'en',
}) {
  return jsonEncode([
    [for (final par in pares) [par[0], par[1]]],
    bd,
    idioma,
  ]);
}

/// El `q` de una petición gtx, sacado de la URL (GET).
String? qDe(http.Request req) => req.url.queryParameters['q'];

/// ¿La petición pidió `dt=bd` (parado a `dt=t`) en la misma URL?
bool pideBd(http.Request req) =>
    req.url.queryParametersAll['dt']?.contains('bd') ?? false;

/// `TextSegment` no trae `==` contractual: hay que comparar por campos.
List<List<String>> crudos(List<TextSegment> segs) =>
    [for (final s in segs) [s.source, s.target]];

void main() {
  group('splitWords / wordTokens', () {
    test('separa palabras y conserva espacios', () {
      expect(splitWords('Hello world'), ['Hello', ' ', 'world']);
      expect(wordTokens('Hello world'), ['Hello', 'world']);
    });

    test('línea vacía no da tokens', () {
      expect(wordTokens('   '), isEmpty);
    });
  });

  group('originalIndexForTranslated', () {
    test('mismo número de palabras: 1 a 1', () {
      expect(originalIndexForTranslated(
          translatedTokenIndex: 0, originalCount: 3, translatedCount: 3), 0);
      expect(originalIndexForTranslated(
          translatedTokenIndex: 1, originalCount: 3, translatedCount: 3), 1);
      expect(originalIndexForTranslated(
          translatedTokenIndex: 2, originalCount: 3, translatedCount: 3), 2);
    });

    test('traducción más larga reparte por posición', () {
      // 2 originales, 4 traducidas: 0,1 -> 0 y 2,3 -> 1.
      expect(originalIndexForTranslated(
          translatedTokenIndex: 0, originalCount: 2, translatedCount: 4), 0);
      expect(originalIndexForTranslated(
          translatedTokenIndex: 1, originalCount: 2, translatedCount: 4), 0);
      expect(originalIndexForTranslated(
          translatedTokenIndex: 2, originalCount: 2, translatedCount: 4), 1);
      expect(originalIndexForTranslated(
          translatedTokenIndex: 3, originalCount: 2, translatedCount: 4), 1);
    });

    test('traducción más corta no se sale de rango', () {
      expect(originalIndexForTranslated(
          translatedTokenIndex: 1, originalCount: 4, translatedCount: 2), 2);
    });

    test('conteos en cero no revientan', () {
      expect(originalIndexForTranslated(
          translatedTokenIndex: 0, originalCount: 0, translatedCount: 3), 0);
      expect(originalIndexForTranslated(
          translatedTokenIndex: 5, originalCount: 4, translatedCount: 2),
          inInclusiveRange(0, 3));
    });
  });

  group('paletteIndexForOriginal', () {
    test('cicla la paleta', () {
      expect(paletteIndexForOriginal(0, 4), 0);
      expect(paletteIndexForOriginal(3, 4), 3);
      expect(paletteIndexForOriginal(4, 4), 0);
      expect(paletteIndexForOriginal(7, 4), 3);
    });
  });

  group('sharesRoot', () {
    test('caza flexiones y género', () {
      expect(sharesRoot('cantan', 'cantar'), isTrue);
      expect(sharesRoot('corriendo', 'correr'), isTrue);
      expect(sharesRoot('hermoso', 'hermosa'), isTrue);
      expect(sharesRoot('sings', 'sing'), isTrue);
    });

    test('no junta palabras distintas ni cortas', () {
      expect(sharesRoot('la', 'las'), isFalse);
      expect(sharesRoot('he', 'él'), isFalse);
      expect(sharesRoot('estar', 'estos'), isFalse);
      expect(sharesRoot('casa', 'cosa'), isFalse);
      expect(sharesRoot('', 'hola'), isFalse);
    });
  });

  group('translateSong', () {
    test('reparte por línea como el viejo y arma segmentPairs', () async {
      // Líneas: vacía (omitida), normal, traducción idéntica ("Hola" ->
      // "Hola", omitida del mapa de líneas).
      final lines = ['Hello world', '', 'Good night', 'Hola'];
      final client = MockClient((req) async {
        return http.Response(
          cuerpoGtx(pares: const [
            ['Hola mundo', 'Hello world'],
            ['\n', '\n'],
            ['Buenas noches', 'Good night'],
            ['\n', '\n'],
            ['Hola', 'Hola'],
          ]),
          200,
        );
      });
      final service = GoogleTranslationService(client: client);

      final song = await service.translateSong(lines);

      // Reglas del viejo translateLines: omitir vacías e idénticas.
      expect(song.translations, {0: 'Hola mundo', 2: 'Buenas noches'});
      // Cada segmento cabe en UNA línea: par completo a esa línea, y las
      // líneas sin traducción no aparecen en segmentPairs.
      expect(song.segmentPairs.keys.toSet(), {0, 2});
      expect(crudos(song.segmentPairs[0]!),
          [
            ['Hello world', 'Hola mundo'],
          ]);
      expect(crudos(song.segmentPairs[2]!),
          [
            ['Good night', 'Buenas noches'],
          ]);
    });

    test('petición única con el texto unido por \\n', () async {
      late String pedido;
      late http.Request capturada;
      final client = MockClient((req) async {
        capturada = req;
        pedido = qDe(req) ?? '';
        expect(pideBd(req), isFalse);
        return http.Response(
          cuerpoGtx(pares: const [
            ['Hola mundo', 'Hello world'],
          ]),
          200,
        );
      });
      final service = GoogleTranslationService(client: client);

      await service.translateSong(['Hello world']);
      expect(pedido, 'Hello world');
      // Una canción corta cabe en UNA petición GET con el texto en la URL.
      expect(capturada.method, 'GET');
      expect(capturada.url.queryParameters['q'], 'Hello world');
    });

    test('canción larga se parte en lotes GET con URLs cortas', () async {
      // 400 líneas de ~120 chars: muy por encima del presupuesto por lote.
      final lines = [
        for (var i = 0; i < 400; i++)
          'linea numero $i ${'palabra ' * 12}fin',
      ];

      final pedidos = <String>[];
      final client = MockClient((req) async {
        final q = qDe(req) ?? '';
        pedidos.add(q);
        // Cada lote: la traducción de cada línea es 'ES:<original>'. Los
        // saltos van como segmentos propios (como en la respuesta real).
        final pares = <List<String>>[];
        final srcs = q.split('\n');
        for (var k = 0; k < srcs.length; k++) {
          if (k > 0) pares.add(const ['\n', '\n']);
          pares.add(['ES:${srcs[k]}', srcs[k]]);
        }
        return http.Response(cuerpoGtx(pares: pares), 200);
      });
      final service = GoogleTranslationService(client: client);

      final song = await service.translateSong(lines);

      // Más de una petición: la canción no viajó entera en una sola URL.
      expect(pedidos.length, greaterThan(1));
      // Ninguna URL rebasa un límite seguro (q codificado <= 1500 + margen
      // para los parámetros fijos).
      for (final req in pedidos) {
        expect(
          Uri.encodeComponent(req).length,
          lessThanOrEqualTo(1500),
        );
      }
      // Ninguna línea se perdió ni se duplicó entre lotes.
      final reconstruido = pedidos.expand((q) => q.split('\n')).toList();
      expect(reconstruido, lines);
      // Todas las líneas quedaron traducidas y repartidas por su índice real.
      expect(song.translations.length, lines.length);
      expect(song.translations[0], 'ES:${lines[0]}');
      expect(song.translations[lines.length - 1], 'ES:${lines.last}');
    });

    test('una línea que por sí sola supera el presupuesto viaja sola',
        () async {
      final larga = 'a' * 20000;
      final pedidos = <String>[];
      final client = MockClient((req) async {
        final q = qDe(req) ?? '';
        pedidos.add(q);
        return http.Response(
          cuerpoGtx(pares: [
            ['ES:$q', q],
          ]),
          200,
        );
      });
      final service = GoogleTranslationService(client: client);

      final song = await service.translateSong([larga]);

      expect(pedidos, [larga]);
      expect(song.translations, {0: 'ES:$larga'});
    });

    test('segmento que cruza líneas con partes iguales se reparte',
        () async {
      final lines = ['red roses', 'tonight'];
      final client = MockClient((req) async {
        return http.Response(
          cuerpoGtx(pares: const [
            ['Rojas\nesta noche', 'red roses\ntonight'],
          ]),
          200,
        );
      });
      final service = GoogleTranslationService(client: client);

      final song = await service.translateSong(lines);

      expect(song.translations, {0: 'Rojas', 1: 'esta noche'});
      // Dos partes -> una por línea, en orden.
      expect(crudos(song.segmentPairs[0]!),
          [
            ['red roses', 'Rojas'],
          ]);
      expect(crudos(song.segmentPairs[1]!),
          [
            ['tonight', 'esta noche'],
          ]);
    });

    test('segmento que cruza con partes desiguales se descarta sin romper',
        () async {
      final lines = ['red roses', 'tonight'];
      final client = MockClient((req) async {
        return http.Response(
          cuerpoGtx(pares: const [
            ['Rojas\nrosas\nrojas\nsí', 'red roses\ntonight'],
          ]),
          200,
        );
      });
      final service = GoogleTranslationService(client: client);

      final song = await service.translateSong(lines);

      // 4 partes de target vs 2 de source: el segmento se descarta, PERO
      // las traducciones (split por \\n del target) siguen sanas.
      expect(song.segmentPairs, isEmpty);
      expect(song.translations[0], isNotEmpty);
      expect(song.translations[1], isNotEmpty);
    });

    test('decoded[0] incoherente: segmentPairs vacío, translations sanas',
        () async {
      final lines = ['Hello world', 'Good night'];
      final client = MockClient((req) async {
        return http.Response(
          cuerpoGtx(pares: const [
            ['Hola mundo', 'Hello world'],
            ['\n', '\n'],
            ['qué más', 'nada-que-reconstruya'],
          ]),
          200,
        );
      });
      final service = GoogleTranslationService(client: client);

      final song = await service.translateSong(lines);

      // La concatenación de sources no reconstruye el texto unido.
      expect(song.segmentPairs, isEmpty);
      expect(song.translations, {0: 'Hola mundo', 1: 'qué más'});
    });

    test('idioma ya español devuelve resultado vacío', () async {
      final client = MockClient((req) async {
        return http.Response(
          cuerpoGtx(
            pares: const [
              ['Hola pareja', 'Hola pareja'],
            ],
            idioma: 'es',
          ),
          200,
        );
      });
      final service = GoogleTranslationService(client: client);

      final song = await service.translateSong(['Hola pareja']);
      expect(song.translations, isEmpty);
      expect(song.segmentPairs, isEmpty);
    });

    test('fallo http devuelve vacío sin romper', () async {
      final client = MockClient((req) async {
        throw http.ClientException('sin red');
      });
      final service = GoogleTranslationService(client: client);

      final song = await service.translateSong(['Hello']);
      expect(song.translations, isEmpty);
      expect(song.segmentPairs, isEmpty);
    });
  });

  group('translateWordList', () {
    test('primary dedup como antes y senses pobladas con bd', () async {
      late List<String> pedidas;
      late bool conBd;
      final client = MockClient((req) async {
        pedidas = (qDe(req) ?? '').split('\n');
        conBd = pideBd(req);
        return http.Response(
          cuerpoGtx(
            pares: const [
              ['Hola', 'Hello'],
              ['\n', '\n'],
              ['mundo', 'WORLD'],
              ['\n', '\n'],
              ['oye', 'hey'],
              ['\n', '\n'],
              ['ama', 'loves'],
            ],
            bd: const [
              [
                'Hello',
                ['¡hola!', 'qué tal'],
              ],
              [
                'loves',
                ['ama a alguien'],
              ],
              // 'hey' es corta (norm 3): se pide pero NO guarda sentidos.
              [
                'hey',
                ['¡eh!'],
              ],
            ],
          ),
          200,
        );
      });
      final service = GoogleTranslationService(client: client);

      final lexicon = await service
          .translateWordList(['Hello', 'hello', 'WORLD', 'hey', 'loves']);

      // La petición fue UNA sola, con dt=t y dt=bd, palabras deduplicadas
      // (sin distinción de mayúsculas) conservando la forma primera.
      expect(conBd, isTrue);
      expect(pedidas, ['Hello', 'WORLD', 'hey', 'loves']);

      expect(lexicon.primary, {
        'hello': 'Hola',
        'world': 'mundo',
        'hey': 'oye',
        'loves': 'ama',
      });
      // Solo palabras con norm >= 4 letras; sentidos CRUDOS en orden.
      expect(lexicon.senses['hello'], unorderedEquals(['¡hola!', 'qué tal']));
      expect(lexicon.senses['loves'], {'ama a alguien'});
      expect(lexicon.senses.containsKey('hey'), isFalse);
    });

    test('shapes rotos -> senses vacío sin romper', () async {
      final client = MockClient((req) async {
        return http.Response(
          // decoded[1] (dt=bd) con basura: no todo es lista de listas
          // razonables; decoded[0] sigue trayendo el primary de siempre.
          jsonEncode([
            [
              ['Hola', 'Hello'],
              ['\n', '\n'],
              ['mundo', 'WORLD'],
            ],
            [
              42,
              ['只会上市', null],
              ['okay', 'no-lista'],
              ['fin'],
            ],
            'en',
          ]),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final service = GoogleTranslationService(client: client);

      final lexicon =
          await service.translateWordList(['Hello', 'WORLD', 'okay']);
      expect(lexicon.primary, {'hello': 'Hola', 'world': 'mundo'});
      expect(lexicon.senses, isEmpty);
    });

    test('respuesta en español / fallo http -> primary vacío', () async {
      final caido =
          GoogleTranslationService(client: MockClient((req) async {
        throw http.ClientException('sin red');
      }));
      final sinNada = await caido.translateWordList(['Hello']);
      expect(sinNada.primary, isEmpty);
      expect(sinNada.senses, isEmpty);

      final enEspanol =
          GoogleTranslationService(client: MockClient((req) async {
        return http.Response(
          cuerpoGtx(
            pares: const [
              ['hola', 'hola'],
            ],
            idioma: 'es',
          ),
          200,
        );
      }));
      final lexicon = await enEspanol.translateWordList(['hola']);
      expect(lexicon.primary, isEmpty);
      expect(lexicon.senses, isEmpty);
    });

    test('lista vacía de entrada devuelve léxico vacío sin pedir nada',
        () async {
      final service =
          GoogleTranslationService(client: MockClient((req) async {
        throw StateError('no se debería pedir nada');
      }));
      final lexicon = await service.translateWordList([]);
      expect(lexicon.primary, isEmpty);
      expect(lexicon.senses, isEmpty);
    });

    test('vocabulario largo se parte en lotes y acumula primary + bd',
        () async {
      String word(int i) => 'palabra${i}_${'x' * 20}';
      final words = [for (var i = 0; i < 200; i++) word(i)];
      final pedidos = <String>[];
      final client = MockClient((req) async {
        final q = qDe(req) ?? '';
        pedidos.add(q);
        final srcs = q.split('\n');
        final pares = <List<String>>[];
        for (var k = 0; k < srcs.length; k++) {
          if (k > 0) pares.add(const ['\n', '\n']);
          pares.add(['tr:${srcs[k]}', srcs[k]]);
        }
        return http.Response(
          cuerpoGtx(
            pares: pares,
            bd: [
              for (final w in srcs)
                [w, ['sentido de $w']],
            ],
          ),
          200,
        );
      });
      final service = GoogleTranslationService(client: client);

      final lexicon = await service.translateWordList(words);

      // Más de una petición y ninguna URL por encima del presupuesto.
      expect(pedidos.length, greaterThan(1));
      for (final q in pedidos) {
        expect(Uri.encodeComponent(q).length, lessThanOrEqualTo(1500));
      }
      // Todas las traducciones de todos los lotes se acumularon.
      expect(lexicon.primary.length, words.length);
      expect(lexicon.primary[word(0)], 'tr:${word(0)}');
      expect(lexicon.senses[word(0)], {'sentido de ${word(0)}'});
    });
  });

  group('translateContextualLines', () {
    test('parseo correcto de la numeración directa', () async {
      late String pedido;
      late bool conBd;
      late http.Request capturada;
      final client = MockClient((req) async {
        capturada = req;
        pedido = qDe(req) ?? '';
        conBd = pideBd(req);
        return http.Response(
          cuerpoGtx(pares: const [
            ['1. Ellos 2. cantan 3. fuerte', 'todo junto'],
          ]),
          200,
        );
      });
      final service = GoogleTranslationService(client: client);

      final out =
          await service.translateContextualLines(['they sing loud']);

      // El q llega numerado con los tokens en orden (y sin dt=bd), GET.
      expect(conBd, isFalse);
      expect(capturada.method, 'GET');
      expect(capturada.url.queryParameters['q'], '1. they 2. sing 3. loud');
      expect(pedido, '1. they 2. sing 3. loud');
      expect(out[0], ['Ellos', 'cantan', 'fuerte']);
    });

    test('números ausentes dejan hueco (mapeo directo por número)',
        () async {
      final client = MockClient((req) async {
        return http.Response(
          cuerpoGtx(pares: const [
            ['1. Ellos 3. fuerte', 'falta el dos'],
          ]),
          200,
        );
      });
      final service = GoogleTranslationService(client: client);

      final out =
          await service.translateContextualLines(['they sing loud']);
      // El "2." no llegó: su casillero queda vacío y los demás en su sitio.
      expect(out[0], ['Ellos', '', 'fuerte']);
    });

    test('numeración desalineada -> mapeo proporcional best-effort',
        () async {
      final client = MockClient((req) async {
        return http.Response(
          cuerpoGtx(pares: const [
            ['2. mundo', 'empieza mal'],
          ]),
          200,
        );
      });
      final service = GoogleTranslationService(client: client);

      final out =
          await service.translateContextualLines(['hello world']);
      // 1 grupo para 2 tokens: cae en el casillero proporcional (0).
      expect(out[0], ['mundo', '']);
    });

    test('numeración perdida -> lista vacía', () async {
      final client = MockClient((req) async {
        return http.Response(
          cuerpoGtx(pares: const [
            ['Ellos cantan fuerte', 'todo junto'],
          ]),
          200,
        );
      });
      final service = GoogleTranslationService(client: client);

      final out =
          await service.translateContextualLines(['they sing loud']);
      expect(out[0], isEmpty);
    });

    test('palabras antes del primer marcador se descartan', () async {
      final client = MockClient((req) async {
        return http.Response(
          cuerpoGtx(pares: const [
            ['Bueno: 1. Ellos 2. cantan', 'con ruido al frente'],
          ]),
          200,
        );
      });
      final service = GoogleTranslationService(client: client);

      final out =
          await service.translateContextualLines(['they sing']);
      expect(out[0], ['Ellos', 'cantan']);
    });

    test('una palabra: q de un marcador y una traducción', () async {
      final client = MockClient((req) async {
        expect(qDe(req), '1. Hello');
        return http.Response(
          cuerpoGtx(pares: const [
            ['1. Hola', 'frase'],
          ]),
          200,
        );
      });
      final service = GoogleTranslationService(client: client);

      final out = await service.translateContextualLines(['Hello']);
      expect(out[0], ['Hola']);
    });

    test('línea sin tokens entra con lista vacía', () async {
      final client = MockClient((req) async {
        throw StateError('línea sin tokens no debería pedir nada');
      });
      final service = GoogleTranslationService(client: client);

      final out = await service.translateContextualLines(['   ']);
      expect(out, {0: <String>[]});
    });

    test('fallo http -> {} sin romper', () async {
      final client = MockClient((req) async {
        throw http.ClientException('sin red');
      });
      final service = GoogleTranslationService(client: client);

      final out =
          await service.translateContextualLines(['they sing loud']);
      expect(out, isEmpty);
    });

    test('lista de entrada vacía -> {}', () async {
      final service =
          GoogleTranslationService(client: MockClient((req) async {
        throw StateError('no se debería pedir nada');
      }));
      expect(await service.translateContextualLines([]), isEmpty);
    });
  });

  group('idioma destino', () {
    test('translateSong usa el tl elegido y traduce a ese idioma', () async {
      late String tl;
      final client = MockClient((req) async {
        tl = req.url.queryParameters['tl'] ?? '';
        return http.Response(
          cuerpoGtx(pares: const [
            ['Bonjour', 'Hello'],
          ]),
          200,
        );
      });
      final service = GoogleTranslationService(client: client);

      final song = await service.translateSong(['Hello'], target: 'fr');

      expect(tl, 'fr');
      expect(song.translations, {0: 'Bonjour'});
    });

    test('si lo detectado ya es el idioma destino, no traduce', () async {
      final client = MockClient((req) async {
        return http.Response(
          cuerpoGtx(
            pares: const [
              ['Hello', 'Hello'],
            ],
            idioma: 'en',
          ),
          200,
        );
      });
      final service = GoogleTranslationService(client: client);

      final song = await service.translateSong(['Hello'], target: 'en');

      expect(song.translations, isEmpty);
      expect(song.segmentPairs, isEmpty);
    });

    test('translateWord respeta el idioma destino', () async {
      late String tl;
      final client = MockClient((req) async {
        tl = req.url.queryParameters['tl'] ?? '';
        return http.Response(
          cuerpoGtx(
            pares: const [
              ['Bonjour', 'Hello'],
            ],
            idioma: 'en',
          ),
          200,
        );
      });
      final service = GoogleTranslationService(client: client);

      final out = await service.translateWord('Hello', target: 'fr');

      expect(tl, 'fr');
      expect(out, 'Bonjour');
    });
  });
}
