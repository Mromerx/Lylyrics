# Lylyrics

Visor de letras sincronizadas para reproductores MPRIS en Linux.

Detecta la canción que se reproduce en **FreeTube** (o cualquier reproductor
MPRIS), busca su letra en [LRCLIB](https://lrclib.net) y la muestra
resaltando la línea actual en tiempo real.

## Requisitos

Para **usar** el binario solo necesitas tu distribución con GTK 3 y
`dbus-x11`.

Para **compilar** desde el código:

| Paquete | Para qué |
|---|---|
| `flutter` | SDK (estable, 3.27 o superior) |
| `clang` | compilador de C++ que usa el runner de Flutter |
| `cmake` | generación de los `CMakeLists.txt` del bundle |
| `ninja-build` | backend de construcción |
| `pkg-config` | localizar las bibliotecas del sistema |
| `libgtk-3-dev` | toolkit de la ventana |
| `libsqlite3-dev` | backend de la caché (sqflite_common_ffi) |

En Arch:

```bash
sudo pacman -S clang cmake ninja pkg-config gtk3 sqlite dbus
```

El ejecutable resultante queda en
`build/linux/x64/release/bundle/lylyrics`.

## Cómo probarlo con FreeTube

### 1. FreeTube debe exponer MPRIS

FreeTube es Electron y expone MPRIS **cuando lo activas**:

> Ajustes → Interfaz → marca **"Integración D-Bus / MPRIS"** (en algunas
> versiones aparece como *Enable MPRIS D-Bus Interface*). Reinicia FreeTube.

Sin esto, FreeTube no aparece en el bus y la app no puede leer nada.

### 2. Comprueba que el bus lo ve

```bash
playerctl -l                    # lista los reproductores
playerctl metadata              # título, artista, álbum de lo que suena
playerctl position
playerctl status                # Playing / Paused / Stopped
```

Alternativa sin `playerctl`:

```bash
busctl --user list | grep -i mpris
```

Si no aparece nada en ninguno de los dos, vuelve al paso 1.

### 3. Sonda propia del proyecto

Este repositorio trae una sonda que imprime los reproductores y su metadata
actual. Es el primer sitio donde mirar si algo falla:

```bash
./tool/check_mpris.sh
```

### 4. Lanza la app

```bash
flutter run -d linux
```

 reproduce una canción y la letra debe aparecer sincronizada.

### 5. Prueba la búsqueda sin depender del reproductor

Para verificar la parte de LRCLIB aislada, con casos reales:

```bash
dart run tool/probe_lrclib.dart
```

Imprime, para títulos sucios tal como los da FreeTube, si se encontró la letra y
las primeras líneas con su marca de tiempo.

## Cómo funciona

```
FreeTube ──MPRIS/D-Bus──► MprisMediaSource ──TrackInfo──► MetadataNormalizer
                                                                    │
                                                              TitleCandidate
                                                                    │
                                                                    ▼
                                            LrclibProvider ──HTTP──► lrclib.net
                                                     │
                                                  Lyrics ──► SyncEngine ──► UI
                                          (caché SQLite)
```

- `core/interfaces/media_source.dart` es el contrato. La UI y los servicios no
  saben qué es D-Bus, así que añadir Android/NewTube u otra fuente más adelante
  es implementar esa interfaz y registrarla en `mediaSourceProvider`.
- `core/interfaces/lyrics_provider.dart` permite cambiar de fuente de letras.
- El `User-Agent` se define en `kUserAgent`
  (`lib/state/providers/app_providers.dart`). LRCLIB es público y **no pide
  API key**, pero sí pide poder identificar al cliente: pon tu correo ahí si
  publicas la app.

### Sincronización

`SyncEngine` mantiene un reloj interpolado: si el reproductor informa
`posición = P` en el instante `T`, la posición real es
`P + (ahora - T) × velocidad`. Cada nueva lectura de `PlaybackState` recalibra
el reloj, así que un seek o un cambio de velocidad no descoloca la letra.

MPRIS no emite señales de posición, solo de metadatos y de `Seeked`. Por eso
`MprisMediaSource` hace *polling* de `Position` **cada segundo y solo mientras
suena**; en pausa no hay temporizadores corriendo.

### Desfase (offset)

Si la letra va adelantada o atrasada, los botones `−0.1 s` / `+0.1 s` de la
barra inferior corrigen el resaltado sin tocar la posición real. El límite es
±10 s. El desfase se guarda por canción.

## Problemas frecuentes

**"No se detectó ningún reproductor MPRIS"**
:   Falta el paso 1 (activar MPRIS en FreeTube) o la app se lanzó fuera de la
    sesión gráfica. Comprueba que `DBUS_SESSION_BUS_ADDRESS` está definido.

**Aparece la canción pero se queda buscando**
:   Comprueba la conexión a internet. Si hay proxy, `http` no lo usa: exporta
    `https_proxy` antes de lanzar la app.

**Sale "No se encontró la letra"**
:   LRCLIB no tiene esa canción, o la tiene con otro título/artista. Usa el
    botón **"Buscar con otros datos"** y corrige el texto a mano. El resultado
    se guarda en caché.

**La letra no va alineada**
:   Ajusta con el offset. Si la línea resaltada va medio compás desviada, es
    un desfase entre la portada de audio del vídeo de YouTube y el audio de
    LRCLIB; el offset lo resuelve.

**El título sale en mayúsculas o con corchetes**
:   El normalizador los limpia, pero si el título real difiere mucho del
    guardado en LRCLIB puede no encontrar coincidencia exacta.

## Limitaciones conocidas

- **Solo Linux y solo dentro del bus de sesión.** No hay soporte de systemd como
  unidad de usuario, ni Wayland con capas Always-on-Top variables.
- **Sin `newPipe` / Android.** La interfaz `MediaSource` está preparada, pero
  no está implementado.
- **Letra plana sin sincronizar**: si LRCLIB solo tiene `plainLyrics`, se
  muestra como texto con scroll libre, sin resaltado.
- **Doble fuente de tiempo**: YouTube y LRCLIB pueden estar desincronizadas
  entre sí. El offset manual existe justo para eso; no se puede corregir solo.
- **Caché negativa de 24 h**: si LRCLIB sube una letra para una canción que
  antes no tenía, habrá que esperar o borrar la caché.
- **Selección de reproductor automática**: con varios reproductores sonando a
  la vez se prioriza FreeTube y luego el que esté en `Playing`. Si hay un solo
  reproductor en `Playing` pero no es el que quieres, usa el selector del
  `AppBar`.
- **El `User-Agent` no se configura por archivo.** Está como constante en el
  código a propósito, para que quede claro qué se envía a LRCLIB.

## Tests

```bash
flutter test
```

294 tests cubren el parseo LRC, el motor de sincronización, el normalizador de
metadatos, el parseo de señales MPRIS, el proveedor LRCLIB (con respuestas
simuladas) y la caché. Ninguno toca la red.

## Estructura

```
lib/
  core/
    models/       track_info, playback_state, lyrics   (contratos)
    interfaces/   media_source, lyrics_provider        (contratos)
  platform/linux/ mpris_media_source.dart              (D-Bus)
  services/       metadata_normalizer, lrclib_provider,
                  lyrics_cache, lrc_parser, sync_engine
  state/providers/ app_providers.dart                  (Riverpod)
  ui/             screens/, widgets/
tool/
  check_mpris.sh    sonda de diagnóstico del bus
  probe_lrclib.dart prueba real de la búsqueda
```