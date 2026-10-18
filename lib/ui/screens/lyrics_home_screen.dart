import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../core/models/lyrics.dart';
import '../../core/models/track_info.dart';
import '../../platform/android/android_media_source.dart';
import '../../services/sync_engine.dart';
import '../../services/token_alignment.dart';
import '../../state/providers/app_providers.dart';
import '../widgets/lyric_line_tile.dart';
import '../widgets/plain_lyrics_view.dart';
import '../widgets/status_panel.dart';
import 'lyrics_search_sheet.dart';
import 'settings_panel.dart';

/// Intención del atajo Espacio: pausar/reproducir la canción.
class _TogglePlayPauseIntent extends Intent {
  const _TogglePlayPauseIntent();
}

/// Pantalla principal: cabecera con la pista y la letra sincronizada debajo.
class LyricsHomeScreen extends ConsumerStatefulWidget {
  const LyricsHomeScreen({super.key});

  @override
  ConsumerState<LyricsHomeScreen> createState() => _LyricsHomeScreenState();
}

class _LyricsHomeScreenState extends ConsumerState<LyricsHomeScreen>
    with WidgetsBindingObserver {
  final ItemScrollController _listController = ItemScrollController();

  /// Si el usuario hace scroll manual, el auto-scroll se pausa este tiempo.
  static const Duration _manualScrollGrace = Duration(seconds: 4);

  DateTime? _lastUserScroll;
  bool _showBackToCurrent = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Al volver de los ajustes del sistema (permiso de notificaciones),
    // reevaluamos el acceso.
    if (state == AppLifecycleState.resumed &&
        defaultTargetPlatform == TargetPlatform.android) {
      ref.invalidate(androidAccessProvider);
    }
  }

  /// Marca que el usuario scrollea a mano y ofrece el botón de volver.
  bool _onUserScroll(UserScrollNotification notification) {
    if (notification.direction == ScrollDirection.idle) return false;
    final now = DateTime.now();
    final last = _lastUserScroll;
    // Filtramos el ruido de los ticks del propio auto-scroll: si llegan dos
    // eventos seguidos del mismo salto, solo cuenta el primero.
    if (last != null && now.difference(last).inMilliseconds < 250) {
      return false;
    }
    _lastUserScroll = now;
    if (!_showBackToCurrent && mounted) {
      setState(() => _showBackToCurrent = true);
    }
    return true;
  }

  /// `true` si el auto-scroll vuelve a estar permitido.
  bool get _autoScrollAllowed {
    final last = _lastUserScroll;
    if (last == null) return true;
    return DateTime.now().difference(last) > _manualScrollGrace;
  }

  void _jumpToCurrent(int? index, int total) {
    if (index == null || total == 0) return;
    _listController.scrollTo(
      index: index.clamp(0, total - 1),
      alignment: 0.4,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
    if (_showBackToCurrent) setState(() => _showBackToCurrent = false);
  }

  /// Espacio pausa/reproduce la canción cuando la app tiene el foco. No
  /// interfiere con los diálogos (búsqueda manual, palabra): esos viven en
  /// otra ruta con su propio foco.
  void _toggleFromKeyboard() {
    ref.read(mediaSourceProvider).togglePlayPause().then((ok) {
      if (!ok && mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            const SnackBar(
              content: Text('The player did not accept the command'),
              duration: Duration(milliseconds: 1500),
              behavior: SnackBarBehavior.floating,
            ),
          );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    final trackAsync = ref.watch(currentTrackProvider);
    // Pintamos el estado "efectivo": la búsqueda automática o, si el usuario
    // eligió una letra en la lupa, esa (modo manual).
    final lyricsState = ref.watch(displayLyricsStateProvider);
    final isManual = lyricsState?.manual ?? false;
    final lineAsync = ref.watch(currentLineIndexProvider);
    // En modo manual la letra no es la de la pista que suena, así que no hay
    // índice que resaltar ni auto-scroll: ignoramos el del motor.
    final currentIndex = isManual ? null : lineAsync.value;
    final playersAsync = ref.watch(playerSelectionProvider);

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.space): _TogglePlayPauseIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _TogglePlayPauseIntent:
              CallbackAction<_TogglePlayPauseIntent>(onInvoke: (_) {
            _toggleFromKeyboard();
            return null;
          }),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
      appBar: _buildAppBar(context, playersAsync.value, trackAsync.value),
      body: Column(
        children: [
          _TrackHeader(track: trackAsync.value),
          _SyncBadge(state: lyricsState),
          const Divider(height: 1),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: NotificationListener<UserScrollNotification>(
                    onNotification: _onUserScroll,
                    child: _buildBody(
                      context,
                      trackAsync.value,
                      lyricsState,
                      currentIndex,
                      settings.get(Settings.fontSize),
                      colorWords: settings.get(Settings.showWordColors),
                    ),
                  ),
                ),
                // Botón para volver a la línea actual tras hacer scroll manual.
                if (_showBackToCurrent && currentIndex != null)
                  Positioned(
                    right: 20,
                    bottom: 20,
                    child: _BackToCurrentButton(
                      onPressed: () => _jumpToCurrent(
                        currentIndex,
                        _lineCount(lyricsState?.lyrics),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // En manual no hay desfase ni contador de línea: la letra no va
          // sincronizada con la canción que suena.
          _BottomBar(
            lineIndex: currentIndex,
            lineCount: isManual ? 0 : _lineCount(lyricsState?.lyrics),
          ),
        ],
      ),
          ),
        ),
      ),
    );
  }

  int _lineCount(Lyrics? lyrics) {
    if (lyrics == null || !lyrics.isSynced) return 0;
    return lyrics.lines.length;
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    PlayerSelection? players,
    TrackInfo? track,
  ) {
    return AppBar(
      title: const Text('Lylyrics'),
      actions: [
        // El selector se muestra con cualquier reproductor (no solo con
        // varios): también alberga la opción "Manual" para volver al modo
        // automático cuando se está mostrando una letra elegida a mano.
        if (players != null && players.hasAny)
          _PlayerSelector(players: players),
        IconButton(
          tooltip: 'Search lyrics',
          icon: const Icon(Icons.search),
          onPressed: () => _openSearch(context, track),
        ),
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(Icons.tune),
          onPressed: () => _openSettings(context),
        ),
      ],
    );
  }

  Widget _buildBody(
    BuildContext context,
    TrackInfo? track,
    LyricsState? lyricsState,
    int? currentIndex,
    double fontSize, {
    bool colorWords = true,
  }) {
    // 1. No hay reproductor: en Android son sesiones multimedia, en Linux
    // MPRIS.
    final players = ref.read(playerSelectionProvider).value;
    if (players != null && !players.hasAny) {
      if (defaultTargetPlatform == TargetPlatform.android) {
        return _AndroidNoPlayer(
          hasAccess: ref.watch(androidAccessProvider).value,
          onOpenSettings: _openListenerSettings,
        );
      }
      return const StatusPanel(
        icon: Icons.usb_off,
        title: 'No MPRIS player detected',
        detail:
            'Open your player and play something. If it is already open, '
            'check with "playerctl -l" in a terminal that it is listed '
            'and that the player exposes MPRIS.',
        tone: StatusTone.warning,
      );
    }

    // 2. Nada reproduciéndose.
    if (track == null) {
      return const StatusPanel(
        icon: Icons.music_note_outlined,
        title: 'Nothing is playing',
        detail: 'Play a song in your player and the lyrics will appear here.',
      );
    }

    final state = lyricsState;
    if (state == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // 3. Instrumental.
    if (state.isInstrumental) {
      return const StatusPanel(
        icon: Icons.music_off_outlined,
        title: 'Instrumental track',
        detail: 'There are no lyrics because this song has no vocals.',
      );
    }

    // 4. Buscando.
    if (state.isLoading || state.phase == LyricsPhase.idle) {
      return const Center(child: CircularProgressIndicator());
    }

    // 5. Error de red.
    if (state.phase == LyricsPhase.error) {
      return StatusPanel(
        icon: Icons.wifi_off,
        title: 'Error searching for lyrics',
        detail: state.errorMessage,
        actionLabel: 'Retry',
        onAction: () => _retry(track),
        tone: StatusTone.error,
      );
    }

    // 6. No encontrada ni en LRCLIB ni en Genius: búsqueda manual.
    if (state.phase == LyricsPhase.notFound || state.lyrics == null) {
      return StatusPanel(
        icon: Icons.search_off,
        title: 'Lyrics not found',
        detail:
            'We searched for "${track.title}"${track.artist.isEmpty ? '' : ' — ${track.artist}'} '
            'in LRCLIB and Genius. You can correct the title or artist by hand.',
        actionLabel: 'Search with other details',
        onAction: () => _openSearch(context, track),
      );
    }

    final lyrics = state.lyrics!;
    final song = ref.watch(songTranslationProvider).value;
    final translations = song?.translations ?? const {};
    final wordLinks = colorWords
        ? ref.watch(songWordLinksProvider).value ?? const <int, Map<int, TokenLink>>{}
        : const <int, Map<int, TokenLink>>{};

    // 7. Letra sin sincronizar o letra manual elegida en la lupa: scroll
    // libre, sin índice ni salto. La manual nunca se sincroniza por tiempo
    // aunque la fuente la traiga con marcas: no es la canción que suena.
    if (state.manual || !lyrics.isSynced) {
      return PlainLyricsView(
        lyrics: lyrics,
        fontSize: fontSize,
        translations: translations,
        colorWords: colorWords,
        wordLinks: wordLinks,
        label: state.manual ? 'Manual lyrics (unsynced)' : null,
      );
    }

    // 8. Letra sincronizada: toque en una línea salta a ese segundo.
    return _SyncedLyricsView(
      controller: _listController,
      lyrics: lyrics,
      currentIndex: currentIndex,
      fontSize: fontSize,
      autoScrollAllowed: _autoScrollAllowed,
      translations: translations,
      colorWords: colorWords,
      wordLinks: wordLinks,
      onSeekLine: (time) => _seekTo(time),
    );
  }

  void _retry(TrackInfo track) {
    final provider = ref.read(lyricsProviderProvider);
    provider.fetch(track).then((lyrics) {
      ref.read(syncEngineProvider).setLyrics(lyrics);
      ref.invalidate(lyricsStateProvider);
    }).catchError((_) {
      ref.invalidate(lyricsStateProvider);
    });
  }

  /// Abre la lupa de búsqueda (LRCLIB + Genius) desde la barra superior o
  /// desde el botón "Buscar con otros datos".
  void _openSearch(BuildContext context, TrackInfo? track) {
    showDialog<void>(
      context: context,
      builder: (_) => LyricsSearchSheet(track: track),
    );
  }

  /// Abre los ajustes en un diálogo, con la misma apariencia que la búsqueda.
  void _openSettings(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => const SettingsPanel(),
    );
  }

  /// Abre los ajustes de "Acceso a notificaciones" (solo Android).
  Future<void> _openListenerSettings() async {
    final source = ref.read(mediaSourceProvider);
    if (source is AndroidMediaSource) {
      await source.openListenerSettings();
    }
  }

  /// Salta la canción al segundo de la línea tocada.
  Future<void> _seekTo(Duration time) async {
    final source = ref.read(mediaSourceProvider);
    final ok = await source.seek(time);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('The player did not accept the seek'),
            duration: Duration(milliseconds: 1500),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }
}

