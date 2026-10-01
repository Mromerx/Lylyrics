import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lylyrics/core/models/lyrics.dart';
import 'package:lylyrics/core/models/playback_state.dart';
import 'package:lylyrics/services/sync_engine.dart';

/// Reloj manual para las pruebas.
///
/// `fakeAsync` falsea los temporizadores pero NO `DateTime.now()`, así que sin
/// esto las pruebas de interpolación dependerían del reloj real y no serían
/// deterministas. El motor por eso acepta un reloj inyectado.
class _TestClock {
  DateTime _now = DateTime(2026, 3, 14, 15, 9);

  DateTime now() => _now;

  void advance(Duration delta) => _now = _now.add(delta);
}

const _tickInterval = Duration(milliseconds: 100);

LyricLine _line(int ms, String text) => LyricLine(
  time: Duration(milliseconds: ms),
  text: text,
);

/// Letra de referencia: una línea cada 10 s.
final List<LyricLine> _lineas = [
  _line(0, 'Línea 0'),
  _line(10000, 'Línea 1'),
  _line(20000, 'Línea 2'),
  _line(30000, 'Línea 3'),
];

Lyrics _letra(List<LyricLine> lines) =>
    Lyrics(lines: lines, isSynced: true, plainText: null);

/// Arnés: motor + reloj + lista de índices emitidos.
class _Rig {
  _Rig({Duration tick = _tickInterval, Lyrics? letra}) {
    engine = SyncEngine(tickInterval: tick, clock: clock.now);
    // La letra se carga antes de suscribirse: así lo que se registra son las
    // emisiones que provoca el motor al moverse, no la de arranque.
    if (letra != null) engine.setLyrics(letra);
    sub = engine.lineIndexStream.listen(seen.add);
  }

  final _TestClock clock = _TestClock();
  final List<int?> seen = <int?>[];
  late final SyncEngine engine;
  late final StreamSubscription<int?> sub;

  /// Emula un `PlaybackState` del reproductor en el instante actual del reloj.
  void play({
    Duration position = Duration.zero,
    double speed = 1.0,
    bool playing = true,
  }) {
    engine.update(
      PlaybackState(
        isPlaying: playing,
        position: position,
        timestamp: clock.now(),
        speed: speed,
        status: playing ? PlaybackStatus.playing : PlaybackStatus.paused,
      ),
    );
  }

  /// Adelanta reloj y timers a la vez, en pasos de un tick, para que cada tick
  /// vea la posición que tendría en la realidad.
  void advance(
    FakeAsync async,
    Duration delta, {
    Duration step = _tickInterval,
  }) {
    var left = delta;
    while (left > Duration.zero) {
      final slice = left < step ? left : step;
      clock.advance(slice);
      async.elapse(slice);
      left -= slice;
    }
    async.flushMicrotasks();
  }

  /// Vacía la cola de microtareas (las emisiones de un broadcast llegan así)
  /// y comprueba la lista de índices vistos.
  void expectSeen(FakeAsync async, Object? expected) {
    async.flushMicrotasks();
    expect(seen, expected);
  }

  /// Deja pasar N ticks sin mover el reloj (el motor no debe cambiar).
  void idle(FakeAsync async, [int ticks = 5]) {
    for (var i = 0; i < ticks; i++) {
      async.elapse(_tickInterval);
    }
    async.flushMicrotasks();
  }

  void dispose() {
    engine.dispose();
  }
}

/// Referencia lineal para contrastar la búsqueda binaria.
int? _lineal(List<LyricLine> lines, Duration position) {
  int? found;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].time <= position) {
      found = i;
    } else {
      break;
    }
  }
  return found;
}

