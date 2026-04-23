import Foundation

enum TurboIncomingLink {
    private static let shareHost = "beepbeep.to"

    static func reference(from url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased() else { return nil }

        switch scheme {
        case "https", "http":
            return webReference(from: url)
        case "beepbeep":
            return customSchemeReference(from: url)
        default:
            return nil
        }
    }

    private static func webReference(from url: URL) -> String? {
        guard let host = url.host?.lowercased(), host == shareHost else { return nil }
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count >= 2 else { return nil }

        switch (pathComponents[0], pathComponents[1]) {
        case ("p", let code) where !code.isEmpty:
            return canonicalShareLink(for: code)
        case ("id", let code) where !code.isEmpty:
            return "did:web:\(shareHost):id:\(code)"
        default:
            return nil
        }
    }

    private static func customSchemeReference(from url: URL) -> String? {
        let host = url.host?.lowercased()
        let pathComponents = url.pathComponents.filter { $0 != "/" }

        if host == "p", let code = pathComponents.first, !code.isEmpty {
            return canonicalShareLink(for: code)
        }

        if host == "id", let code = pathComponents.first, !code.isEmpty {
            return "did:web:\(shareHost):id:\(code)"
        }

        guard host == "add",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let reference = components.queryItems?.first(where: { $0.name == "ref" || $0.name == "code" })?.value,
              !reference.isEmpty else {
            return nil
        }

        return reference
    }

    private static func canonicalShareLink(for code: String) -> String {
        let encodedCode = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? code
        return "https://\(shareHost)/p/\(encodedCode)"
    }
}
