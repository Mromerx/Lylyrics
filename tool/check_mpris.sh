#!/usr/bin/env bash
#
# check_mpris.sh — diagnóstico rápido de los reproductores MPRIS publicados en
# el bus de sesión. Sirve para comprobar a mano lo mismo que la app ve por
# D-Bus: qué reproductores hay, qué dicen de sí mismos (Identity, DesktopEntry)
# y qué metadatos exponen.
#
# Uso:
#   ./tool/check_mpris.sh              # todos los reproductores MPRIS
#   ./tool/check_mpris.sh freetube     # solo los que casen con "freetube"
#                                      # (el texto se trata como regex)
#   MPRIS_TOOL=dbus-send ./tool/check_mpris.sh   # fuerza el plan B
#
# Herramientas: `busctl` (systemd) o `dbus-send` como alternativa.

set -uo pipefail

# Los nombres de propiedades e interfaces los impone la especificación MPRIS,
# así que se mantienen en inglés; los comentarios, en español.
readonly MPRIS_PREFIX='org.mpris.MediaPlayer2.'
readonly MPRIS_PATH='/org/mpris/MediaPlayer2'
readonly MPRIS_ROOT_IFACE='org.mpris.MediaPlayer2'
readonly MPRIS_PLAYER_IFACE='org.mpris.MediaPlayer2.Player'
readonly DBUS_PROPS_IFACE='org.freedesktop.DBus.Properties'
readonly DBUS_SERVICE='org.freedesktop.DBus'
readonly DBUS_PATH='/org/freedesktop/DBus'

readonly FILTER="${1:-}"

# Detección de herramienta, con escape manual: MPRIS_TOOL=dbus-send fuerza el
# plan B aunque exista busctl (útil para comparar las dos salidas).
if [ -n "${MPRIS_TOOL:-}" ]; then
  readonly TOOL_NAME="$MPRIS_TOOL"
else
  readonly TOOL_NAME="$(
    if command -v busctl >/dev/null 2>&1; then
      printf 'busctl'
    elif command -v dbus-send >/dev/null 2>&1; then
      printf 'dbus-send'
    else
      printf ''
    fi
  )"
fi

readonly BUSCTL_BIN="$(
  if [ "$TOOL_NAME" = 'busctl' ]; then
    command -v busctl 2>/dev/null || true
  fi
)"

# Colapsa salidas multilínea (los dict de dbus-send ocupan varias líneas) en
# una sola línea legible.
compact() {
  tr '\n' ' ' | tr -s ' ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# clean_value (toma la entrada por stdin): quita el marcador de tipo que
# anteponen las dos herramientas a cada valor D-Bus y normaliza las listas de
# cadenas a "A, B".
#   busctl    s "FreeTube" | as 2 "A", "B" | x 192061000
#   dbus-send string "FreeTube" | array [ string "A", string "B" ]
clean_value() {
  local value previous pass
  value=$(compact)
  # Cada pasada quita un nivel de "array [ string ... ]" o "as 2 ...". Se
  # repite hasta que el valor no cambie porque el orden de los marcadores de
  # tipo depende de cómo los imprime cada herramienta.
  for pass in 1 2 3 4 5; do
    previous="$value"
    value=$(printf '%s' "$value" | sed \
      -e 's/^\[ //' \
      -e 's/ \]$//' \
      -e 's/^\(as\|ao\|ay\|s\|o\|x\|d\|b\|i\|u\|n\|q\|g\|y\|v\) //' \
      -e 's/^\(array\|string\|int64\|int32\|uint32\|uint64\|objectpath\|object\|double\|boolean\) //' \
      -e 's/^path //' \
      -e 's/^[0-9][0-9]* //' \
      -e 's/", "\{0,1\}string "/"", "/g' \
      -e 's/"//g' \
      | compact)
    if [ "$value" = "$previous" ]; then
      break
    fi
  done
  printf '%s' "$value"
}

# strip_variant: limpia el valor de una propiedad escalar y descarta la
# cabecera "method return ..." que añade dbus-send.
strip_variant() {
  case "$TOOL_NAME" in
    busctl) clean_value ;;
    *)
      sed -e 's/^.*variant[[:space:]][[:space:]]*//' | clean_value
      ;;
  esac
}

