import SwiftUI
import AppKit
import CodeEditTextView
import Textual

/// The note editor: CodeEditTextView in the UI font, dark colors from the design system.
struct NoteEditor: NSViewRepresentable {
    @Binding var text: String
    /// Changes when another note is opened, so undo never jumps back into the previous note.
    var noteID: URL?
    @Environment(\.accent) private var accent

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let font = NSFont(name: "Inter", size: 14) ?? .systemFont(ofSize: 14)
        let tv = TextView(string: text, font: font, textColor: NSColor(C.text), lineHeightMultiplier: 1.3,
                          wrapLines: true, letterSpacing: 1.0, delegate: context.coordinator)
        tv.selectionManager.insertionPointColor = NSColor(C.text)
        tv.selectionManager.selectionBackgroundColor = NSColor(accent.border)
        tv.edgeInsets = .zero
        tv.textInsets = .init(left: 0, right: 8)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = tv
        scroll.contentView.postsFrameChangedNotifications = true
        context.coordinator.noteID = noteID
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak scroll, weak tv] _ in
            MainActor.assumeIsolated { tv?.updatedViewport(scroll?.documentVisibleRect ?? .zero) }
        }
        tv.updateFrameIfNeeded()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? TextView else { return }
        tv.selectionManager.selectionBackgroundColor = NSColor(accent.border)
        if tv.string != text { tv.string = text }
        if context.coordinator.noteID != noteID {
            context.coordinator.noteID = noteID
            tv._undoManager?.clearStack()
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let o = coordinator.observer { NotificationCenter.default.removeObserver(o) }
    }

    final class Coordinator: TextViewDelegate {
        var parent: NoteEditor
        var noteID: URL?
        var observer: NSObjectProtocol?
        init(_ parent: NoteEditor) { self.parent = parent }

        func textView(_ textView: TextView, didReplaceContentsIn range: NSRange, with string: String) {
            MainActor.assumeIsolated { parent.text = textView.string }
        }
    }
}

/// Live Markdown preview of a note.
struct NotePreview: View {
    let text: String
    var body: some View {
        ScrollView {
            // "$" stays plain text: math needs a font bundle that can't ship inside a signed app.
            StructuredText(markdown: text.replacingOccurrences(of: "$", with: "\\$"))
                .textual.imageAttachmentLoader(LocalImagesOnly(inner: .image()))
                .textual.emojiAttachmentLoader(LocalImagesOnly(inner: .emoji()))
                .font(F.ui(14))
                .foregroundStyle(C.text)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// Privacy: the preview only shows pictures that are files on this Mac. Web images are never fetched.
struct LocalImagesOnly<Inner: AttachmentLoader>: AttachmentLoader {
    let inner: Inner

    func attachment(for url: URL, text: String, environment: ColorEnvironmentValues) async throws -> Inner.Attachment {
        guard let local = NoteFiles.localImage(url) else { throw URLError(.unsupportedURL) }
        return try await inner.attachment(for: local, text: text, environment: environment)
    }
}

extension NoteFiles {
    /// The file an image link points to, or nil if it's anything but a file. Relative paths are inside the notes folder.
    static func localImage(_ url: URL, base: URL = folder) -> URL? {
        guard url.scheme == nil else { return url.isFileURL ? url : nil }
        return url.path.hasPrefix("/") ? URL(fileURLWithPath: url.path) : base.appendingPathComponent(url.path)
    }
}
