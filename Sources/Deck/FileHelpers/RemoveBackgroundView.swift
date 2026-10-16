import SwiftUI
import Vision
import CoreImage
import UniformTypeIdentifiers

/// Cuts out the subject of a photo and saves it as a PNG with a see-through background.
struct RemoveBackgroundView: View {
    @State private var source: URL?
    @State private var before: NSImage?
    @State private var after: CGImage?
    @State private var busy = false
    @State private var message = ""
    @State private var saved: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DropZone(prompt: "Drop a photo", allowFolders: false, multiple: false) { if let u = $0.first { cut(u) } }
            if source != nil {
                HStack(spacing: 8) {
                    Tile { TileLabel(text: "Before"); preview(before) }
                    Tile {
                        TileLabel(text: "After")
                        if busy { ProgressView().controlSize(.small) }
                        preview(after.map { NSImage(cgImage: $0, size: .zero) })
                    }
                }
                .frame(height: 320)
                HStack {
                    Button("Save") { save() }.buttonStyle(.primary).keyboardShortcut(.defaultAction).disabled(after == nil)
                    if let saved { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }.buttonStyle(.pill) }
                    Text(message).font(F.label).foregroundStyle(C.text2)
                }
            }
        }
    }

    @ViewBuilder private func preview(_ img: NSImage?) -> some View {
        if let img { Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    private func cut(_ url: URL) {
        source = url; before = NSImage(contentsOf: url); after = nil; saved = nil; message = ""; busy = true
        Task.detached {
            let out = try? Self.removeBackground(url)
            await MainActor.run {
                after = out; busy = false
                if out == nil { message = "Couldn't find a clear subject. Try a photo with one person, pet or thing up front." }
            }
        }
    }

    nonisolated static func removeBackground(_ url: URL) throws -> CGImage? {
        let handler = VNImageRequestHandler(url: url)
        let req = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([req])
        guard let mask = req.results?.first else { return nil }
        let buffer = try mask.generateMaskedImage(ofInstances: mask.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        return CIContext().createCGImage(ci, from: ci.extent)
    }

    private func save() {
        guard let after, let source else { return }
        let url = FileManager.default.freeURL(in: source.deletingLastPathComponent(),
                                              name: source.deletingPathExtension().lastPathComponent + " (no background)", ext: "png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, after, nil)
        if CGImageDestinationFinalize(dest) { saved = url; message = "Saved \(url.lastPathComponent)" }
        else { message = "Couldn't save here. Try another folder." }
    }
}
