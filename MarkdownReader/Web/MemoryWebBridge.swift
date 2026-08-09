import Foundation
import WebKit

struct MemoryRenderContext: Equatable, Sendable {
    let sourceRevisionHash: String
    let projectionVersion: Int
    let renderRevision: UUID
}

struct MemoryRenderMark: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case passage
        case headingBookmark
        case locationChoice
    }

    let memoryID: UUID
    let token: String
    let kind: Kind
    let selector: ResolvedMemorySelector
    let accessibilityLabel: String
}

struct WebRect: Decodable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct WebMarkGeometry: Decodable, Equatable, Sendable {
    let token: String
    let rects: [WebRect]
}

struct WebMarkGeometryResponse: Decodable, Equatable, Sendable {
    let sourceRevisionHash: String
    let projectionVersion: Int
    let renderRevision: UUID
    let scrollY: Double
    let documentHeight: Double
    let baseDocumentHeight: Double
    let viewportWidth: Double
    let viewportHeight: Double
    let bottomInset: Double
    let marks: [WebMarkGeometry]

    var documentGeometry: WebDocumentGeometry {
        WebDocumentGeometry(
            scrollY: scrollY,
            documentHeight: documentHeight,
            baseDocumentHeight: baseDocumentHeight,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            bottomInset: bottomInset
        )
    }
}

struct WebDocumentGeometry: Equatable, Sendable {
    static let empty = WebDocumentGeometry(
        scrollY: 0,
        documentHeight: 0,
        baseDocumentHeight: 0,
        viewportWidth: 0,
        viewportHeight: 0,
        bottomInset: 0
    )

    let scrollY: Double
    let documentHeight: Double
    /// The page height before Marginalia adds native scroll space for packed
    /// notes. Keeping the base separate prevents inset feedback from growing
    /// the document on every geometry refresh.
    let baseDocumentHeight: Double
    let viewportWidth: Double
    let viewportHeight: Double
    let bottomInset: Double

    /// Converts CSS-pixel geometry reported by WebKit into native points in
    /// the adjacent SwiftUI gutter. `pageZoom` changes this ratio, so treating
    /// the two coordinate systems as interchangeable makes leaders drift.
    func nativeScale(forViewportHeight nativeViewportHeight: CGFloat) -> CGFloat {
        guard nativeViewportHeight.isFinite,
              nativeViewportHeight > 0,
              viewportHeight.isFinite,
              viewportHeight > 0 else { return 1 }
        let scale = nativeViewportHeight / CGFloat(viewportHeight)
        return scale.isFinite && scale > 0 ? scale : 1
    }
}

struct DOMProjectionBlockTarget: Decodable, Equatable, Sendable {
    let sourceRevisionHash: String
    let projectionVersion: Int
    let renderRevision: UUID
    let blockID: String
}

enum MemoryWebBridge {
    static let contentWorld = WKContentWorld.world(name: "MarkdownReader.MemoryBridge")
    static let maximumSelectionCharacters = 64 * 1024
    static let maximumSelectionRuns = 256

