#!/usr/bin/env bash
# Empaqueta el bundle de escritorio de Flutter (build/linux/x64/release/bundle)
# en un AppImage real, autocontenido y ejecutable.
#
# Uso:
#   bash linux/packaging/build-appimage.sh [VERSION]
#
# Si no se indica VERSION se lee del campo `version` de pubspec.yaml.
# Requiere haber ejecutado antes: flutter build linux --release
set -euo pipefail

APP_NAME="lylyrics"
ARCH="x86_64"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  VERSION="$(grep -E '^version:' "$ROOT_DIR/pubspec.yaml" | head -n1 | awk '{print $2}' | cut -d+ -f1)"
fi
if [ -z "$VERSION" ]; then
  echo "ERROR: no se pudo determinar la versión." >&2
  exit 1
fi

BUNDLE_DIR="$ROOT_DIR/build/linux/x64/release/bundle"
EXECUTABLE="$BUNDLE_DIR/$APP_NAME"
ICON_SRC="$ROOT_DIR/assets/app_icon.png"
DESKTOP_SRC="$SCRIPT_DIR/$APP_NAME.desktop"

BUILD_DIR="$ROOT_DIR/build/appimage"
APPDIR="$BUILD_DIR/${APP_NAME}.AppDir"
TOOLS_DIR="$BUILD_DIR/tools"
OUTPUT_DIR="$BUILD_DIR/out"
FINAL_APPIMAGE="$BUILD_DIR/${APP_NAME}-${VERSION}-${ARCH}.AppImage"

for required in "$EXECUTABLE" "$ICON_SRC" "$DESKTOP_SRC"; do
  if [ ! -e "$required" ]; then
    echo "ERROR: recurso requerido no encontrado: $required" >&2
    exit 1
  fi
done
if [ ! -x "$EXECUTABLE" ]; then
  echo "ERROR: $EXECUTABLE no es ejecutable. Ejecuta 'flutter build linux --release'." >&2
  exit 1
fi

echo "==> Preparando AppDir en $APPDIR"
rm -rf "$APPDIR" "$OUTPUT_DIR"
mkdir -p \
  "$APPDIR/usr/bin" \
  "$APPDIR/usr/share/applications" \
  "$APPDIR/usr/share/icons/hicolor/256x256/apps" \
  "$OUTPUT_DIR" \
  "$TOOLS_DIR"

# El bundle de Flutter es relocalizable: el ejecutable espera `lib/` y `data/`
# junto a él (RPATH $ORIGIN/lib). Se copia tal cual bajo usr/bin.
cp -a "$BUNDLE_DIR/." "$APPDIR/usr/bin/"

# Desktop entry + icono real del proyecto.
install -m 0644 "$DESKTOP_SRC" "$APPDIR/$APP_NAME.desktop"
install -m 0644 "$DESKTOP_SRC" "$APPDIR/usr/share/applications/$APP_NAME.desktop"
install -m 0644 "$ICON_SRC" "$APPDIR/$APP_NAME.png"
install -m 0644 "$ICON_SRC" "$APPDIR/usr/share/icons/hicolor/256x256/apps/$APP_NAME.png"

# AppRun: punto de entrada estándar del AppImage.
ln -sf "usr/bin/$APP_NAME" "$APPDIR/AppRun"

echo "==> Obteniendo herramientas de empaquetado (linuxdeploy + plugin GTK)"
LINUXDEPLOY="$TOOLS_DIR/linuxdeploy-${ARCH}.AppImage"
GTK_PLUGIN="$TOOLS_DIR/linuxdeploy-plugin-gtk.sh"

if [ ! -x "$LINUXDEPLOY" ]; then
  curl -fsSL -o "$LINUXDEPLOY" \
    "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${ARCH}.AppImage"
  chmod +x "$LINUXDEPLOY"
fi
if [ ! -x "$GTK_PLUGIN" ]; then
  curl -fsSL -o "$GTK_PLUGIN" \
    "https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh"
  chmod +x "$GTK_PLUGIN"
fi

export PATH="$TOOLS_DIR:$PATH"
export APPIMAGE_EXTRACT_AND_RUN=1
export DEPLOY_GTK_VERSION=3
export NO_STRIP=1

echo "==> Desplegando dependencias de sistema y generando AppImage"
(
  cd "$OUTPUT_DIR"
  "$LINUXDEPLOY" \
    --appdir "$APPDIR" \
    --executable "$APPDIR/usr/bin/$APP_NAME" \
    --desktop-file "$APPDIR/$APP_NAME.desktop" \
    --icon-file "$APPDIR/$APP_NAME.png" \
    --plugin gtk \
    --output appimage
)

PRODUCED="$(find "$OUTPUT_DIR" -maxdepth 1 -name '*.AppImage' -print -quit)"
if [ -z "$PRODUCED" ]; then
  echo "ERROR: linuxdeploy no generó ningún AppImage." >&2
  exit 1
fi

mv -f "$PRODUCED" "$FINAL_APPIMAGE"
chmod +x "$FINAL_APPIMAGE"

echo "==> Verificando estructura del AppImage"
if ! file "$FINAL_APPIMAGE" | grep -q "ELF"; then
  echo "ERROR: $FINAL_APPIMAGE no es un binario ELF válido." >&2
  exit 1
fi

EXTRACT_DIR="$(mktemp -d)"
trap 'rm -rf "$EXTRACT_DIR"' EXIT
(
  cd "$EXTRACT_DIR"
  "$FINAL_APPIMAGE" --appimage-extract >/dev/null
  test -x "squashfs-root/AppRun"
  test -f "squashfs-root/usr/bin/$APP_NAME"
  test -d "squashfs-root/usr/bin/data/flutter_assets"
  test -f "squashfs-root/usr/share/applications/$APP_NAME.desktop"
)

echo "==> AppImage listo: $FINAL_APPIMAGE"
ls -lh "$FINAL_APPIMAGE"
