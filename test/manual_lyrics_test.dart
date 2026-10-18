import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lylyrics/core/models/lyrics.dart';
import 'package:lylyrics/core/models/track_info.dart';
import 'package:lylyrics/state/providers/app_providers.dart';

/// La letra elegida en la lupa ("modo manual") manda sobre la búsqueda
/// automática, se marca como manual (sin sincronizar por tiempo) y se
/// descarta al cambiar de canción o al volver a "Automático"/reproductor.
void main() {
  const trackA = TrackInfo(
    title: 'Canción A',
    artist: 'Artista',
    duration: Duration(seconds: 200),
  );
  const trackB = TrackInfo(
    title: 'Canción B',
    artist: 'Otro',
    duration: Duration(seconds: 180),
  );

  Lyrics synced(String text) => Lyrics(
        lines: [LyricLine(time: Duration.zero, text: text)],
        isSynced: true,
      );

  ProviderContainer containerWith(
    Stream<TrackInfo?> tracks, {
    LyricsState? automatic,
  }) {
    final container = ProviderContainer(
      overrides: [
        currentTrackProvider.overrideWith((ref) => tracks),
        lyricsStateProvider.overrideWith(
          (ref) => Stream.value(automatic ?? const LyricsState()),
        ),
      ],
    );
    addTearDown(container.dispose);
    // Mantenemos viva la pista: el notifier manual se engancha a ella.
    final sub = container.listen(currentTrackProvider, (_, __) {});
    addTearDown(sub.close);
    container.listen(lyricsStateProvider, (_, __) {});
    return container;
  }

  test('la letra manual se pinta marcada como manual', () async {
    final container = containerWith(
      Stream.value(trackA),
      automatic: const LyricsState(phase: LyricsPhase.loading, track: trackA),
    );
    await pumpEventQueue();
    final manual = synced('otra letra');

    container.read(manualLyricsProvider.notifier).apply(trackA, manual);

    final state = container.read(displayLyricsStateProvider);
    expect(state?.manual, isTrue);
    expect(state?.lyrics, same(manual));
  });

  test('sin letra manual manda el resultado automático', () async {
    final automatic = LyricsState(
      phase: LyricsPhase.found,
      lyrics: synced('auto'),
      track: trackA,
    );
    final container = containerWith(Stream.value(trackA), automatic: automatic);
    await pumpEventQueue();

    final state = container.read(displayLyricsStateProvider);
    expect(state?.manual, isFalse);
    expect(state?.lyrics, same(automatic.lyrics));
  });

  test('clear() vuelve a la letra automática', () async {
    final automatic = LyricsState(
      phase: LyricsPhase.found,
      lyrics: synced('auto'),
      track: trackA,
    );
    final container = containerWith(Stream.value(trackA), automatic: automatic);
    await pumpEventQueue();

    container
        .read(manualLyricsProvider.notifier)
        .apply(trackA, synced('manual'));
    expect(container.read(displayLyricsStateProvider)?.manual, isTrue);

    container.read(manualLyricsProvider.notifier).clear();
    final state = container.read(displayLyricsStateProvider);
    expect(state?.manual, isFalse);
    expect(state?.lyrics, same(automatic.lyrics));
  });

  group('displayLyricsCacheKey', () {
    test('en modo automático la clave es la de la pista', () {
      final state = LyricsState(
        phase: LyricsPhase.found,
        lyrics: synced('auto'),
        track: trackA,
      );
      expect(displayLyricsCacheKey(state, trackA), trackA.cacheKey);
    });

    test('en modo manual la clave se aísla del resultado automático', () {
      final automatic = LyricsState(
        phase: LyricsPhase.found,
        lyrics: synced('auto'),
        track: trackA,
      );
      final manual = LyricsState(
        phase: LyricsPhase.found,
        lyrics: synced('auto'),
        track: trackA,
        manual: true,
      );
      expect(
        displayLyricsCacheKey(manual, trackA),
        isNot(displayLyricsCacheKey(automatic, trackA)),
      );
    });

    test('dos letras manuales distintas no comparten clave', () {
      final one = LyricsState(
        phase: LyricsPhase.found,
        lyrics: synced('una letra'),
        track: trackA,
        manual: true,
      );
      final two = LyricsState(
        phase: LyricsPhase.found,
        lyrics: synced('otra letra'),
        track: trackA,
        manual: true,
      );
      expect(
        displayLyricsCacheKey(one, trackA),
        isNot(displayLyricsCacheKey(two, trackA)),
      );
      // La misma letra manual sí comparte clave (caché estable).
      expect(
        displayLyricsCacheKey(one, trackA),
        displayLyricsCacheKey(one, trackA),
      );
    });
  });

  test('la letra manual se descarta al cambiar de canción', () async {
    final controller = StreamController<TrackInfo?>();
    addTearDown(controller.close);
    final container = containerWith(controller.stream);

    controller.add(trackA);
    await pumpEventQueue();

    container
        .read(manualLyricsProvider.notifier)
        .apply(trackA, synced('manual'));
    expect(container.read(displayLyricsStateProvider)?.manual, isTrue);

    controller.add(trackB);
    await pumpEventQueue();
    expect(container.read(displayLyricsStateProvider)?.manual, isFalse);
  });
}