    /// Reads a range only after an explicit native command. Both endpoints must
    /// map to opaque runs in one supported semantic block. The root context is
    /// returned with the range so native code can reject a stale response.
    static let selectionJavaScript = """
    const root = document.getElementById('reader');
    const selection = window.getSelection();
    if (!root || !selection || selection.rangeCount !== 1 || selection.isCollapsed) return null;
    const range = selection.getRangeAt(0);
    const elementFor = node => node?.nodeType === Node.ELEMENT_NODE ? node : node?.parentElement;
    const runPoint = (container, offset) => {
      const element = elementFor(container);
      const run = element?.closest('[data-memory-run]');
      if (!run || !root.contains(run)) return null;
      const block = run.closest('[data-memory-block]');
      if (!block) return null;
      const before = document.createRange();
      before.selectNodeContents(run);
      try { before.setEnd(container, offset); } catch (_) { return null; }
      return {
        block,
        runID: run.dataset.memoryRun || '',
        utf16Offset: before.toString().length
      };
    };
    const start = runPoint(range.startContainer, range.startOffset);
    const end = runPoint(range.endContainer, range.endOffset);
    if (!start || !end || start.block !== end.block) return null;
    const selectedVisibleText = range.toString();
    if (selectedVisibleText.length === 0 || selectedVisibleText.length > maxCharacters) return null;
    const fragment = range.cloneContents();
    const runCount = new Set(Array.from(fragment.querySelectorAll?.('[data-memory-run]') || [])
      .map(node => node.dataset.memoryRun)).size + 2;
    if (runCount > maxRuns) return null;
    return {
      sourceRevisionHash: root.dataset.sourceRevision || '',
      renderRevision: root.dataset.renderRevision || '',
      projectionVersion: Number(root.dataset.projectionVersion || 0),
      blockID: start.block.dataset.memoryBlock || '',
      start: { runID: start.runID, utf16Offset: start.utf16Offset },
      end: { runID: end.runID, utf16Offset: end.utf16Offset },
      selectedVisibleText
    };
    """

    /// Resolves an explicit heading-bookmark command to the block containing
    /// the selection, or to the top visible semantic block when no selection
    /// exists. It does not change selection or persist anything.
    static let headingTargetJavaScript = """
    const root = document.getElementById('reader');
    if (!root) return null;
    const selection = window.getSelection();
    let block = null;
    if (selection && selection.rangeCount === 1 && !selection.isCollapsed) {
      const range = selection.getRangeAt(0);
      const node = range.startContainer?.nodeType === Node.ELEMENT_NODE
        ? range.startContainer : range.startContainer?.parentElement;
      block = node?.closest?.('[data-memory-block]') || null;
    }
    if (!block || !root.contains(block)) {
      block = Array.from(root.querySelectorAll('[data-memory-block]')).find(candidate => {
        const rect = candidate.getBoundingClientRect();
        return rect.bottom > 1 && rect.top < window.innerHeight;
      }) || null;
    }
    if (!block) return null;
    return {
      sourceRevisionHash: root.dataset.sourceRevision || '',
      projectionVersion: Number(root.dataset.projectionVersion || 0),
      renderRevision: root.dataset.renderRevision || '',
      blockID: block.dataset.memoryBlock || ''
    };
    """

    /// Returns the top visible semantic text point and a fractional fallback.
    /// Native code validates the full render context and maps this DOM point
    /// through the current projection; no text search occurs here.
    static let readingPositionJavaScript = """
    const root = document.getElementById('reader');
    if (!root) return null;
    const blocks = Array.from(root.querySelectorAll('[data-memory-block]'));
    const block = blocks.find(candidate => {
      const rect = candidate.getBoundingClientRect();
      return rect.bottom > 1 && rect.top < window.innerHeight;
    });
    if (!block) return null;

    const runPoint = (container, offset) => {
      const element = container?.nodeType === Node.ELEMENT_NODE ? container : container?.parentElement;
      const run = element?.closest?.('[data-memory-run]');
      if (!run || !block.contains(run)) return null;
      const before = document.createRange();
      before.selectNodeContents(run);
      try { before.setEnd(container, offset); } catch (_) { return null; }
      return { runID: run.dataset.memoryRun || '', utf16Offset: before.toString().length };
    };

    const rect = block.getBoundingClientRect();
    const x = Math.min(Math.max(rect.left + 8, 1), Math.max(1, window.innerWidth - 2));
    const y = Math.min(Math.max(rect.top + 2, 1), Math.max(1, window.innerHeight - 2));
    const caret = document.caretRangeFromPoint?.(x, y) || null;
    let point = caret ? runPoint(caret.startContainer, caret.startOffset) : null;
    if (!point) {
      const firstRun = block.querySelector('[data-memory-run]');
      if (!firstRun) return null;
      point = { runID: firstRun.dataset.memoryRun || '', utf16Offset: 0 };
    }
    const maximum = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
    return {
      sourceRevisionHash: root.dataset.sourceRevision || '',
      renderRevision: root.dataset.renderRevision || '',
      projectionVersion: Number(root.dataset.projectionVersion || 0),
      blockID: block.dataset.memoryBlock || '',
      point,
      fallbackScrollFraction: Math.min(1, Math.max(0, window.scrollY / maximum))
    };
    """

