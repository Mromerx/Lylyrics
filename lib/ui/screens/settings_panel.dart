import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers/app_providers.dart';
import '../widgets/settings_tiles.dart';

/// Diálogo de ajustes, con la misma apariencia que el de búsqueda
/// ([LyricsSearchSheet]): título con icono, contenido y una acción de cierre.
///
/// Cada fila usa un widget de [settings_tiles.dart], así que todas las opciones
/// comparten la misma estructura (icono + etiqueta + control). Añadir una
/// opción nueva es declararla en [Settings] y colocar aquí su fila.
class SettingsPanel extends ConsumerWidget {
  const SettingsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // En pantallas estrechas el ancho fijo de escritorio desborda el diálogo;
    // lo acotamos al espacio disponible (el AlertDialog ya aplica sus insets).
    final contentWidth = math.min(460.0, MediaQuery.sizeOf(context).width - 48);
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.tune, size: 20),
          SizedBox(width: 8),
          Text('Settings'),
        ],
      ),
      content: SizedBox(
        width: contentWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsSection(
                title: 'Appearance',
                children: [
                  StepperSettingTile(
                    def: Settings.fontSize,
                    icon: Icons.text_fields,
                    title: 'Font size',
                    step: 2,
                    min: 14,
                    max: 56,
                    format: (value) => '${value.toStringAsFixed(0)} pt',
                  ),
                  SwitchSettingTile(
                    def: Settings.themeIsDark,
                    icon: Icons.dark_mode_outlined,
                    title: 'Dark theme',
                  ),
                ],
              ),
              const Divider(height: 1),
              SettingsSection(
                title: 'Lyrics',
                children: [
                  SwitchSettingTile(
                    def: Settings.showWordColors,
                    icon: Icons.palette_outlined,
                    title: 'Word colors',
                    subtitle: 'Colour each word with the matching part',
                  ),
                ],
              ),
              const Divider(height: 1),
              SettingsSection(
                title: 'Translation',
                children: [
                  DropdownSettingTile<String>(
                    def: Settings.translationTarget,
                    icon: Icons.translate,
                    title: 'Translate lyrics to',
                    options: [
                      for (final lang in kTranslationLanguages) lang.code,
                    ],
                    labelOf: translationLanguageLabel,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