/// Estado sin reproductor en Android: permiso o nada sonando.
///
/// Sin acceso a notificaciones el servicio nativo no puede leer sesiones
/// (es el equivalente al D-Bus ausente en Linux): se pide activarlo con un
/// botón a los ajustes del sistema. Con acceso pero sin sesiones, se pide
/// abrir un reproductor.
class _AndroidNoPlayer extends StatelessWidget {
  const _AndroidNoPlayer({required this.hasAccess, required this.onOpenSettings});

  /// `null` = aún comprobando el permiso.
  final bool? hasAccess;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    if (hasAccess == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!hasAccess!) {
      return StatusPanel(
        icon: Icons.notifications_off,
        title: 'Notification permission',
        detail:
            'Enable "Notification access" for Lylyrics in the system settings: '
            'without that permission it cannot tell what is playing in other apps.',
        actionLabel: 'Open settings',
        onAction: onOpenSettings,
        tone: StatusTone.warning,
      );
    }
    return const StatusPanel(
      icon: Icons.music_note_outlined,
      title: 'Nothing is playing',
      detail:
          'Open your player and play something: the lyrics will appear here. If it is '
          'already playing and it does not appear, check that its notification is visible.',
    );
  }
}

/// Lista con auto-scroll: cuando cambia la línea actual, la centra.
///
/// Se hace desde el propio widget con `didUpdateWidget` en lugar de un
/// `ItemScrollController` porque así el salto se dispara una sola vez por
/// cambio de índice y no en cada reconstrucción.
class _SyncedLyricsView extends StatefulWidget {
  const _SyncedLyricsView({
    required this.controller,
    required this.lyrics,
    required this.currentIndex,
    required this.fontSize,
    required this.autoScrollAllowed,
    this.translations = const {},
    this.onSeekLine,
    this.colorWords = true,
    this.wordLinks = const {},
  });

