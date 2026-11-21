# AO3Lib for KOReader

An unofficial plugin for browsing, downloading, and reading works from Archive of Our Own. This fork of [IntrovertedMage's AO3 Downloader](https://github.com/IntrovertedMage/AO3Downloader.koplugin) focuses on managing a local fanfiction library and integrating with Bookshelf.

## Features

- Search AO3 by tags or detailed filters, download by work ID, and browse authors, series, collections, and bookmarks.
- Use an AO3 account for bookmarks, kudos, comments, and other account actions.
- Discover downloaded AO3 EPUBs in the configured download folder and KOReader home folder, and browse them offline by author or fandom.
- Download into `Author/Title` folders, or organize existing downloads while preserving reading progress and associated book data.
- Review available updates before replacing downloaded EPUBs, with reading progress preserved.
- Optionally convert HTML downloads to EPUB when native downloads are unavailable, and replace conversions with native EPUBs later.
- Access AO3 metadata and filters from Bookshelf book details, with AO3 symbol placeholders for books without covers.

AO3 works are identified from metadata inside their EPUBs, including books downloaded outside this plugin. Local reading and library browsing remain available when AO3 is offline.

## Install

1. Download this fork using [Code → Download ZIP](https://github.com/GallowsDove/AO3Lib.koplugin/archive/refs/heads/main.zip), or clone the repository.
2. Copy the plugin into KOReader's `plugins` directory as `AO3Downloader.koplugin`, including its `assets` folder.
3. Restart KOReader, then open **AO3Lib** from the file manager's Search menu.

Keep the installed folder named `AO3Downloader.koplugin` for compatibility with existing installations.

Typical plugin locations:

| Device | Plugins folder |
|--------|----------------|
| Kindle | `/mnt/us/koreader/plugins/` |
| Kobo | `/mnt/onboard/.adds/koreader/plugins/` |
| Android | `<koreader-dir>/plugins/` |

To update, replace the plugin folder and restart KOReader. Bookshelf integration is optional and requires a compatible version of [Bookshelf](https://github.com/AndyHazz/bookshelf.koplugin).

## Credits

Original plugin by [IntrovertedMage](https://github.com/IntrovertedMage/AO3Downloader.koplugin). The missing-cover badge design is inspired by [AO3 Plus](https://github.com/gin7uro/koreader-ao3-plus), using AO3's official symbols; asset sources and license are included in [assets/ao3-icons](assets/ao3-icons).

Additional symbol styles by [ZerafinaCSS](https://github.com/ZerafinaCSS/Replace-the-AO3-Icons-2.0) (MIT).
