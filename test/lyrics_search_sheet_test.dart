import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lylyrics/ui/screens/lyrics_search_sheet.dart';

/// Al abrir la lupa, el campo "Title" no debe quedar enfocado: nada de cursor
/// ni de teclado automático en Android.
void main() {
  testWidgets('el campo Title no arranca enfocado en la lupa', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: _Launcher()),
      ),
    );

    await tester.tap(find.byIcon(Icons.manage_search));
    await tester.pumpAndSettle();

    expect(find.byType(LyricsSearchSheet), findsOneWidget);

    final titleField = tester.widgetList<EditableText>(
      find.byType(EditableText),
    ).first;
    expect(titleField.focusNode.hasFocus, isFalse);
  });
}

class _Launcher extends StatelessWidget {
  const _Launcher();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: IconButton(
          icon: const Icon(Icons.manage_search),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const LyricsSearchSheet(),
          ),
        ),
      ),
    );
  }
}
