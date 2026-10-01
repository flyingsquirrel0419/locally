import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LocallyCore

final class RedirectPolicyTests: XCTestCase {
    private func request(_ url: String, authorized: Bool = true) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        if authorized {
            request.setValue("Bearer hf_secret", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func testHostMatching() {
        XCTAssertTrue(RedirectPolicy.isAllowedHFHost("huggingface.co"))
        XCTAssertTrue(RedirectPolicy.isAllowedHFHost("hf.co"))
        XCTAssertTrue(RedirectPolicy.isAllowedHFHost("cdn-lfs.hf.co"))
        XCTAssertTrue(RedirectPolicy.isAllowedHFHost("cas-bridge.xethub.hf.co"))
        XCTAssertTrue(RedirectPolicy.isAllowedHFHost("HuggingFace.co"))
        XCTAssertFalse(RedirectPolicy.isAllowedHFHost("evilhuggingface.co"))
        XCTAssertFalse(RedirectPolicy.isAllowedHFHost("huggingface.co.evil.com"))
        XCTAssertFalse(RedirectPolicy.isAllowedHFHost("nothf.co"))
        XCTAssertFalse(RedirectPolicy.isAllowedHFHost("hf.co.attacker.io"))
        XCTAssertFalse(RedirectPolicy.isAllowedHFHost(""))
    }

    func testAuthorizationKeptOnSameHostRedirect() {
        let original = request("https://huggingface.co/org/model/resolve/main/m.bin")
        let redirect = request("https://cdn-lfs-us-1.hf.co/org/model/abcdef", authorized: true)
        let sanitized = RedirectPolicy.sanitize(request: redirect, original: original)
        XCTAssertEqual(sanitized?.value(forHTTPHeaderField: "Authorization"), "Bearer hf_secret")
    }

    func testAuthorizationStrippedOnCrossHostRedirect() {
        let original = request("https://huggingface.co/org/model/resolve/main/m.bin")
        let redirect = request("https://attacker.example.com/steal", authorized: true)
        let sanitized = RedirectPolicy.sanitize(request: redirect, original: original)
        XCTAssertNil(sanitized?.value(forHTTPHeaderField: "Authorization"))
        // The rest of the request survives.
        XCTAssertEqual(sanitized?.url?.host, "attacker.example.com")
    }

    func testAuthorizationStrippedForLookalikeHosts() {
        let original = request("https://huggingface.co/org/model/resolve/main/m.bin")
        for host in ["evilhuggingface.co", "huggingface.co.evil.com", "hf.co.attacker.io"] {
            let redirect = request("https://\(host)/x", authorized: true)
            let sanitized = RedirectPolicy.sanitize(request: redirect, original: original)
            XCTAssertNil(sanitized?.value(forHTTPHeaderField: "Authorization"), host)
        }
    }

    func testNonHTTPSRedirectRefused() {
        let original = request("https://huggingface.co/org/model/resolve/main/m.bin")
        let plain = request("http://huggingface.co/org/model/resolve/main/m.bin")
        XCTAssertNil(RedirectPolicy.sanitize(request: plain, original: original))
    }

    func testNoAuthorizationHeaderPassesThrough() {
        let original = request("https://huggingface.co/x", authorized: false)
        let redirect = request("https://attacker.example.com/x", authorized: false)
        let sanitized = RedirectPolicy.sanitize(request: redirect, original: original)
        XCTAssertNotNil(sanitized)
        XCTAssertNil(sanitized?.value(forHTTPHeaderField: "Authorization"))
    }
}
