import 'package:flutter/material.dart';

/// Cabecera común de los diálogos de la app (ajustes y búsqueda).
///
/// Muestra el icono dentro de una cápsula tintada junto al título. Es el
/// único punto donde se define el aspecto del encabezado, así que compartirlo
/// es lo que garantiza que ambos diálogos se vean exactamente igual.
class DialogHeader extends StatelessWidget {
  const DialogHeader({super.key, required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            icon,
            size: 20,
            color: scheme.onSecondaryContainer,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(title)),
      ],
    );
  }
}
