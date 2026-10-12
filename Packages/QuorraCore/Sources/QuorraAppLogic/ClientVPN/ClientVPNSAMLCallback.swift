import ClientVPN
import Foundation
import LoopbackCallback

/// AWS Client VPN's SAML sign-in returns to `http://127.0.0.1:35001` as a form POST.
enum ClientVPNSAMLCallback {
    static let port: UInt16 = 35_001
    /// Form encoding can spend three bytes on each byte of the Base64 assertion.
    static let limits = LoopbackHTTPRequest.Limits(header: 16 * 1_024, body: 3 * ClientVPNLimits.credentialBytes)

    /// The Base64 SAML assertion in a callback request. `relayState` is the one the challenge URL carried.
    static func assertion(from request: LoopbackHTTPRequest, port: UInt16, relayState: String?) throws -> String {
        guard request.method == "POST", request.target.hasPrefix("/"), !request.target.hasPrefix("//"),
              let target = URLComponents(string: "http://127.0.0.1:\(port)\(request.target)"),
              target.host == "127.0.0.1", target.port == Int(port), target.query == nil, target.fragment == nil,
              request.fields["host"] == ["127.0.0.1:\(port)"],
              let types = request.fields["content-type"], types.count == 1,
              types[0].lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "application/x-www-form-urlencoded",
              let form = String(data: request.body, encoding: .utf8) else {
            throw ClientVPNLiveFailure.authentication
        }
        let values = try formValues(form)
        guard values.keys.allSatisfy({ $0 == "SAMLResponse" || $0 == "RelayState" }),
              let assertions = values["SAMLResponse"], assertions.count == 1,
              let assertion = assertions.first, !assertion.isEmpty,
              (values["RelayState"]?.count ?? 0) <= 1,
              relayState.map({ values["RelayState"] == [$0] }) ?? true,
              Data(base64Encoded: assertion)?.isEmpty == false else {
            throw ClientVPNLiveFailure.authentication
        }
        guard assertion.utf8.count <= ClientVPNLimits.credentialBytes else { throw ClientVPNLiveFailure.invalidCredentials }
        return assertion
    }

    private static func formValues(_ form: String) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        for pair in form.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let name = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  let value = String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  !name.isEmpty else {
                throw ClientVPNLiveFailure.authentication
            }
            result[name, default: []].append(value)
        }
        return result
    }
}

/// The pages the browser shows after a Client VPN sign-in, in the same frame as Identity Center's.
enum ClientVPNCallbackPage {
    static func received(profileName: String) -> CallbackPage {
        CallbackPage(accepted: true, title: "VPN sign-in received", tone: .ok, statusLabel: "RECEIVED", content: """
        <div><h1>Sign-in received</h1><p class="lead">Your identity provider approved the VPN sign-in for <span class="session mono">\(CallbackPage.escaped(profileName))</span>. Quorra is connecting now.</p></div>
        <ol>
        <li>\(CallbackPage.doneIcon)<span class="label">You signed in with your identity provider</span><span class="tag mono">DONE</span></li>
        <li>\(CallbackPage.nowIcon)<span class="label">Quorra connects the VPN</span><span class="tag mono now">NOW</span></li>
        <li>\(CallbackPage.pendingIcon)<span class="label later">Your Mac reaches the VPN’s network</span><span class="tag mono">NEXT</span></li>
        </ol>
        \(CallbackPage.closeTabStep(note: "Nothing else to do here. Quorra shows the VPN as connected when it’s done."))
        """)
    }

    static let notAccepted = CallbackPage(accepted: false, title: "VPN sign-in response not accepted", tone: .idle, statusLabel: "IGNORED", content: """
    <div><h1>This response wasn’t accepted</h1><p class="lead">It doesn’t match the VPN sign-in Quorra is waiting for, so Quorra ignored it. Any sign-in in progress carries on.</p></div>
    <div class="box"><div class="tag mono">THIS USUALLY MEANS</div><ul><li>The tab is from an earlier VPN sign-in that has since been replaced.</li><li>The sign-in took too long and Quorra stopped waiting.</li></ul></div>
    <p class="closing">You can close this tab. To connect, start again from Quorra and finish in the tab it opens.</p>
    """)
}
