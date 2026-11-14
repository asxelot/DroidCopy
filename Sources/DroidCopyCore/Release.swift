import Foundation

/// The newest DroidCopy release on GitHub, and comparing version numbers.
public enum Release {
    public static let latestURL = URL(string: "https://api.github.com/repos/asxelot/DroidCopy/releases/latest")!
    public static let pageURL = URL(string: "https://github.com/asxelot/DroidCopy/releases/latest")!

    public struct Info: Equatable, Sendable {
        /// "1.1", without the tag's "v".
        public let version: String
        /// The release's page, where the disk image is.
        public let page: URL
        public init(version: String, page: URL) {
            self.version = version
            self.page = page
        }
    }

    /// "v1.0.1" → [1, 0, 1]. Anything after the numbers ("-beta") is ignored.
    public static func numbers(_ version: String) -> [Int] {
        var v = Substring(version)
        if v.first == "v" || v.first == "V" { v = v.dropFirst() }
        var out: [Int] = []
        for part in v.split(separator: ".") {
            let digits = part.prefix(while: \.isNumber)
            guard let n = Int(digits) else { break }
            out.append(n)
            if digits.count != part.count { break }
        }
        return out
    }

    /// Whether `a` is a later version than `b`: 1.0.10 > 1.0.9, and 1.1 > 1.0.1. 1.0 == 1.0.0.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = numbers(a), y = numbers(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// GitHub's "latest release" JSON. nil for a draft or prerelease, or anything unexpected.
    public static func parse(_ data: Data) -> Info? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, !numbers(tag).isEmpty,
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true else { return nil }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? pageURL
        var version = tag
        if version.first == "v" || version.first == "V" { version.removeFirst() }
        return Info(version: version, page: page)
    }

    /// Asks GitHub for the latest release. nil when offline or GitHub didn't answer sensibly.
    public static func fetchLatest(appVersion: String, session: URLSession = .shared) async -> Info? {
        var request = URLRequest(url: latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DroidCopy/\(appVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }
}
