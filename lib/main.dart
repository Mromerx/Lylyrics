import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'platform/linux/mpris_media_source.dart';
import 'services/lyrics_cache.dart';
import 'state/providers/app_providers.dart';
import 'ui/screens/lyrics_home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // window_manager necesita inicializarse antes de usar la ventana.
  await windowManager.ensureInitialized();

  const options = WindowOptions(
    size: Size(880, 700),
    minimumSize: Size(420, 420),
    center: true,
    title: 'Lylyrics',
    titleBarStyle: TitleBarStyle.normal,
    backgroundColor: Color(0xFF101014),
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  // Cerramos streams, timers y la base de datos al salir de la ventana, para
  // no dejar conexiones D-Bus colgando.
  // Contenedor explícito para poder soltar los recursos al cerrar la ventana
  // (suscripciones D-Bus, timers y la base de datos de caché).
  final container = ProviderContainer();
  windowManager.addListener(_WindowCloser(container));

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const LylyricsApp(),
    ),
  );
}

/// Raíz de la aplicación.
class LylyricsApp extends ConsumerWidget {
  const LylyricsApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(uiSettingsProvider);
    return MaterialApp(
      title: 'Lylyrics',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: settings.themeModeIsDark ? ThemeMode.dark : ThemeMode.light,
      home: const _Bootstrap(),
    );
  }

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF6C4DF6),
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: brightness == Brightness.dark
          ? const Color(0xFF101014)
          : scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
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
    // 1. Abrir la caché.
    await ref.read(lyricsCacheProvider).init();

    // 2. Comprobar que hay un bus de sesión (imprescindible para MPRIS).
    final busAddress = Platform.environment['DBUS_SESSION_BUS_ADDRESS'];
    if (busAddress == null || busAddress.isEmpty) {
      // En sistemas sin variable puede existir igualmente el socket por defecto.
      final socket = '${Platform.environment['XDG_RUNTIME_DIR'] ?? '/run/user/${Platform.environment['UID'] ?? '1000'}'}/bus';
      if (!File(socket).existsSync()) {
        throw const _DbusUnavailable();
      }
    }

    // 3. Arrancar la fuente de medios y el motor.
    final source = ref.read(mediaSourceProvider);
    if (source is MprisMediaSource) {
      await source.ready;
    }

    // 4. Registrar la caché para cerrarla al salir de la app.
    ref.read(keepAliveRegistry.notifier).add(
          ref.read(lyricsCacheProvider),
        );
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
                'Lylyrics necesita D-Bus para hablar con el reproductor',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Text(
                'No se encontró DBUS_SESSION_BUS_ADDRESS. Esto pasa cuando la '
                'app se lanza fuera de una sesión gráfica de escritorio.\n\n'
                'Lánzala desde una terminal normal de tu escritorio, o revise '
                'que dbus-x11 esté instalado.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Text(
                'Detalle: $error',
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