  final ItemScrollController controller;
  final Lyrics lyrics;
  final int? currentIndex;
  final double fontSize;

  /// `false` cuando el usuario está scrolleando a mano: no saltamos.
  final bool autoScrollAllowed;

  /// Traducción al español por índice de línea (una petición por canción).
  final Map<int, String> translations;

  /// Colores pastel de correspondencia palabra ↔ traducción.
  final bool colorWords;

  /// Enlaces reales `línea -> (orden traducido -> TokenLink)`.
  final Map<int, Map<int, TokenLink>> wordLinks;

  /// Salto al segundo de la línea tocada.
  final ValueChanged<Duration>? onSeekLine;

  @override
  State<_SyncedLyricsView> createState() => _SyncedLyricsViewState();
}

class _SyncedLyricsViewState extends State<_SyncedLyricsView> {
  int _lastScrolledTo = -1;

  @override
  void didUpdateWidget(_SyncedLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final index = widget.currentIndex;
    if (index == null || index == _lastScrolledTo) return;
    if (!widget.autoScrollAllowed) return;
    _lastScrolledTo = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = index.clamp(0, widget.lyrics.lines.length - 1);
      widget.controller.scrollTo(
        index: target,
        alignment: 0.4,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void initState() {
    super.initState();
    // Al aparecer con letra ya cargada, saltamos a la línea actual.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  void _scrollToCurrent() {
    final index = widget.currentIndex;
    if (index == null || !widget.autoScrollAllowed) return;
    if (widget.lyrics.lines.isEmpty) return;
    _lastScrolledTo = index;
    widget.controller.jumpTo(
      index: index.clamp(0, widget.lyrics.lines.length - 1),
      alignment: 0.4,
    );
  }

  @override
  Widget build(BuildContext context) {
    final index = widget.currentIndex;
    return ScrollablePositionedList.builder(
      itemCount: widget.lyrics.lines.length,
      itemScrollController: widget.controller,
      padding: const EdgeInsets.symmetric(vertical: 160),
      itemBuilder: (context, i) {
        final line = widget.lyrics.lines[i];
        final seek = widget.onSeekLine == null
            ? null
            : () => widget.onSeekLine!(line.time);
        return LyricLineTile(
          text: line.text,
          translation: widget.translations[i],
          fontSize: widget.fontSize,
          style: _styleFor(i, index),
          colorWords: widget.colorWords,
          wordLinks: widget.wordLinks[i],
          onSeek: line.isBlank ? null : seek,
        );
      },
    );
  }

  LyricLineStyle _styleFor(int lineIndex, int? currentIndex) {
    if (currentIndex == null) return LyricLineStyle.future;
    if (lineIndex == currentIndex) return LyricLineStyle.current;
    if (lineIndex < currentIndex) return LyricLineStyle.past;
    return LyricLineStyle.future;
  }
}

/// Cabecera: título y artista de la pista actual + botón pausa/reproducir.
class _TrackHeader extends ConsumerWidget {
  const _TrackHeader({required this.track});

  final TrackInfo? track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final current = track;
    if (current == null) {
      return const SizedBox(height: 56);
    }
    final isPlaying = ref.watch(playbackStateProvider).value?.isPlaying ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 16, 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  current.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  current.artist.isEmpty ? 'Unknown artist' : current.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton.filledTonal(
            tooltip: isPlaying ? 'Pause' : 'Play',
            icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
            onPressed: () => _toggle(ref, context),
          ),
        ],
      ),
    );
  }

  Future<void> _toggle(WidgetRef ref, BuildContext context) async {
    final ok = await ref.read(mediaSourceProvider).togglePlayPause();
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
          ..showSnackBar(
            const SnackBar(
              content: Text('The player did not accept the command'),
              duration: Duration(milliseconds: 1500),
              behavior: SnackBarBehavior.floating,
            ),
          );
    }
  }
}

