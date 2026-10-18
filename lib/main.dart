import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'platform/linux/mpris_media_source.dart';
import 'services/lyrics_cache.dart';
import 'state/providers/app_providers.dart';
import 'ui/screens/lyrics_home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Preferencias persistentes (todos los ajustes de usuario). Se cargan antes
  // de montar la app para que el primer frame ya use los valores guardados.
  final prefs = await SharedPreferences.getInstance();

  // window_manager es solo de escritorio: en Android se omite.
  final isDesktop = !Platform.isAndroid;
  if (isDesktop) {
    // window_manager necesita inicializarse antes de usar la ventana.
    await windowManager.ensureInitialized();

    const options = WindowOptions(
      size: Size(880, 700),
      minimumSize: Size(420, 420),
      center: true,
      title: 'Lylyrics',
      titleBarStyle: TitleBarStyle.normal,
      backgroundColor: Color(0xFF1B1B1B),
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  // Cerramos streams, timers y la base de datos al salir de la ventana, para
  // no dejar conexiones D-Bus colgando.
  // Contenedor explícito para poder soltar los recursos al cerrar la ventana
  // (suscripciones D-Bus, timers y la base de datos de caché).
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
  if (isDesktop) {
    windowManager.addListener(_WindowCloser(container));
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const LylyricsApp(),
    ),
  );
}

/// Azul rey: color de acento principal de la app.
const Color kRoyalBlue = Color(0xFF2447E0);

/// Tinte claro del azul rey, para el acento en modo oscuro.
const Color kRoyalBlueLight = Color(0xFFAEC1FF);

/// Tinte pálido del azul rey, para contenedores en modo claro.
const Color kRoyalBluePale = Color(0xFFD9E1FF);

/// Ámbar: tercer color, para avisos y estados de alerta.
const Color kAmber = Color(0xFFFFB300);

/// Raíz de la aplicación.
class LylyricsApp extends ConsumerWidget {
  const LylyricsApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    return MaterialApp(
      title: 'Lylyrics',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: settings.get(Settings.themeIsDark)
          ? ThemeMode.dark
          : ThemeMode.light,
      home: const _Bootstrap(),
    );
  }

  /// Paleta de 3 colores: neutros suaves (gris claro / gris oscuro) + azul
  /// rey (acento principal) + ámbar (avisos).
  ///
  /// El azul rey se usa en 3 tonos del mismo tono, atados a roles: el azul
  /// base, un tinte claro (acento en oscuro) y un tinte pálido (contenedores
  /// en claro). El texto sobre azul es neutro (blanco o casi negro), no otro
  /// azul. Las superficies de ambos modos son neutras, sin llegar al blanco
  /// ni al negro puros para no cansar la vista.
  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    // Ámbar oscurecido para que sea legible sobre fondo claro.
    final amber = dark ? kAmber : const Color(0xFFB37400);
    final scheme = ColorScheme.fromSeed(
      seedColor: kRoyalBlue,
      brightness: brightness,
    ).copyWith(
      primary: dark ? kRoyalBlueLight : kRoyalBlue,
      onPrimary: dark ? const Color(0xFF1B1B1B) : Colors.white,
      primaryContainer: dark ? kRoyalBlue : kRoyalBluePale,
      onPrimaryContainer: dark ? Colors.white : const Color(0xFF1B1B1B),
      secondary: dark ? kRoyalBlueLight : kRoyalBlue,
      onSecondary: dark ? const Color(0xFF1B1B1B) : Colors.white,
      secondaryContainer: dark ? kRoyalBlue : kRoyalBluePale,
      onSecondaryContainer: dark ? Colors.white : const Color(0xFF1B1B1B),
      tertiary: amber,
      onTertiary: dark ? const Color(0xFF241A00) : Colors.white,
      tertiaryContainer:
          dark ? const Color(0xFF5A4300) : const Color(0xFFFFE2A6),
      onTertiaryContainer:
          dark ? const Color(0xFFFFE2A6) : const Color(0xFF241A00),
      error: amber,
      onError: dark ? const Color(0xFF241A00) : Colors.white,
      // Superficies neutras suavizadas (ni blanco ni negro puros).
      surface: dark ? const Color(0xFF1B1B1B) : const Color(0xFFEFEFEF),
      onSurface: dark ? const Color(0xFFDADADA) : const Color(0xFF2B2B2B),
      onSurfaceVariant: dark ? const Color(0xFFA6A6A6) : const Color(0xFF616161),
      surfaceContainerLowest:
          dark ? const Color(0xFF161616) : const Color(0xFFF6F6F6),
      surfaceContainerLow:
          dark ? const Color(0xFF202020) : const Color(0xFFE9E9E9),
      surfaceContainer: dark ? const Color(0xFF262626) : const Color(0xFFE3E3E3),
      surfaceContainerHigh:
          dark ? const Color(0xFF2D2D2D) : const Color(0xFFDCDCDC),
      surfaceContainerHighest:
          dark ? const Color(0xFF343434) : const Color(0xFFD5D5D5),
      outline: dark ? const Color(0xFF7A7A7A) : const Color(0xFF9E9E9E),
      outlineVariant: dark ? const Color(0xFF424242) : const Color(0xFFCFCFCF),
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor:
          dark ? const Color(0xFF1B1B1B) : const Color(0xFFEFEFEF),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      snackBarTheme:
          const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }
}

