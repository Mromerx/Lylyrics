import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lylyrics/state/providers/app_providers.dart';
import 'package:lylyrics/ui/screens/settings_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpPanel(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const SettingsPanel(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('no desborda en una pantalla estrecha (Android)', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpPanel(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Translate lyrics to'), findsOneWidget);
    expect(find.text('Spanish'), findsOneWidget);
  });

  testWidgets('mantiene la fila horizontal en pantalla ancha', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpPanel(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Translate lyrics to'), findsOneWidget);
    expect(find.text('Spanish'), findsOneWidget);
  });
}
