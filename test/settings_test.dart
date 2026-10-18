import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lylyrics/state/providers/app_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ProviderContainer> _containerWith(
  Map<String, Object> initial,
) async {
  SharedPreferences.setMockInitialValues(initial);
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('valores por defecto', () {
    test('sin nada guardado usa los defaults', () async {
      final container = await _containerWith({});
      addTearDown(container.dispose);

      final settings = container.read(appSettingsProvider);
      expect(settings.get(Settings.fontSize), 26);
      expect(settings.get(Settings.themeIsDark), false);
      expect(settings.get(Settings.showWordColors), false);
      expect(settings.get(Settings.translationTarget), 'es');
    });
  });

  group('persistencia', () {
    test('cada ajuste se guarda y se restaura', () async {
      final container = await _containerWith({});
      addTearDown(container.dispose);
      final notifier = container.read(appSettingsProvider.notifier);

      notifier.set(Settings.fontSize, 30.0);
      notifier.set(Settings.themeIsDark, false);
      notifier.set(Settings.showWordColors, false);
      notifier.set(Settings.translationTarget, 'fr');

      final prefs = container.read(sharedPreferencesProvider);
      expect(prefs.getDouble('ui.fontSize'), 30);
      expect(prefs.getBool('ui.themeIsDark'), false);
      expect(prefs.getBool('ui.showWordColors'), false);
      expect(prefs.getString('ui.translationTarget'), 'fr');

      // Un contenedor nuevo arranca con lo guardado.
      final restored = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(restored.dispose);

      final settings = restored.read(appSettingsProvider);
      expect(settings.get(Settings.fontSize), 30);
      expect(settings.get(Settings.themeIsDark), false);
      expect(settings.get(Settings.showWordColors), false);
      expect(settings.get(Settings.translationTarget), 'fr');
    });

    test('se restaura desde shared_preferences al arrancar', () async {
      final container = await _containerWith({
        'ui.translationTarget': 'ja',
        'ui.fontSize': 40.0,
      });
      addTearDown(container.dispose);

      final settings = container.read(appSettingsProvider);
      expect(settings.get(Settings.translationTarget), 'ja');
      expect(settings.get(Settings.fontSize), 40);
    });
  });

  group('normalización', () {
    test('el tamaño de fuente se acota entre 14 y 56', () async {
      final container = await _containerWith({});
      addTearDown(container.dispose);
      final notifier = container.read(appSettingsProvider.notifier);

      notifier.set(Settings.fontSize, 100.0);
      expect(container.read(appSettingsProvider).get(Settings.fontSize), 56);

      notifier.set(Settings.fontSize, 1.0);
      expect(container.read(appSettingsProvider).get(Settings.fontSize), 14);
    });
  });

  group('reset', () {
    test('devuelve un ajuste a su valor por defecto', () async {
      final container = await _containerWith({});
      addTearDown(container.dispose);
      final notifier = container.read(appSettingsProvider.notifier);

      notifier.set(Settings.translationTarget, 'de');
      notifier.reset(Settings.translationTarget);

      expect(
        container.read(appSettingsProvider).get(Settings.translationTarget),
        'es',
      );
    });
  });
}
