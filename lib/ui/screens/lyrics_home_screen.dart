import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../core/models/lyrics.dart';
import '../../core/models/track_info.dart';
import '../../services/sync_engine.dart';
import '../../state/providers/app_providers.dart';
import '../widgets/lyric_line_tile.dart';
import '../widgets/status_panel.dart';
import 'manual_search_sheet.dart';
import 'settings_panel.dart';

/// Pantalla principal: cabecera con la pista y la letra sincronizada debajo.
class LyricsHomeScreen extends ConsumerStatefulWidget {
  const LyricsHomeScreen({super.key});

  @override
  ConsumerState<LyricsHomeScreen> createState() => _LyricsHomeScreenState();
}

class _LyricsHomeScreenState extends ConsumerState<LyricsHomeScreen> {
  final ItemScrollController _listController = ItemScrollController();

  /// Si el usuario hace scroll manual, el auto-scroll se pausa este tiempo.
  static const Duration _manualScrollGrace = Duration(seconds: 4);

  DateTime? _lastUserScroll;
  bool _showBackToCurrent = false;
  bool _settingsOpen = false;

  @override
  void dispose() {
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(uiSettingsProvider);
    final trackAsync = ref.watch(currentTrackProvider);
    final lyricsAsync = ref.watch(lyricsStateProvider);
    final lineAsync = ref.watch(currentLineIndexProvider);
    final playersAsync = ref.watch(playerSelectionProvider);

    return Scaffold(
      appBar: _buildAppBar(context, playersAsync.value, trackAsync.value),
      body: Column(
        children: [
          _TrackHeader(
            track: trackAsync.value,
            fontSize: settings.fontSize,
          ),
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
                      lyricsAsync.value,
                      lineAsync.value,
                      settings.fontSize,
                    ),
                  ),
                ),
                // Botón para volver a la línea actual tras hacer scroll manual.
                if (_showBackToCurrent && lineAsync.value != null)
                  Positioned(
                    right: 20,
                    bottom: 20,
                    child: _BackToCurrentButton(
                      onPressed: () => _jumpToCurrent(
                        lineAsync.value,
                        _lineCount(lyricsAsync.value?.lyrics),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          _BottomBar(
            lineIndex: lineAsync.value,
            lineCount: _lineCount(lyricsAsync.value?.lyrics),
          ),
        ],
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
        if (players != null && players.available.length > 1)
          _PlayerSelector(players: players),
        IconButton(
          tooltip: 'Ajustes',
          icon: const Icon(Icons.tune),
          onPressed: () => setState(() => _settingsOpen = !_settingsOpen),
        ),
      ],
      bottom: _settingsOpen
          ? PreferredSize(
              preferredSize: const Size.fromHeight(96),
              child: SettingsPanel(
                onClose: () => setState(() => _settingsOpen = false),
              ),
            )
          : null,
    );
  }

