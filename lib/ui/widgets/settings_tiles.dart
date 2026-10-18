import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers/app_providers.dart';

/// Cabecera que agrupa varias filas de ajustes bajo un mismo título.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
          child: Text(
            title.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        ...children,
        const SizedBox(height: 6),
      ],
    );
  }
}

/// Fila base de un ajuste: icono, etiqueta y control a la derecha.
///
/// Todos los ajustes comparten esta estructura; solo cambia el [trailing].
///
/// En pantallas estrechas (móvil) los controles anchos, como los desplegables
/// con etiquetas largas, no caben en la fila horizontal y dejan la etiqueta en
/// un hilo. Con [stackWhenNarrow] el control se apila debajo de la etiqueta
/// ocupando todo el ancho, usando [expandedTrailing] en lugar de [trailing].
class _SettingTile extends StatelessWidget {
  const _SettingTile({
    required this.icon,
    required this.title,
    required this.trailing,
    this.subtitle,
    this.onTap,
    this.stackWhenNarrow = false,
    this.expandedTrailing,
  });

  static const double _minHorizontalWidth = 420;

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget trailing;
  final VoidCallback? onTap;
  final bool stackWhenNarrow;
  final Widget? expandedTrailing;

  @override
  Widget build(BuildContext context) {
    if (!stackWhenNarrow) {
      return _horizontal(context, trailing);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= _minHorizontalWidth) {
          return _horizontal(context, trailing);
        }
        return _vertical(context);
      },
    );
  }

  Widget _horizontal(BuildContext context, Widget control) {
    final theme = Theme.of(context);
    return ListTile(
      // Sin resaltado al pasar el ratón: el color de fondo se mantiene.
      hoverColor: Colors.transparent,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Icon(icon, size: 20),
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
      trailing: control,
      onTap: onTap,
    );
  }

  Widget _vertical(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 20),
                const SizedBox(width: 16),
                Expanded(child: Text(title)),
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.only(left: 36),
                child: Text(
                  subtitle!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: expandedTrailing ?? trailing,
            ),
          ],
        ),
      ),
    );
  }
}

/// Ajuste booleano: un `Switch` idéntico para todos los ajustes de este tipo.
class SwitchSettingTile extends ConsumerWidget {
  const SwitchSettingTile({
    super.key,
    required this.def,
    required this.icon,
    required this.title,
    this.subtitle,
  });

  final SettingDef<bool> def;
  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(appSettingsProvider.select((s) => s.get(def)));
    return _SettingTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: Switch(
        value: value,
        // Sin halo ni cambio de color al pasar el ratón: el círculo mantiene
        // su color base en todos los estados (el tema M3 lo tiñe de
        // `primaryContainer`, un azul claro, al hacer hover).
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        thumbColor: _staticThumbColor(context),
        onChanged: (next) =>
            ref.read(appSettingsProvider.notifier).set(def, next),
      ),
      onTap: () => ref.read(appSettingsProvider.notifier).set(def, !value),
    );
  }
}

/// Ajuste de elección única entre varias opciones ([options]).
class DropdownSettingTile<T> extends ConsumerWidget {
  const DropdownSettingTile({
    super.key,
    required this.def,
    required this.icon,
    required this.title,
    required this.options,
    required this.labelOf,
    this.subtitle,
  });

  final SettingDef<T> def;
  final IconData icon;
  final String title;
  final String? subtitle;
  final List<T> options;
  final String Function(T value) labelOf;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(appSettingsProvider.select((s) => s.get(def)));
    return _SettingTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      stackWhenNarrow: true,
      // Ancho acotado: con opciones largas ("Chinese (Simplified)") el control
      // sin acotar se comía el espacio de la etiqueta.
      trailing: SizedBox(
        width: 180,
        child: _dropdown(context, ref, value),
      ),
      expandedTrailing: _dropdown(context, ref, value),
    );
  }

  Widget _dropdown(BuildContext context, WidgetRef ref, T value) {
    return DropdownButton<T>(
      value: value,
      isExpanded: true,
      underline: const SizedBox.shrink(),
      focusColor: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      items: [
        for (final option in options)
          DropdownMenuItem<T>(
            value: option,
            child: Text(
              labelOf(option),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (next) {
        if (next == null) return;
        ref.read(appSettingsProvider.notifier).set(def, next);
      },
    );
  }
}

/// Ajuste numérico con botones − / + dentro del rango [min]–[max].
class StepperSettingTile extends ConsumerWidget {
  const StepperSettingTile({
    super.key,
    required this.def,
    required this.icon,
    required this.title,
    required this.step,
    required this.min,
    required this.max,
    required this.format,
    this.subtitle,
  });

  final SettingDef<double> def;
  final IconData icon;
  final String title;
  final String? subtitle;
  final double step;
  final double min;
  final double max;
  final String Function(double value) format;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(appSettingsProvider.select((s) => s.get(def)));
    final notifier = ref.read(appSettingsProvider.notifier);
    // Siempre en una línea: los botones compactos caben junto a la etiqueta
    // incluso en móvil, así que no se apilan.
    return _SettingTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: _stepper(context, value, notifier),
    );
  }

  Widget _stepper(
    BuildContext context,
    double value,
    AppSettingsNotifier notifier,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _stepperButton(
          icon: Icons.remove,
          tooltip: 'Decrease',
          onPressed: value <= min ? null : () => notifier.set(def, value - step),
        ),
        SizedBox(
          width: 46,
          child: Text(
            format(value),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        _stepperButton(
          icon: Icons.add,
          tooltip: 'Increase',
          onPressed: value >= max ? null : () => notifier.set(def, value + step),
        ),
      ],
    );
  }

  /// Botón compacto para que el stepper quepa en una sola línea en móvil.
  Widget _stepperButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 20),
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
    );
  }
}

/// Color del círculo del switch que NO depende del hover ni del foco.
///
/// Replica los colores base de Material 3 (`onPrimary` encendido, `outline`
/// apagado) pero sin el tinte azul (`primaryContainer`) que aplica el tema al
/// pasar el ratón por encima.
WidgetStateProperty<Color> _staticThumbColor(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return WidgetStateProperty.resolveWith((states) {
    if (states.contains(WidgetState.disabled)) {
      return states.contains(WidgetState.selected)
          ? scheme.surface
          : scheme.onSurface.withValues(alpha: 0.38);
    }
    return states.contains(WidgetState.selected)
        ? scheme.onPrimary
        : scheme.outline;
  });
}
