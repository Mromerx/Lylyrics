import 'package:flutter/material.dart';

/// Mensaje central con icono, título, detalle y una acción opcional.
///
/// Cubre los estados "nada reproduciéndose", "no encontrada", "error de red" y
/// "reproductor no detectado" sin duplicar la maquetación en cada pantalla.
class StatusPanel extends StatelessWidget {
  const StatusPanel({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
    this.actionLabel,
    this.onAction,
    this.secondary,
    this.tone = StatusTone.neutral,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Contenido extra debajo del detalle (campo de búsqueda, por ejemplo).
  final Widget? secondary;

  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color color = switch (tone) {
      StatusTone.neutral => theme.colorScheme.onSurfaceVariant,
      StatusTone.error => theme.colorScheme.error,
      StatusTone.warning => theme.colorScheme.tertiary,
    };

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: color),
              const SizedBox(height: 20),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge,
              ),
              if (detail != null) ...[
                const SizedBox(height: 10),
                Text(
                  detail!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 22),
                FilledButton.tonal(
                  onPressed: onAction,
                  child: Text(actionLabel!),
                ),
              ],
              if (secondary != null) ...[
                const SizedBox(height: 22),
                secondary!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

enum StatusTone { neutral, warning, error }