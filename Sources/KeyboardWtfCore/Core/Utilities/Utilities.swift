import Foundation
import os

public struct SystemClock: Clock { public init() {} ; public func now() -> Date { Date() } }

public final class RedactingLogger: Logger {
    private let logger = os.Logger(subsystem: "com.yourname.keyboardwtf", category: "app")
    private let patterns = ["sk-[A-Za-z0-9_-]{10,}", "Bearer\\s+[A-Za-z0-9._-]+"]
    public init() {}
    public func info(_ event: String, metadata: [String: String] = [:]) { emit(.info, event, metadata) }
    public func error(_ event: String, metadata: [String: String] = [:]) { emit(.error, event, metadata) }
    private func emit(_ level: OSLogType, _ event: String, _ metadata: [String: String]) {
        let line = redact(([event] + metadata.map { "\($0.key)=\($0.value)" }).joined(separator: " "))
        logger.log(level: level, "\(line, privacy: .public)")
    }
    public func redact(_ value: String) -> String {
        patterns.reduce(value) { partial, pattern in
            (try? NSRegularExpression(pattern: pattern)).map { regex in
                regex.stringByReplacingMatches(in: partial, range: NSRange(partial.startIndex..., in: partial), withTemplate: "[REDACTED]")
            } ?? partial
        }
    }
}

public extension String {
    var compactWhitespace: String { split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
}
