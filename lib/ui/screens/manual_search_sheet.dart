import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/track_info.dart';
import '../../state/providers/app_providers.dart';

/// Formulario de búsqueda manual: el usuario corrige artista y título.
class ManualSearchSheet extends ConsumerStatefulWidget {
  const ManualSearchSheet({super.key, required this.track});

  /// Pista que se está reproduciendo, para prellenar los campos.
  final TrackInfo track;

  @override
  ConsumerState<ManualSearchSheet> createState() => _ManualSearchSheetState();
}

class _ManualSearchSheetState extends ConsumerState<ManualSearchSheet> {
  late final TextEditingController _titleController;
  late final TextEditingController _artistController;

  bool _searching = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.track.title);
    _artistController = TextEditingController(text: widget.track.artist);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _artistController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Escribe un título.');
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });

    try {
      final search = ref.read(manualSearchProvider);
      final lyrics = await search(title, _artistController.text);
      if (!mounted) return;
      if (lyrics == null) {
        setState(() {
          _searching = false;
          _error = 'Sin resultados con esos datos.';
        });
        return;
      }
      // Sustituimos la letra en pantalla por la encontrada.
      ref.read(syncEngineProvider).setLyrics(lyrics);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = 'Error: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Buscar letra'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Título',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _search(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _artistController,
              decoration: const InputDecoration(
                labelText: 'Artista (opcional)',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _search(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _searching ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _searching ? null : _search,
          child: _searching
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Buscar'),
        ),
      ],
    );
  }
}