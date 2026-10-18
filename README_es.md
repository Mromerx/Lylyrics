# Lylyrics

Visor de letras sincronizadas para reproductores **MPRIS** en Linux y para las
sesiones multimedia de **Android**. Detecta lo que suena, busca la letra, la
sincroniza con la reproducción y la muestra resaltando la línea actual.

La interfaz está en inglés; el código y los comentarios, en español.

## Características

- **Sincronización en tiempo real** con la posición del reproductor (reloj
  interpolado, precisión de ~100 ms). Resalta la línea que toca y atenúa el
  resto.
- **Auto-scroll suave** que sigue la canción. Si se hace scroll manual se
  pausa unos segundos y aparece un botón para volver a la línea actual.
- **Múltiples fuentes de letra, en cascada:**
  1. [LRCLIB](https://lrclib.net) — fuente principal, con letra sincronizada.
  2. **NetEase Cloud Music** — primer respaldo (endpoints web públicos).
  3. **Genius** — último respaldo (scraping, letra plana sin tiempos).
- **Búsqueda manual** (lupa): consulta LRCLIB, NetEase y Genius a la vez y
  muestra todas las coincidencias con su origen y si vienen sincronizadas.
- **Traducción por línea** (Google Translate, sin API key) al idioma que elija
  el usuario.
- **Colores por palabra**: cada palabra de la línea original recibe un tono
  pastel propio y su traducción hereda el mismo color, para ver qué palabra
  corresponde a cuál.

  > **Aviso:** este emparejamiento **suele fallar en identificar qué palabra
  > original corresponde a qué palabra traducida**. El color solo es fiable
  > cuando el alineado por contenido encuentra el enlace; en el resto de casos
  > se recurre a un reparto posicional que se desalinea. Los fallos son más
  > frecuentes cuando:
  > - el idioma usa un alfabeto no latino (ruso, japonés, coreano, chino,
  >   árabe, hindi), donde el normalizador descarta los tokens;
  > - el idioma no separa palabras con espacios (chino, japonés), donde toda la
  >   línea acaba con un único color;
  > - la traducción **reordena** palabras o cambia su número (artículos,
  >   preposiciones añadidas), ya que el reparto posicional pinta el color de
  >   otra palabra e incluso repite colores;
  > - la canción supera los límites internos de cobertura léxica (≈250 palabras
  >   únicas, ≈25 líneas contextuales), dejando palabras sin enlace;
  > - hay palabras repetidas, contracciones o puntuación contada como palabra,
  >   que desplazan los índices.
- **Traducción de palabra suelta**: clic derecho (escritorio) o pulsación larga
  (Android) sobre una palabra muestra su traducción exacta en un diálogo.
- **Salto a un punto de la canción**: clic o toque sobre una línea hace `seek`
  en el reproductor.
- **Desfase por canción**: ajusta la sincronía ±10 s con saltos de 0.5 s, y
  recuerda el offset de cada pista.
- **Selector de reproductor** cuando hay más de uno activo (MPRIS o sesiones
  Android).
- **Caché local de las letras de LRCLIB** en SQLite con TTL de 24 h: al
  arrancar se descarta lo caducado y dentro de ese plazo no se repiten
  peticiones. NetEase y Genius son respaldos que no se cachean.
- **Ajustes persistentes**: tamaño de fuente, tema claro/oscuro, colores por
  palabra y idioma destino de la traducción.
- **Atajo de teclado**: `Espacio` pausa/reproduce cuando la app tiene el foco.

## Idiomas de traducción

La traducción (por línea y palabra suelta) admite estos idiomas destino,
independientemente del idioma original de la canción:

Inglés, español, francés, alemán, italiano, portugués, ruso, japonés, coreano,
chino simplificado, árabe e hindi.

## Requisitos

| Plataforma | Necesitas |
| --- | --- |
| Linux | Flutter (estable), un bus de sesión D-Bus y `libsqlite3` del sistema |
| Android | Flutter (estable), Android SDK, permiso de **acceso a notificaciones** para leer las sesiones multimedia |

En Linux la app **necesita D-Bus**: si no encuentra el bus de sesión lo avisa
con una pantalla de error en lugar de fallar de forma opaca.

## Puesta en marcha (Linux)

```bash
git clone <repo>
cd lylyrics
flutter pub get
flutter run -d linux
```

Compilar:

```bash
flutter build linux --release
```

## Puesta en marcha (Android)

```bash
flutter pub get
flutter run -d <dispositivo>
```

La primera vez hay que conceder **Acceso a notificaciones** a Lylyrics desde
los ajustes del sistema; sin ese permiso el servicio nativo no puede leer qué
está sonando.

## Tests

```bash
flutter test
```

Cubren el parseo LRC, el motor de sincronización, la caché, los proveedores de
letras, el alineado palabra a palabra, los ajustes y las fuentes de medios
(pura lógica, sin D-Bus ni Android).

## Herramientas de diagnóstico

- `tool/check_mpris.sh` — lista los reproductores MPRIS del bus de sesión y sus
  metadatos. Acepta un filtro: `./tool/check_mpris.sh vlc`.
- `dart run tool/probe_lrclib.dart` — sonda real contra LRCLIB sin UI.
- `dart run tool/probe_netease.dart` — sonda real contra NetEase sin UI.

## Arquitectura

La UI y los servicios nunca hablan directamente con MPRIS, D-Bus ni Android:
todo pasa por contratos, así que añadir una plataforma o una fuente de letra
nueva no obliga a tocar el resto.

```
lib/
├── core/
│   ├── interfaces/    # MediaSource y LyricsProvider (los contratos)
│   └── models/        # TrackInfo, PlaybackState, Lyrics
├── platform/
│   ├── linux/         # MprisMediaSource (D-Bus + MPRIS)
│   └── android/       # AndroidMediaSource (canal con el servicio nativo)
├── services/
│   ├── lrclib_provider.dart      # fuente principal de letras
│   ├── netease_provider.dart     # respaldo NetEase
│   ├── genius_scraper.dart       # respaldo Genius
│   ├── lyrics_cache.dart         # caché SQLite
│   ├── sync_engine.dart          # línea actual según la posición
│   ├── translation_service.dart  # Google Translate (sin API key)
│   └── token_alignment.dart      # alineado palabra-por-palabra
├── state/providers/   # Riverpod: cablea fuentes, caché y UI
└── ui/                # Pantallas y widgets
```

**Puntos clave del diseño:**

- `MediaSource` abstrae la reproducción. Linux implementa MPRIS; Android, un
  canal con un `MediaListenerService` nativo. Los servicios no saben cuál está
  activo.
- El **motor de sincronización** recibe una posición interpolada (MPRIS no
  emite la posición continua) y aplica el offset a los tiempos de línea, no a
  la posición: así el desfase solo afecta a la línea resaltada.
- La **traducción palabra a palabra** se apoya en los segmentos alineados que
  devuelve Google (`dt=t` / `dt=bd`) para emparejar cada palabra original con
  su traducción, sin diccionarios locales.
