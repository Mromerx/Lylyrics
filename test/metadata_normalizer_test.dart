import 'package:flutter_test/flutter_test.dart';
import 'package:lylyrics/core/models/track_info.dart';
import 'package:lylyrics/services/metadata_normalizer.dart';

/// Formato compacto de un candidato para comparar listas enteras:
/// `confianza|artista|título` (usando `~` cuando no hay artista).
String _fmt(TitleCandidate c) =>
    '${c.confidence}|${c.artist ?? '~'}|${c.title}';

List<String> _fmts(List<TitleCandidate> candidates) => [
  for (final c in candidates) _fmt(c),
];

void main() {
  final n = MetadataNormalizer();

  // =====================================================================
  group('normalizeForCompare', () {
    test('minúsculas y sin tildes', () {
      expect(
        MetadataNormalizer.normalizeForCompare('Tití Me Preguntó'),
        'titi me pregunto',
      );
      expect(
        MetadataNormalizer.normalizeForCompare('TITI  ME   PREGUNTO!!!'),
        'titi me pregunto',
      );
    });

    test('cubre el abecedario español completo', () {
      expect(
        MetadataNormalizer.normalizeForCompare('Ñoño ÁÉÍÓÚü çÇ âêîôû'),
        'nono aeiouu cc aeiou',
      );
      expect(MetadataNormalizer.normalizeForCompare('ÁÉÍÓÚÜÑ'), 'aeiouun');
      expect(MetadataNormalizer.normalizeForCompare('Canción'), 'cancion');
      expect(MetadataNormalizer.normalizeForCompare('MÚSICAS'), 'musicas');
    });

    test('quita puntuación y colapsa espacios', () {
      expect(MetadataNormalizer.normalizeForCompare('Jay-Z'), 'jay z');
      expect(MetadataNormalizer.normalizeForCompare('Jay Z'), 'jay z');
      expect(MetadataNormalizer.normalizeForCompare('AC/DC'), 'ac dc');
      expect(MetadataNormalizer.normalizeForCompare('  MÚSICAS   '), 'musicas');
      expect(MetadataNormalizer.normalizeForCompare('a!!!  b'), 'a b');
    });

    test('sirve para deduplicar y para comparar con LRCLIB', () {
      expect(
        MetadataNormalizer.normalizeForCompare('Bad Bunny - Topic'),
        'bad bunny topic',
      );
      expect(
        MetadataNormalizer.normalizeForCompare('el Psy,  el Autocontrol'),
        MetadataNormalizer.normalizeForCompare('El Psy El Autocontrol'),
      );
    });
  });

  // =====================================================================
  group('cleanTitle: se quitan las etiquetas sucias', () {
    const seQuitan = <String, String>{
      'KAROL G - PROVENZA (Official Video)': 'KAROL G - PROVENZA',
      'El PanAMEka (Official Video)': 'El PanAMEka',
      'Shape of You [Official Audio]': 'Shape of You',
      'Resaca (Lyrics)': 'Resaca',
      'Resaca (Letra)': 'Resaca',
      'Estúpido Cupido (Video Oficial)': 'Estúpido Cupido',
      'Dile (Letra Oficial)': 'Dile',
      'Faded (Audio)': 'Faded',
      'Faded (HD)': 'Faded',
      'Faded [HD]': 'Faded',
      'Faded HD': 'Faded',
      'Faded 4K': 'Faded',
      'Africa (Remastered)': 'Africa',
      'Africa (Remastered 2011)': 'Africa',
      'Africa [Remaster]': 'Africa',
      'Africa [Remastered 2011]': 'Africa',
      'Todo De Ti (Español)': 'Todo De Ti',
      'Who Am I (English)': 'Who Am I',
      'Dime (Subtitulado)': 'Dime',
      'Take On Me (Video)': 'Take On Me',
      'Take On Me (Official Music Video)': 'Take On Me',
      'Take On Me (Official Lyric Video)': 'Take On Me',
      'Dynamite (Full Album)': 'Dynamite',
      'Ocean Drive (Letra Oficial) [HD]': 'Ocean Drive',
      'PROVENZA Official Video': 'PROVENZA',
      'PROVENZA Official Music Video': 'PROVENZA',
      'Blinding Lights 4K': 'Blinding Lights',
      'Song |  ': 'Song',
      "Who Am I (What's My Name)? (Official Video)": 'Who Am I?',
      'Canción (Official Video': 'Canción',
    };

    seQuitan.forEach((raw, expected) {
      test('"$raw" -> "$expected"', () {
        expect(MetadataNormalizer.cleanTitle(raw), expected);
      });
    });

    const seConservan = <String, String>{
      "Style (Taylor's Version)": "Style (Taylor's Version)",
      'Song (feat. Natti Natasha)': 'Song (feat. Natti Natasha)',
      'Song (ft. Young Thug)': 'Song (ft. Young Thug)',
      'Del Mar (Don Omar Remix)': 'Del Mar (Don Omar Remix)',
      'Shape of You (Radio Edit)': 'Shape of You (Radio Edit)',
      'WSP - En vivo (Official Video)': 'WSP - En vivo',
      'Song (Live)': 'Song (Live)',
      'Song (Acoustic)': 'Song (Acoustic)',
      'Dime (Acústica)': 'Dime (Acústica)',
      'Dime (Instrumental)': 'Dime (Instrumental)',
      'Song (Variation)': 'Song (Variation)',
      'Song (Deluxe Edition)': 'Song (Deluxe Edition)',
      'Havana (feat. Young Thug) [Official Video]': 'Havana (feat. Young Thug)',
    };

    seConservan.forEach((raw, expected) {
      test('"$raw" -> "$expected"', () {
        expect(MetadataNormalizer.cleanTitle(raw), expected);
      });
    });

    test('no toca "(feat. X)" ni "(Remix de Y)" al quitar lo de alrededor', () {
      expect(
        MetadataNormalizer.cleanTitle(
          'Tití Me Preguntó (Official Video) [feat. Jhay Cortez]',
        ),
        'Tití Me Preguntó [feat. Jhay Cortez]',
      );
      expect(
        MetadataNormalizer.cleanTitle('Del Mar (Don Omar Remix) (Audio)'),
        'Del Mar (Don Omar Remix)',
      );
    });

    test('stripAllTags quita incluso lo que aporta información', () {
      expect(
        MetadataNormalizer.stripAllTags("Style (Taylor's Version)"),
        'Style',
      );
      expect(
        MetadataNormalizer.stripAllTags('Dime (Video Oficial) [HD]'),
        'Dime',
      );
    });
  });

  // =====================================================================
  group('cleanArtist', () {
    test('quita el sufijo de canal', () {
      expect(MetadataNormalizer.cleanArtist('Bad Bunny - Topic'), 'Bad Bunny');
      expect(MetadataNormalizer.cleanArtist('WISIN VEVO'), 'WISIN');
      expect(MetadataNormalizer.cleanArtist('KAROL G Records'), 'KAROL G');
      expect(MetadataNormalizer.cleanArtist('Nathy Peluso 2'), 'Nathy Peluso');
      expect(MetadataNormalizer.cleanArtist('WISIN Official'), 'WISIN');
      expect(MetadataNormalizer.cleanArtist('Karol G Música'), 'Karol G');
      expect(
        MetadataNormalizer.cleanArtist('Bad Bunny Television'),
        'Bad Bunny',
      );
      expect(MetadataNormalizer.looksLikeChannelName('Karol G Música'), isTrue);
      expect(
        MetadataNormalizer.cleanArtist('Bad Bunny (Official)'),
        'Bad Bunny',
      );
    });

    test('se queda con el artista principal si hay invitados', () {
      expect(MetadataNormalizer.cleanArtist('WISIN feat. Yandel'), 'WISIN');
      expect(
        MetadataNormalizer.cleanArtist('J Balvin ft. Bad Bunny'),
        'J Balvin',
      );
      expect(
        MetadataNormalizer.cleanArtist('Bad Bunny x Jhay Cortez'),
        'Bad Bunny',
      );
      expect(
        MetadataNormalizer.cleanArtist('Rosalía featuring Nathy Peluso'),
        'Rosalía',
      );
    });

    test('respeta los "&" que son parte del nombre', () {
      expect(
        MetadataNormalizer.cleanArtist('Simon & Garfunkel'),
        'Simon & Garfunkel',
      );
      expect(MetadataNormalizer.cleanArtist('TV Girl'), 'TV Girl');
      expect(MetadataNormalizer.cleanArtist('Al-alpha'), 'Al-alpha');
      expect(MetadataNormalizer.cleanArtist('AC/DC'), 'AC/DC');
    });

    test('conserva el nombre tal cual si no hay nada que quitar', () {
      expect(
        MetadataNormalizer.cleanArtist('Rauw Alejandro'),
        'Rauw Alejandro',
      );
      expect(MetadataNormalizer.cleanArtist('ROSALÍA'), 'ROSALÍA');
      expect(MetadataNormalizer.cleanArtist('20'), '');
      expect(MetadataNormalizer.cleanArtist('Topic'), '');
      expect(MetadataNormalizer.cleanArtist('Vevo'), '');
      expect(MetadataNormalizer.cleanArtist(''), '');
    });

    test('featuredPart devuelve el invitado', () {
      expect(MetadataNormalizer.featuredPart('WISIN feat. Yandel'), 'Yandel');
      expect(
        MetadataNormalizer.featuredPart('WISIN featuring Yandel'),
        'Yandel',
      );
      expect(
        MetadataNormalizer.featuredPart('Bad Bunny x Jhay Cortez'),
        'Jhay Cortez',
      );
      expect(
        MetadataNormalizer.featuredPart('con Nathy Peluso'),
        'Nathy Peluso',
      );
      expect(
        MetadataNormalizer.featuredPart(
          'Camila Cabello - Havana ft. Young Thug',
        ),
        'Young Thug',
      );
      expect(MetadataNormalizer.featuredPart('Bad Bunny'), isNull);
      expect(MetadataNormalizer.featuredPart('Simon & Garfunkel'), isNull);
    });

    test('featuredInTags saca invitados de etiquetas del título', () {
      expect(
        MetadataNormalizer.featuredInTags(
          'Nube (con Nathy Peluso) (Official Video)',
        ),
        ['Nathy Peluso'],
      );
      expect(
        MetadataNormalizer.featuredInTags('Tití Me Preguntó (feat. Jhay)'),
        ['Jhay'],
      );
      expect(
        MetadataNormalizer.featuredInTags('Tití Me Preguntó (Official Video)'),
        isEmpty,
      );
    });
  });

  // =====================================================================
  group('looksLikeChannelName', () {
    test('detecta nombres de canal típicos', () {
      expect(
        MetadataNormalizer.looksLikeChannelName('Bad Bunny - Topic'),
        isTrue,
      );
      expect(MetadataNormalizer.looksLikeChannelName('WISIN VEVO'), isTrue);
      expect(
        MetadataNormalizer.looksLikeChannelName('KAROL G Oficial'),
        isTrue,
      );
      expect(
        MetadataNormalizer.looksLikeChannelName('Sony Music Records'),
        isTrue,
      );
      expect(MetadataNormalizer.looksLikeChannelName('Artista 2'), isTrue);
      expect(MetadataNormalizer.looksLikeChannelName('Official'), isTrue);
      expect(
        MetadataNormalizer.looksLikeChannelName('Canal De Música Oficial'),
        isTrue,
      );
      expect(MetadataNormalizer.looksLikeChannelName(''), isTrue);
      expect(MetadataNormalizer.looksLikeChannelName('Desconocido'), isTrue);
      expect(MetadataNormalizer.looksLikeChannelName('Unknown'), isTrue);
    });

    test('acepta artistas reales, incluso con & o guiones', () {
      expect(MetadataNormalizer.looksLikeChannelName('Bad Bunny'), isFalse);
      expect(MetadataNormalizer.looksLikeChannelName('AC/DC'), isFalse);
      expect(MetadataNormalizer.looksLikeChannelName('Jay-Z'), isFalse);
      expect(
        MetadataNormalizer.looksLikeChannelName('Simon & Garfunkel'),
        isFalse,
      );
      expect(
        MetadataNormalizer.looksLikeChannelName('Bad Bunny x Jhay Cortez'),
        isFalse,
      );
      expect(MetadataNormalizer.looksLikeChannelName('TV Girl'), isFalse);
      expect(
        MetadataNormalizer.looksLikeChannelName('Unknown Mortal Orchestra'),
        isFalse,
      );
    });
  });

  // =====================================================================
  group('splitArtistTitle', () {
    test('separa "Artista - Canción" con guiones legítimos dentro', () {
      expect(
        MetadataNormalizer.splitArtistTitle('AC/DC - Back In Black'),
        'AC/DC',
      );
      expect(
        MetadataNormalizer.splitArtistTitle('Jay-Z - Biggie Tyga'),
        'Jay-Z',
      );
      expect(
        MetadataNormalizer.splitArtistTitle('Al-alpha - Everything'),
        'Al-alpha',
      );
      expect(
        MetadataNormalizer.splitArtistTitle('Funkoars - The Real Deal'),
        'Funkoars',
      );
    });

    test('usa el separador que deja la derecha más limpia', () {
      expect(
        MetadataNormalizer.splitArtistTitle(
          'Jay-Z - Biggie Tyga - Jock Rockstar',
        ),
        'Jay-Z - Biggie Tyga',
      );
      expect(
        MetadataNormalizer.splitArtistTitle(
          'Sean Paul - Shakira - Hips Dont Lie',
        ),
        'Sean Paul - Shakira',
      );
    });

    test('rechaza que el artista sea un canal y retrocede', () {
      expect(
        MetadataNormalizer.splitArtistTitle(
          'Shakira - Bzrp Music Sessions, Vol. 53 - El Psy, El Autocontrol',
        ),
        'Shakira',
      );
      expect(MetadataNormalizer.splitArtistTitle('Song - Artista 2'), 'Song');
      expect(MetadataNormalizer.splitArtistTitle('Resaca (Letra)'), isNull);
    });

    test('acepta "Artista | Canción" y "Artista: Canción"', () {
      expect(
        MetadataNormalizer.splitArtistTitle(
          'Bad Bunny x Jhay Cortez | Pero Peach',
        ),
        'Bad Bunny x Jhay Cortez',
      );
      expect(
        MetadataNormalizer.splitArtistTitle(
          'Quevedo: BZRP Music Sessions, Vol. 52 - Resaca',
        ),
        'Quevedo',
      );
    });

    test('respeta el artista que ya conoce el reproductor', () {
      final split = MetadataNormalizer.splitTitle(
        'Bad Bunny - Tití Me Preguntó (Official Video)',
        knownArtist: 'Bad Bunny - Topic',
      );
      expect(split.artist, 'Bad Bunny');
      expect(split.title, 'Tití Me Preguntó (Official Video)');
      expect(split.hasSplit, isTrue);
    });

    test('splitTitle sin separador devuelve el título entero', () {
      final split = MetadataNormalizer.splitTitle('Song (Official Video)');
      expect(split.artist, isNull);
      expect(split.title, 'Song (Official Video)');
      expect(split.hasSplit, isFalse);
      expect(MetadataNormalizer.splitTitle('').title, '');
    });
  });

  // =====================================================================
  group('TitleCandidate', () {
    test('expone artista, confianza y clave de comparación', () {
      const a = TitleCandidate(
        artist: 'Bad Bunny',
        title: 'Tití',
        confidence: 100,
      );
      const b = TitleCandidate(
        artist: 'bad  bunny',
        title: 'titi!!!',
        confidence: 70,
      );
      expect(a.hasArtist, isTrue);
      expect(a.compareKey, b.compareKey);
      expect(a, isNot(b));
      expect(
        const TitleCandidate(artist: null, title: 'x', confidence: 1).hasArtist,
        isFalse,
      );
      expect(a.toString(), contains('Tití'));
    });
  });

  // =====================================================================
  group('candidates con casos reales', () {
    test('WISIN feat. Yandel - El PanAMEka (Official Video)', () {
      const track = TrackInfo(
        title: 'WISIN feat. Yandel - El PanAMEka (Official Video)',
        artist: 'WISIN',
      );
      expect(
        MetadataNormalizer.cleanTitle(track.title),
        'WISIN feat. Yandel - El PanAMEka',
      );
      expect(
        MetadataNormalizer.splitArtistTitle(track.title),
        'WISIN feat. Yandel',
      );
      expect(_fmts(n.candidates(track)), [
        '100|WISIN|El PanAMEka',
        '85|WISIN feat. Yandel|El PanAMEka',
        '80|WISIN & Yandel|El PanAMEka',
        '70|~|El PanAMEka',
        '65|WISIN|WISIN feat. Yandel - El PanAMEka (Official Video)',
        '40|~|WISIN feat. Yandel - El PanAMEka (Official Video)',
      ]);
    });

    test('KAROL G - PROVENZA (Official Video)', () {
      const track = TrackInfo(
        title: 'KAROL G - PROVENZA (Official Video)',
        artist: 'KAROL G',
      );
      expect(MetadataNormalizer.splitArtistTitle(track.title), 'KAROL G');
      expect(_fmts(n.candidates(track)), [
        '100|KAROL G|PROVENZA',
        '70|~|PROVENZA',
        '65|KAROL G|KAROL G - PROVENZA (Official Video)',
        '40|~|KAROL G - PROVENZA (Official Video)',
      ]);
    });

    test('Bad Bunny x Jhay Cortez | Pero Peach (LETRA) con separador "|"', () {
      const track = TrackInfo(
        title: 'Bad Bunny x Jhay Cortez | Pero Peach (LETRA)',
        artist: '',
      );
      expect(
        MetadataNormalizer.cleanTitle(track.title),
        'Bad Bunny x Jhay Cortez | Pero Peach',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Bad Bunny|Pero Peach',
        '85|Bad Bunny x Jhay Cortez|Pero Peach',
        '80|Bad Bunny & Jhay Cortez|Pero Peach',
        '70|~|Pero Peach',
        '65|Bad Bunny|Bad Bunny x Jhay Cortez | Pero Peach (LETRA)',
        '40|~|Bad Bunny x Jhay Cortez | Pero Peach (LETRA)',
      ]);
    });

    test('colaboración solo en el campo artista', () {
      const track = TrackInfo(
        title: 'Pero Peach (LETRA)',
        artist: 'Bad Bunny x Jhay Cortez',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Bad Bunny|Pero Peach',
        '80|Bad Bunny & Jhay Cortez|Pero Peach',
        '70|~|Pero Peach',
        '65|Bad Bunny|Pero Peach (LETRA)',
        '40|~|Pero Peach (LETRA)',
      ]);
    });

    test('Shakira - Bzrp Music Sessions, Vol. 53 - El Psy, El Autocontrol', () {
      const track = TrackInfo(
        title:
            'Shakira - Bzrp Music Sessions, Vol. 53 - El Psy, '
            'El Autocontrol (Español)',
        artist: 'Shakira',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Shakira|Bzrp Music Sessions, Vol. 53 - El Psy, El Autocontrol',
        '76|Shakira|El Psy, El Autocontrol',
        '70|~|Bzrp Music Sessions, Vol. 53 - El Psy, El Autocontrol',
        '65|Shakira|Shakira - Bzrp Music Sessions, Vol. 53 - El Psy, '
            'El Autocontrol (Español)',
        '40|~|Shakira - Bzrp Music Sessions, Vol. 53 - El Psy, '
            'El Autocontrol (Español)',
      ]);
    });

    test('Quevedo: BZRP Music Sessions, Vol. 52 - Resaca (Letra)', () {
      const track = TrackInfo(
        title: 'Quevedo: BZRP Music Sessions, Vol. 52 - Resaca (Letra)',
        artist: 'Quevedo',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Quevedo|BZRP Music Sessions, Vol. 52 - Resaca',
        '76|Quevedo|Resaca',
        '70|~|BZRP Music Sessions, Vol. 52 - Resaca',
        '65|Quevedo|Quevedo: BZRP Music Sessions, Vol. 52 - Resaca (Letra)',
        '40|~|Quevedo: BZRP Music Sessions, Vol. 52 - Resaca (Letra)',
      ]);
    });

    test('Ed Sheeran - Shape of You [Official Video]', () {
      const track = TrackInfo(
        title: 'Ed Sheeran - Shape of You [Official Video]',
        artist: 'Ed Sheeran',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Ed Sheeran|Shape of You',
        '70|~|Shape of You',
        '65|Ed Sheeran|Ed Sheeran - Shape of You [Official Video]',
        '40|~|Ed Sheeran - Shape of You [Official Video]',
      ]);
    });

    test('AC/DC - Back In Black (la barra no es separador)', () {
      const track = TrackInfo(title: 'AC/DC - Back In Black', artist: 'AC/DC');
      expect(
        MetadataNormalizer.cleanTitle(track.title),
        'AC/DC - Back In Black',
      );
      expect(_fmts(n.candidates(track)), [
        '100|AC/DC|Back In Black',
        '70|~|Back In Black',
        '65|AC/DC|AC/DC - Back In Black',
        '40|~|AC/DC - Back In Black',
      ]);
    });

    test('Jay-Z - Biggie Tyga - Jock Rockstar', () {
      const track = TrackInfo(
        title: 'Jay-Z - Biggie Tyga - Jock Rockstar',
        artist: 'Jay-Z',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Jay-Z|Jock Rockstar',
        '85|Jay-Z - Biggie Tyga|Jock Rockstar',
        '70|~|Jock Rockstar',
        '65|Jay-Z|Jay-Z - Biggie Tyga - Jock Rockstar',
        '40|~|Jay-Z - Biggie Tyga - Jock Rockstar',
      ]);
    });

    test("Taylor Swift - Style (Taylor's Version)", () {
      const track = TrackInfo(
        title: "Taylor Swift - Style (Taylor's Version)",
        artist: 'Taylor Swift',
      );
      expect(_fmts(n.candidates(track)), [
        "100|Taylor Swift|Style (Taylor's Version)",
        "70|~|Style (Taylor's Version)",
        "65|Taylor Swift|Taylor Swift - Style (Taylor's Version)",
        '60|~|Style',
        "40|~|Taylor Swift - Style (Taylor's Version)",
      ]);
    });

    test('a-ha - Take On Me (Official Music Video)', () {
      const track = TrackInfo(
        title: 'a-ha - Take On Me (Official Music Video)',
        artist: 'a-ha',
      );
      expect(_fmts(n.candidates(track)), [
        '100|a-ha|Take On Me',
        '70|~|Take On Me',
        '65|a-ha|a-ha - Take On Me (Official Music Video)',
        '40|~|a-ha - Take On Me (Official Music Video)',
      ]);
    });

    test('Rauw Alejandro - Todo De Ti (Video Oficial)', () {
      const track = TrackInfo(
        title: 'Rauw Alejandro - Todo De Ti (Video Oficial)',
        artist: 'Rauw Alejandro',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Rauw Alejandro|Todo De Ti',
        '70|~|Todo De Ti',
        '65|Rauw Alejandro|Rauw Alejandro - Todo De Ti (Video Oficial)',
        '40|~|Rauw Alejandro - Todo De Ti (Video Oficial)',
      ]);
    });

    test('Bad Bunny - Tití Me Preguntó con artista "Bad Bunny - Topic"', () {
      const track = TrackInfo(
        title: 'Bad Bunny - Tití Me Preguntó (Official Video)',
        artist: 'Bad Bunny - Topic',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Bad Bunny|Tití Me Preguntó',
        '90|Bad Bunny - Topic|Bad Bunny - Tití Me Preguntó (Official Video)',
        '70|~|Tití Me Preguntó',
        '65|Bad Bunny|Bad Bunny - Tití Me Preguntó (Official Video)',
        '40|~|Bad Bunny - Tití Me Preguntó (Official Video)',
      ]);
    });

    test('Camila Cabello - Havana ft. Young Thug', () {
      const track = TrackInfo(
        title: 'Camila Cabello - Havana ft. Young Thug',
        artist: 'Camila Cabello',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Camila Cabello|Havana ft. Young Thug',
        '80|Camila Cabello & Young Thug|Havana ft. Young Thug',
        '70|~|Havana ft. Young Thug',
        '65|Camila Cabello|Camila Cabello - Havana ft. Young Thug',
        '40|~|Camila Cabello - Havana ft. Young Thug',
      ]);
    });

    test('Don Omar - Dile (Official Video)', () {
      const track = TrackInfo(
        title: 'Don Omar - Dile (Official Video)',
        artist: 'Don Omar',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Don Omar|Dile',
        '70|~|Dile',
        '65|Don Omar|Don Omar - Dile (Official Video)',
        '40|~|Don Omar - Dile (Official Video)',
      ]);
    });

    test('Rosalía - MALIKITA (Official Video)', () {
      const track = TrackInfo(
        title: 'Rosalía - MALIKITA (Official Video)',
        artist: 'Rosalía',
      );
      expect(MetadataNormalizer.cleanArtist(track.artist), 'Rosalía');
      expect(_fmts(n.candidates(track)), [
        '100|Rosalía|MALIKITA',
        '70|~|MALIKITA',
        '65|Rosalía|Rosalía - MALIKITA (Official Video)',
        '40|~|Rosalía - MALIKITA (Official Video)',
      ]);
    });

    test('Myke Towers - LALA (Official Video)', () {
      const track = TrackInfo(
        title: 'Myke Towers - LALA (Official Video)',
        artist: 'Myke Towers',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Myke Towers|LALA',
        '70|~|LALA',
        '65|Myke Towers|Myke Towers - LALA (Official Video)',
        '40|~|Myke Towers - LALA (Official Video)',
      ]);
    });

    test('Metallica - Master Of Puppet (Official Music Video)', () {
      const track = TrackInfo(
        title: 'Metallica - Master Of Puppet (Official Music Video)',
        artist: 'Metallica',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Metallica|Master Of Puppet',
        '70|~|Master Of Puppet',
        '65|Metallica|Metallica - Master Of Puppet (Official Music Video)',
        '40|~|Metallica - Master Of Puppet (Official Music Video)',
      ]);
    });

    test('BTS - Dynamite (Official Video)', () {
      const track = TrackInfo(
        title: 'BTS - Dynamite (Official Video)',
        artist: 'BTS',
      );
      expect(_fmts(n.candidates(track)), [
        '100|BTS|Dynamite',
        '70|~|Dynamite',
        '65|BTS|BTS - Dynamite (Official Video)',
        '40|~|BTS - Dynamite (Official Video)',
      ]);
    });

    test('SZA - Kill Bill (Official Video)', () {
      const track = TrackInfo(
        title: 'SZA - Kill Bill (Official Video)',
        artist: 'SZA',
      );
      expect(_fmts(n.candidates(track)), [
        '100|SZA|Kill Bill',
        '70|~|Kill Bill',
        '65|SZA|SZA - Kill Bill (Official Video)',
        '40|~|SZA - Kill Bill (Official Video)',
      ]);
    });

    test('Feid - ATREVIDO (Official Video)', () {
      const track = TrackInfo(
        title: 'Feid - ATREVIDO (Official Video)',
        artist: 'Feid',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Feid|ATREVIDO',
        '70|~|ATREVIDO',
        '65|Feid|Feid - ATREVIDO (Official Video)',
        '40|~|Feid - ATREVIDO (Official Video)',
      ]);
    });

    test('Al-alpha - Everything (Official Audio)', () {
      const track = TrackInfo(
        title: 'Al-alpha - Everything (Official Audio)',
        artist: 'Al-alpha',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Al-alpha|Everything',
        '70|~|Everything',
        '65|Al-alpha|Al-alpha - Everything (Official Audio)',
        '40|~|Al-alpha - Everything (Official Audio)',
      ]);
    });

    test('Funkoars - The Real Deal sin artista en la pista', () {
      const track = TrackInfo(
        title: 'Funkoars - The Real Deal (Original Mix)',
        artist: '',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Funkoars|The Real Deal (Original Mix)',
        '70|~|The Real Deal (Original Mix)',
        '65|Funkoars|Funkoars - The Real Deal (Original Mix)',
        '60|~|The Real Deal',
        '40|~|Funkoars - The Real Deal (Original Mix)',
      ]);
    });

    test('artista "" y título imposible: nunca inventa artista', () {
      const track = TrackInfo(
        title: 'Vandalize (Official Music Video)',
        artist: '',
      );
      final cands = n.candidates(track);
      expect(_fmts(cands), [
        '70|~|Vandalize',
        '40|~|Vandalize (Official Music Video)',
      ]);
      expect(cands.every((c) => c.artist == null), isTrue);
    });

    test('usa el álbum para deducir el artista si el campo no vale', () {
      const track = TrackInfo(
        title: 'Desconocido',
        artist: '',
        album: 'Quevedo - Resaca',
      );
      expect(_fmts(n.candidates(track)), [
        '70|~|Desconocido',
        '68|Quevedo|Desconocido',
      ]);
    });

    test('artista "Bad Bunny - Topic" sin artista en el título: tope 70', () {
      const track = TrackInfo(
        title: 'Tití Me Preguntó (Official Video)',
        artist: 'Bad Bunny - Topic',
      );
      expect(_fmts(n.candidates(track)), [
        '70|~|Tití Me Preguntó',
        '55|Bad Bunny|Tití Me Preguntó',
        '40|~|Tití Me Preguntó (Official Video)',
      ]);
    });

    test('artista VEVO: limpieza a confianza baja', () {
      const track = TrackInfo(
        title: 'Shape of You (Official Video)',
        artist: 'Ed Sheeran VEVO',
      );
      expect(_fmts(n.candidates(track)), [
        '70|~|Shape of You',
        '55|Ed Sheeran|Shape of You',
        '40|~|Shape of You (Official Video)',
      ]);
    });

    test('Alan Walker - Faded (Official Audio) [HD]', () {
      const track = TrackInfo(
        title: 'Alan Walker - Faded (Official Audio) [HD]',
        artist: 'Alan Walker',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Alan Walker|Faded',
        '70|~|Faded',
        '65|Alan Walker|Alan Walker - Faded (Official Audio) [HD]',
        '40|~|Alan Walker - Faded (Official Audio) [HD]',
      ]);
    });

    test('Ed Sheeran - Shape of You (Radio Edit) conserva la edición', () {
      const track = TrackInfo(
        title: 'Ed Sheeran - Shape of You (Radio Edit)',
        artist: 'Ed Sheeran',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Ed Sheeran|Shape of You (Radio Edit)',
        '70|~|Shape of You (Radio Edit)',
        '65|Ed Sheeran|Ed Sheeran - Shape of You (Radio Edit)',
        '60|~|Shape of You',
        '40|~|Ed Sheeran - Shape of You (Radio Edit)',
      ]);
    });

    test('EMINEM - Lose Yourself (Official Music Video) en mayúsculas', () {
      const track = TrackInfo(
        title: 'EMINEM - Lose Yourself (Official Music Video)',
        artist: 'Eminem',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Eminem|Lose Yourself',
        '70|~|Lose Yourself',
        '65|Eminem|EMINEM - Lose Yourself (Official Music Video)',
        '40|~|EMINEM - Lose Yourself (Official Music Video)',
      ]);
    });

    test("Snoop Dogg - Who Am I (What's My Name)? (Official Video)", () {
      const track = TrackInfo(
        title: "Snoop Dogg - Who Am I (What's My Name)? (Official Video)",
        artist: 'Snoop Dogg',
      );
      expect(
        MetadataNormalizer.cleanTitle(
          "Who Am I (What's My Name)? (Official Video)",
        ),
        'Who Am I?',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Snoop Dogg|Who Am I?',
        '70|~|Who Am I?',
        "65|Snoop Dogg|Snoop Dogg - Who Am I (What's My Name)? (Official Video)",
        "40|~|Snoop Dogg - Who Am I (What's My Name)? (Official Video)",
      ]);
    });

    test('The Weeknd - Blinding Lights 4K', () {
      const track = TrackInfo(
        title: 'The Weeknd - Blinding Lights 4K',
        artist: 'The Weeknd',
      );
      expect(_fmts(n.candidates(track)), [
        '100|The Weeknd|Blinding Lights',
        '70|~|Blinding Lights',
        '65|The Weeknd|The Weeknd - Blinding Lights 4K',
        '40|~|The Weeknd - Blinding Lights 4K',
      ]);
    });

    test('Nathy Peluso - Bzrp Music Sessions Vol. 42 - Todo De Ti', () {
      const track = TrackInfo(
        title:
            'Nathy Peluso - Bzrp Music Sessions Vol. 42 - Todo De Ti '
            '(Letra Oficial)',
        artist: 'Nathy Peluso',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Nathy Peluso|Bzrp Music Sessions Vol. 42 - Todo De Ti',
        '76|Nathy Peluso|Todo De Ti',
        '70|~|Bzrp Music Sessions Vol. 42 - Todo De Ti',
        '65|Nathy Peluso|Nathy Peluso - Bzrp Music Sessions Vol. 42 - '
            'Todo De Ti (Letra Oficial)',
        '40|~|Nathy Peluso - Bzrp Music Sessions Vol. 42 - Todo De Ti '
            '(Letra Oficial)',
      ]);
    });

    test('Toto - Africa (Remastered 2011)', () {
      const track = TrackInfo(
        title: 'Toto - Africa (Remastered 2011)',
        artist: 'Toto',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Toto|Africa',
        '70|~|Africa',
        '65|Toto|Toto - Africa (Remastered 2011)',
        '40|~|Toto - Africa (Remastered 2011)',
      ]);
    });

    test('Beyoncé - Halo (Official Video) [4K]', () {
      const track = TrackInfo(
        title: 'Beyoncé - Halo (Official Video) [4K]',
        artist: 'Beyoncé',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Beyoncé|Halo',
        '70|~|Halo',
        '65|Beyoncé|Beyoncé - Halo (Official Video) [4K]',
        '40|~|Beyoncé - Halo (Official Video) [4K]',
      ]);
    });

    test('Queen - Bohemian Rhapsody (Official Video) (Live)', () {
      const track = TrackInfo(
        title: 'Queen - Bohemian Rhapsody (Official Video) (Live)',
        artist: 'Queen',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Queen|Bohemian Rhapsody (Live)',
        '70|~|Bohemian Rhapsody (Live)',
        '65|Queen|Queen - Bohemian Rhapsody (Official Video) (Live)',
        '60|~|Bohemian Rhapsody',
        '40|~|Queen - Bohemian Rhapsody (Official Video) (Live)',
      ]);
    });

    test('Sean Paul - Shakira - Hips Dont Lie (dos guiones)', () {
      const track = TrackInfo(
        title: 'Sean Paul - Shakira - Hips Dont Lie',
        artist: 'Sean Paul',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Sean Paul|Hips Dont Lie',
        '85|Sean Paul - Shakira|Hips Dont Lie',
        '70|~|Hips Dont Lie',
        '65|Sean Paul|Sean Paul - Shakira - Hips Dont Lie',
        '40|~|Sean Paul - Shakira - Hips Dont Lie',
      ]);
    });

    test('Simon & Garfunkel sin separador no genera candidatos extra', () {
      const track = TrackInfo(
        title: 'Bridge Over Troubled Water',
        artist: 'Simon & Garfunkel',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Simon & Garfunkel|Bridge Over Troubled Water',
        '70|~|Bridge Over Troubled Water',
      ]);
    });

    test('Morat - La stereotypical (Oficial)', () {
      const track = TrackInfo(
        title: 'Morat - La stereotypical (Oficial)',
        artist: 'Morat',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Morat|La stereotypical',
        '70|~|La stereotypical',
        '65|Morat|Morat - La stereotypical (Oficial)',
        '40|~|Morat - La stereotypical (Oficial)',
      ]);
    });

    test('Quevedo - Resaca (Letra Oficial) [HD] sin campo artista', () {
      const track = TrackInfo(
        title: 'Quevedo - Resaca (Letra Oficial) [HD]',
        artist: '',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Quevedo|Resaca',
        '70|~|Resaca',
        '65|Quevedo|Quevedo - Resaca (Letra Oficial) [HD]',
        '40|~|Quevedo - Resaca (Letra Oficial) [HD]',
      ]);
    });

    test('J Balvin - Tiara ft. Tyga', () {
      const track = TrackInfo(
        title: 'J Balvin - Tiara ft. Tyga',
        artist: 'J Balvin',
      );
      expect(_fmts(n.candidates(track)), [
        '100|J Balvin|Tiara ft. Tyga',
        '80|J Balvin & Tyga|Tiara ft. Tyga',
        '70|~|Tiara ft. Tyga',
        '65|J Balvin|J Balvin - Tiara ft. Tyga',
        '40|~|J Balvin - Tiara ft. Tyga',
      ]);
    });

    test('Billie Eilish - Ocean Eyes (Lyrics)', () {
      const track = TrackInfo(
        title: 'Billie Eilish - Ocean Eyes (Lyrics)',
        artist: 'Billie Eilish',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Billie Eilish|Ocean Eyes',
        '70|~|Ocean Eyes',
        '65|Billie Eilish|Billie Eilish - Ocean Eyes (Lyrics)',
        '40|~|Billie Eilish - Ocean Eyes (Lyrics)',
      ]);
    });

    test('título entero en mayúsculas', () {
      const track = TrackInfo(
        title: 'BAD BUNNY - TITI ME PREGUNTO (OFFICIAL VIDEO)',
        artist: 'BAD BUNNY',
      );
      expect(_fmts(n.candidates(track)), [
        '100|BAD BUNNY|TITI ME PREGUNTO',
        '70|~|TITI ME PREGUNTO',
        '65|BAD BUNNY|BAD BUNNY - TITI ME PREGUNTO (OFFICIAL VIDEO)',
        '40|~|BAD BUNNY - TITI ME PREGUNTO (OFFICIAL VIDEO)',
      ]);
    });

    test('invitado en español dentro de paréntesis: "(con Nathy Peluso)"', () {
      const track = TrackInfo(
        title: 'Bizarrap - Nube (con Nathy Peluso) (Official Video)',
        artist: '',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Bizarrap|Nube',
        '80|Bizarrap & Nathy Peluso|Nube',
        '70|~|Nube',
        '65|Bizarrap|Bizarrap - Nube (con Nathy Peluso) (Official Video)',
        '40|~|Bizarrap - Nube (con Nathy Peluso) (Official Video)',
      ]);
    });

    test('cancelled candidate: artista del título con sufijo de canal', () {
      const track = TrackInfo(
        title: 'Estúpido Cupido (Video Oficial)',
        artist: 'Grupo Firme',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Grupo Firme|Estúpido Cupido',
        '70|~|Estúpido Cupido',
        '65|Grupo Firme|Estúpido Cupido (Video Oficial)',
        '40|~|Estúpido Cupido (Video Oficial)',
      ]);
    });

    test('Unknown Mortal Orchestra no se descarta por "Unknown"', () {
      const track = TrackInfo(
        title: 'XBtar',
        artist: 'Unknown Mortal Orchestra',
      );
      expect(_fmts(n.candidates(track)), [
        '100|Unknown Mortal Orchestra|XBtar',
        '70|~|XBtar',
      ]);
    });

    test('canal con más de 4 palabras tampoco se usa como artista', () {
      const track = TrackInfo(
        title: 'Tití Me Preguntó',
        artist: 'Sony Music Entertainment Colombia',
      );
      final cands = n.candidates(track);
      expect(cands.first.confidence, 70);
      expect(cands.first.artist, isNull);
      expect(cands.last.confidence, lessThanOrEqualTo(70));
    });

    test(
      'artista del título con más palabras que el campo del reproductor',
      () {
        const track = TrackInfo(
          title: 'Frankie Sounds - Ocean Drive',
          artist: 'Frankie',
        );
        expect(_fmts(n.candidates(track)), [
          '100|Frankie|Ocean Drive',
          '85|Frankie Sounds|Ocean Drive',
          '70|~|Ocean Drive',
          '65|Frankie|Frankie Sounds - Ocean Drive',
          '40|~|Frankie Sounds - Ocean Drive',
        ]);
      },
    );
  });

  // =====================================================================
  group('invariantes sobre casos reales', () {
    const pistas = <TrackInfo>[
      TrackInfo(
        title: 'WISIN feat. Yandel - El PanAMEka (Official Video)',
        artist: 'WISIN',
      ),
      TrackInfo(
        title: 'KAROL G - PROVENZA (Official Video)',
        artist: 'KAROL G',
      ),
      TrackInfo(
        title: 'Bad Bunny x Jhay Cortez | Pero Peach (LETRA)',
        artist: '',
      ),
      TrackInfo(title: 'Pero Peach (LETRA)', artist: 'Bad Bunny x Jhay Cortez'),
      TrackInfo(
        title:
            'Shakira - Bzrp Music Sessions, Vol. 53 - El Psy, El Autocontrol (Español)',
        artist: 'Shakira',
      ),
      TrackInfo(
        title: 'Quevedo: BZRP Music Sessions, Vol. 52 - Resaca (Letra)',
        artist: 'Quevedo',
      ),
      TrackInfo(
        title: 'Ed Sheeran - Shape of You [Official Video]',
        artist: 'Ed Sheeran',
      ),
      TrackInfo(title: 'AC/DC - Back In Black', artist: 'AC/DC'),
      TrackInfo(title: 'Jay-Z - Biggie Tyga - Jock Rockstar', artist: 'Jay-Z'),
      TrackInfo(
        title: "Taylor Swift - Style (Taylor's Version)",
        artist: 'Taylor Swift',
      ),
      TrackInfo(
        title: 'a-ha - Take On Me (Official Music Video)',
        artist: 'a-ha',
      ),
      TrackInfo(
        title: 'Rauw Alejandro - Todo De Ti (Video Oficial)',
        artist: 'Rauw Alejandro',
      ),
      TrackInfo(
        title: 'Bad Bunny - Tití Me Preguntó (Official Video)',
        artist: 'Bad Bunny - Topic',
      ),
      TrackInfo(
        title: 'Tití Me Preguntó (Official Video)',
        artist: 'Bad Bunny - Topic',
      ),
      TrackInfo(
        title: 'Camila Cabello - Havana ft. Young Thug',
        artist: 'Camila Cabello',
      ),
      TrackInfo(title: 'Don Omar - Dile (Official Video)', artist: 'Don Omar'),
      TrackInfo(
        title: 'Rosalía - MALIKITA (Official Video)',
        artist: 'Rosalía',
      ),
      TrackInfo(
        title: 'Myke Towers - LALA (Official Video)',
        artist: 'Myke Towers',
      ),
      TrackInfo(
        title: 'Metallica - Master Of Puppet (Official Music Video)',
        artist: 'Metallica',
      ),
      TrackInfo(title: 'BTS - Dynamite (Official Video)', artist: 'BTS'),
      TrackInfo(title: 'SZA - Kill Bill (Official Video)', artist: 'SZA'),
      TrackInfo(title: 'Feid - ATREVIDO (Official Video)', artist: 'Feid'),
      TrackInfo(
        title: 'Al-alpha - Everything (Official Audio)',
        artist: 'Al-alpha',
      ),
      TrackInfo(title: 'Funkoars - The Real Deal (Original Mix)', artist: ''),
      TrackInfo(title: 'Vandalize (Official Music Video)', artist: ''),
      TrackInfo(title: 'Desconocido', artist: '', album: 'Quevedo - Resaca'),
      TrackInfo(
        title: 'Alan Walker - Faded (Official Audio) [HD]',
        artist: 'Alan Walker',
      ),
      TrackInfo(
        title: 'Ed Sheeran - Shape of You (Radio Edit)',
        artist: 'Ed Sheeran',
      ),
      TrackInfo(
        title: 'EMINEM - Lose Yourself (Official Music Video)',
        artist: 'Eminem',
      ),
      TrackInfo(
        title: "Snoop Dogg - Who Am I (What's My Name)? (Official Video)",
        artist: 'Snoop Dogg',
      ),
      TrackInfo(title: 'The Weeknd - Blinding Lights 4K', artist: 'The Weeknd'),
      TrackInfo(
        title:
            'Nathy Peluso - Bzrp Music Sessions Vol. 42 - Todo De Ti (Letra Oficial)',
        artist: 'Nathy Peluso',
      ),
      TrackInfo(title: 'Toto - Africa (Remastered 2011)', artist: 'Toto'),
      TrackInfo(
        title: 'Beyoncé - Halo (Official Video) [4K]',
        artist: 'Beyoncé',
      ),
      TrackInfo(
        title: 'Queen - Bohemian Rhapsody (Official Video) (Live)',
        artist: 'Queen',
      ),
      TrackInfo(
        title: 'Sean Paul - Shakira - Hips Dont Lie',
        artist: 'Sean Paul',
      ),
      TrackInfo(
        title: 'Bridge Over Troubled Water',
        artist: 'Simon & Garfunkel',
      ),
      TrackInfo(title: 'Morat - La típica (Oficial)', artist: 'Morat'),
      TrackInfo(title: 'Quevedo - Resaca (Letra Oficial) [HD]', artist: ''),
      TrackInfo(title: 'J Balvin - Tiara ft. Tyga', artist: 'J Balvin'),
      TrackInfo(
        title: 'Billie Eilish - Ocean Eyes (Lyrics)',
        artist: 'Billie Eilish',
      ),
      TrackInfo(
        title: 'BAD BUNNY - TITI ME PREGUNTO (OFFICIAL VIDEO)',
        artist: 'BAD BUNNY',
      ),
      TrackInfo(
        title: 'Bizarrap - Nube (con Nathy Peluso) (Official Video)',
        artist: '',
      ),
      TrackInfo(
        title: 'Estúpido Cupido (Video Oficial)',
        artist: 'Grupo Firme',
      ),
      TrackInfo(title: 'XBtar', artist: 'Unknown Mortal Orchestra'),
      TrackInfo(
        title: 'Tití Me Preguntó',
        artist: 'Sony Music Entertainment Colombia',
      ),
      TrackInfo(title: 'Frankie Sounds - Ocean Drive', artist: 'Frankie'),
      TrackInfo(
        title: 'Shape of You (Official Video)',
        artist: 'Ed Sheeran VEVO',
      ),
    ];

    test('no hay candidatos duplicados (par artista+título normalizado)', () {
      for (final track in pistas) {
        final keys = n.candidates(track).map((c) => c.compareKey).toList();
        expect(
          keys.toSet().length,
          keys.length,
          reason: 'duplicados en "${track.title}" / "${track.artist}"',
        );
      }
    });

    test('las confianzas van siempre de mayor a menor', () {
      for (final track in pistas) {
        final cands = n.candidates(track);
        for (var i = 1; i < cands.length; i++) {
          expect(
            cands[i].confidence,
            lessThanOrEqualTo(cands[i - 1].confidence),
            reason: 'orden roto en "${track.title}"',
          );
        }
      }
    });

    test('todo candidato tiene título no vacío y confianza 0..100', () {
      for (final track in pistas) {
        for (final c in n.candidates(track)) {
          expect(c.title.trim(), isNotEmpty, reason: track.title);
          expect(c.confidence, inInclusiveRange(0, 100));
        }
      }
    });

    test('sin artista fiable el máximo es 70 y no hay artista inventado', () {
      for (final track in pistas) {
        final fromTitle = MetadataNormalizer.splitArtistTitle(
          track.title,
          knownArtist: track.artist,
        );
        final hayArtista =
            MetadataNormalizer.isReliableArtist(track.artist) ||
            (fromTitle != null &&
                MetadataNormalizer.isReliableArtist(fromTitle));
        if (hayArtista) continue;
        for (final c in n.candidates(track)) {
          expect(
            c.confidence,
            lessThanOrEqualTo(70),
            reason: 'demasiada confianza sin artista: "${track.title}"',
          );
          final a = c.artist;
          if (c.confidence > 68 && a != null) {
            expect(
              MetadataNormalizer.isReliableArtist(a),
              isTrue,
              reason: 'artista no fiable con confianza alta: "${track.title}"',
            );
          }
        }
      }
    });

    test('el primer candidato es el de mayor confianza y nunca está vacío', () {
      for (final track in pistas) {
        final cands = n.candidates(track);
        expect(cands, isNotEmpty, reason: 'sin candidatos: "${track.title}"');
        final confianzaMax = cands
            .map((c) => c.confidence)
            .reduce((a, b) => a > b ? a : b);
        expect(cands.first.confidence, confianzaMax);
      }
    });

    test('el título limpio siempre aparece entre los candidatos', () {
      for (final track in pistas) {
        final limpio = MetadataNormalizer.cleanTitle(track.title);
        if (limpio.isEmpty) continue;
        final hay = n
            .candidates(track)
            .any((c) => c.title.contains(limpio) || limpio.contains(c.title));
        expect(
          hay,
          isTrue,
          reason:
              'no aparece el título limpio de '
              '"${track.title}"',
        );
      }
    });
  });
}
