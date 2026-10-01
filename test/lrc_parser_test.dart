import 'package:flutter_test/flutter_test.dart';
import 'package:lylyrics/core/models/lyrics.dart';
import 'package:lylyrics/services/lrc_parser.dart';

/// Formato compacto de una línea para comparar listas enteras:
/// `milisegundos@texto` (`~` cuando el texto está vacío, así se ve la pausa).
String _l(LyricLine line) =>
    '${line.time.inMilliseconds}@${line.text.isEmpty ? '~' : line.text}';

List<String> _ls(List<LyricLine> lines) => [for (final l in lines) _l(l)];

/// Letra sincronizada de ejemplo: 5 líneas, una de ellas pausa instrumental.
final _cancion = '''
[ar:Bad Bunny]
[ti:Después de lawara]
[00:00.50]Intro
[00:04.00]
[00:08.00]Primera estrofa
[00:12.00]Segunda estrofa
''';

void main() {
  const parser = LrcParser();

  // =====================================================================
  group('formatos de timestamp', () {
    test('[mm:ss.xx] básico: tiempo exacto y texto', () {
      final r = parser.parse('[00:12.00]Hola mundo');
      expect(_ls(r.lines), ['12000@Hola mundo']);
      expect(r.isSynced, isTrue);
      expect(r.ignoredLines, isEmpty);
    });

    test('[mm:ss.xxx]: los tres decimales son milisegundos', () {
      final r = parser.parse('[00:12.345]Hola');
      expect(r.lines.single.time, const Duration(milliseconds: 12345));
      expect(_ls(r.lines), ['12345@Hola']);
    });

    test('[mm:ss] sin fracciones', () {
      final r = parser.parse('[01:05]Cinco');
      expect(_ls(r.lines), ['65000@Cinco']);
    });

    test('sin corchetes: "mm:ss.xx Texto"', () {
      final r = parser.parse('00:12.00 Hola mundo');
      expect(_ls(r.lines), ['12000@Hola mundo']);
      expect(r.ignoredLines, isEmpty);
    });

    test('minutos por encima de 59', () {
      final r = parser.parse('[75:00.00]Setenta y cinco minutos');
      expect(r.lines.single.time, const Duration(minutes: 75));
      expect(r.lines.single.time.inMinutes, 75);
    });

    test('minutos de tres dígitos', () {
      final r = parser.parse('[100:30.50]Ciento');
      expect(
        r.lines.single.time,
        const Duration(minutes: 100, seconds: 30, milliseconds: 500),
      );
    });

    test('un solo dígito de fracción es décimas', () {
      final r = parser.parse('[00:12.1]Hola');
      expect(_ls(r.lines), ['12100@Hola']);
    });

    test('coma decimal se acepta como separador (tolerancia)', () {
      final r = parser.parse('[00:12,50]Hola');
      expect(_ls(r.lines), ['12500@Hola']);
    });

    test('espacios dentro del timestamp y dentro del texto', () {
      final r = parser.parse('[00:12.00 ]   Hola   ');
      expect(_ls(r.lines), ['12000@Hola']);
      expect(
        LrcParser.parseTimestamp('[ 01:02.03 ]'),
        const Duration(minutes: 1, seconds: 2, milliseconds: 30),
      );
    });

    test('timestamp pegado al texto sin espacio NO se interpreta', () {
      final r = parser.parse('00:12.00Hola');
      expect(r.lines, isEmpty);
      expect(r.ignoredLines, ['00:12.00Hola']);
    });

    test('parseTimestamp acepta y rechaza lo esperado', () {
      expect(
        LrcParser.parseTimestamp('[00:12.00]'),
        const Duration(milliseconds: 12000),
      );
      expect(LrcParser.parseTimestamp('00:12.00'), const Duration(seconds: 12));
      expect(
        LrcParser.parseTimestamp('  [01:00]  '),
        const Duration(minutes: 1),
      );
      expect(
        LrcParser.parseTimestamp('00:00.001'),
        const Duration(microseconds: 1000),
      );
      expect(
        LrcParser.parseTimestamp('00:00.9'),
        const Duration(milliseconds: 900),
      );
      expect(
        LrcParser.parseTimestamp('00:00.99'),
        const Duration(milliseconds: 990),
      );
      // Mal formados.
      expect(LrcParser.parseTimestamp('[aa:bb]'), isNull);
      expect(LrcParser.parseTimestamp('[00:75.00]'), isNull); // segundos > 59
      expect(LrcParser.parseTimestamp('[12]'), isNull);
      expect(LrcParser.parseTimestamp('[]'), isNull);
      expect(LrcParser.parseTimestamp(''), isNull);
      expect(LrcParser.parseTimestamp('   '), isNull);
      expect(LrcParser.parseTimestamp('[00:12.00'), isNull);
      expect(LrcParser.parseTimestamp('[ar:Bad Bunny]'), isNull);
    });
  });

  // =====================================================================
  group('varios timestamps por línea', () {
    test('dos timestamps generan dos LyricLine con el mismo texto', () {
      final r = parser.parse('[00:12.00][01:20.30]Texto repetido');
      expect(_ls(r.lines), ['12000@Texto repetido', '80300@Texto repetido']);
    });

    test('tres timestamps', () {
      final r = parser.parse('[00:01.00][00:02.00][00:03.00]Estribillo');
      expect(_ls(r.lines), [
        '1000@Estribillo',
        '2000@Estribillo',
        '3000@Estribillo',
      ]);
    });

    test('timestamp entre corchetes y timestamp suelto', () {
      final r = parser.parse('[00:05.00] 00:06.00 Texto');
      expect(_ls(r.lines), ['5000@Texto', '6000@Texto']);
    });
  });

  // =====================================================================
  group('orden de las líneas', () {
    test('orden inverso en la fuente -> ordenado ascendente', () {
      final r = parser.parse('[00:20.00]Tres\n[00:05.00]Uno\n[00:12.00]Dos');
      expect(_ls(r.lines), ['5000@Uno', '12000@Dos', '20000@Tres']);
    });

    test('tiempos repetidos: orden estable, gana el orden del fichero', () {
      final r = parser.parse('[00:10.00]Zeta\n[00:10.00]Alfa\n[00:10.00]Media');
      expect(_ls(r.lines), ['10000@Zeta', '10000@Alfa', '10000@Media']);
    });

    test('tiempos repetidos y desordenados a la vez', () {
      final r = parser.parse(
        '[00:10.00]C\n[00:02.00]A\n[00:10.00]B\n[00:02.00]Z',
      );
      expect(_ls(r.lines), ['2000@A', '2000@Z', '10000@C', '10000@B']);
    });

    test('los milisegundos mandan: 10.20 va antes que 10.50', () {
      final r = parser.parse('[00:10.50]B\n[00:10.20]A');
      expect(_ls(r.lines), ['10200@A', '10500@B']);
    });
  });

  // =====================================================================
  group('líneas vacías y pausas instrumentales', () {
    test('una línea con timestamp y sin texto se conserva', () {
      final r = parser.parse('[00:20.00]');
      expect(r.lines, hasLength(1));
      expect(r.lines.single.isBlank, isTrue);
      expect(_ls(r.lines), ['20000@~']);
      expect(r.lines.single.text, '');
    });

    test('la pausa entre dos frases se conserva y ordena bien', () {
      final r = parser.parse('[00:04.00]Antes\n[00:08.00]\n[00:12.00]Después');
      expect(_ls(r.lines), ['4000@Antes', '8000@~', '12000@Después']);
      expect(r.lines[1].isBlank, isTrue);
    });

    test('línea en blanco sin timestamp no es ni línea ni ignorada', () {
      final r = parser.parse('\n\n   \n[00:01.00]Hola\n\n');
      expect(_ls(r.lines), ['1000@Hola']);
      expect(r.ignoredLines, isEmpty);
    });

    test('visibleLines deja fuera la pausa pero no se pierde el hueco', () {
      final lyrics = parser.parse(_cancion).toLyrics();
      expect(lyrics.isSynced, isTrue);
      expect(lyrics.lines, hasLength(4));
      expect(lyrics.visibleLines.map((l) => l.text), [
        'Intro',
        'Primera estrofa',
        'Segunda estrofa',
      ]);
      expect(lyrics.instrumental, isFalse);
    });
  });

  // =====================================================================
  group('ignoredLines', () {
    test('texto sin timestamp', () {
      final r = parser.parse('Hola mundo\n[00:01.00]Con tiempo');
      expect(_ls(r.lines), ['1000@Con tiempo']);
      expect(r.ignoredLines, ['Hola mundo']);
    });

    test('timestamp malformado', () {
      final r = parser.parse('[00:12.0x0]Roto\n[00:75.00]Segundos\nBien');
      expect(r.lines, isEmpty);
      expect(r.ignoredLines, ['[00:12.0x0]Roto', '[00:75.00]Segundos', 'Bien']);
    });

    test('corchete sin cerrar', () {
      final r = parser.parse('[00:12.00 Texto');
      expect(r.lines, isEmpty);
      expect(r.ignoredLines, ['[00:12.00 Texto']);
    });

    test('[Chorus] y similares van a ignoradas', () {
      final r = parser.parse('[Chorus]\n[00:01.00]Coro');
      expect(r.ignoredLines, ['[Chorus]']);
      expect(_ls(r.lines), ['1000@Coro']);
    });

    test('el texto plano entero acaba ignorado', () {
      final r = parser.parse('Primera línea\nSegunda línea\nTercera');
      expect(r.lines, isEmpty);
      expect(r.isSynced, isFalse);
      expect(r.ignoredLines, hasLength(3));
      expect(r.metadata, isNull);
    });

    test('las ignoradas no llevan el CR del CRLF', () {
      final r = parser.parse('Sin tiempo\r\n[00:01.00]Con tiempo\r\n');
      expect(r.ignoredLines, ['Sin tiempo']);
    });
  });

  // =====================================================================
  group('metadatos', () {
    test('[ar:], [ti:] y [al:]', () {
      final r = parser.parse(
        '[ar:Bad Bunny]\n[ti:Tití Me Preguntó]\n'
        '[al:Un Verano Sin Ti]\n[00:01.00]La letra',
      );
      expect(r.metadata!.artist, 'Bad Bunny');
      expect(r.metadata!.title, 'Tití Me Preguntó');
      expect(r.metadata!.album, 'Un Verano Sin Ti');
      expect(r.metadata!.length, isNull);
      expect(_ls(r.lines), ['1000@La letra']);
    });

    test('[au:] y [by:] no se pierden', () {
      final r = parser.parse('[au:Alguien][by:Editor LRC]\n[00:01.00]X');
      expect(r.metadata!.author, 'Alguien');
      expect(r.metadata!.creator, 'Editor LRC');
    });

    test('las claves van en minúsculas y el valor se recorta', () {
      final r = parser.parse('[AR:  Bad Bunny  ]\n[00:01.00]X');
      expect(r.metadata!.artist, 'Bad Bunny');
    });

    test('[length:03:41] se parsea a Duration', () {
      final r = parser.parse('[length:03:41]\n[00:01.00]X');
      expect(r.metadata!.length, const Duration(minutes: 3, seconds: 41));
      expect(r.metadata!.rawLength, '03:41');
    });

    test('[length:221] son segundos sueltos', () {
      final r = parser.parse('[length:221]\n[00:01.00]X');
      expect(r.metadata!.length, const Duration(seconds: 221));
    });

    test('[length:] con decimales y coma', () {
      expect(
        LrcParser.parseLength('1:02.5'),
        const Duration(minutes: 1, seconds: 2, milliseconds: 500),
      );
      expect(
        LrcParser.parseLength('1:02,5'),
        const Duration(minutes: 1, seconds: 2, milliseconds: 500),
      );
      expect(
        LrcParser.parseLength('90.5'),
        const Duration(seconds: 90, milliseconds: 500),
      );
    });

    test('[length:] inválido -> null pero sin romper', () {
      expect(LrcParser.parseLength('abc'), isNull);
      expect(LrcParser.parseLength(''), isNull);
      final r = parser.parse('[length:no-se]\n[00:01.00]X');
      expect(r.metadata!.length, isNull);
      expect(r.metadata!.rawLength, 'no-se');
    });

    test('tag en la MISMA línea que el texto: se extrae y la línea sigue', () {
      final r = parser.parse('[00:12.00][ar:Bad Bunny]Texto');
      expect(r.metadata!.artist, 'Bad Bunny');
      expect(_ls(r.lines), ['12000@Texto']);
    });

    test('varios tags antes del texto de la misma línea', () {
      final r = parser.parse('[00:12.00][ti:Canción][ar:Artista] Hola ');
      expect(r.metadata!.title, 'Canción');
      expect(r.metadata!.artist, 'Artista');
      expect(_ls(r.lines), ['12000@Hola']);
    });

    test('una línea solo de metadatos no se marca como ignorada', () {
      final r = parser.parse('[ar:Solo]\n[00:01.00]X');
      expect(r.ignoredLines, isEmpty);
      expect(r.metadata!.artist, 'Solo');
    });

    test('tags desconocidos van a extraTags y no al texto', () {
      final r = parser.parse('[re:LRC Editor]\n[00:01.00]Texto');
      expect(r.metadata!.extraTags['re'], 'LRC Editor');
      expect(_ls(r.lines), ['1000@Texto']);
      expect(LrcMetadata.knownTags.contains('re'), isFalse);
    });

    test('tag vacío -> campo null, sin excepción', () {
      final r = parser.parse('[ar:]\n[ti:Canción]\n[00:01.00]X');
      expect(r.metadata!.artist, isNull);
      expect(r.metadata!.title, 'Canción');
      expect(r.metadata!.isNotEmpty, isTrue);
      // Si lo único que hay son tags vacíos, no hay metadatos que devolver.
      expect(parser.parse('[ar:]\n[ti:]\n[00:01.00]X').metadata, isNull);
    });

    test('sin cabecera no hay metadatos', () {
      final r = parser.parse('[00:01.00]X');
      expect(r.metadata, isNull);
    });

    test('LrcMetadata: igualdad y toString', () {
      const a = LrcMetadata(artist: 'A', length: Duration(seconds: 1));
      const b = LrcMetadata(artist: 'A', length: Duration(seconds: 1));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const LrcMetadata(artist: 'B')));
      expect(a.toString(), contains('A'));
      expect(const LrcMetadata().isEmpty, isTrue);
    });
  });

  // =====================================================================
  group('[offset:]', () {
    test('positivo: se suma a todas las líneas', () {
      final r = parser.parse('[offset:500]\n[00:10.00]A\n[00:20.00]B');
      expect(_ls(r.lines), ['10500@A', '20500@B']);
      expect(r.metadata!.offset, const Duration(milliseconds: 500));
      expect(r.hasOffset, isTrue);
    });

    test('negativo: se resta a todas las líneas', () {
      final r = parser.parse('[offset:-300]\n[00:10.00]A\n[00:20.00]B');
      expect(_ls(r.lines), ['9700@A', '19700@B']);
      expect(r.metadata!.offset, const Duration(milliseconds: -300));
    });

    test('con signo + explícito', () {
      expect(LrcParser.parseOffset('+750'), const Duration(milliseconds: 750));
    });

    test('se acota a ±5000 ms', () {
      expect(LrcParser.parseOffset('999999'), const Duration(seconds: 5));
      expect(LrcParser.parseOffset('-999999'), const Duration(seconds: -5));
      expect(LrcParser.parseOffset('5000'), const Duration(seconds: 5));
      expect(LrcParser.parseOffset('-5000'), const Duration(seconds: -5));
      expect(LrcParser.maxOffsetMs, 5000);
    });

    test('un offset enorme puede dejar tiempos negativos sin romper', () {
      final r = parser.parse('[offset:-5000]\n[00:01.00]A\n[00:30.00]B');
      expect(_ls(r.lines), ['-4000@A', '25000@B']);
      // Sigue ordenado ascendente: sumar una constante no rompe el orden.
      for (var i = 1; i < r.lines.length; i++) {
        expect(r.lines[i].time >= r.lines[i - 1].time, isTrue);
      }
    });

    test('offset con basura -> no hay metadatos, el resto se parsea igual', () {
      final r = parser.parse('[offset:mucho]\n[00:10.00]A');
      expect(r.metadata, isNull);
      expect(_ls(r.lines), ['10000@A']);
      expect(r.hasOffset, isFalse);
      expect(LrcParser.parseOffset('mucho'), isNull);
      expect(LrcParser.parseOffset(''), isNull);
    });

    test('offset 0 explícito', () {
      final r = parser.parse('[offset:0]\n[00:10.00]A');
      expect(r.metadata!.offset, Duration.zero);
      expect(r.hasOffset, isFalse);
    });
  });

  // =====================================================================
  group('basura y casos límite', () {
    test('entrada vacía', () {
      expect(parser.parse('').lines, isEmpty);
      expect(parser.parse('').metadata, isNull);
      expect(parser.parse('').ignoredLines, isEmpty);
      expect(parser.parse('').toLyrics().isSynced, isFalse);
    });

    test('solo espacios y tabuladores', () {
      final r = parser.parse('   \n\t\n\t \t');
      expect(r.lines, isEmpty);
      expect(r.ignoredLines, isEmpty);
    });

    test('BOM de UTF-8 al principio', () {
      final r = parser.parse('\uFEFF[00:12.00]Con BOM');
      expect(_ls(r.lines), ['12000@Con BOM']);
      expect(r.ignoredLines, isEmpty);
    });

    test('BOM y CRLF juntos, como en un fichero de Windows', () {
      final raw =
          '\uFEFF[ar:Bad Bunny]\r\n[00:12.00]Hola\r\n[00:20.00]Adiós\r\n';
      final r = parser.parse(raw);
      expect(r.metadata!.artist, 'Bad Bunny');
      expect(_ls(r.lines), ['12000@Hola', '20000@Adiós']);
    });

    test('CR solo (Mac clásico)', () {
      final r = parser.parse('[00:01.00]A\r[00:02.00]B');
      expect(_ls(r.lines), ['1000@A', '2000@B']);
    });

    test('caracteres de control no rompen nada y no se cuelan', () {
      final r = parser.parse('[00:12.00]Ho\u0000la\u0007\u001F');
      expect(_ls(r.lines), ['12000@Hola']);
    });

    test('basura pura sin timestamps', () {
      final r = parser.parse('¿?%%\n\t\t\n***');
      expect(r.lines, isEmpty);
      expect(r.ignoredLines, ['¿?%%', '***']);
    });

    test('solo corchetes sueltos', () {
      final r = parser.parse('[]\n[[\n]]');
      expect(r.lines, isEmpty);
      expect(r.ignoredLines, hasLength(3));
    });

    test('muchas líneas de golpe (50 000) sin revostar', () {
      final buffer = StringBuffer();
      for (var i = 0; i < 50000; i++) {
        final ms = i * 250;
        final mm = (ms ~/ 60000).toString().padLeft(2, '0');
        final ss = ((ms ~/ 1000) % 60).toString().padLeft(2, '0');
        final xx = ((ms % 1000) ~/ 10).toString().padLeft(2, '0');
        buffer.writeln('[$mm:$ss.$xx]Línea $i');
      }
      final r = parser.parse(buffer.toString());
      expect(r.lines, hasLength(50000));
      expect(r.ignoredLines, isEmpty);
      expect(r.lines.first.text, 'Línea 0');
      expect(r.lines.last.time.inMilliseconds, 49999 * 250);
      for (var i = 1; i < r.lines.length; i++) {
        expect(r.lines[i].time >= r.lines[i - 1].time, isTrue);
      }
    });
  });

  // =====================================================================
  group('normalización del texto', () {
    test('recorta espacios sobrantes de los extremos', () {
      final r = parser.parse('[00:01.00]     Hola mundo     ');
      expect(r.lines.single.text, 'Hola mundo');
    });

    test('NO destruye espacios internos ni tabs', () {
      final r = parser.parse('[00:01.00]Hola    que     tal\testá');
      expect(r.lines.single.text, 'Hola    que     tal\testá');
    });

    test('conserva el texto tal cual por lo demás (signos, tildes)', () {
      const texto = "¡No, no! Dime: 'sí' — ¿qué? 100% ñandú";
      final r = parser.parse('[00:01.00]$texto');
      expect(r.lines.single.text, texto);
    });

    test('texto solo de espacios se considera pausa', () {
      final r = parser.parse('[00:01.00]      ');
      expect(r.lines.single.text, '');
      expect(r.lines.single.isBlank, isTrue);
    });

    test('el trim no se come un texto que empieza por corchete', () {
      final r = parser.parse('[00:01.00]  [algo] dentro');
      expect(r.lines.single.text, '[algo] dentro');
    });

    test('trim en línea con varios timestamps y tag', () {
      final r = parser.parse('[00:01.00][00:02.00]  \t Hola \t  ');
      expect(_ls(r.lines), ['1000@Hola', '2000@Hola']);
    });
  });

  // =====================================================================
  group('helpers y resultado', () {
    test('parseSynced devuelve solo las líneas', () {
      expect(_ls(LrcParser.parseSynced(_cancion)), [
        '500@Intro',
        '4000@~',
        '8000@Primera estrofa',
        '12000@Segunda estrofa',
      ]);
    });

    test('toLyrics marca isSynced y conserva las pausas', () {
      final lyrics = parser.parse(_cancion).toLyrics();
      expect(lyrics.isSynced, isTrue);
      expect(lyrics.lines, hasLength(4));
      expect(lyrics.plainText, isNull);
      expect(lyrics.toString(), contains('synced: true'));
    });

    test('toLyrics sin timestamps no inventa sincronización', () {
      final lyrics = parser.parse('Hola\nAdiós').toLyrics();
      expect(lyrics.isSynced, isFalse);
      expect(lyrics.lines, isEmpty);
    });

    test('plainText del resultado', () {
      final r = parser.parse('[00:01.00]Uno\n[00:02.00]\n[00:03.00]Dos');
      expect(r.plainText, 'Uno\nDos');
    });

    test('las listas del resultado no se pueden modificar', () {
      final r = parser.parse(_cancion);
      expect(
        () => r.lines.add(const LyricLine(time: Duration.zero, text: 'x')),
        throwsUnsupportedError,
      );
      expect(() => r.ignoredLines.add('x'), throwsUnsupportedError);
    });

    test('LrcParseResult: igualdad y toString', () {
      final a = parser.parse(_cancion);
      final b = parser.parse(_cancion);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.toString(), contains('lines: 4'));
      expect(const LrcParseResult.empty(), const LrcParseResult.empty());
      expect(const LrcParseResult.empty().isSynced, isFalse);
    });

    test('LRC real completo: orden y contenido exactos', () {
      const raw =
          '[ti:Blinding Lights]\n'
          '[ar:The Weeknd]\n'
          '[al:After Hours]\n'
          '[length:03:41]\n'
          '[offset:+250]\n'
          '[00:00.30]Has anything ever been so clear?\n'
          '[00:05.10]\n'
          '[00:11.90]I couldn\'t ever imagine it all\n'
          '[02:10.00]Ending, I don\'t know\n';
      final r = parser.parse(raw);
      expect(_ls(r.lines), [
        '550@Has anything ever been so clear?',
        '5350@~',
        '12150@I couldn\'t ever imagine it all',
        '130250@Ending, I don\'t know',
      ]);
      expect(r.metadata!.title, 'Blinding Lights');
      expect(r.metadata!.artist, 'The Weeknd');
      expect(r.metadata!.album, 'After Hours');
      expect(r.metadata!.length, const Duration(minutes: 3, seconds: 41));
      expect(r.metadata!.offset, const Duration(milliseconds: 250));
      expect(r.ignoredLines, isEmpty);
    });

    test('inmunidades: ninguna entrada razonable revienta', () {
      final basuras = <String>[
        '',
        ' ',
        '\n\n\n',
        '[]',
        '[]]',
        '[[',
        '[00:',
        ']:',
        '00:',
        ':00',
        '[ar',
        'ar:]',
        '[00:00.00]',
        '[]Hola',
        '99999999999999:00.00 Larga',
        '[offset:]',
        '[offset:abc]',
        '[length:]',
        '🙂🙂🙂',
        '[00:12.00]🙂 Emoji',
      ];
      // Con caracteres de verdad: se generan en codigo para no depender
      // de escapes raros en el propio fichero de test.
      basuras.add(String.fromCharCodes([0, 1, 2, 127]));
      basuras.add('[00:01.00]Ho${String.fromCharCode(0)}la');
      for (final basura in basuras) {
        expect(
          () => parser.parse(basura),
          returnsNormally,
          reason: 'entrada de ${basura.length} bytes',
        );
      }
      // Con y sin salto final, con BOM y con CRLF.
      final conBOM = '\uFEFF[00:01.00]A\r\n[00:02.00]B\n\r\n';
      expect(_ls(parser.parse(conBOM).lines), ['1000@A', '2000@B']);
    });
  });
}
