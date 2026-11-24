import Foundation

/// Reads a pipe line by line until it closes (eslogger's output, for days at a time).
///
/// Each chunk is read inside its own autorelease pool. The watch's loop runs on the main thread and never returns to
/// a run loop, so nothing else ever drains the pool: before this, every chunk eslogger wrote stayed in memory, and
/// the background watch grew by exactly the bytes it had read (114 MB after three hours, 370 MB in the eval).
public enum LineReader {
    public static func forEachLine(_ handle: FileHandle, _ body: (String) -> Void) {
        var buffer = Data()
        while true {
            let more = autoreleasepool { () -> Bool in
                let chunk = handle.availableData
                if chunk.isEmpty { return false }
                buffer.append(chunk)
                var start = buffer.startIndex
                while let nl = buffer[start...].firstIndex(of: 0x0A) {
                    body(String(decoding: buffer[start..<nl], as: UTF8.self))
                    start = buffer.index(after: nl)
                }
                buffer.removeSubrange(buffer.startIndex..<start)
                return true
            }
            if !more { break }
        }
        if !buffer.isEmpty { body(String(decoding: buffer, as: UTF8.self)) }
    }
}
