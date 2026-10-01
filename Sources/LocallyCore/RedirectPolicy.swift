import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Decides whether an Authorization header may accompany a request to a
/// given host, and sanitizes redirected requests. Pure and platform-free so
/// the policy is unit-testable without URLSession.
public enum RedirectPolicy {
    /// Hosts the Hugging Face token may be sent to. Exactly these, or any
    /// subdomain of them — `evilhuggingface.co` must not match.
    public static let allowedHFHosts: Set<String> = ["huggingface.co", "hf.co"]

    /// True when `host` equals an allowed host or is a subdomain of one.
    public static func isAllowedHFHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if allowedHFHosts.contains(lower) { return true }
        for domain in allowedHFHosts where lower.hasSuffix("." + domain) {
            return true
        }
        return false
    }

    /// True when the redirect target is a host the token may travel to.
    public static func isAllowedRedirectTarget(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return isAllowedHFHost(host)
    }

    /// Returns the redirect request with Authorization stripped when the
    /// target host is outside the allowed set (e.g. cdn-lfs*.hf.co is fine,
    /// an attacker-controlled host is not). Returns nil to refuse the
    /// redirect entirely when the scheme is not HTTPS.
    public static func sanitize(request: URLRequest, original: URLRequest) -> URLRequest? {
        guard let url = request.url, url.scheme?.lowercased() == "https" else { return nil }
        var sanitized = request
        if let host = url.host, !isAllowedHFHost(host) {
            sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return sanitized
    }
}