    /// Paints only resolver-confirmed run fragments. It never searches for a
    /// quote and receives no database identifier or note text. Existing marks
    /// are unwrapped before the same projection coordinates are applied.
    static let markJavaScript = """
    const root = document.getElementById('reader');
    const stale = !root || root.dataset.sourceRevision !== expectedSourceRevision ||
      root.dataset.renderRevision !== expectedRenderRevision ||
      Number(root.dataset.projectionVersion || 0) !== expectedProjectionVersion;
    if (stale) return null;

    for (const mark of Array.from(root.querySelectorAll('mark.memory-mark'))) {
      const parent = mark.parentNode;
      while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
      parent.removeChild(mark);
      parent.normalize();
    }
    for (const block of root.querySelectorAll('[data-memory-block-tokens]')) {
      delete block.dataset.memoryBlockTokens;
    }

    const locate = (run, offset) => {
      if (!Number.isInteger(offset) || offset < 0) return null;
      const walker = document.createTreeWalker(run, NodeFilter.SHOW_TEXT);
      let remaining = offset;
      let node = walker.nextNode();
      while (node) {
        const length = node.nodeValue?.length || 0;
        if (remaining <= length) return { node, offset: remaining };
        remaining -= length;
        node = walker.nextNode();
      }
      return remaining === 0 ? { node: run, offset: run.childNodes.length } : null;
    };

    for (const row of Array.isArray(marks) ? marks : []) {
      if (!row || typeof row.token !== 'string' || !Array.isArray(row.fragments)) continue;
      if (row.kind !== 'passage') {
        const block = root.querySelector(`[data-memory-block="${CSS.escape(row.blockID || '')}"]`);
        if (!block) continue;
        let tokens = [];
        try { tokens = JSON.parse(block.dataset.memoryBlockTokens || '[]'); } catch (_) {}
        if (!Array.isArray(tokens)) tokens = [];
        if (!tokens.includes(row.token)) tokens.push(row.token);
        block.dataset.memoryBlockTokens = JSON.stringify(tokens);
        continue;
      }
      const fragments = row.fragments.slice().sort((a, b) => {
        if (a.runID === b.runID) return b.lower - a.lower;
        return a.runID < b.runID ? 1 : -1;
      });
      let focusable = true;
      for (const fragment of fragments) {
        const run = root.querySelector(`[data-memory-run="${CSS.escape(fragment.runID || '')}"]`);
        if (!run) continue;
        const start = locate(run, fragment.lower);
        const end = locate(run, fragment.upper);
        if (!start || !end) continue;
        const range = document.createRange();
        try {
          range.setStart(start.node, start.offset);
          range.setEnd(end.node, end.offset);
        } catch (_) { continue; }
        if (range.collapsed) continue;
        const mark = document.createElement('mark');
        mark.className = focusable ? 'memory-mark' : 'memory-mark memory-mark-continuation';
        mark.dataset.memoryToken = row.token;
        if (focusable) {
          mark.tabIndex = 0;
          mark.setAttribute('role', 'mark');
          mark.setAttribute('aria-label', row.accessibilityLabel || 'Resolved remembered passage');
          focusable = false;
        }
        mark.appendChild(range.extractContents());
        range.insertNode(mark);
      }
    }
    return geometryResponse(root);
    """

    static let geometryJavaScript = """
    const root = document.getElementById('reader');
    if (!root || root.dataset.sourceRevision !== expectedSourceRevision ||
        root.dataset.renderRevision !== expectedRenderRevision ||
        Number(root.dataset.projectionVersion || 0) !== expectedProjectionVersion) return null;
    return geometryResponse(root);
    """

