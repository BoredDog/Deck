import Foundation

/// macOS's own converters (avconvert, afconvert, textutil). Used when the bigger helper isn't installed,
/// so a light install still converts the everyday things without downloading anything.
enum BuiltIn {
    /// textutil reads these and writes most of the same.
    static let textutilIn: Set<String> = ["txt", "html", "htm", "rtf", "doc", "docx", "odt", "webarchive"]
    private static let textutilOut: [String: String] = ["doc.txt": "txt", "doc.html": "html", "doc.rtf": "rtf", "doc.docx": "docx", "doc.odt": "odt"]

    /// The built-in tool and arguments for this target, or nil when only the helper can do it.
    static func route(_ id: String, inExt: String, src: URL, out: URL,
                      has: (String) -> Bool = Engine.has) -> (tool: String, args: [String])? {
        if !has("ffmpeg") {
            let s = src.path, o = out.path
            switch id {
            case "video.mp4", "video.m4v", "video.mov": return ("avconvert", ["-p", "Preset1920x1080", "-s", s, "-o", o])
            case "video.iphone": return ("avconvert", ["-p", "PresetHEVC1920x1080", "-s", s, "-o", o])
            case "video.audio": return ("avconvert", ["-p", "PresetAppleM4A", "-s", s, "-o", o])
            case "audio.aac": return ("afconvert", ["-f", "m4af", "-d", "aac", s, o])
            case "audio.alac": return ("afconvert", ["-f", "m4af", "-d", "alac", s, o])
            case "audio.wav": return ("afconvert", ["-f", "WAVE", "-d", "LEI16", s, o])
            case "audio.aiff": return ("afconvert", ["-f", "AIFF", "-d", "BEI16", s, o])
            default: break
            }
        }
        if !has("pandoc"), textutilIn.contains(inExt), let fmt = textutilOut[id] {
            return ("textutil", ["-convert", fmt, src.path, "-output", out.path])
        }
        return nil
    }
}