/// Insignia que indica si la canción está sincronizada por tiempo o no.
///
/// Solo aparece cuando ya hay letra cargada (fase `found`); el resto de
/// estados (buscando, error, instrumental, no encontrada) ya tienen su
/// propio panel explicativo.
class _SyncBadge extends StatelessWidget {
  const _SyncBadge({required this.state});

  final LyricsState? state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = state;
    final lyrics = s?.lyrics;
    if (s == null ||
        s.phase != LyricsPhase.found ||
        lyrics == null ||
        lyrics.instrumental) {
      return const SizedBox.shrink();
    }
    if (s.manual) {
      return _SyncBadgeRow(
        icon: Icons.edit_note,
        label: 'Manual lyrics',
        color: theme.colorScheme.secondary,
      );
    }
    final synced = lyrics.isSynced;
    return _SyncBadgeRow(
      icon: synced ? Icons.sync : Icons.sync_disabled,
      label: synced ? 'Synced to time' : 'Not synced to time',
      color: synced ? theme.colorScheme.primary : theme.colorScheme.tertiary,
    );
  }
}

/// Fila de la insignia de estado de sincronización.
class _SyncBadgeRow extends StatelessWidget {
  const _SyncBadgeRow({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(color: color),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Barra inferior con el índice de línea y los controles de offset.
class _BottomBar extends ConsumerWidget {
  const _BottomBar({required this.lineIndex, required this.lineCount});

  final int? lineIndex;
  final int lineCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (lineCount == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final position = (lineIndex ?? 0) + 1;

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Text(
            '$position / $lineCount',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          const _OffsetControls(),
        ],
      ),
    );
  }
}

/// Controles de offset (±0.5 s) para la canción actual.
class _OffsetControls extends ConsumerStatefulWidget {
  const _OffsetControls();

