# Lylyrics

Synchronized lyrics viewer for **MPRIS** players on Linux and for **Android**
media sessions. It detects what is playing, fetches the lyrics, syncs them with
playback and displays them highlighting the current line.

The interface is in English; the code and comments are in Spanish.

[Leer en español](README_es.md)

## Features

- **Real-time sync** with the player position (interpolated clock, ~100 ms
  precision). It highlights the current line and dims the rest.
- **Smooth auto-scroll** that follows the song. Manual scrolling pauses it for a
  few seconds and a button appears to jump back to the current line.
- **Multiple lyrics sources, in cascade:**
  1. [LRCLIB](https://lrclib.net) — main source, with synchronized lyrics.
  2. **NetEase Cloud Music** — first fallback (public web endpoints).
  3. **Genius** — last fallback (scraping, plain lyrics without timing).
- **Manual search** (magnifier): queries LRCLIB, NetEase and Genius at once and
  shows every match with its origin and whether it comes synchronized.
- **Line-by-line translation** (Google Translate, no API key) into the language
  chosen by the user.
- **Per-word colors**: each word of the original line gets its own pastel tone
  and its translation inherits the same color, so you can see which word
  corresponds to which.

  > **Warning:** this pairing **often fails to identify which original word
  > corresponds to which translated word**. The color is only reliable when the
  > content-based alignment finds the link; otherwise it falls back to a
  > positional distribution that drifts out of sync. Failures are more frequent
  > when:
  > - the language uses a non-Latin alphabet (Russian, Japanese, Korean,
  >   Chinese, Arabic, Hindi), where the normalizer drops the tokens;
  > - the language does not separate words with spaces (Chinese, Japanese),
  >   where the whole line ends up with a single color;
  > - the translation **reorders** words or changes their number (added
  >   articles, prepositions), since the positional distribution paints another
  >   word's color and even repeats colors;
  > - the song exceeds the internal lexical coverage limits (≈250 unique words,
  >   ≈25 contextual lines), leaving words without a link;
  > - there are repeated words, contractions or punctuation counted as a word,
  >   which shift the indices.
- **Single-word translation**: right click (desktop) or long press (Android) on
  a word shows its exact translation in a dialog.
- **Jump to a point in the song**: clicking or tapping a line performs a `seek`
  on the player.
- **Per-song offset**: adjust the sync by ±10 s in 0.5 s steps, and it remembers
  the offset of each track.
- **Player selector** when there is more than one active (MPRIS or Android
  sessions).
- **Local cache of LRCLIB lyrics** in SQLite with a 24 h TTL: expired entries
  are dropped on startup and requests are not repeated within that window.
  NetEase and Genius are fallbacks and are not cached.
- **Persistent settings**: font size, light/dark theme, per-word colors and
  translation target language.
- **Keyboard shortcut**: `Space` pauses/plays when the app has focus.

## Translation languages

The translation (line-by-line and single-word) supports these target languages,
regardless of the original language of the song:

English, Spanish, French, German, Italian, Portuguese, Russian, Japanese,
Korean, Simplified Chinese, Arabic and Hindi.

## Requirements

| Platform | You need |
| --- | --- |
| Linux | Flutter (stable), a D-Bus session bus and the system's `libsqlite3` |
| Android | Flutter (stable), Android SDK, **notification access** permission to read media sessions |

On Linux the app **needs D-Bus**: if it cannot find the session bus it notifies
you with an error screen instead of failing opaquely.

## Getting started (Linux)

```bash
git clone <repo>
cd lylyrics
flutter pub get
flutter run -d linux
```

Build:

```bash
flutter build linux --release
```

## Getting started (Android)

```bash
flutter pub get
flutter run -d <device>
```

The first time you must grant **Notification access** to Lylyrics from the
system settings; without that permission the native service cannot read what is
playing.

## Tests

```bash
flutter test
```

They cover the LRC parsing, the sync engine, the cache, the lyrics providers,
the word-by-word alignment, the settings and the media sources (pure logic,
without D-Bus or Android).

## Diagnostic tools

- `tool/check_mpris.sh` — lists the MPRIS players on the session bus and their
  metadata. It accepts a filter: `./tool/check_mpris.sh vlc`.
- `dart run tool/probe_lrclib.dart` — real probe against LRCLIB without UI.
- `dart run tool/probe_netease.dart` — real probe against NetEase without UI.

## Architecture

The UI and the services never talk directly to MPRIS, D-Bus or Android:
everything goes through contracts, so adding a platform or a new lyrics source
does not force you to touch the rest.

```
lib/
├── core/
│   ├── interfaces/    # MediaSource and LyricsProvider (the contracts)
│   └── models/        # TrackInfo, PlaybackState, Lyrics
├── platform/
│   ├── linux/         # MprisMediaSource (D-Bus + MPRIS)
│   └── android/       # AndroidMediaSource (channel to the native service)
├── services/
│   ├── lrclib_provider.dart      # main lyrics source
│   ├── netease_provider.dart     # NetEase fallback
│   ├── genius_scraper.dart       # Genius fallback
│   ├── lyrics_cache.dart         # SQLite cache
│   ├── sync_engine.dart          # current line according to position
│   ├── translation_service.dart  # Google Translate (no API key)
│   └── token_alignment.dart      # word-by-word alignment
├── state/providers/   # Riverpod: wires sources, cache and UI
└── ui/                # Screens and widgets
```

**Key design points:**

- `MediaSource` abstracts playback. Linux implements MPRIS; Android, a channel
  to a native `MediaListenerService`. The services do not know which one is
  active.
- The **sync engine** receives an interpolated position (MPRIS does not emit
  continuous position) and applies the offset to the line timestamps, not to the
  position: that way the offset only affects the highlighted line.
- The **word-by-word translation** relies on the aligned segments returned by
  Google (`dt=t` / `dt=bd`) to pair each original word with its translation,
  without local dictionaries.