  Widget _buildBody(
    BuildContext context,
    TrackInfo? track,
    LyricsState? lyricsState,
    int? currentIndex,
    double fontSize,
  ) {
    // 1. No hay reproductor MPRIS: es lo primero que hay que explicar.
    final players = ref.read(playerSelectionProvider).value;
    if (players != null && !players.hasAny) {
      return const StatusPanel(
        icon: Icons.usb_off,
        title: 'No se detectó ningún reproductor MPRIS',
        detail:
            'Abre FreeTube y reproduce algo. Si ya lo tienes abierto, comprueba '
            'con "playerctl -l" en una terminal que aparece listado. FreeTube '
            'debe exposing MPRIS: Ajustes → Interfaz → activar "Integración '
            'D-Bus / MPRIS".',
        tone: StatusTone.warning,
      );
    }

    // 2. Nada reproduciéndose.
    if (track == null) {
      return const StatusPanel(
        icon: Icons.music_note_outlined,
        title: 'Nada reproduciéndose',
        detail: 'Pon una canción en tu reproductor y la letra aparecerá aquí.',
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
        title: 'Pista instrumental',
        detail: 'No hay letra porque esta canción no tiene voz.',
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
        title: 'Error al buscar la letra',
        detail: state.errorMessage,
        actionLabel: 'Reintentar',
        onAction: () => _retry(track),
        tone: StatusTone.error,
      );
    }

    // 6. No encontrada: offering búsqueda manual.
    if (state.phase == LyricsPhase.notFound || state.lyrics == null) {
      return StatusPanel(
        icon: Icons.search_off,
        title: 'No se encontró la letra',
        detail:
            'Buscamos "${track.title}"${track.artist.isEmpty ? '' : ' — ${track.artist}'} '
            'en LRCLIB. Puedes corregir el título o el artista a mano.',
        actionLabel: 'Buscar con otros datos',
        onAction: () => _openManualSearch(context, track),
      );
    }

    final lyrics = state.lyrics!;

    // 7. Letra sin sincronizar: scroll libre, sin índice.
    if (!lyrics.isSynced) {
      return _PlainLyricsView(
        lyrics: lyrics,
        fontSize: fontSize,
        onCopyLine: null,
      );
    }

    // 8. Letra sincronizada.
    return _SyncedLyricsView(
      controller: _listController,
      lyrics: lyrics,
      currentIndex: currentIndex,
      fontSize: fontSize,
      autoScrollAllowed: _autoScrollAllowed,
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

  void _openManualSearch(BuildContext context, TrackInfo track) {
    showDialog<void>(
      context: context,
      builder: (_) => ManualSearchSheet(track: track),
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
  });

  final ItemScrollController controller;
  final Lyrics lyrics;
  final int? currentIndex;
  final double fontSize;

  /// `false` cuando el usuario está scrolleando a mano: no saltamos.
  final bool autoScrollAllowed;

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
        return LyricLineTile(
          text: widget.lyrics.lines[i].text,
          fontSize: widget.fontSize,
          style: _styleFor(i, index),
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

/// Letra no sincronizada: texto plano con scroll libre.
class _PlainLyricsView extends StatelessWidget {
  const _PlainLyricsView({
    required this.lyrics,
    required this.fontSize,
    required this.onCopyLine,
  });

  final Lyrics lyrics;
  final double fontSize;
  final VoidCallback? onCopyLine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Text(
                  'Letra sin sincronizar',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            for (final line in lyrics.visibleLines)
              LyricLineTile(
                text: line.text,
                fontSize: fontSize,
                style: LyricLineStyle.future,
              ),
          ],
        ),
      ),
    );
  }
}

/// Cabecera: título y artista de la pista actual.
class _TrackHeader extends StatelessWidget {
  const _TrackHeader({required this.track, required this.fontSize});

  final TrackInfo? track;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (track == null) {
      return const SizedBox(height: 56);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            track!.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            track!.artist.isEmpty ? 'Artista desconocido' : track!.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
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

/// Controles de offset (±0.1 s) para la canción actual.
class _OffsetControls extends ConsumerStatefulWidget {
  const _OffsetControls();

  @override
  ConsumerState<_OffsetControls> createState() => _OffsetControlsState();
}

class _OffsetControlsState extends ConsumerState<_OffsetControls> {
  @override
  Widget build(BuildContext context) {
    final engine = ref.watch(syncEngineProvider);
    final track = ref.watch(currentTrackProvider).value;
    final offset = engine.offset;
    final theme = Theme.of(context);

    if (track == null) return const SizedBox.shrink();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Desfase ${_formatOffset(offset)}',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        IconButton(
          tooltip: 'Adelantar letra 0,1 s',
          icon: const Icon(Icons.fast_rewind, size: 18),
          onPressed: () => _adjust(engine, offset, -const Duration(milliseconds: 100)),
        ),
        IconButton(
          tooltip: 'Retroceder letra 0,1 s',
          icon: const Icon(Icons.fast_forward, size: 18),
          onPressed: () => _adjust(engine, offset, const Duration(milliseconds: 100)),
        ),
        if (offset != Duration.zero)
          IconButton(
            tooltip: 'Restablecer desfase',
            icon: const Icon(Icons.restart_alt, size: 18),
            onPressed: () => _reset(engine, track.cacheKey),
          ),
      ],
    );
  }

  void _adjust(SyncEngine engine, Duration current, Duration delta) {
    engine.setOffset(current + delta);
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

  final PlayerSelection players;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(mediaSourceProvider);
    return PopupMenuButton<String>(
      tooltip: 'Cambiar reproductor',
      icon: const Icon(Icons.select_all),
      onSelected: (value) => source.selectPlayer(value),
      itemBuilder: (context) => [
        CheckedPopupMenuItem<String>(
          value: '',
          checked: players.selected == null,
          child: const Text('Automático'),
          onTap: () {},
        ),
        for (final name in players.available)
          CheckedPopupMenuItem<String>(
            value: name,
            checked: players.selected == name,
            child: Text(name),
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
      tooltip: 'Volver a la línea actual',
      child: const Icon(Icons.my_location),
    );
  }
}