  /// Paso de cada pulsación en los botones de desfase.
  static const Duration step = Duration(milliseconds: 500);

  @override
  ConsumerState<_OffsetControls> createState() => _OffsetControlsState();
}

class _OffsetControlsState extends ConsumerState<_OffsetControls> {
  @override
  Widget build(BuildContext context) {
    final engine = ref.watch(syncEngineProvider);
    final track = ref.watch(currentTrackProvider).value;
    // El mapa SÍ notifica a la UI, así que el texto se actualiza en cada
    // pulsación (el motor por sí solo es mutable y no reconstruiría nada).
    final savedByTrack = ref.watch(offsetByTrackProvider);
    final theme = Theme.of(context);

    if (track == null) return const SizedBox.shrink();
    final trackKey = track.cacheKey;
    final offset = savedByTrack[trackKey] ?? Duration.zero;

    // Si el motor aún no tiene el desfase guardado (p. ej. tras cargar una
    // letra nueva, que resetea el offset), lo reaplicamos fuera del build.
    if (engine.offset != offset) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        engine.setOffset(offset);
      });
    }

    final hasOffset = offset != Duration.zero;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // El propio texto es el botón de "volver a 0,0 s": al tocarlo se
        // restablece. El icono se reserva siempre con Opacity (no cambia el
        // ancho), así que nada se desplaza hacia los lados al aparecer.
        Tooltip(
          message: hasOffset
              ? 'Tap to reset to 0.0 s'
              : 'No offset',
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: hasOffset ? () => _reset(engine, trackKey) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Opacity(
                    opacity: hasOffset ? 1 : 0,
                    child: Icon(
                      Icons.restart_alt,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Offset ${_formatOffset(offset)}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: hasOffset
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Move lyrics earlier 0.5 s',
          icon: const Icon(Icons.fast_rewind, size: 18),
          onPressed: () => _adjust(engine, trackKey, offset, -_OffsetControls.step),
        ),
        IconButton(
          tooltip: 'Move lyrics later 0.5 s',
          icon: const Icon(Icons.fast_forward, size: 18),
          onPressed: () => _adjust(engine, trackKey, offset, _OffsetControls.step),
        ),
      ],
    );
  }

  void _adjust(
    SyncEngine engine,
    String trackKey,
    Duration current,
    Duration delta,
  ) {
    // Guardamos en el mapa (esto reconstruye y actualiza el texto en
    // pantalla) y lo aplicamos al motor para que la línea cambie ya.
    ref.read(offsetByTrackProvider.notifier).adjust(trackKey, current, delta);
    final next = ref.read(offsetByTrackProvider)[trackKey] ?? Duration.zero;
    engine.setOffset(next);
  }

  void _reset(SyncEngine engine, String trackKey) {
    engine.setOffset(Duration.zero);
    ref.read(offsetByTrackProvider.notifier).reset(trackKey);
  }

  String _formatOffset(Duration d) {
    final ms = d.inMilliseconds;
    final sign = ms >= 0 ? '+' : '-';
    final abs = ms.abs();
    return '$sign${(abs / 1000).toStringAsFixed(1)} s';
  }
}

