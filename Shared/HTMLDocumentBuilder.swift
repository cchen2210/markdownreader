import Foundation

enum HTMLDocumentBuilder {
    static func buildStandalone(rendered: RenderedMarkdown, title: String, style: RenderStyle) -> String {
        let html = buildPreview(rendered: rendered, title: title, style: style)
        var embeddedImageBytes = 0
        var replacements: [String: String] = [:]
        for (assetID, assetURL) in rendered.imageAssets {
            guard let imageRoot = rendered.imageRoot,
                  let image = try? LocalImageLoader.load(from: assetURL, within: imageRoot),
                  let mimeType = image.contentType.preferredMIMEType else {
                replacements[assetID] = "data:,"
                continue
            }
            guard embeddedImageBytes <= MarkdownRenderer.maximumDeclaredImageBytes - image.data.count else {
                replacements[assetID] = "data:,"
                continue
            }
            embeddedImageBytes += image.data.count
            replacements[assetID] = "data:\(mimeType);base64,\(image.data.base64EncodedString())"
        }
        return replacingImageSources(in: html, rendered: rendered, replacements: replacements)
    }

    static func buildPreview(rendered: RenderedMarkdown, title: String, style: RenderStyle) -> String {
        let html = build(rendered: rendered, title: title, style: style)
        var replacements: [String: String] = [:]
        for (linkID, target) in rendered.linkTargets {
            let destination = safeStandaloneLink(target) ?? "#blocked-link"
            replacements[linkID] = escapeAttribute(destination)
        }
        return replaceRegistryURLs(
            in: html,
            prefix: "mdreader-link://open/\(rendered.resourceToken)/",
            replacements: replacements
        )
    }

    static func replacingImageSources(
        in html: String,
        rendered: RenderedMarkdown,
        replacements: [String: String]
    ) -> String {
        replaceRegistryURLs(
            in: html,
            prefix: "mdreader://asset/\(rendered.resourceToken)/",
            replacements: replacements
        )
    }

