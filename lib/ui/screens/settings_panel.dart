import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../state/providers/app_providers.dart';

/// Panel de ajustes: tamaño de fuente, tema y "siempre encima".
class SettingsPanel extends ConsumerWidget {
  const SettingsPanel({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(uiSettingsProvider);
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            // Tamaño de fuente.
            const Icon(Icons.text_fields, size: 18),
            const SizedBox(width: 8),
            SizedBox(
              width: 130,
              child: Slider(
                value: settings.fontSize,
                min: 14,
                max: 56,
                divisions: 21,
                label: settings.fontSize.toStringAsFixed(0),
                onChanged: (v) =>
                    ref.read(uiSettingsProvider.notifier).setFontSize(v),
              ),
            ),
            const SizedBox(width: 8),
            Text('${settings.fontSize.toStringAsFixed(0)} pt',
                style: theme.textTheme.labelMedium),

            const Spacer(),

            // Tema.
            IconButton(
              tooltip: settings.themeModeIsDark ? 'Tema oscuro' : 'Tema claro',
              icon: Icon(
                settings.themeModeIsDark ? Icons.dark_mode : Icons.light_mode,
              ),
              onPressed: () => ref.read(uiSettingsProvider.notifier).toggleTheme(),
            ),

            // Siempre encima.
            IconButton(
              tooltip: 'Siempre encima',
              icon: Icon(
                settings.alwaysOnTop ? Icons.push_pin : Icons.push_pin_outlined,
              ),
              isSelected: settings.alwaysOnTop,
              onPressed: () {
                final next = !settings.alwaysOnTop;
                ref.read(uiSettingsProvider.notifier).setAlwaysOnTop(next);
                windowManager.setAlwaysOnTop(next);
              },
            ),

            IconButton(
              tooltip: 'Cerrar ajustes',
              icon: const Icon(Icons.close),
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}