/// Prepara la caché y el motor de sincronización antes de mostrar la UI.
///
/// También muestra una pantalla de arranque si D-Bus no está disponible, que es
/// un fallo fatal en Linux y merece un mensaje claro en vez de un error rojo.
class _Bootstrap extends ConsumerStatefulWidget {
  const _Bootstrap();

  @override
  ConsumerState<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends ConsumerState<_Bootstrap> {
  late final Future<void> _ready;

  @override
  void initState() {
    super.initState();
    _ready = _initialize();
  }

  Future<void> _initialize() async {
    // 1. Abrir la caché (ruta según plataforma) y descartar lo que ya superó
    //    el TTL de 24 h. Se revisa solo al entrar en la app, sin temporizadores
    //    en segundo plano.
    final cache = ref.read(lyricsCacheProvider);
    await cache.init(path: await resolveCachePath());
    await cache.purgeExpired();

    // 2. Comprobar que hay un bus de sesión (imprescindible para MPRIS).
    // En Android no hay D-Bus: la fuente son las sesiones multimedia.
    if (!Platform.isAndroid) {
      final busAddress = Platform.environment['DBUS_SESSION_BUS_ADDRESS'];
      if (busAddress == null || busAddress.isEmpty) {
        // En sistemas sin variable puede existir igualmente el socket por defecto.
        final socket = '${Platform.environment['XDG_RUNTIME_DIR'] ?? '/run/user/${Platform.environment['UID'] ?? '1000'}'}/bus';
        if (!File(socket).existsSync()) {
          throw const _DbusUnavailable();
        }
      }
    }

    // 3. Arrancar la fuente de medios y el motor.
    final source = ref.read(mediaSourceProvider);
    if (source is MprisMediaSource) {
      await source.ready;
    }

    // 4. Registrar la caché para cerrarla al salir de la app.
    ref.read(keepAliveRegistry.notifier).add(cache);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _FatalError(error: snapshot.error!);
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return const LyricsHomeScreen();
      },
    );
  }
}

/// Excepción interna para el mensaje de "no hay bus de sesión".
class _DbusUnavailable implements Exception {
  const _DbusUnavailable();
}

/// Pantalla de error fatal.
class _FatalError extends StatelessWidget {
  const _FatalError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 16),
              Text(
                'Lylyrics needs D-Bus to talk to the player',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(
                'DBUS_SESSION_BUS_ADDRESS was not found. This happens when the '
                'app is launched outside a graphical desktop session.\n\n'
                'Launch it from a normal desktop terminal, or check that '
                'dbus-x11 is installed.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.4,
                    ),
              ),
              const SizedBox(height: 12),
              Text(
                'Detail: $error',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Registro de recursos que deben cerrarse al destruir la app.
///
/// Es un `StateProvider` simple en lugar de un `Provider` porque no queremos
/// lógico de negocio: solo "recuérdate cerrar esto al final".
final keepAliveRegistry = NotifierProvider<KeepAliveRegistry, List<LyricsCache>>(
    KeepAliveRegistry.new);

/// Lista de cachés abiertas. [closeAll] se invoca al cerrar la ventana.
class KeepAliveRegistry extends Notifier<List<LyricsCache>> {
  @override
  List<LyricsCache> build() => [];

  void add(LyricsCache cache) {
    if (state.contains(cache)) return;
    state = [...state, cache];
  }

  Future<void> closeAll() async {
    final caches = [...state];
    state = [];
    for (final cache in caches) {
      await cache.close();
    }
  }
}

/// Cierra los recursos abiertos cuando el usuario cierra la ventana.
///
/// `window_manager` no expone un `Provider`, así que el listener recibe el
/// contenedor y libera lo que la app tenga abierto.
class _WindowCloser extends WindowListener {
  _WindowCloser(this._container);

  final ProviderContainer _container;

  @override
  void onWindowClose() {
    _container.read(keepAliveRegistry.notifier).closeAll().ignore();
  }
}
