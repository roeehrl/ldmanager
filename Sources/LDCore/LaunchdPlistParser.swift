import Foundation

/// Judges a plist the way launchd does. launchd parses job plists with libxpc's
/// `xpc_create_from_plist`, which accepts and rejects different files than
/// Foundation's PropertyListSerialization (it rejects OpenStep plists, `<true></true>`
/// and bad base64, and tolerates a malformed `<integer>` or invalid UTF-8 in a
/// string). When that symbol is available we ask it directly; otherwise we fall
/// back to rules measured against launchd on macOS 27.
public enum LaunchdPlistParser {
    private typealias CreateFn = @convention(c) (UnsafeRawPointer, Int) -> UnsafeMutableRawPointer?
    private typealias ReleaseFn = @convention(c) (UnsafeMutableRawPointer) -> Void

    private static let functions: (create: CreateFn, release: ReleaseFn)? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let create = dlsym(handle, "xpc_create_from_plist"),
              let release = dlsym(handle, "xpc_release") else { return nil }
        return (unsafeBitCast(create, to: CreateFn.self), unsafeBitCast(release, to: ReleaseFn.self))
    }()

    /// true/false: whether launchd would parse these bytes. nil: can't tell here.
    public static func launchdAccepts(_ data: Data) -> Bool? {
        if let fns = functions {
            guard !data.isEmpty else { return false }
            return data.withUnsafeBytes { buf -> Bool in
                guard let base = buf.baseAddress, let obj = fns.create(base, buf.count) else { return false }
                fns.release(obj)
                return true
            }
        }
        return fallbackAccepts(data)
    }

    /// Rules measured against launchd when libxpc's parser isn't reachable.
    static func fallbackAccepts(_ data: Data) -> Bool? {
        guard !data.isEmpty else { return false }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard (try? PropertyListSerialization.propertyList(from: data, format: &format)) != nil else {
            return nil  // Foundation can't parse it; launchd might still (it's more lenient in places).
        }
        if format == .openStep { return false }
        if format == .xml {
            let text = String(decoding: data, as: UTF8.self)
            if text.contains("<true></true>") || text.contains("<false></false>") { return false }
            if containsInvalidBase64(text) { return false }
        }
        return true
    }

    static func containsInvalidBase64(_ text: String) -> Bool {
        var rest = Substring(text)
        while let open = rest.range(of: "<data>"), let close = rest[open.upperBound...].range(of: "</data>") {
            let body = rest[open.upperBound..<close.lowerBound].filter { !$0.isWhitespace }
            if Data(base64Encoded: String(body)) == nil { return true }
            rest = rest[close.upperBound...]
        }
        return false
    }
}
