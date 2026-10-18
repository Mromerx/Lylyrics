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
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
          child: Text(
            title.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        ...children,
      ],
    );
  }
}

/// Fila base de un ajuste: icono, etiqueta y control a la derecha.
///
/// Todos los ajustes comparten esta estructura; solo cambia el [trailing].
class _SettingTile extends StatelessWidget {
  const _SettingTile({
    required this.icon,
    required this.title,
    required this.trailing,
    this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      // Sin resaltado al pasar el ratón: el color de fondo se mantiene.
      hoverColor: Colors.transparent,
      leading: Icon(icon, size: 20),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: trailing,
      onTap: onTap,
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
      trailing: DropdownButton<T>(
        value: value,
        underline: const SizedBox.shrink(),
        focusColor: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        items: [
          for (final option in options)
            DropdownMenuItem<T>(value: option, child: Text(labelOf(option))),
        ],
        onChanged: (next) {
          if (next == null) return;
          ref.read(appSettingsProvider.notifier).set(def, next);
        },
      ),
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
    return _SettingTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Decrease',
            icon: const Icon(Icons.remove, size: 20),
            onPressed: value <= min
                ? null
                : () => notifier.set(def, value - step),
          ),
          SizedBox(
            width: 52,
            child: Text(
              format(value),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          IconButton(
            tooltip: 'Increase',
            icon: const Icon(Icons.add, size: 20),
            onPressed: value >= max
                ? null
                : () => notifier.set(def, value + step),
          ),
        ],
      ),
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