    static func build(rendered: RenderedMarkdown, title: String, style: RenderStyle) -> String {
        let colors = colorCSS(for: style.appearance)
        let bodyFont = style.bodyStyle == .serif
            ? "ui-serif, 'New York', Georgia, serif"
            : "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
        let safeTitle = escapeText(title)
        let colorScheme = colorSchemeCSS(for: style.appearance)

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src mdreader: cid: data:; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; media-src 'none'; form-action 'none'; base-uri 'none'">
          <title>\(safeTitle)</title>
          <style>
          \(colors)
          :root { color-scheme: \(colorScheme); --reader-width: \(style.width.points)px; }
          * { box-sizing: border-box; }
          html { background: var(--canvas); }
          body {
            margin: 0;
            background: var(--canvas);
            color: var(--text);
            font-family: \(bodyFont);
            font-size: \(style.textSize)px;
            line-height: \(style.lineHeight);
            -webkit-font-smoothing: antialiased;
            text-rendering: optimizeLegibility;
          }
          main {
            width: min(var(--reader-width), calc(100vw - 48px));
            margin: 0 auto;
            padding: 56px 0 96px;
            overflow-wrap: anywhere;
          }
          p { margin: 0 0 1em; }
          h1, h2, h3, h4, h5, h6 {
            color: var(--text);
            font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif;
            line-height: 1.2;
            letter-spacing: -0.016em;
            scroll-margin-top: 28px;
          }
          h1 { font-size: 2.12em; margin: 0 0 0.85em; }
          h2 { font-size: 1.65em; margin: 1.6em 0 0.65em; padding-top: 0.2em; border-bottom: 1px solid var(--divider); }
          h3 { font-size: 1.3em; margin: 1.45em 0 0.55em; }
          h4 { font-size: 1.08em; margin: 1.35em 0 0.45em; }
          h5 { font-size: 0.95em; margin: 1.25em 0 0.4em; }
          h6 { color: var(--muted); font-size: 0.84em; letter-spacing: 0.04em; margin: 1.2em 0 0.35em; text-transform: uppercase; }
          a { color: var(--link); text-decoration: underline; text-decoration-thickness: 0.07em; text-underline-offset: 0.16em; }
          a:hover { text-decoration-thickness: 0.12em; }
          strong { font-weight: 650; }
          hr { border: 0; border-top: 1px solid var(--divider); margin: 2.5em 0; }
          blockquote { color: var(--muted); border-left: 3px solid var(--accent); margin: 1.4em 0; padding: 0.1em 0 0.1em 1.1em; }
          blockquote > :last-child { margin-bottom: 0; }
          ul, ol { margin: 0.4em 0 1.1em; padding-left: 1.5em; }
          li { margin: 0.28em 0; padding-left: 0.12em; }
          li > p { margin: 0.2em 0; }
          li.task-item { list-style: none; margin-left: -1.35em; }
          input[type='checkbox'] { margin: 0 0.58em 0 0; accent-color: var(--accent); }
          code, pre { font-family: ui-monospace, 'SFMono-Regular', Menlo, monospace; font-variant-ligatures: none; }
          :not(pre) > code { background: var(--code); border: 1px solid var(--divider); border-radius: 4px; font-size: 0.84em; padding: 0.14em 0.34em; }
          .code-block { background: var(--code); border: 1px solid var(--divider); border-radius: 9px; margin: 1.35em 0; overflow: hidden; }
          .code-label { border-bottom: 1px solid var(--divider); color: var(--muted); font: 600 0.68em/1 -apple-system, sans-serif; letter-spacing: 0.06em; padding: 0.72rem 1rem; text-transform: uppercase; }
          pre { font-size: 0.82em; line-height: 1.55; margin: 0; overflow: auto; padding: 1rem; tab-size: 4; white-space: pre; }
          .syntax-keyword, .syntax-directive { color: var(--syntax-keyword); font-weight: 600; }
          .syntax-type { color: var(--syntax-type); }
          .syntax-literal, .syntax-number { color: var(--syntax-number); }
          .syntax-string { color: var(--syntax-string); }
          .syntax-comment { color: var(--syntax-comment); font-style: italic; }
          .syntax-tag { color: var(--syntax-tag); }
          .syntax-attribute { color: var(--syntax-attribute); }
          .syntax-variable { color: var(--syntax-variable); }
          pre:focus-visible, .table-scroll:focus-visible { outline: 3px solid var(--focus); outline-offset: -3px; }
          .raw-html { color: var(--muted); white-space: pre-wrap; }
          .raw-html-inline { color: var(--muted); }
          .table-scroll { margin: 1.4em 0; max-width: 100%; overflow-x: auto; }
          table { border-collapse: collapse; font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 0.84em; min-width: 100%; }
          th, td { border-bottom: 1px solid var(--divider); padding: 0.62em 0.75em; text-align: left; vertical-align: top; }
          th { background: var(--code); font-size: 0.9em; font-weight: 650; }
          .align-center { text-align: center; }
          .align-right { text-align: right; }
          img { display: block; height: auto; margin: 1.5em auto; max-width: 100%; }
          .image-placeholder { border: 1px dashed var(--divider); border-radius: 7px; color: var(--muted); display: block; font-family: -apple-system, sans-serif; font-size: 0.82em; margin: 1.2em 0; padding: 1em; text-align: center; }
          .render-limit { color: var(--muted); font-family: -apple-system, sans-serif; font-style: italic; }
          .footnote-ref { font-family: -apple-system, sans-serif; font-size: 0.72em; line-height: 0; margin-left: 0.08em; vertical-align: super; }
          .footnote-ref a { text-decoration: none; }
          .footnotes { border-top: 1px solid var(--divider); color: var(--muted); font-size: 0.88em; margin-top: 3.5em; padding-top: 1.25em; }
          .footnotes::before { content: 'Footnotes'; color: var(--text); display: block; font-family: -apple-system, sans-serif; font-size: 0.82em; font-weight: 650; letter-spacing: 0.05em; margin-bottom: 0.9em; text-transform: uppercase; }
          .footnotes ol { margin-bottom: 0; }
          .footnotes li { padding-left: 0.3em; }
          .footnote-backref { font-family: -apple-system, sans-serif; margin-left: 0.28em; text-decoration: none; }
          ::selection { background: var(--selection); }
          @media (max-width: 700px) { main { width: calc(100vw - 32px); padding-top: 32px; } }
          @media print {
            :root { --canvas:#fff;--text:#111;--muted:#444;--divider:#ccc;--code:#f5f5f5;--link:#111;--syntax-keyword:#6D1F80;--syntax-type:#174F96;--syntax-number:#704800;--syntax-string:#275E2D;--syntax-comment:#555;--syntax-tag:#8F2F27;--syntax-attribute:#704800;--syntax-variable:#6B4900; }
            body { background: #fff; color: #111; font-size: 11pt; }
            main { margin: 0; max-width: none; padding: 0; width: 100%; }
            a { text-decoration: underline; }
            h1, h2, h3 { break-after: avoid; }
            pre, blockquote, table { break-inside: avoid; }
          }
          </style>
        </head>
        <body><main id="reader" role="main">\(rendered.bodyHTML)</main></body>
        </html>
        """
    }

    private static func colorCSS(for appearance: ReaderAppearance) -> String {
        let light = "--canvas:#FAF9F6;--text:#20201E;--muted:#686761;--divider:#D9D6CF;--code:#F1EFEA;--link:#9A452C;--accent:#C7603F;--focus:#007AFF;--selection:#F0C9B8;--syntax-keyword:#8B2AA3;--syntax-type:#1F66C1;--syntax-number:#8B5A00;--syntax-string:#2E7136;--syntax-comment:#666B72;--syntax-tag:#B33B31;--syntax-attribute:#8B5A00;--syntax-variable:#875D00;"
        let dark = "--canvas:#1C1C1B;--text:#ECECE8;--muted:#A7A69F;--divider:#3D3C38;--code:#272725;--link:#F09A7A;--accent:#E27D5C;--focus:#5E9EFF;--selection:#633C2F;--syntax-keyword:#C792EA;--syntax-type:#82AAFF;--syntax-number:#F78C6C;--syntax-string:#C3E88D;--syntax-comment:#9AA0AA;--syntax-tag:#FF8A80;--syntax-attribute:#FFCB6B;--syntax-variable:#F2C66D;"
        let sepia = "--canvas:#F4ECD8;--text:#3D3428;--muted:#726455;--divider:#D8CBAF;--code:#EAE0C7;--link:#88442F;--accent:#B85B3E;--focus:#006BD6;--selection:#DFC3A3;--syntax-keyword:#7D3568;--syntax-type:#355F86;--syntax-number:#80551F;--syntax-string:#466B3B;--syntax-comment:#766C5F;--syntax-tag:#904334;--syntax-attribute:#80551F;--syntax-variable:#74531F;"

        switch appearance {
        case .automatic:
            return ":root{\(light)}@media(prefers-color-scheme:dark){:root{\(dark)}}"
        case .light:
            return ":root{\(light)}"
        case .dark:
            return ":root{\(dark)}"
        case .sepia:
            return ":root{\(sepia)}"
        }
    }

    private static func colorSchemeCSS(for appearance: ReaderAppearance) -> String {
        switch appearance {
        case .automatic: "light dark"
        case .light, .sepia: "light"
        case .dark: "dark"
        }
    }

    private static func safeStandaloneLink(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            return nil
        }

        if let scheme = URL(string: trimmed)?.scheme?.lowercased() {
            return ["http", "https", "mailto"].contains(scheme) ? trimmed : nil
        }

        guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
            return nil
        }
        return trimmed
    }

    /// Replaces opaque registry URLs in one forward pass. IDs are delimited by
    /// the surrounding HTML attribute quote, so `link-1` can never rewrite the
    /// prefix of `link-10` and work scales with the document rather than
    /// registry-size times document-size.
    private static func replaceRegistryURLs(
        in html: String,
        prefix: String,
        replacements: [String: String]
    ) -> String {
        guard !replacements.isEmpty else { return html }

        var result = ""
        result.reserveCapacity(html.count)
        var cursor = html.startIndex
        while let prefixRange = html.range(of: prefix, range: cursor..<html.endIndex) {
            result += html[cursor..<prefixRange.lowerBound]
            guard let quote = html[prefixRange.upperBound...].firstIndex(of: "\"") else {
                result += html[prefixRange.lowerBound...]
                return result
            }

            let identifier = String(html[prefixRange.upperBound..<quote])
            if let replacement = replacements[identifier] {
                result += replacement
            } else {
                result += html[prefixRange.lowerBound..<quote]
            }
            cursor = quote
        }
        result += html[cursor...]
        return result
    }

    private static func escapeText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ value: String) -> String {
        escapeText(value)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
