import 'package:flutter_test/flutter_test.dart';
import 'package:lylyrics/services/token_alignment.dart';
import 'package:lylyrics/services/translation_service.dart' show TextSegment;

void main() {
  // Helper: alinea y devuelve el mapa plano traducida -> índice original.
  Map<int, int> indices(Map<int, TokenLink> enlaces) =>
      {for (final e in enlaces.entries) e.key: e.value.originalIndex};

  group('alignLineTokens', () {
    test('empareja por traducción exacta aunque el orden cambie', () {
      final enlaces = alignLineTokens(
        originalTokens: const ['Hello', 'beautiful', 'world'],
        translatedTokens: const ['Hola', 'mundo', 'hermoso'],
        wordMap: const {
          'hello': 'hola',
          'beautiful': 'hermoso',
          'world': 'mundo',
        },
        senseMap: const {},
      );
      expect(indices(enlaces), {0: 0, 1: 2, 2: 1});
      expect(enlaces[0]!.tier, 2);
      expect(enlaces[1]!.tier, 2);
      expect(enlaces[2]!.tier, 2);
    });

    test('lo no emparejable se omite (la UI usa la reserva)', () {
      final enlaces = alignLineTokens(
        originalTokens: const ['xyz'],
        translatedTokens: const ['cualquiera'],
        wordMap: const {},
        senseMap: const {},
      );
      expect(enlaces, isEmpty);
    });

    test('nombres propios iguales empareja sin mapa', () {
      final enlaces = alignLineTokens(
        originalTokens: const ['Maria', 'dijo', 'hola'],
        translatedTokens: const ['Maria', 'dijo', 'hola'],
        wordMap: const {},
        senseMap: const {},
      );
      expect(indices(enlaces), {0: 0, 1: 1, 2: 2});
      expect(enlaces[0]!.tier, 2);
    });

    test('frase de dos palabras -> cada parte pinta', () {
      // Preferimos un original >= 4 letras aquí: la regla anti-ruido
      // (norm <= 3 solo igualdad directa) vetaría la contención para
      // tokens cortos como 'do'.
      final enlaces = alignLineTokens(
        originalTokens: const ['finish', 'homework'],
        translatedTokens: const ['haz', 'la', 'tarea'],
        wordMap: const {'finish': 'haz', 'homework': 'la tarea'},
        senseMap: const {},
      );
      expect(indices(enlaces), {0: 0, 1: 1, 2: 1});
      expect(enlaces[1]!.tier, greaterThanOrEqualTo(1));
      expect(enlaces[2]!.tier, greaterThanOrEqualTo(1));
    });

    test('raíz común aunque el contexto conjuga (tier 1)', () {
      final enlaces = alignLineTokens(
        originalTokens: const ['they', 'sing', 'loud'],
        translatedTokens: const ['Ellos', 'cantan', 'fuerte'],
        wordMap: const {
          'they': 'ellos',
          'sing': 'cantar',
          'loud': 'fuerte',
        },
        senseMap: const {},
      );
      expect(indices(enlaces), {0: 0, 1: 1, 2: 2});
      expect(enlaces[1]!.tier, 1);
    });

    test('swap explícito: adjetivo y sustantivo invertidos', () {
      final enlaces = alignLineTokens(
        originalTokens: const ['beautiful', 'world'],
        translatedTokens: const ['mundo', 'hermoso'],
        wordMap: const {
          'beautiful': 'hermoso',
          'world': 'mundo',
        },
        senseMap: const {},
      );
      expect(indices(enlaces), {0: 1, 1: 0});
    });

    test('swap explícito con vecinos alrededor', () {
      final enlaces = alignLineTokens(
        originalTokens: const ['reach', 'beautiful', 'world', 'tonight'],
        translatedTokens: const ['alcanza', 'mundo', 'hermoso', 'esta', 'noche'],
        wordMap: const {
          'reach': 'alcanza',
          'beautiful': 'hermoso',
          'world': 'mundo',
          'tonight': 'esta noche',
        },
        senseMap: const {},
      );
      // El swap (world<->mundo con beautiful<->hermoso) se mantiene aunque
      // haya vecinos: 'alcanza'->0, 'mundo'->2, 'hermoso'->1.
      expect(indices(enlaces)[0], 0);
      expect(indices(enlaces)[1], 2);
      expect(indices(enlaces)[2], 1);
    });

    test('repetidas: cada traducida cae en una original distinta (1 a 1)', () {
      final enlaces = alignLineTokens(
        originalTokens: const ['yeah', 'yeah', 'baby'],
        translatedTokens: const ['sí', 'sí', 'bebé'],
        wordMap: const {'yeah': 'sí', 'baby': 'bebé'},
        senseMap: const {},
      );
      expect(indices(enlaces), {0: 0, 1: 1, 2: 2});
    });

    test('senseMap habilita tier 2 (sentidos del banco)', () {
      final enlaces = alignLineTokens(
        originalTokens: const ['the', 'bank', 'of', 'the', 'river'],
        translatedTokens: const ['la', 'orilla', 'del', 'río'],
        wordMap: const {'bank': 'banco'},
        senseMap: const {
          'bank': {'orilla', 'banco'},
        },
      );
      // "orilla" solo existe vía sentidos; 'the'/'del' van por la reserva.
      expect(indices(enlaces), {1: 1});
      expect(enlaces[1]!.tier, 2);
    });

    test('anti-ruido: tokens cortos no reclaman por contención', () {
      // "no" -> "ninguno": contención en el léxico, pero por la regla
      // anti-ruido (norm <= 3) solo vale igualdad directa => se omite.
      final sinIgualdad = alignLineTokens(
        originalTokens: const ['no'],
        translatedTokens: const ['ninguno'],
        wordMap: const {'no': 'ninguno'},
        senseMap: const {},
      );
      expect(sinIgualdad, isEmpty);

      // En cambio, con igualdad directa sí empareja.
      final conIgualdad = alignLineTokens(
        originalTokens: const ['no', 'love'],
        translatedTokens: const ['no', 'amor'],
        wordMap: const {'love': 'amor'},
        senseMap: const {},
      );
      expect(indices(conIgualdad), {0: 0, 1: 1});
    });

    test('segmentos priorizan y orientan dentro de su rango', () {
      final enlaces = alignLineTokens(
        originalTokens: const ['I', 'love', 'red', 'roses'],
        translatedTokens: const ['amo', 'rosas', 'rojas'],
        wordMap: const {
          'love': 'amo',
          'red': 'roja',
          'roses': 'rosas',
        },
        senseMap: const {},
        segments: const [
          TextSegment(source: 'red roses', target: 'rosas rojas'),
          TextSegment(source: 'I love', target: 'amo'),
        ],
      );
      final idx = indices(enlaces);
      // 'amo' sale por contención del léxico de 'love'.
      expect(idx[0], 1);
      // 'rosas' y 'rojas' enlazan dentro del rango del segmento {2, 3}
      // (roses / red), no caen dentro de 'love' ni de la línea entera.
      expect(idx[1], anyOf(2, 3));
      expect(idx[2], anyOf(2, 3));
      expect(idx[1], isNot(1));
      expect(idx[2], isNot(1));
      // El swap 'rosas rojas' <-> 'red roses' es lo canónico.
      expect(idx, {0: 1, 1: 3, 2: 2});
    });

    test('listas vacías no revientan', () {
      expect(
        alignLineTokens(
          originalTokens: const [],
          translatedTokens: const ['hola'],
          wordMap: const {},
          senseMap: const {},
        ),
        isEmpty,
      );
      expect(
        alignLineTokens(
          originalTokens: const ['hola'],
          translatedTokens: const [],
          wordMap: const {},
          senseMap: const {},
        ),
        isEmpty,
      );
      expect(
        alignLineTokens(
          originalTokens: const [],
          translatedTokens: const [],
          wordMap: const {},
          senseMap: const {},
        ),
        isEmpty,
      );
    });

    test('derrame: la traducción de una frase cubre dos tokens seguidos', () {
      final enlaces = alignLineTokens(
        originalTokens: const ['finish', 'homework'],
        translatedTokens: const ['haz', 'la', 'tarea'],
        wordMap: const {'finish': 'haz', 'homework': 'la tarea'},
        senseMap: const {},
      );
      // 'la' y 'tarea' vienen del derrame de la traducción de 'homework'.
      expect(indices(enlaces), {0: 0, 1: 1, 2: 1});
    });
  });

  group('phraseVocabulary', () {
    test('incluye unigramas, bigramas y trigramas en orden', () {
      final vocab = phraseVocabulary(const ['give', 'up', 'everything']);
      expect(vocab, containsAll(<String>[
        'give',
        'up',
        'everything',
        'give up',
        'up everything',
        'give up everything',
      ]));
      expect(vocab, isNot(contains('up everything and')));
    });

    test('normaliza los tokens al armar las frases', () {
      final vocab = phraseVocabulary(const ['Give,', 'UP!', 'everything?']);
      expect(vocab, contains('give up'));
      expect(vocab, contains('give up everything'));
    });

    test('descarta frases de solo tokens <= 2 letras', () {
      final vocab = phraseVocabulary(const ['to', 'be']);
      expect(vocab, contains('to'));
      expect(vocab, contains('be'));
      expect(vocab, isNot(contains('to be')));
    });

    test('sin tokens no revienta y las de puntuación se caen', () {
      expect(phraseVocabulary(const []), isEmpty);
      expect(phraseVocabulary(const ['!']), isEmpty);
    });
  });
}