void main() {
  // =====================================================================
  group('indexAt: búsqueda binaria pura', () {
    test('lista vacía -> null', () {
      expect(SyncEngine.indexAt(const <LyricLine>[], Duration.zero), isNull);
      expect(
        SyncEngine.indexAt(const <LyricLine>[], const Duration(hours: 1)),
        isNull,
      );
    });

    test('posición anterior a la primera línea -> null', () {
      expect(
        SyncEngine.indexAt(_lineas, const Duration(milliseconds: -1)),
        isNull,
      );
      expect(SyncEngine.indexAt(_lineas, Duration.zero), 0);
      expect(SyncEngine.indexAt(_lineas, const Duration(seconds: 999)), 3);
    });

    test('posición negativa con líneas positivas -> null', () {
      expect(
        SyncEngine.indexAt([
          _line(1000, 'a'),
          _line(2000, 'b'),
        ], const Duration(milliseconds: 999)),
        isNull,
      );
    });

    test('exacto en una línea (incluida la primera y la última)', () {
      expect(SyncEngine.indexAt(_lineas, Duration.zero), 0);
      expect(SyncEngine.indexAt(_lineas, const Duration(seconds: 10)), 1);
      expect(SyncEngine.indexAt(_lineas, const Duration(seconds: 30)), 3);
    });

    test('entre dos líneas -> la anterior', () {
      expect(SyncEngine.indexAt(_lineas, const Duration(milliseconds: 1)), 0);
      expect(
        SyncEngine.indexAt(
          _lineas,
          const Duration(seconds: 9, milliseconds: 999),
        ),
        0,
      );
      expect(SyncEngine.indexAt(_lineas, const Duration(seconds: 15)), 1);
      expect(
        SyncEngine.indexAt(
          _lineas,
          const Duration(seconds: 25, milliseconds: 500),
        ),
        2,
      );
    });

    test('después de la última -> el último índice', () {
      expect(SyncEngine.indexAt(_lineas, const Duration(seconds: 31)), 3);
      expect(SyncEngine.indexAt(_lineas, const Duration(hours: 3)), 3);
    });

    test('tiempos repetidos -> gana la última de las empatadas', () {
      final lines = [
        _line(0, 'a'),
        _line(1000, 'b'),
        _line(1000, 'c'),
        _line(1000, 'd'),
        _line(2000, 'e'),
      ];
      expect(SyncEngine.indexAt(lines, const Duration(milliseconds: 999)), 0);
      expect(SyncEngine.indexAt(lines, const Duration(seconds: 1)), 3);
      expect(SyncEngine.indexAt(lines, const Duration(milliseconds: 1001)), 3);
      expect(SyncEngine.indexAt(lines, const Duration(seconds: 2)), 4);
    });

    test('línea única', () {
      final lines = [_line(5000, 'solo')];
      expect(SyncEngine.indexAt(lines, const Duration(seconds: 4)), isNull);
      expect(SyncEngine.indexAt(lines, const Duration(seconds: 5)), 0);
      expect(SyncEngine.indexAt(lines, const Duration(seconds: 500)), 0);
    });

    test('tiempos negativos (offset negativo del LRC)', () {
      final lines = [_line(-2000, 'a'), _line(0, 'b'), _line(1000, 'c')];
      expect(SyncEngine.indexAt(lines, const Duration(seconds: -3)), isNull);
      expect(SyncEngine.indexAt(lines, const Duration(milliseconds: -1999)), 0);
      expect(SyncEngine.indexAt(lines, const Duration(milliseconds: -1)), 0);
      expect(SyncEngine.indexAt(lines, Duration.zero), 1);
      expect(SyncEngine.indexAt(lines, const Duration(seconds: 1)), 2);
      expect(SyncEngine.indexAt(lines, const Duration(seconds: 99)), 2);
    });

    test('1 000 líneas: 500 posiciones coinciden con la búsqueda lineal', () {
      final lines = [for (var i = 0; i < 1000; i++) _line(i * 500, 'L$i')];
      for (var ms = 0; ms <= 500000; ms += 1000) {
        final position = Duration(milliseconds: ms);
        expect(
          SyncEngine.indexAt(lines, position),
          _lineal(lines, position),
          reason: 'posición ${ms}ms',
        );
      }
    });

    test('1 000 líneas: 2 000 posiciones pseudoaleatorias = lineal', () {
      final lines = [for (var i = 0; i < 1000; i++) _line(i * 333, 'L$i')];
      var seed = 987654321;
      for (var n = 0; n < 2000; n++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        final position = Duration(milliseconds: seed % 400000);
        expect(
          SyncEngine.indexAt(lines, position),
          _lineal(lines, position),
          reason: 'posición ${position.inMilliseconds}ms',
        );
      }
    });

    test('escala: 200 000 líneas se resuelven bien en los extremos', () {
      final lines = [for (var i = 0; i < 200000; i++) _line(i * 200, 'L$i')];
      expect(
        SyncEngine.indexAt(lines, const Duration(milliseconds: -1)),
        isNull,
      );
      expect(SyncEngine.indexAt(lines, const Duration(milliseconds: 199)), 0);
      expect(
        SyncEngine.indexAt(lines, const Duration(milliseconds: 19999999)),
        99999,
      );
      expect(
        SyncEngine.indexAt(lines, const Duration(milliseconds: 20000100)),
        100000,
      );
      // 1 h = 3 600 000 ms = línea 18 000 (van cada 200 ms).
      expect(SyncEngine.indexAt(lines, const Duration(hours: 1)), 18000);
      // La última línea (199 999) está en 39 999 800 ms.
      expect(
        SyncEngine.indexAt(lines, const Duration(milliseconds: 39999799)),
        199998,
      );
      expect(
        SyncEngine.indexAt(lines, const Duration(milliseconds: 39999800)),
        199999,
      );
      // Más allá de la última se queda en la última, sin reventar.
      expect(SyncEngine.indexAt(lines, const Duration(hours: 99)), 199999);
    });
  });

  // =====================================================================
  group('update: reloj interpolado', () {
    test('con isPlaying la posición avanza con el reloj', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        rig.play(position: Duration.zero);
        expect(rig.engine.interpolatedPosition, Duration.zero);
        rig.advance(async, const Duration(seconds: 5));
        expect(rig.engine.interpolatedPosition, const Duration(seconds: 5));
        expect(rig.engine.currentIndex, 0);
        rig.advance(async, const Duration(seconds: 7));
        expect(rig.engine.interpolatedPosition, const Duration(seconds: 12));
        expect(rig.engine.currentIndex, 1);
        rig.dispose();
      });
    });

    test('la posición reportada manda sobre lo queapsed del reloj', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        // El reproductor dice que va por el segundo 25 aunque solo hayan
        // pasado 300 ms de reloj: manda lo que reporta MPRIS.
        rig.play(position: const Duration(seconds: 25));
        rig.idle(async, 3);
        rig.expectSeen(async, [2]);
        expect(rig.engine.currentIndex, 2);
        rig.dispose();
      });
    });

    test('seek hacia adelante recalibra y emite', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        rig.play(position: Duration.zero);
        rig.advance(async, const Duration(seconds: 2));
        // Nada nuevo: la letra se cargó ya en el índice 0 y seguimos en el 0.
        rig.expectSeen(async, isEmpty);
        expect(rig.engine.currentIndex, 0);
        rig.play(position: const Duration(seconds: 22));
        rig.expectSeen(async, [2]);
        expect(rig.engine.currentIndex, 2);
        rig.dispose();
      });
    });

    test('seek hacia atrás recalibra y emite', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        rig.play(position: const Duration(seconds: 28));
        rig.expectSeen(async, [2]);
        rig.play(position: const Duration(seconds: 5));
        rig.expectSeen(async, [2, 0]);
        expect(rig.engine.currentIndex, 0);
        rig.dispose();
      });
    });

    test('pausa: la posición queda congelada aunque el reloj corra', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        rig.play(position: const Duration(seconds: 10));
        rig.expectSeen(async, [1]);
        rig.play(position: const Duration(seconds: 10), playing: false);
        rig.advance(async, const Duration(seconds: 60));
        expect(rig.engine.interpolatedPosition, const Duration(seconds: 10));
        expect(rig.engine.currentIndex, 1);
        rig.expectSeen(async, [1]); // nada nuevo: ni posición ni índice cambian
        rig.dispose();
      });
    });

    test('reanudación: sigue desde donde estaba, no desde cero', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        rig.play(position: const Duration(seconds: 12), playing: false);
        rig.expectSeen(async, [1]);
        rig.advance(async, const Duration(seconds: 30));
        expect(rig.engine.interpolatedPosition, const Duration(seconds: 12));
        rig.play(position: const Duration(seconds: 12)); // reanuda
        rig.advance(async, const Duration(seconds: 3));
        expect(rig.engine.interpolatedPosition, const Duration(seconds: 15));
        rig.expectSeen(async, [1]);
        rig.advance(async, const Duration(seconds: 6));
        expect(rig.engine.interpolatedPosition, const Duration(seconds: 21));
        rig.expectSeen(async, [1, 2]);
        rig.dispose();
      });
    });

    test('velocidad 2.0: la posición avanza el doble', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        rig.play(position: Duration.zero, speed: 2.0);
        rig.advance(async, const Duration(seconds: 5));
        expect(rig.engine.interpolatedPosition, const Duration(seconds: 10));
        expect(rig.engine.currentIndex, 1);
        rig.dispose();
      });
    });

    test('velocidad 0.5: la posición avanza a la mitad', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        rig.play(position: Duration.zero, speed: 0.5);
        rig.advance(async, const Duration(seconds: 10));
        expect(rig.engine.interpolatedPosition, const Duration(seconds: 5));
        expect(rig.engine.currentIndex, 0);
        rig.advance(async, const Duration(seconds: 10));
        expect(rig.engine.currentIndex, 1);
        rig.dispose();
      });
    });

    test('velocidad absurda (NaN) no rompe la interpolación', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        rig.play(position: Duration.zero, speed: double.nan);
        rig.advance(async, const Duration(seconds: 5));
        expect(rig.engine.interpolatedPosition, const Duration(seconds: 5));
        rig.dispose();
      });
    });

    test('update repetido con la misma posición no emite más', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        for (var i = 0; i < 5; i++) {
          rig.play(position: const Duration(seconds: 12));
        }
        rig.expectSeen(async, [1]);
        rig.dispose();
      });
    });

    test('sin estado de reproducción la posición es cero', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        expect(rig.engine.interpolatedPosition, Duration.zero);
        expect(rig.engine.currentIndex, 0);
        expect(rig.engine.playbackState, isNull);
        rig.dispose();
      });
    });
  });

  // =====================================================================
  group('emisiones: solo cuando cambia el índice', () {
    test('no emite si el índice no cambia (una línea larga)', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        rig.play(position: const Duration(seconds: 12));
        rig.expectSeen(async, [1]);
        rig.idle(async, 10); // 1 s de ticks: seguimos en la línea 1
        rig.expectSeen(async, [1]);
        rig.expectSeen(async, hasLength(1));
        rig.dispose();
      });
    });

    test('emite una vez por línea, en orden, al avanzar', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        rig.play(position: Duration.zero);
        rig.advance(async, const Duration(seconds: 35));
        // El 0 se emitió al cargar la letra (el arnés aún no estaba
        // suscrito); al reproducir solo se avisa de los CAMBIOS.
        rig.expectSeen(async, [1, 2, 3]);
        rig.dispose();
      });
    });

    test('el stream es broadcast: dos oyentes reciben lo mismo', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        final otro = <int?>[];
        final sub2 = rig.engine.lineIndexStream.listen(otro.add);
        rig.play(position: Duration.zero);
        rig.advance(async, const Duration(seconds: 12));
        rig.expectSeen(async, [1]);
        expect(otro, [1]);
        sub2.cancel();
        rig.dispose();
      });
    });

    test(
      'una línea vacía (pausa instrumental) se emite como cualquier otra',
      () {
        fakeAsync((async) {
          final rig = _Rig(
            letra: _letra([
              _line(0, 'Coro'),
              _line(10000, ''),
              _line(20000, 'Otra'),
            ]),
          );
          rig.play(position: const Duration(seconds: 11));
          rig.expectSeen(async, [1]);
          expect(rig.engine.currentIndex, 1);
          expect(rig.engine.lyrics!.lines[1].isBlank, isTrue);
          rig.advance(async, const Duration(seconds: 10));
          rig.expectSeen(async, [1, 2]);
          rig.dispose();
        });
      },
    );

    test('posición anterior a la primera línea -> null y luego índice', () {
      fakeAsync((async) {
        final rig = _Rig(
          letra: _letra([_line(5000, 'Tarde'), _line(10000, 'Otra')]),
        );
        rig.play(position: Duration.zero);
        // Nadie se enteró del `null` de arranque (ya se había consumido al
        // cargar la letra), pero el estado actual se consulta igual.
        rig.expectSeen(async, isEmpty);
        expect(rig.engine.currentIndex, isNull);
        rig.advance(async, const Duration(seconds: 5));
        rig.expectSeen(async, [0]);
        rig.dispose();
      });
    });

    test('posición posterior a la última línea -> se queda en la última', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        rig.play(position: const Duration(seconds: 29));
        rig.expectSeen(async, [2]);
        rig.advance(async, const Duration(seconds: 60));
        rig.expectSeen(async, [2, 3]);
        rig.idle(async, 10);
        rig.expectSeen(async, [2, 3]);
        expect(rig.engine.currentIndex, 3);
        rig.dispose();
      });
    });
  });

  // =====================================================================
  group('letra no sincronizada o ausente', () {
    test('letra no sincronizada: emite null UNA vez y se calla', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.engine.setLyrics(Lyrics.fromPlain('Hola\nAdiós'));
        rig.play(position: Duration.zero);
        rig.advance(async, const Duration(seconds: 30));
        rig.expectSeen(async, [null]);
        expect(rig.engine.currentIndex, isNull);
        rig.dispose();
      });
    });

    test('sin letra (null): null una vez y silencio', () {
      fakeAsync((async) {
        final rig = _Rig()..engine.setLyrics(null);
        rig.play(position: Duration.zero);
        rig.advance(async, const Duration(seconds: 30));
        rig.expectSeen(async, [null]);
        rig.dispose();
      });
    });

    test('sin letra: null y silencio; al llegar la letra, el índice real', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.play(position: const Duration(seconds: 12));
        rig.advance(async, const Duration(seconds: 5));
        rig.expectSeen(async, [null]);
        expect(rig.engine.currentIndex, isNull);
        rig.engine.setLyrics(_letra(_lineas));
        rig.expectSeen(async, [null, 1]);
        rig.dispose();
      });
    });

    test('letra sincronizada que llega después de una no sincronizada', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.engine.setLyrics(Lyrics.fromPlain('Hola'));
        rig.play(position: const Duration(seconds: 15));
        rig.expectSeen(async, [null]);
        rig.engine.setLyrics(_letra(_lineas));
        rig.expectSeen(async, [null, 1]);
        expect(rig.engine.currentIndex, 1);
        rig.dispose();
      });
    });

    test('letra sincronizada pero vacía cuenta como no sincronizada', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.engine.setLyrics(const Lyrics(lines: [], isSynced: true));
        rig.play(position: Duration.zero);
        rig.advance(async, const Duration(seconds: 5));
        rig.expectSeen(async, [null]);
        rig.dispose();
      });
    });
  });

  // =====================================================================
  group('setLyrics y recálculo', () {
    test('setLyrics mientras suena emite la línea actual al instante', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.play(position: const Duration(seconds: 25));
        rig.expectSeen(async, [null]);
        rig.engine.setLyrics(_letra(_lineas));
        rig.expectSeen(async, [null, 2]); // sin esperar al siguiente tick
        expect(rig.engine.currentIndex, 2);
        rig.dispose();
      });
    });

    test('cambio de letra recalibra y vuelve a emitir si toca', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        rig.play(position: const Duration(seconds: 22));
        rig.expectSeen(async, [2]);
        // Letra con la misma línea pero tiempos muy distintos.
        rig.engine.setLyrics(
          _letra([_line(0, 'a'), _line(1000, 'b'), _line(2000, 'c')]),
        );
        rig.expectSeen(async, [
          2,
        ]); // 22 s está más allá de la última: sigue la 2
        rig.engine.setLyrics(
          _letra([_line(0, 'a'), _line(60000, 'b'), _line(70000, 'c')]),
        );
        rig.expectSeen(async, [2, 0]); // ahora 22 s cae en la primera
        expect(rig.engine.currentIndex, 0);
        rig.dispose();
      });
    });

    test('quitar la letra vuelve a emitir null', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        rig.play(position: const Duration(seconds: 12));
        rig.expectSeen(async, [1]);
        rig.engine.setLyrics(null);
        rig.expectSeen(async, [1, null]);
        expect(rig.engine.currentIndex, isNull);
        rig.dispose();
      });
    });

    test('setLyrics con la misma letra no duplica emisiones', () {
      fakeAsync((async) {
        final lyrics = _letra(_lineas);
        final rig = _Rig(letra: lyrics);
        rig.play(position: const Duration(seconds: 12));
        rig.expectSeen(async, [1]);
        rig.engine.setLyrics(lyrics);
        rig.expectSeen(async, [1]);
        rig.dispose();
      });
    });
  });

  // =====================================================================
  group('offset manual', () {
    test('+0,1 s desplaza la línea justo en el instante', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        rig.play(position: const Duration(seconds: 10));
        rig.expectSeen(async, [1]);
        rig.engine.setOffset(const Duration(milliseconds: 100));
        expect(rig.engine.offset, const Duration(milliseconds: 100));
        // 10 s ya no llega a la línea 1 (ahora empieza en 10,1): se va a la 0.
        expect(rig.engine.currentIndex, 0);
        rig.expectSeen(async, [1, 0]);
        rig.dispose();
      });
    });

    test('-0,1 s avanza la línea en el instante', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        rig.play(position: const Duration(seconds: 10));
        rig.engine.setOffset(const Duration(milliseconds: -100));
        expect(rig.engine.currentIndex, 1);
        rig.engine.setOffset(const Duration(milliseconds: -200));
        expect(rig.engine.currentIndex, 1);
        rig.engine.setOffset(const Duration(milliseconds: 200));
        expect(rig.engine.currentIndex, 0);
        rig.dispose();
      });
    });

    test('offset de 0 no cambia nada ni emite', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        rig.play(position: const Duration(seconds: 12));
        rig.engine.setOffset(Duration.zero);
        rig.expectSeen(async, [1]);
        expect(rig.engine.offset, Duration.zero);
        rig.dispose();
      });
    });

    test('un offset grande mueve varias líneas de golpe', () {
      fakeAsync((async) {
        final rig = _Rig(
          letra: _letra([for (var i = 0; i < 10; i++) _line(i * 1000, 'L$i')]),
        );
        rig.play(position: const Duration(milliseconds: 2500));
        expect(rig.engine.currentIndex, 2);
        rig.engine.setOffset(const Duration(seconds: -3));
        expect(rig.engine.currentIndex, 5);
        rig.engine.setOffset(const Duration(seconds: 3));
        // 2,5 s < 3 s: la línea 0 ya ni ha empezado.
        expect(rig.engine.currentIndex, isNull);
        rig.dispose();
      });
    });

    test('el offset se acota a ±10 s', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        rig.engine.setOffset(const Duration(hours: 1));
        expect(rig.engine.offset, SyncEngine.maxOffset);
        rig.engine.setOffset(const Duration(hours: -1));
        expect(rig.engine.offset, -SyncEngine.maxOffset);
        rig.engine.setOffset(const Duration(seconds: 3));
        expect(rig.engine.offset, const Duration(seconds: 3));
        rig.dispose();
      });
    });

    test('el offset va a los tiempos de línea, no a la posición', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        rig.play(position: const Duration(seconds: 12));
        rig.engine.setOffset(const Duration(seconds: 5));
        // La posición real sigue siendo 12 s (sirve para la barra de progreso).
        expect(rig.engine.interpolatedPosition, const Duration(seconds: 12));
        expect(rig.engine.currentIndex, 0);
        rig.dispose();
      });
    });

    test('setLyrics reinicia el offset (es por canción)', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        rig.engine.setOffset(const Duration(seconds: 2));
        expect(rig.engine.offset, const Duration(seconds: 2));
        rig.engine.setLyrics(_letra(_lineas));
        expect(rig.engine.offset, Duration.zero);
        rig.dispose();
      });
    });

    test('pasos de ±0,1 s acumulados', () {
      fakeAsync((async) {
        final rig = _Rig(
          letra: _letra([_line(0, 'a'), _line(10000, 'b'), _line(20000, 'c')]),
        );
        rig.play(position: const Duration(seconds: 10));
        rig.expectSeen(async, [1]);
        for (var i = 0; i < 5; i++) {
          rig.engine.setOffset(Duration(milliseconds: (i + 1) * 100));
        }
        // 10 s con +0,5 s de desfase cae en la línea 0.
        expect(rig.engine.currentIndex, 0);
        rig.expectSeen(async, [1, 0]);
        for (var i = 0; i < 5; i++) {
          rig.engine.setOffset(Duration(milliseconds: -(i + 1) * 100));
        }
        expect(rig.engine.offset, const Duration(milliseconds: -500));
        expect(rig.engine.currentIndex, 1);
        rig.dispose();
      });
    });
  });

  // =====================================================================
  group('dispose', () {
    test('es idempotente y deja de emitir', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        rig.play(position: Duration.zero);
        rig.advance(async, const Duration(seconds: 12));
        rig.expectSeen(async, [1]);

        rig.dispose();
        expect(rig.engine.isDisposed, isTrue);
        final antes = List<int?>.from(rig.seen);

        // Nada de esto debe reventar ni emitir.
        rig.dispose();
        rig.dispose();
        rig.advance(async, const Duration(seconds: 30));
        rig.engine.setLyrics(_letra(_lineas));
        rig.engine.setOffset(const Duration(seconds: 1));
        rig.play(position: const Duration(seconds: 25));
        async.flushMicrotasks();

        rig.expectSeen(async, antes);
        rig.dispose();
      });
    });

    test('el stream queda cerrado', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra(_lineas));
        var cerrado = false;
        rig.sub.onDone(() => cerrado = true);
        rig.dispose();
        async.flushMicrotasks();
        expect(cerrado, isTrue);
      });
    });
  });

  // =====================================================================
  group('precisión y cadencia', () {
    test('una línea se detecta como mucho un tick tarde', () {
      fakeAsync((async) {
        final rig = _Rig(letra: _letra([_line(0, 'a'), _line(1500, 'b')]));
        rig.play(position: Duration.zero);
        rig.idle(async, 10); // posición = 10 ms
        // La línea 0 se emitió al cargar la letra, antes de estar suscrito.
        rig.expectSeen(async, isEmpty);
        expect(rig.engine.currentIndex, 0);
        final t0 = rig.clock.now();

        // Tick por tick: en cuanto el reloj pasa de 1,5 s debe saltar, y como
        // mucho en el primer tick posterior al cruce.
        var ticks = 0;
        for (var i = 0; i < 30; i++) {
          rig.advance(async, const Duration(milliseconds: 100));
          ticks++;
          if (rig.engine.currentIndex == 1) break;
        }
        // El cruce exacto es a los 1490 ms desde t0; con tick de 100 ms se
        // detecta en el tick de 1500 ms (10 ms de retraso, ni un tick más).
        expect(ticks, 15);
        expect(rig.clock.now().difference(t0).inMilliseconds, 1500);
        expect(rig.engine.currentIndex, 1);
        rig.expectSeen(async, [1]);
        rig.dispose();
      });
    });

    test('el tick por defecto son 100 ms (no se ralentiza)', () {
      fakeAsync((async) {
        final clock = _TestClock();
        final engine = SyncEngine(clock: clock.now);
        final visto = <int?>[];
        engine.lineIndexStream.listen(visto.add);
        engine.setLyrics(_letra(_lineas));
        engine.update(
          PlaybackState(
            isPlaying: true,
            position: Duration.zero,
            timestamp: clock.now(),
          ),
        );

        // 9,5 s de pista = 95 ticks y ninguna línea nueva (la 1 empieza
        // justo en 10 s), así que solo puede verse el 0 de arranque.
        clock.advance(const Duration(milliseconds: 9500));
        async.elapse(const Duration(milliseconds: 9500));
        async.flushMicrotasks();
        expect(visto, [0]);
        expect(engine.currentIndex, 0);

        // Justo al cruzar los 10 s salta a la línea 1, sin más ticks de sobra.
        clock.advance(const Duration(milliseconds: 500));
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();
        expect(visto, [0, 1]);
        engine.dispose();
      });
    });

    test('un tick más fino también funciona', () {
      fakeAsync((async) {
        final rig = _Rig(tick: const Duration(milliseconds: 20));
        rig.engine.setLyrics(_letra(_lineas));
        rig.play(position: Duration.zero);
        for (var i = 0; i < 5; i++) {
          rig.advance(
            async,
            const Duration(milliseconds: 20),
            step: const Duration(milliseconds: 20),
          );
        }
        rig.expectSeen(async, [0]);
        rig.dispose();
      });
    });

    test('tick cero o negativo no revienta (se acota a 1 ms)', () {
      fakeAsync((async) {
        final rig = _Rig(tick: Duration.zero);
        rig.engine.setLyrics(_letra(_lineas));
        rig.play(position: Duration.zero);
        async.elapse(const Duration(milliseconds: 50));
        async.flushMicrotasks();
        rig.expectSeen(async, [0]);
        rig.dispose();
      });
    });
  });
}