# list_players: nombres de bus MPRIS presentes ahora mismo.
list_players() {
  if [ -n "$BUSCTL_BIN" ]; then
    "$BUSCTL_BIN" --user --no-pager list 2>/dev/null \
      | awk 'NR > 1 { print $1 }' \
      | grep -E "^${MPRIS_PREFIX}" || true
  else
    dbus-send --session --print-reply \
      --dest="$DBUS_SERVICE" "$DBUS_PATH" "$DBUS_SERVICE.ListNames" 2>/dev/null \
      | sed -n 's/^[[:space:]]*string "\(.*\)"[[:space:]]*$/\1/p' \
      | grep -E "^${MPRIS_PREFIX}" || true
  fi
}

# get_property_raw <bus> <interface> <property>
# Devuelve el valor tal cual lo imprime la herramienta, colapsado a una línea.
get_property_raw() {
  local bus="$1" iface="$2" prop="$3" out
  if [ -n "$BUSCTL_BIN" ]; then
    out=$("$BUSCTL_BIN" --user --no-pager get-property "$bus" "$MPRIS_PATH" \
      "$iface" "$prop" 2>/dev/null)
  else
    out=$(dbus-send --session --print-reply \
      --dest="$bus" "$MPRIS_PATH" "$DBUS_PROPS_IFACE.Get" \
      "string:$iface" "string:$prop" 2>/dev/null)
  fi
  printf '%s' "$out" | compact
}

# get_property <bus> <interface> <property>
# Igual, pero con el valor ya limpio (sin marcador de tipo).
get_property() {
  get_property_raw "$1" "$2" "$3" | strip_variant
}

# meta_field <dict Metadata> <clave>
# D-Bus no permite pedir una subclave de `Metadata` por separado, así que
# sacamos el dict entero y lo troceamos aquí. Todas las claves de metadatos
# MPRIS llevan el prefijo "xesam:" o "mpris:", y eso nos sirve de ancla para
# separar un valor del siguiente.
meta_field() {
  local raw="$1" key="$2" value
  [ -z "$raw" ] && return 0
  case "$TOOL_NAME" in
    busctl)
      # Formato: a{sv} 6 "xesam:title" s "Blinding Lights" "xesam:url" s "..."
      value=$(printf '%s' "$raw" \
        | sed -n "s/^.*\"$key\"[[:space:]][[:space:]]*//p" \
        | sed 's/ "\(xesam\|mpris\):[^"]*".*$//')
      ;;
    *)
      # Formato: ... dict entry( string "xesam:title" variant string "..." ) ...
      # Detrás del valor viene siempre el cierre del "dict entry(" y, si era
      # el último del dict, también el del array exterior.
      value=$(printf '%s' "$raw" \
        | sed -n "s/^.*string \"$key\"[[:space:]][[:space:]]*variant[[:space:]][[:space:]]*//p" \
        | sed -e 's/ dict entry(.*$//' \
              -e 's/ \]$//' \
              -e 's/ )$//')
      ;;
  esac
  printf '%s' "$value" | clean_value
}

# human_length <valor de mpris:length o de Position>
# MPRIS los expresa en microsegundos; los pasamos a segundos y a mm:ss.
human_length() {
  local raw="$1" us
  us=$(printf '%s' "$raw" | grep -oE '\-?[0-9]+' | head -1)
  if [ -n "$us" ] && [ "$us" -gt 0 ] 2>/dev/null; then
    awk -v us="$us" \
      'BEGIN { printf "%d us (%02d:%05.2f)", us, int(us / 60000000), (us % 60000000) / 1000000 }'
  else
    printf '%s' "${raw:-<no disponible>}"
  fi
}

