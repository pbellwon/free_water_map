#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# DarmowaKranówka
# Pełna aktualizacja statycznych stron SEO miast
# ============================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WEB_DIR="$ROOT_DIR/web"
BUILD_DIR="$ROOT_DIR/build/web"

MIGRATION_SCRIPT="$ROOT_DIR/functions/migrate_city.js"
GENERATOR_SCRIPT="$ROOT_DIR/scripts/generate_city_pages.js"

echo
echo "=========================================="
echo " DarmowaKranówka — update stron miast"
echo "=========================================="
echo

cd "$ROOT_DIR"

# ------------------------------------------------------------
# 1. Sprawdzenie wymaganych plików i katalogów
# ------------------------------------------------------------

if [ ! -f "$MIGRATION_SCRIPT" ]; then
  echo "BŁĄD: Brak functions/migrate_city.js"
  exit 1
fi

if [ ! -f "$GENERATOR_SCRIPT" ]; then
  echo "BŁĄD: Brak scripts/generate_city_pages.js"
  exit 1
fi

if [ ! -d "$WEB_DIR" ]; then
  echo "BŁĄD: Brak katalogu web/"
  exit 1
fi

if [ ! -d "$BUILD_DIR" ]; then
  echo "BŁĄD: Brak build/web"
  echo
  echo "Najpierw musi istnieć aktualny build aplikacji."
  exit 1
fi

# ------------------------------------------------------------
# 2. Uzupełnienie city + citySlug dla nowych lokali
# ------------------------------------------------------------

echo "1/6 Uzupełnianie city + citySlug..."
echo

node "$MIGRATION_SCRIPT"

echo

# ------------------------------------------------------------
# 3. Odczyt poprzednich stron miast z sitemap.xml
# ------------------------------------------------------------

OLD_CITY_SLUGS=""

if [ -f "$WEB_DIR/sitemap.xml" ]; then
  OLD_CITY_SLUGS=$(
    grep -oE 'https://darmowakranowka\.pl/[a-z0-9-]+/' \
      "$WEB_DIR/sitemap.xml" \
    | sed -E 's#https://darmowakranowka\.pl/([^/]+)/#\1#' \
    | grep -v '^mapa$' \
    | sort -u \
    || true
  )
fi

# ------------------------------------------------------------
# 4. Usunięcie poprzednich stron miast z web/
# ------------------------------------------------------------

echo "2/6 Czyszczenie poprzednich stron miast w web/..."

if [ -n "$OLD_CITY_SLUGS" ]; then
  while IFS= read -r city; do
    if [ -n "$city" ]; then
      rm -rf "$WEB_DIR/$city"
    fi
  done <<< "$OLD_CITY_SLUGS"
fi

# ------------------------------------------------------------
# 5. Generowanie stron na podstawie aktualnego Firestore
# ------------------------------------------------------------

echo "3/6 Generowanie aktualnych stron miast..."
echo

node "$GENERATOR_SCRIPT"

# ------------------------------------------------------------
# 6. Odczyt aktualnych stron miast z sitemap.xml
# ------------------------------------------------------------

if [ ! -f "$WEB_DIR/sitemap.xml" ]; then
  echo "BŁĄD: Generator nie utworzył web/sitemap.xml"
  exit 1
fi

CITY_SLUGS=$(
  grep -oE 'https://darmowakranowka\.pl/[a-z0-9-]+/' \
    "$WEB_DIR/sitemap.xml" \
  | sed -E 's#https://darmowakranowka\.pl/([^/]+)/#\1#' \
  | grep -v '^mapa$' \
  | sort -u \
  || true
)

echo
echo "Aktualne strony miast:"

if [ -z "$CITY_SLUGS" ]; then
  echo "  Brak miast spełniających próg generatora."
else
  while IFS= read -r city; do
    if [ -n "$city" ]; then
      echo "  - $city"
    fi
  done <<< "$CITY_SLUGS"
fi

echo

# ------------------------------------------------------------
# 7. Usunięcie poprzednich stron miast z build/web
# ------------------------------------------------------------

echo "4/6 Czyszczenie poprzednich stron miast w build/web..."

if [ -n "$OLD_CITY_SLUGS" ]; then
  while IFS= read -r city; do
    if [ -n "$city" ]; then
      rm -rf "$BUILD_DIR/$city"
    fi
  done <<< "$OLD_CITY_SLUGS"
fi

# ------------------------------------------------------------
# 8. Kopiowanie aktualnych stron miast do build/web
# ------------------------------------------------------------

echo "5/6 Kopiowanie aktualnych stron do build/web..."

if [ -n "$CITY_SLUGS" ]; then
  while IFS= read -r city; do
    if [ -z "$city" ]; then
      continue
    fi

    if [ ! -f "$WEB_DIR/$city/index.html" ]; then
      echo "BŁĄD: Brak $WEB_DIR/$city/index.html"
      exit 1
    fi

    cp -R "$WEB_DIR/$city" "$BUILD_DIR/"
  done <<< "$CITY_SLUGS"
fi

cp "$WEB_DIR/sitemap.xml" "$BUILD_DIR/sitemap.xml"

# ------------------------------------------------------------
# 9. Deploy
# ------------------------------------------------------------

echo
echo "6/6 Deploy Firebase Hosting..."
echo

firebase deploy --only hosting

echo
echo "=========================================="
echo " GOTOWE"
echo "=========================================="
echo
echo "Wykonano:"
echo "  - uzupełnienie city + citySlug"
echo "  - pobranie aktualnych danych z Firestore"
echo "  - regenerację stron miast"
echo "  - usunięcie nieaktualnych stron miast"
echo "  - synchronizację z build/web"
echo "  - aktualizację sitemap.xml"
echo "  - deploy Firebase Hosting"
echo