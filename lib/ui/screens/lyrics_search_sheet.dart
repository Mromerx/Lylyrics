import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/lyrics.dart';
import '../../core/models/track_info.dart';
import '../../services/lyrics_search.dart';
import '../../state/providers/app_providers.dart';

/// Diálogo de la lupa: busca a la vez en LRCLIB, NetEase y Genius y deja
/// elegir la coincidencia que el usuario quiera mostrar.
///
/// Sustituye a la antigua búsqueda manual (que se quedaba con el primer
/// resultado): aquí se ven todas las coincidencias de ambas fuentes, con su
/// origen y si vienen sincronizadas por tiempo.
class LyricsSearchSheet extends ConsumerStatefulWidget {
  const LyricsSearchSheet({super.key, this.track});

  /// Pista actual, para prellenar los campos. Puede ser `null` si no suena
  /// nada todavía.
  final TrackInfo? track;

  @override
  ConsumerState<LyricsSearchSheet> createState() => _LyricsSearchSheetState();
}

class _LyricsSearchSheetState extends ConsumerState<LyricsSearchSheet> {
  late final TextEditingController _titleController;
  late final TextEditingController _artistController;

  bool _searching = false;
  bool _loadingResult = false;
  String? _error;
  List<SearchResult> _results = const [];

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.track?.title ?? '');
    _artistController = TextEditingController(text: widget.track?.artist ?? '');
  }

  @override
  void dispose() {
    _titleController.dispose();
    _artistController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final title = _titleController.text.trim();
    final artist = _artistController.text.trim();
    if (title.isEmpty && artist.isEmpty) {
      setState(() => _error = 'Enter a title or an artist.');
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
      _results = const [];
    });
    try {
      final results = await ref
          .read(lyricsSearchServiceProvider)
          .search(title, artist: artist);
      if (!mounted) return;
      setState(() {
        _searching = false;
        _results = results;
        if (results.isEmpty) {
          _error = 'No results in LRCLIB, NetEase or Genius.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = 'Search error: $e';
      });
    }
  }

  Future<void> _pick(SearchResult result) async {
    if (_loadingResult) return;
    setState(() {
      _loadingResult = true;
      _error = null;
    });
    try {
      final lyrics =
          await ref.read(lyricsSearchServiceProvider).load(result);
      if (!mounted) return;
      if (lyrics == null) {
        setState(() {
          _loadingResult = false;
          _error = 'Could not load those lyrics.';
        });
        return;
      }
      _apply(lyrics);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingResult = false;
        _error = 'Load error: $e';
      });
    }
  }

  void _apply(Lyrics lyrics) {
    final track = ref.read(currentTrackProvider).value ?? widget.track;
    if (track == null) {
      setState(() {
        _loadingResult = false;
        _error = 'Nothing is playing: the lyrics cannot be pinned.';
      });
      return;
    }
    // La letra elegida puede no ser la de la canción que suena: NO se le pasa
    // al motor de sincronización (no tiene sentido resaltarla por tiempo).
    // El override hace que la UI la pinte como texto libre por encima del
    // resultado automático; el selector de reproductor vuelve al modo auto.
    ref.read(manualLyricsProvider.notifier).apply(track, lyrics);
    Navigator.of(context).pop();
  }

  /// Botón "x" para vaciar un campo de un clic; solo aparece si hay texto.
  Widget? _clearButton(TextEditingValue value, TextEditingController controller) {
    if (value.text.isEmpty) return null;
    return IconButton(
      tooltip: 'Clear',
      icon: const Icon(Icons.clear, size: 18),
      onPressed: controller.clear,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.search, size: 20),
          SizedBox(width: 8),
          Text('Search lyrics'),
        ],
      ),
      content: SizedBox(
        width: 460,
        height: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _titleController,
              builder: (context, value, _) => TextField(
                controller: _titleController,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  labelText: 'Title',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: _clearButton(value, _titleController),
                ),
                onSubmitted: (_) => _search(),
              ),
            ),
            const SizedBox(height: 10),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _artistController,
              builder: (context, value, _) => TextField(
                controller: _artistController,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  labelText: 'Artist (optional)',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: _clearButton(value, _artistController),
                ),
                onSubmitted: (_) => _search(),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(child: _buildResults(context)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _searching ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _searching ? null : _search,
          icon: _searching
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.search, size: 18),
          label: const Text('Search'),
        ),
      ],
    );
  }

  Widget _buildResults(BuildContext context) {
    final theme = Theme.of(context);
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_results.isEmpty) {
      return Center(
        child: Text(
          _error ??
              'Enter a title and search: LRCLIB, NetEase and Genius are queried.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: _error != null
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${_results.length} results · '
          '${_sourcesLabel()}',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 4),
          Text(
            _error!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 6),
        Expanded(
          child: Stack(
            children: [
              ListView.separated(
                itemCount: _results.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) => _ResultTile(
                  result: _results[i],
                  onTap: _loadingResult ? null : () => _pick(_results[i]),
                ),
              ),
              if (_loadingResult)
                const Positioned.fill(
                  child: ColoredBox(
                    color: Color(0x66000000),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
  /// Etiqueta de las fuentes presentes en el último resultado, en el orden
  /// de prioridad del pipeline: LRCLIB + NetEase + Genius.
  String _sourcesLabel() {
    final present = {
      for (final r in _results) r.sourceLabel,
    };
    return [
      if (present.contains('LRCLIB')) 'LRCLIB',
      if (present.contains('NetEase')) 'NetEase',
      if (present.contains('Genius')) 'Genius',
    ].join(' + ');
  }
}

/// Fila de un resultado: origen, título, artista y tipo de letra.
class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.result, this.onTap});

  final SearchResult result;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      onTap: onTap,
      leading: _SourceBadge(label: result.sourceLabel),
      title: Text(
        result.title.isEmpty ? '(untitled)' : result.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        result.artist.isEmpty ? 'Unknown artist' : result.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Icon(
        result.synced ? Icons.sync : Icons.notes,
        size: 18,
        color: result.synced
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Chip de origen (LRCLIB / Genius).
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}