# show_field <etiqueta> <valor>
show_field() {
  local value
  value=$(printf '%s' "${2:-}" | compact)
  printf '  %-16s: %s\n' "$1" "${value:-<no disponible>}"
}

# --- Entorno --------------------------------------------------------------

printf '== Entorno ==\n'
if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  printf '  %s: definido (%s)\n' 'DBUS_SESSION_BUS_ADDRESS' \
    "$DBUS_SESSION_BUS_ADDRESS"
else
  printf '  %s: NO definido\n' 'DBUS_SESSION_BUS_ADDRESS'
  printf '  No hay bus de sesion, asi que la app tampoco podra hablar MPRIS.\n'
  printf '  Exporta DBUS_SESSION_BUS_ADDRESS y vuelve a ejecutar el script.\n'
  exit 1
fi

if [ -z "$TOOL_NAME" ] || ! command -v "$TOOL_NAME" >/dev/null 2>&1; then
  printf '  %-16s: %s\n' 'herramienta' "${TOOL_NAME:-ninguna}"
  printf '  Instala systemd (busctl) o dbus (dbus-send) y reintenta.\n'
  exit 1
fi
printf '  %-16s: %s\n' 'herramienta' "$TOOL_NAME"
printf '  %-16s: %s\n' 'filtro' "${FILTER:-(ninguno)}"
printf '\n'

# --- Reproductores --------------------------------------------------------

if [ -n "$FILTER" ]; then
  PLAYERS=$(list_players | grep -Ei "$FILTER" || true)
else
  PLAYERS=$(list_players)
fi

if [ -z "$PLAYERS" ]; then
  if [ -n "$FILTER" ]; then
    printf 'Ningun reproductor MPRIS casa con el filtro "%s".\n' "$FILTER"
  else
    printf 'No hay ningun reproductor MPRIS en el bus de sesion.\n'
    printf 'Si esperabas ver alguno, comprueba que lo exponga (por ejemplo el\n'
    printf 'plugin MPRIS del navegador, el de Spotify o el de VLC).\n'
  fi
  exit 0
fi

COUNT=0
while IFS= read -r BUS; do
  [ -z "$BUS" ] && continue
  COUNT=$((COUNT + 1))
  printf '== %s ==\n' "$BUS"

  # Interfaz raíz org.mpris.MediaPlayer2: quién es el reproductor.
  show_field 'Identity' "$(get_property "$BUS" "$MPRIS_ROOT_IFACE" 'Identity')"
  show_field 'DesktopEntry' \
    "$(get_property "$BUS" "$MPRIS_ROOT_IFACE" 'DesktopEntry')"

  # Interfaz org.mpris.MediaPlayer2.Player: qué está sonando.
  METADATA=$(get_property_raw "$BUS" "$MPRIS_PLAYER_IFACE" 'Metadata')
  show_field 'PlaybackStatus' \
    "$(get_property "$BUS" "$MPRIS_PLAYER_IFACE" 'PlaybackStatus')"
  show_field 'xesam:title' "$(meta_field "$METADATA" 'xesam:title')"
  show_field 'xesam:artist' "$(meta_field "$METADATA" 'xesam:artist')"
  show_field 'xesam:album' "$(meta_field "$METADATA" 'xesam:album')"
  show_field 'mpris:length' \
    "$(human_length "$(meta_field "$METADATA" 'mpris:length')")"
  show_field 'mpris:trackid' "$(meta_field "$METADATA" 'mpris:trackid')"

  # Útiles para depurar la sincronía de la letra.
  show_field 'Position' \
    "$(human_length "$(get_property "$BUS" "$MPRIS_PLAYER_IFACE" 'Position')")"
  show_field 'Rate' "$(get_property "$BUS" "$MPRIS_PLAYER_IFACE" 'Rate')"
  show_field 'Volume' "$(get_property "$BUS" "$MPRIS_PLAYER_IFACE" 'Volume')"
  printf '\n'
done <<<"$PLAYERS"

printf '%d reproductor(es) MPRIS en el bus de sesion.\n' "$COUNT"