    /// Extends the WebKit document only below its existing content. The
    /// reader's computed bottom padding is captured once per render so setting
    /// the inset repeatedly is idempotent and resetting to zero preserves the
    /// original document styling.
    static let bottomInsetJavaScript = """
    const root = document.getElementById('reader');
    if (!root || root.dataset.sourceRevision !== expectedSourceRevision ||
        root.dataset.renderRevision !== expectedRenderRevision ||
        Number(root.dataset.projectionVersion || 0) !== expectedProjectionVersion) return null;
    if (!root.dataset.memoryBasePaddingBottom) {
      const computed = Number.parseFloat(getComputedStyle(root).paddingBottom || '0');
      root.dataset.memoryBasePaddingBottom = String(Number.isFinite(computed) ? computed : 0);
    }
    if (!root.dataset.memoryBaseDocumentHeight) {
      root.dataset.memoryBaseDocumentHeight = String(document.documentElement.scrollHeight);
    }
    const basePadding = Number(root.dataset.memoryBasePaddingBottom || 0);
    const baseDocumentHeight = Number(root.dataset.memoryBaseDocumentHeight || window.innerHeight);
    const normalizedInset = Number.isFinite(bottomInset) ? Math.max(0, bottomInset) : 0;
    root.dataset.memoryBottomInset = String(normalizedInset);
    root.style.paddingBottom = `${basePadding + normalizedInset}px`;
    root.style.minHeight = normalizedInset > 0 ? `${baseDocumentHeight + normalizedInset}px` : '';
    return geometryResponse(root);
    """

    static let hitTestJavaScript = """
    const root = document.getElementById('reader');
    if (!root || root.dataset.renderRevision !== expectedRenderRevision) return null;
    const mark = document.elementFromPoint(x, y)?.closest('mark.memory-mark');
    return mark && root.contains(mark) ? (mark.dataset.memoryToken || null) : null;
    """

    static let geometryHelperJavaScript = """
    const geometryResponse = root => {
      const appliedInset = Number(root.dataset.memoryBottomInset || 0);
      if (appliedInset === 0) {
        root.dataset.memoryBaseDocumentHeight = String(document.documentElement.scrollHeight);
      }
      const grouped = new Map();
      for (const mark of root.querySelectorAll('mark.memory-mark')) {
        const token = mark.dataset.memoryToken || '';
        if (!token) continue;
        if (!grouped.has(token)) grouped.set(token, []);
        for (const rect of mark.getClientRects()) {
          grouped.get(token).push({ x: rect.x, y: rect.y, width: rect.width, height: rect.height });
        }
      }
      for (const block of root.querySelectorAll('[data-memory-block-tokens]')) {
        let tokens = [];
        try { tokens = JSON.parse(block.dataset.memoryBlockTokens || '[]'); } catch (_) {}
        if (!Array.isArray(tokens)) continue;
        const rect = block.getBoundingClientRect();
        for (const token of tokens) {
          if (typeof token !== 'string' || !token) continue;
          if (!grouped.has(token)) grouped.set(token, []);
          grouped.get(token).push({ x: rect.x, y: rect.y, width: rect.width, height: rect.height });
        }
      }
      return {
        sourceRevisionHash: root.dataset.sourceRevision || '',
        projectionVersion: Number(root.dataset.projectionVersion || 0),
        renderRevision: root.dataset.renderRevision || '',
        scrollY: window.scrollY,
        documentHeight: document.documentElement.scrollHeight,
        baseDocumentHeight: Number(root.dataset.memoryBaseDocumentHeight || document.documentElement.scrollHeight),
        viewportWidth: window.innerWidth,
        viewportHeight: window.innerHeight,
        bottomInset: appliedInset,
        marks: Array.from(grouped.entries()).map(([token, rects]) => ({ token, rects }))
      };
    };
    """

    static var markProgram: String { geometryHelperJavaScript + "\n" + markJavaScript }
    static var geometryProgram: String { geometryHelperJavaScript + "\n" + geometryJavaScript }
    static var bottomInsetProgram: String { geometryHelperJavaScript + "\n" + bottomInsetJavaScript }
}
