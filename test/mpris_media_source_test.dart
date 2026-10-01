import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lylyrics/core/models/playback_state.dart';
import 'package:lylyrics/platform/linux/mpris_media_source.dart';

/// Metadata real de un reproductor Chromium (FreeTube), ya deserializado tal y
/// como lo devuelve `DBusValue.toNative()`: `DBusArray.toNative()` produce un
/// `Iterable`, no una `List`, así que lo dejamos así a propósito.
Map<String, dynamic> chromiumMetadata({String? title = 'Blinding Lights'}) {
  return <String, dynamic>{
    'mpris:artUrl': 'file:///tmp/cover.png',
    'mpris:length': 200040000,
    'mpris:trackid': '/org/chromium/MediaPlayer2/TrackList/TrackABCD',
    'xesam:album': 'After Hours',
    'xesam:artist': <String>['The Weeknd'],
    if (title != null) 'xesam:title': title,
    'xesam:url': 'https://youtu.be/4NRXx6U8ABQ',
  };
}

void main() {
  group('trackInfoFromRaw', () {
    test('une varios artistas con comas y conserva álbum, duración y app', () {
      final track = trackInfoFromRaw(
        title: 'Blinding Lights',
        artists: const <String>['The Weeknd', 'Malayalam', 'The Weeknd'],
        album: 'After Hours',
        lengthMicros: 200040000,
        app: 'org.mpris.MediaPlayer2.chromium.instance2934',
      );

      expect(track, isNotNull);
      // El artista duplicado se descarta (sin duplicados en la clave de caché).
      expect(track!.artist, 'The Weeknd, Malayalam');
      expect(track.title, 'Blinding Lights');
      expect(track.album, 'After Hours');
      expect(track.duration, const Duration(microseconds: 200040000));
      expect(track.sourceApp, 'org.mpris.MediaPlayer2.chromium.instance2934');
    });

    test('sin título pero con artista usa el artista como título', () {
      final track = trackInfoFromRaw(
        artists: const <String>['Daft Punk'],
        lengthMicros: 1000000,
      );
      expect(track?.title, 'Daft Punk');
      expect(track?.artist, 'Daft Punk');
    });

    test('sin título ni artistas devuelve null', () {
      expect(trackInfoFromRaw(), isNull);
      expect(trackInfoFromRaw(title: '   ', artists: const <String>[]), isNull);
      expect(trackInfoFromRaw(title: '', artists: const <String>['  ']), isNull);
    });

    test('duración cero o negativa se trata como desconocida (spec MPRIS)', () {
      expect(trackInfoFromRaw(title: 'A', lengthMicros: 0)?.duration, isNull);
      expect(trackInfoFromRaw(title: 'A', lengthMicros: -1)?.duration, isNull);
      expect(trackInfoFromRaw(title: 'A')?.duration, isNull);
    });

    test('limpia espacios sueltos en álbum y app', () {
      final track = trackInfoFromRaw(
        title: '  Blinding Lights  ',
        artists: const <String>['  The Weeknd '],
        album: '   After Hours ',
        app: ' org.mpris.MediaPlayer2.freetube ',
      );
      expect(track?.title, 'Blinding Lights');
      expect(track?.artist, 'The Weeknd');
      expect(track?.album, 'After Hours');
      expect(track?.sourceApp, 'org.mpris.MediaPlayer2.freetube');
    });
  });

  group('trackInfoFromMetadata', () {
    test('convierte un dict sucio de Metadata en TrackInfo', () {
      final track = trackInfoFromMetadata(
        chromiumMetadata(),
        app: 'org.mpris.MediaPlayer2.chromium.instance2934',
      );

      expect(track, isNotNull);
      expect(track!.title, 'Blinding Lights');
      expect(track.artist, 'The Weeknd');
      expect(track.album, 'After Hours');
      expect(track.duration, const Duration(seconds: 200, milliseconds: 40));
      expect(track.sourceApp, 'org.mpris.MediaPlayer2.chromium.instance2934');
    });

    test('acepta el Iterable que produce DBusArray.toNative()', () {
      final metadata = <String, dynamic>{
        'xesam:title': 'Relearn',
        // Iterable, no List: es lo que devuelve el array `as` de dbus.
        'xesam:artist': <String>['Loathe', 'Various'].map((e) => e).toList().map((e) => '$e '),
        'mpris:length': 240000000,
      };
      final track = trackInfoFromMetadata(metadata);
      expect(track?.artist, 'Loathe, Various');
      expect(track?.duration, const Duration(minutes: 4));
    });

    test('metadata vacía o sin título devuelve null', () {
      expect(trackInfoFromMetadata(const <String, dynamic>{}), isNull);
      expect(
        trackInfoFromMetadata(<String, dynamic>{
          'mpris:length': 1000,
          'xesam:album': 'After Hours',
        }),
        isNull,
      );
      expect(
        trackInfoFromMetadata(<String, dynamic>{'xesam:title': '   '}),
        isNull,
      );
    });
  });

  group('posición en microsegundos', () {
    test('positionFromMicros recorta nulos, ceros y negativos', () {
      expect(positionFromMicros(null), Duration.zero);
      expect(positionFromMicros(0), Duration.zero);
      expect(positionFromMicros(-42), Duration.zero);
    });

    test('positionFromMicros convierte bien los valores positivos', () {
      expect(positionFromMicros(1), const Duration(microseconds: 1));
      expect(positionFromMicros(200040000),
          const Duration(microseconds: 200040000));
      expect(positionFromMicros(3600000000), const Duration(hours: 1));
    });

    test('clampPosition acota a [0, duración]', () {
      expect(clampPosition(const Duration(seconds: -3), const Duration(minutes: 1)),
          Duration.zero);
      expect(
        clampPosition(const Duration(minutes: 9), const Duration(minutes: 3)),
        const Duration(minutes: 3),
      );
      // Sin duración conocida no se toca nada.
      expect(clampPosition(const Duration(minutes: 9), null),
          const Duration(minutes: 9));
      // Duración cero o negativa = desconocida, tampoco acota.
      expect(clampPosition(const Duration(minutes: 9), Duration.zero),
          const Duration(minutes: 9));
    });

    test('interpolatePosition extrapola solo si está reproduciendo', () {
      final timestamp = DateTime(2026, 1, 1, 12);
      final now = timestamp.add(const Duration(seconds: 10));

      expect(
        interpolatePosition(
          now: now,
          position: const Duration(seconds: 30),
          timestamp: timestamp,
          rate: 1.0,
          isPlaying: true,
        ),
        const Duration(seconds: 40),
      );
      // A doble velocidad avanza el doble.
      expect(
        interpolatePosition(
          now: now,
          position: const Duration(seconds: 30),
          timestamp: timestamp,
          rate: 2.0,
          isPlaying: true,
        ),
        const Duration(seconds: 50),
      );
      // En pausa la posición se queda donde estaba.
      expect(
        interpolatePosition(
          now: now,
          position: const Duration(seconds: 30),
          timestamp: timestamp,
          rate: 1.0,
          isPlaying: false,
        ),
        const Duration(seconds: 30),
      );
      // Un reloj que ha ido hacia atrás no mueve la posición.
      expect(
        interpolatePosition(
          now: timestamp.subtract(const Duration(seconds: 5)),
          position: const Duration(seconds: 30),
          timestamp: timestamp,
          rate: 1.0,
          isPlaying: true,
        ),
        const Duration(seconds: 30),
      );
      // Rate no finito (NaN) se trata como 1.0 en lugar de romper.
      expect(
        interpolatePosition(
          now: now,
          position: Duration.zero,
          timestamp: timestamp,
          rate: double.nan,
          isPlaying: true,
        ),
        const Duration(seconds: 10),
      );
    });
  });

  group('detección de cambio de canción', () {
    test('normalizeTitle colapsa mayúsculas y espacios', () {
      expect(normalizeTitle('  Blinding   LIGHTS '), 'blinding lights');
      expect(normalizeTitle('   '), isNull);
      expect(normalizeTitle(null), isNull);
    });

    test('trackKeyFromRaw combina trackid y título', () {
      expect(
        trackKeyFromRaw(
          trackId: '/org/mpris/MediaPlayer2/spotify/track/4',
          title: 'Blinding Lights',
        ),
        '/org/mpris/MediaPlayer2/spotify/track/4|blinding lights',
      );
    });

    test('trackKeyFromRaw descarta los trackid centinela', () {
      expect(trackKeyFromRaw(trackId: '/', title: 'Blinding Lights'),
          'blinding lights');
      expect(
        trackKeyFromRaw(
          trackId: '/org/mpris/MediaPlayer2/TrackList/NoTrack',
          title: 'Blinding Lights',
        ),
        'blinding lights',
      );
      expect(trackKeyFromRaw(trackId: '  ', title: 'Blinding Lights'),
          'blinding lights');
    });

    test('trackKeyFromRaw con title en minúsculas es la misma clave', () {
      final a = trackKeyFromRaw(
          trackId: '/track/1', title: 'Blinding Lights');
      final b = trackKeyFromRaw(trackId: '/track/1', title: 'BLINDING LIGHTS');
      expect(a, b);
    });

    test('trackKeyFromRaw sin nada utilizable devuelve null', () {
      expect(trackKeyFromRaw(), isNull);
      expect(trackKeyFromRaw(trackId: '/', title: '  '), isNull);
    });

    test('trackKeyChanged detecta cambios reales y descarta duplicados', () {
      const id = '/track/1';
      final key = trackKeyFromRaw(trackId: id, title: 'Blinding Lights');

      // Misma canción, mismo trackid: no hay cambio.
      expect(
        trackKeyChanged(
          previous: key,
          next: trackKeyFromRaw(trackId: id, title: 'blinding lights'),
        ),
        isFalse,
      );
      // Sigue sonando la misma canción: repetimos clave, no se emite nada.
      expect(trackKeyChanged(previous: key, next: key), isFalse);
      // null -> null tampoco es cambio (evita riegos de null en bucle).
      expect(trackKeyChanged(), isFalse);
      // Cambio real de pista.
      expect(
        trackKeyChanged(
          previous: key,
          next: trackKeyFromRaw(trackId: '/track/2', title: 'Save Your Tears'),
        ),
        isTrue,
      );
      // Mismo trackid pero distinto título (algunos reproductores lo reutilizan).
      expect(
        trackKeyChanged(
          previous: key,
          next: trackKeyFromRaw(trackId: id, title: 'Save Your Tears'),
        ),
        isTrue,
      );
      // Pista -> nada y nada -> pista.
      expect(trackKeyChanged(previous: key, next: null), isTrue);
      expect(trackKeyChanged(previous: null, next: key), isTrue);
    });
  });

  group('puntuación de reproductores', () {
    test('FreeTube gana a un chromium genérico', () {
      final freeTube = mprisPlayerScore(
        busName: 'org.mpris.MediaPlayer2.chromium.instance2934',
        identity: 'FreeTube',
        desktopEntry: 'freetube',
      );
      final chromium = mprisPlayerScore(
        busName: 'org.mpris.MediaPlayer2.chromium.instance1234',
        identity: 'Chromium',
      );
      final desconocido = mprisPlayerScore(
        busName: 'org.mpris.MediaPlayer2.instance7',
      );

      expect(freeTube, greaterThan(chromium));
      expect(chromium, greaterThan(desconocido));
      expect(freeTube, greaterThan(1000 - 1));
    });

    test('detecta FreeTube por cualquiera de las pistas', () {
      final porBusName = mprisPlayerScore(
          busName: 'org.mpris.MediaPlayer2.freetube');
      final porIdentity = mprisPlayerScore(
          busName: 'org.mpris.MediaPlayer2.kdeconnect', identity: 'free tube');
      final porDesktop = mprisPlayerScore(
          busName: 'org.mpris.MediaPlayer2.chrome',
          desktopEntry: 'FreeTube');
      final porPista = mprisPlayerScore(
          busName: 'org.mpris.MediaPlayer2.chrome', hints: const ['Class=FreeTube']);

      expect(porBusName, 1000);
      expect(porIdentity, 1000);
      expect(porDesktop, 1000);
      expect(porPista, 1000);
    });

    test('un reproductor conocido vale más que uno desconocido', () {
      final vlc = mprisPlayerScore(
          busName: 'org.mpris.MediaPlayer2.vlc', identity: 'VLC media player');
      final desconocido = mprisPlayerScore(busName: 'org.mpris.MediaPlayer2.xyz');
      expect(vlc, greaterThan(desconocido));
      expect(mprisPlayerScore(busName: 'org.mpris.MediaPlayer2.xyz'), 0);
    });
  });

  group('selección de reproductor', () {
    final players = <String, MprisPlayerInfo>{
      'org.mpris.MediaPlayer2.vlc':
          MprisPlayerInfo.probed(busName: 'org.mpris.MediaPlayer2.vlc',
              identity: 'VLC'),
      'org.mpris.MediaPlayer2.chromium.instance2934': MprisPlayerInfo.probed(
          busName: 'org.mpris.MediaPlayer2.chromium.instance2934',
          identity: 'FreeTube',
          status: PlaybackStatus.playing),
      'org.mpris.MediaPlayer2.playerctld': MprisPlayerInfo.probed(
          busName: 'org.mpris.MediaPlayer2.playerctld',
          identity: 'unknown',
          status: PlaybackStatus.playing),
    };

    test('con varios reproduciendo gana el de mayor puntuación', () {
      expect(
        selectBestPlayer(players: players),
        'org.mpris.MediaPlayer2.chromium.instance2934',
      );
    });

    test('si nada está reproduciendo gana el de mayor puntuación', () {
      final parados = <String, MprisPlayerInfo>{
        'org.mpris.MediaPlayer2.vlc':
            MprisPlayerInfo.probed(busName: 'org.mpris.MediaPlayer2.vlc'),
        'org.mpris.MediaPlayer2.chromium.instance1':
            MprisPlayerInfo.probed(
                busName: 'org.mpris.MediaPlayer2.chromium.instance1',
                identity: 'FreeTube'),
      };
      expect(
        selectBestPlayer(players: parados),
        'org.mpris.MediaPlayer2.chromium.instance1',
      );
    });

    test('la elección forzada manda aunque esté parado', () {
      expect(
        selectBestPlayer(
          players: players,
          forced: 'org.mpris.MediaPlayer2.vlc',
        ),
        'org.mpris.MediaPlayer2.vlc',
      );
    });

    test('una elección forzada que ya no existe vuelve al modo automático', () {
      expect(
        selectBestPlayer(
          players: players,
          forced: 'org.mpris.MediaPlayer2.cerrado',
        ),
        'org.mpris.MediaPlayer2.chromium.instance2934',
      );
    });

    test('sin reproductores devuelve null', () {
      expect(selectBestPlayer(players: const <String, MprisPlayerInfo>{}), isNull);
    });

    test('el desempate es determinista por nombre de bus', () {
      final empatados = <String, MprisPlayerInfo>{
        'org.mpris.MediaPlayer2.bbb': MprisPlayerInfo.probed(
            busName: 'org.mpris.MediaPlayer2.bbb',
            status: PlaybackStatus.playing),
        'org.mpris.MediaPlayer2.aaa': MprisPlayerInfo.probed(
            busName: 'org.mpris.MediaPlayer2.aaa',
            status: PlaybackStatus.playing),
      };
      expect(selectBestPlayer(players: empatados), 'org.mpris.MediaPlayer2.aaa');
      expect(selectBestPlayer(players: empatados), 'org.mpris.MediaPlayer2.aaa');
    });

    test('comparar reproductores ordena por estado y luego por score', () {
      final parado = MprisPlayerInfo.probed(
          busName: 'org.mpris.MediaPlayer2.a', identity: 'FreeTube');
      final sonando = MprisPlayerInfo.probed(
          busName: 'org.mpris.MediaPlayer2.b',
          identity: 'nada',
          status: PlaybackStatus.playing);
      expect(compareMprisPlayers(parado, sonando), greaterThan(0));
      expect(compareMprisPlayers(sonando, parado), lessThan(0));
      // A igualdad de estado, gana el de mayor puntuación.
      final vlc = MprisPlayerInfo.probed(
          busName: 'org.mpris.MediaPlayer2.vlc', identity: 'VLC');
      final free = MprisPlayerInfo.probed(
          busName: 'org.mpris.MediaPlayer2.freetube', identity: 'FreeTube');
      expect(compareMprisPlayers(vlc, free), greaterThan(0));
    });

    test('la ficha del reproductor se construye con su score', () {
      final info = MprisPlayerInfo.probed(
        busName: 'org.mpris.MediaPlayer2.chromium.instance2934',
        identity: 'FreeTube',
        desktopEntry: 'freetube',
        status: PlaybackStatus.paused,
      );
      expect(info.score, 1000);
      expect(info.shortName, 'chromium.instance2934');
      expect(info.label, 'FreeTube');
      expect(info.status, PlaybackStatus.paused);
      expect(info.copyWith(status: PlaybackStatus.playing).status,
          PlaybackStatus.playing);
      expect(info.copyWith(), info);
      // Sin Identity se muestra el nombre corto.
      expect(
        MprisPlayerInfo.probed(busName: 'org.mpris.MediaPlayer2.vlc').label,
        'vlc',
      );
    });
  });

  group('valores sucios de D-Bus', () {
    test('valueAsString acepta cadenas y descarta lo vacío', () {
      expect(valueAsString('FreeTube'), 'FreeTube');
      expect(valueAsString('   '), isNull);
      expect(valueAsString(42), isNull);
      expect(valueAsString(null), isNull);
    });

    test('valueAsStringList normaliza y deduplica', () {
      expect(
        valueAsStringList(<Object>['The Weeknd', ' the weeknd ', 'Malayalam']),
        <String>['The Weeknd', 'Malayalam'],
      );
      // dbus devuelve Iterable en vez de List para `as`.
      expect(
        valueAsStringList(<String>['A', 'B'].map((e) => e)),
        <String>['A', 'B'],
      );
      expect(valueAsStringList(<Object?>[null, '  ']), isEmpty);
      expect(valueAsStringList('Solista'), <String>['Solista']);
      expect(valueAsStringList(null), isEmpty);
    });

    test('valueAsInt y valueAsDouble toleran strings y no finitos', () {
      expect(valueAsInt(42), 42);
      expect(valueAsInt(42.9), 43);
      expect(valueAsInt('123'), 123);
      expect(valueAsInt('no soy un número'), isNull);
      expect(valueAsInt(double.nan), isNull);
      expect(valueAsDouble(1), 1.0);
      expect(valueAsDouble('1.25'), 1.25);
      expect(valueAsDouble(null), isNull);
    });

    test('playbackStatusFromRaw traduce y tolera basura', () {
      expect(playbackStatusFromRaw('Playing'), PlaybackStatus.playing);
      expect(playbackStatusFromRaw(' Paused '), PlaybackStatus.paused);
      expect(playbackStatusFromRaw('Stopped'), PlaybackStatus.stopped);
      expect(playbackStatusFromRaw(null), PlaybackStatus.stopped);
      expect(playbackStatusFromRaw('Roto'), PlaybackStatus.stopped);
    });

    test('metadataFromNative desenvuelve variants y varios tipos de dict', () {
      // Tal cual lo devuelve asStringVariantDict(): valores ya desenvueltos.
      final yaDesenvuelto = metadataFromNative(<String, DBusValue>{
        'xesam:title': DBusString('Blinding Lights'),
        'mpris:length': DBusInt64(200040000),
        'xesam:artist':
            DBusArray(DBusSignature('s'), [DBusString('The Weeknd')]),
      });
      expect(yaDesenvuelto['xesam:title'], 'Blinding Lights');
      expect(yaDesenvuelto['mpris:length'], 200040000);
      expect(yaDesenvuelto['xesam:artist'], <String>['The Weeknd']);

      // Dict nativo con el variant todavía puesto alrededor.
      final conVariant = metadataFromNative(<String, dynamic>{
        'xesam:title': DBusVariant(DBusString('Save Your Tears')),
        'mpris:trackid': DBusVariant(DBusObjectPath.unchecked('/track/9')),
      });
      expect(conVariant['xesam:title'], 'Save Your Tears');
      expect(conVariant['mpris:trackid'], '/track/9');

      expect(metadataFromNative(null), isEmpty);
      expect(metadataFromNative('no soy un dict'), isEmpty);
      expect(metadataFromNative(DBusString('tampoco')), isEmpty);
    });
  });

  group('propertiesChangedValues', () {
    DBusDict cambios() => DBusDict(DBusSignature('s'), DBusSignature('v'),
        <DBusValue, DBusValue>{
          DBusString('mpris:trackid'):
              DBusVariant(DBusObjectPath.unchecked('/track/7')),
          DBusString('xesam:title'): DBusVariant(DBusString('Mock Song')),
        });

    test('lee el dict del segundo valor (firma sa{sv}as)', () {
      final changed = propertiesChangedValues(<Object?>[
        DBusString('org.mpris.MediaPlayer2.Player'),
        cambios(),
        DBusArray(DBusSignature('s'), <DBusValue>[]),
      ]);

      expect(changed['xesam:title'], 'Mock Song');
      // El object path llega como String, no como DBusObjectPath.
      expect(changed['mpris:trackid'], '/track/7');
    });

    test('acepta el dict envuelto en variant y la forma corta', () {
      final envuelto = propertiesChangedValues(<Object?>[
        DBusString('org.mpris.MediaPlayer2.Player'),
        DBusVariant(cambios()),
      ]);
      expect(envuelto['xesam:title'], 'Mock Song');

      final corto = propertiesChangedValues(<Object?>[cambios()]);
      expect(corto.keys, containsAll(<String>['xesam:title', 'mpris:trackid']));
    });

    test('tolera señales vacías o sin dict', () {
      expect(propertiesChangedValues(<Object?>[]), isEmpty);
      expect(propertiesChangedValues(<Object?>[DBusString('Player')]), isEmpty);
      expect(propertiesChangedValues(<Object?>[null]), isEmpty);
    });
  });

  group('valueAs* desenvuelven DBusValue', () {
    // Regresión: la señal `Seeked` llega como DBusInt64 y las propiedades
    // pueden venir envueltas en un variant. Sin desenvolver se perdían.
    test('valueAsInt lee DBusInt64 y variantes', () {
      expect(valueAsInt(DBusInt64(120000000)), 120000000);
      expect(valueAsInt(DBusVariant(DBusInt64(42))), 42);
      expect(valueAsInt(DBusDouble(2.9)), 3);
      expect(valueAsInt(' 1500 '), 1500);
      expect(valueAsInt(null), isNull);
      expect(valueAsInt(DBusString('no soy un número')), isNull);
    });

    test('valueAsString y valueAsDouble leen variants y tipos básicos', () {
      expect(valueAsString(DBusString(' FreeTube ')), 'FreeTube');
      expect(valueAsString(DBusVariant(DBusString('Playing'))), 'Playing');
      // Un object path se devuelve como texto (ver nativeValueOf).
      expect(valueAsString(DBusObjectPath.unchecked('/track/3')), '/track/3');
      expect(valueAsDouble(DBusDouble(1.5)), 1.5);
      expect(valueAsDouble(DBusVariant(DBusInt64(2))), 2.0);
      expect(valueAsDouble(DBusString('0.75')), 0.75);
      expect(valueAsDouble(DBusString('malo')), isNull);
    });
  });
}
