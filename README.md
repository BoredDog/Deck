<p align="center">
  <img src="docs/icon.png" width="128" alt="Deck icon">
</p>

<h1 align="center">deck</h1>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-0c0c0c?style=flat-square&logo=apple&logoColor=white" alt="macOS 15+">
  <img src="https://img.shields.io/badge/100%25-local-c6ff3d?style=flat-square&labelColor=0c0c0c" alt="100% local">
  <img src="https://img.shields.io/badge/price-free-4fc9b8?style=flat-square&labelColor=0c0c0c" alt="free">
</p>

deck is a menu bar app that does a bunch of stuff i kept needing other apps for. converting files, finding files, a focus timer, calendar, notes, downloads, a system monitor. i wanted it all in one place and i didn't want any of it leaving my mac, so nothing does.

needs macOS 15 or later.

## install

1. grab the dmg from [releases](https://github.com/BoredDog/Deck/releases/latest)
2. drag deck into Applications
3. first time you open it, right-click deck and pick Open, then Open again. it's not notarized so macOS complains once. if it only shows "Done", go to System Settings > Privacy & Security and hit Open Anyway
4. it lives in the menu bar (the D). it only shows in the dock while its window is open

basic conversions work out of the box with stuff already built into macOS. for everything else deck uses free helpers like ffmpeg, pandoc and ImageMagick, installed through [Homebrew](https://brew.sh) (install that first). in Files you can get them all at once (around 1.5 GB) or let deck grab each one the first time you need it.

deck checks github for new releases and asks before downloading anything. you can turn that off in settings.

## what it does

- files: convert ~80 formats (images, video, audio, docs, excel, powerpoint, latex), shrink files (lossless ones can be restored exactly), copy text out of images and pdfs, pdf tools, remove backgrounds, batch rename, find duplicates, tidy Downloads. also in finder's right-click menu. originals are never touched
- find: search every file on the mac by name, hidden and system files too
- mac: cpu, memory, disk, network, battery, temps, fans. clear caches and old backups, uninstall apps along with their leftovers
- downloads: fast resumable downloads with aria2, torrents and metalinks too
- plan: your calendars and reminders from macOS accounts (icloud, google, outlook), quick add in plain words, habits, weekly review, journal
- focus: timer, block sites and apps, background sounds, break reminders, music controls, equalizer with per-app volume
- notes: markdown notes saved as plain files, plus encrypted private notes
- inbox: everything deck did in one list. notifications wait until your focus session is over
- quick panel: double-tap Option, push the pointer into the top-right corner, or ⌃⌥Space
- also: clipboard history (skips passwords), keep awake, weather (off by default), a few color themes

## privacy

- no accounts, no analytics, no cloud
- it only goes online for things you start (downloads, installing helpers), update checks, and weather if you turn it on. location gets rounded to ~1 km before it's sent to Open-Meteo
- converters run with the network blocked
- clipboard history, journal and private notes are encrypted with a key in your keychain

## permissions

deck tells you why before macOS asks.

| permission | for | if you say no |
|---|---|---|
| calendars, reminders | plan | plan is empty |
| notifications | downloads done, events, breaks | still shows in inbox |
| accessibility | option double-tap (only watches that key) | use the shortcut or corner |
| location | weather | no weather |
| automation | spotify/music controls, exporting pages/numbers/keynote | those buttons don't work |
| system audio | equalizer (nothing is recorded) | no equalizer |
| full disk access | find and storage outside your home folder | home folder only |
| login items | helper for site blocking and fan control | password prompt every time you block sites |
| keychain | the encryption key | that stuff stays in memory only |

## building

needs Xcode with Swift 6.

```sh
scripts/bundle.sh      # build + install to /Applications
swift test
scripts/make-dmg.sh    # the release dmg
```

`scripts/bundle-xcode.sh` also builds the notification center widgets (needs XcodeGen). if you build it yourself, deck updates by pulling from github and rebuilding.

## credits

- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)
- [MenuBarExtraAccess](https://github.com/orchetect/MenuBarExtraAccess)
- [Yams](https://github.com/jpsim/Yams)
- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation)
- [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView)
- [Textual](https://github.com/gonzalezreal/textual)
- [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3, bundled)
- [AudioCap](https://github.com/insidegui/AudioCap) (BSD-2, adapted for the equalizer)
- [Stats](https://github.com/exelban/stats) (MIT, SMC code adapted for sensors and fans)

helpers from homebrew: ffmpeg, pandoc, ImageMagick, aria2, zstd, xz, libjxl, oxipng, FLAC, qpdf, Ghostscript, WebP, libheif, 7-Zip. optional add-ons: LibreOffice, Tectonic, fontTools, yt-dlp.

## license

haven't picked one yet.
