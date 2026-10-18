import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers/app_providers.dart';
import '../widgets/dialog_header.dart';
import '../widgets/settings_tiles.dart';

/// Diálogo de ajustes, con la misma apariencia que el de búsqueda
/// ([LyricsSearchSheet]): misma cabecera ([DialogHeader]), mismos márgenes y
/// misma acción de cierre.
///
/// Cada fila usa un widget de [settings_tiles.dart], así que todas las
/// opciones comparten la misma estructura (icono + etiqueta + control).
/// Añadir una opción nueva es declararla en [Settings] y colocar aquí su fila.
class SettingsPanel extends ConsumerWidget {
  const SettingsPanel({super.key});

  /// Margen exterior del diálogo. Uno más ajustado que el de serie deja más
  /// ancho útil en móvil, que es justo donde las etiquetas se apretaban.
  static const EdgeInsets _insetPadding =
      EdgeInsets.symmetric(horizontal: 20, vertical: 24);

  /// Sangría del contenido (8) sumada a la de cada fila (16) para que el
  /// texto de los ajustes quede alineado con el título (24).
  static const EdgeInsets _contentPadding = EdgeInsets.fromLTRB(8, 0, 8, 0);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // El ancho se acota a lo que deja el diálogo: pantalla menos los márgenes
    // exteriores (20×2) y el relleno del contenido (8×2).
    final available = MediaQuery.sizeOf(context).width - 56;
    final contentWidth = math.min(460.0, available);
    return AlertDialog(
      insetPadding: _insetPadding,
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      contentPadding: _contentPadding,
      actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      title: const DialogHeader(icon: Icons.tune, title: 'Settings'),
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
