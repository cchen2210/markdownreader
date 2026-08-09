# Markdown Reader for macOS

A native, reader-first Markdown app for macOS. It opens arbitrary Markdown files in place, renders them locally, refreshes after external saves, and includes a Finder Quick Look extension.

## Install for local use

A verified Release build is placed at `Build/Markdown Reader.app` and installed for this account at the stable path `~/Applications/Markdown Reader.app`:

```sh
./Scripts/build-release.sh
./Scripts/install-local.sh
```

Quit Markdown Reader before updating it. Both scripts assemble and verify a staged bundle before replacing their exact destination; the install script restores the prior app if the final verification fails, then registers the installed bundle with Launch Services. Keep the app in `~/Applications` or `/Applications` before using **Settings → General → Make Default** so Finder associations and the Quick Look extension do not point into a disposable build directory.

## What is included

- Native document windows, recent files, tabs, and Finder file association
- CommonMark plus GFM tables, task lists, strikethrough, footnotes, and bare-link detection
- Escaped, JavaScript-free syntax coloring for common programming and markup languages
- Outline navigation, find, source view, zoom, and reader appearance controls
- Local images with containment, type, byte, and pixel limits
- Print plus self-contained PDF and HTML export
- Preferred-editor handoff, Reveal in Finder, Copy Path, and Copy Markdown
- Data-based Quick Look extension sharing the same renderer
- A no-network, no-document-JavaScript WebKit boundary
- **Reading Memory** for explicitly saving passages, heading bookmarks, and private notes without modifying the Markdown file
- A responsive Marginalia surface with an in-document gutter, compact rail, and repair inspector
- A global Reading Memory window with full-text search, favourites, continue-reading state, repair review, and Markdown or JSON export
- Exact-only anchor recovery after external edits, with visible ambiguous/orphaned states and explicit manual reattachment

Reading Memory never saves a text selection on its own. Use **Reader → Remember Passage** (`⌘⇧M`), **Remember Passage with Note** (`⌘⌥⇧M`), or **Bookmark This Heading** (`⌘⇧B`). Open the global notebook with `⌘⇧R` and toggle the current document’s memory surface with `⌘⌃M`.

All Reading Memory data stays in a private local SQLite database at `~/Library/Application Support/com.cchen.MarkdownReader/ReadingMemory.sqlite3`. Notes and anchor evidence are separate from the source document. Export is the only built-in path that copies this data elsewhere; exported files are written from the exact previewed bytes with owner-only permissions.

## Build

Open `MarkdownReader.xcodeproj` in Xcode and run the `MarkdownReader` scheme, or run:

```sh
xcodebuild \
  -project MarkdownReader.xcodeproj \
  -scheme MarkdownReader \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .derivedData \
  build
```

The app appears at `.derivedData/Build/Products/Debug/Markdown Reader.app`. The `MarkdownReader` scheme runs the main app; the Quick Look provider is embedded automatically.

Open `Samples/Welcome.md` to exercise the main reader surface, a local image, and Markdown-to-Markdown navigation.

### Reproducible local Release

`Scripts/build-release.sh` uses only tools bundled with Xcode. It resolves the versions recorded in `Package.resolved`, builds all standard macOS architectures with the Release configuration, embeds the Quick Look extension, applies a local ad-hoc signature, verifies the complete bundle, and copies it to `Build/Markdown Reader.app`. The separate install script preserves `~/Applications/Markdown Reader.app` as the durable launch and file-association location.

The paths can be isolated for automation without editing either script:

```sh
MARKDOWN_READER_DERIVED_DATA_PATH=/tmp/MarkdownReaderDerivedData \
MARKDOWN_READER_ARTIFACT_DIR=/tmp/MarkdownReaderArtifacts \
./Scripts/build-release.sh

MARKDOWN_READER_ARTIFACT_PATH='/tmp/MarkdownReaderArtifacts/Markdown Reader.app' \
MARKDOWN_READER_INSTALL_ROOT=/tmp/MarkdownReaderApplications \
./Scripts/install-local.sh
```

## Project generation

`MarkdownReader.xcodeproj` is committed and builds without XcodeGen or Homebrew. `project.yml` is its source of truth; maintainers who already use XcodeGen should regenerate after changing project structure:

```sh
xcodegen generate
```

XcodeGen is not part of the build or install workflow. Third-party source dependencies are pinned to Swift Markdown 0.8.0 and GRDB 7.10.0; the first build may fetch them from GitHub.

## Current scope

This release is deliberately read-only: Reading Memory changes its own local database, never the opened Markdown bytes. It does not include a source editor, accounts, cloud sync, vaults, plugins, rendered math, executable Mermaid diagrams, remote images, automatic/fuzzy anchor reassignment, bulk repair, or scheduled resurfacing. Conventional footnote definitions and indented continuation blocks are supported; lazy unindented continuations, nested references inside footnote definitions, and escaped closing brackets in footnote identifiers remain literal Markdown.

The main app intentionally runs without App Sandbox so arbitrary Markdown files and their sibling images work in place without repeated folder grants. The tradeoff is less filesystem containment than a sandboxed app. The Quick Look extension remains sandboxed and receives no containing-folder authorization from the app: it can render the selected Markdown document, but relative sibling images are omitted whenever macOS grants access only to that file. The scripted Release artifact is ad-hoc signed for local use. It is not notarized, suitable for redistribution, or prepared for the Mac App Store; another Mac may reject it or require that user to build it locally. The workflow does not upload the app or require Apple Developer credentials.