/// Selector de reproductor cuando hay varios.
class _PlayerSelector extends ConsumerWidget {
  const _PlayerSelector({required this.players});

  /// Valor centinela de la entrada "Manual" (no es un reproductor real).
  static const String _manualValue = '__manual__';

  final PlayerSelection players;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(mediaSourceProvider);
    final manualActive = ref.watch(manualLyricsProvider) != null;
    return PopupMenuButton<String>(
      tooltip: 'Switch player',
      icon: const Icon(Icons.speaker),
      onSelected: (value) {
        // "Manual" es solo un indicador de la letra elegida en la lupa:
        // pulsarlo no cambia nada, se sale del modo manual buscando otra
        // letra o eligiendo un reproductor / "Automático".
        if (value == _manualValue) return;
        // Volver a la letra sincronizada de lo que suena: se descarta la
        // letra elegida a mano y se selecciona el reproductor pedido.
        ref.read(manualLyricsProvider.notifier).clear();
        source.selectPlayer(value);
      },
      itemBuilder: (context) => [
        CheckedPopupMenuItem<String>(
          value: '',
          checked: !manualActive && players.selected == null,
          child: const Text('Automatic'),
        ),
        for (final name in players.available)
          CheckedPopupMenuItem<String>(
            value: name,
            checked: !manualActive && players.selected == name,
            child: Text(name),
          ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem<String>(
          value: _manualValue,
          checked: manualActive,
          child: const Text('Manual'),
        ),
      ],
    );
  }
}

/// Botón flotante para volver a la línea actual.
class _BackToCurrentButton extends StatelessWidget {
  const _BackToCurrentButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.small(
      onPressed: onPressed,
      tooltip: 'Back to current line',
      child: const Icon(Icons.my_location),
    );
  }
}