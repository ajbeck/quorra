import CryptoKit
import Foundation

/// The page the browser shows after it hands a sign-in back to Quorra's loopback listener.
///
/// Designed on the Quorra Site Design canvas ("Browser sign-in pages"). One stylesheet and inline
/// SVG only: no scripts, images, fonts or network loads. The response's Content Security Policy
/// allows that stylesheet by its hash and nothing else.
enum SignInCallbackPage: Equatable {
    /// The browser returned an authorization code; Quorra is exchanging it.
    case received(sessionName: String)
    /// IAM Identity Center returned `access_denied`.
    case declined(sessionName: String)
    /// A request that doesn't match the sign-in in progress (wrong state, stray path).
    case notAccepted

    var statusLine: String {
        switch self {
        case .received: "200 OK"
        case .declined, .notAccepted: "400 Bad Request"
        }
    }

    /// The `Content-Security-Policy` header value: the page's one `<style>` element, by hash.
    static let contentSecurityPolicy = "default-src 'none'; style-src 'sha256-\(Data(SHA256.hash(data: Data(stylesheet.utf8))).base64EncodedString())'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

    var html: String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title) — Quorra</title>
        <style>\(Self.stylesheet)</style>
        </head>
        <body>
        <main>
        <div class="card">
        <div class="top"><div class="brand mono">\(Self.mark)QUORRA</div><span class="status mono \(statusClass)">\(statusLabel)</span></div>
        \(content)
        </div>
        <p class="foot">This page comes from Quorra at <span class="mono">127.0.0.1</span>, on this Mac only. It loads nothing from the internet.</p>
        </main>
        </body>
        </html>

        """
    }

    private var title: String {
        switch self {
        case .received: "Sign-in received"
        case .declined: "Sign-in declined"
        case .notAccepted: "Sign-in response not accepted"
        }
    }

    private var statusClass: String {
        switch self {
        case .received: "ok"
        case .declined: "warn"
        case .notAccepted: "idle"
        }
    }

    private var statusLabel: String {
        switch self {
        case .received: "RECEIVED"
        case .declined: "DECLINED"
        case .notAccepted: "IGNORED"
        }
    }

    private var content: String {
        switch self {
        case .received(let sessionName):
            """
            <div><h1>Sign-in received</h1><p class="lead">IAM Identity Center approved the sign-in for <span class="session mono">\(Self.escaped(sessionName))</span>. Quorra is finishing it now.</p></div>
            <ol>
            <li>\(Self.doneIcon)<span class="label">You approved access in the browser</span><span class="tag mono">DONE</span></li>
            <li>\(Self.nowIcon)<span class="label">Quorra saves the session in your Keychain</span><span class="tag mono now">NOW</span></li>
            <li>\(Self.pendingIcon)<span class="label later">Your AWS tools pick up credentials from Quorra</span><span class="tag mono">NEXT</span></li>
            </ol>
            <div class="next">\(Self.closeTabIcon)<div class="next-text"><div class="eyebrow mono">YOUR NEXT STEP</div><div class="next-title">Close this tab</div><div class="next-note">Nothing else to do here. Quorra shows the session as signed in when it’s done.</div></div><kbd class="mono">⌘W</kbd></div>
            """
        case .declined(let sessionName):
            """
            <div><h1>Sign-in was declined</h1><p class="lead">IAM Identity Center didn’t give Quorra access to <span class="session mono">\(Self.escaped(sessionName))</span>, so nothing was saved.</p></div>
            <ol>
            <li>\(Self.stoppedIcon)<span class="label">Access was denied in the browser</span><span class="tag mono warn">STOPPED</span></li>
            <li>\(Self.pendingIcon)<span class="label later">No session or credentials were stored</span><span class="tag mono">SKIPPED</span></li>
            </ol>
            <p class="closing">You can close this tab. To try again, choose Sign In for the session in Quorra. If it’s declined again, check with your AWS administrator that you’re assigned to this account.</p>
            """
        case .notAccepted:
            """
            <div><h1>This response wasn’t accepted</h1><p class="lead">It doesn’t match the sign-in Quorra is waiting for, so Quorra ignored it. Any sign-in in progress carries on, and nothing was saved from this page.</p></div>
            <div class="box"><div class="tag mono">THIS USUALLY MEANS</div><ul><li>The tab is from an earlier sign-in that has since been replaced.</li><li>The sign-in took too long and Quorra stopped waiting.</li></ul></div>
            <p class="closing">You can close this tab. To sign in, start again from Quorra and finish in the tab it opens.</p>
            """
        }
    }

    /// Escapes text for an HTML text node.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static let mark = ##"<svg width="28" height="28" viewBox="0 0 28 28" aria-hidden="true"><circle cx="13" cy="13" r="9.5" fill="none" stroke="#5fb9de" stroke-width="2.5"/><path d="M19.5 19.5 L25 25" stroke="#5fb9de" stroke-width="2.5" stroke-linecap="round"/></svg>"##
    private static let doneIcon = ##"<svg width="20" height="20" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="9" fill="#0f1d16" stroke="#4ade80" stroke-width="1.5"/><path d="M6 10.2 L8.8 13 L14 7.5" fill="none" stroke="#4ade80" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>"##
    private static let nowIcon = ##"<svg width="20" height="20" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="9" fill="#0e1d24" stroke="#5fb9de" stroke-width="1.5"/><circle cx="10" cy="10" r="3" fill="#5fb9de"/></svg>"##
    private static let pendingIcon = ##"<svg width="20" height="20" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="9" fill="none" stroke="#2a3540" stroke-width="1.5"/></svg>"##
    private static let stoppedIcon = ##"<svg width="20" height="20" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="9" fill="#1d1710" stroke="#f0b070" stroke-width="1.5"/><path d="M7 7 L13 13 M13 7 L7 13" fill="none" stroke="#f0b070" stroke-width="1.8" stroke-linecap="round"/></svg>"##
    private static let closeTabIcon = ##"<svg width="36" height="36" viewBox="0 0 36 36" aria-hidden="true"><rect x="3" y="7" width="30" height="22" rx="4" fill="none" stroke="#5fb9de" stroke-width="2"/><path d="M3 13 H33" stroke="#5fb9de" stroke-width="2"/><path d="M14.5 17.5 L21.5 24.5 M21.5 17.5 L14.5 24.5" stroke="#5fb9de" stroke-width="2.2" stroke-linecap="round"/></svg>"##

    /// Colours from the site's foundations (`docs/assets/css/main.css`); system fonts, as in the app.
    static let stylesheet = """
    :root{color-scheme:dark}
    *{box-sizing:border-box}
    body{margin:0;background:#0a0d11;color:#e8edf2;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif}
    main{min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:28px;padding:48px 20px}
    .mono{font-family:ui-monospace,"SF Mono",Menlo,monospace}
    .card{width:100%;max-width:34rem;background:#11161c;border:1px solid #222c36;border-radius:14px;padding:40px;display:flex;flex-direction:column;gap:28px}
    .top{display:flex;align-items:center;justify-content:space-between;gap:16px}
    .brand{display:flex;align-items:center;gap:10px;font-size:12px;letter-spacing:.16em;color:#a9b6c3}
    .status{display:inline-flex;align-items:center;gap:8px;font-size:11px;letter-spacing:.14em;border:1px solid;border-radius:999px;padding:5px 11px}
    .status::before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor}
    .status.ok{color:#4ade80;border-color:#1d3a2a;background:#0f1d16}
    .status.warn{color:#f0b070;border-color:#3d2e1c;background:#1d1710}
    .status.idle{color:#a9b6c3;border-color:#2a3540;background:#0e131a}
    h1{margin:0;font-size:30px;line-height:1.15;font-weight:700;letter-spacing:-.02em}
    .lead{margin:12px 0 0;font-size:16px;line-height:1.6;color:#a9b6c3}
    .session{font-size:14.5px;color:#e8edf2;background:#0e131a;border:1px solid #1a222b;border-radius:6px;padding:2px 7px}
    ol{margin:0;padding:0;list-style:none;border-top:1px solid #1a222b}
    ol li{display:flex;align-items:center;gap:14px;padding:14px 0;border-bottom:1px solid #1a222b}
    .label{flex-grow:1;font-size:15px}
    .later{color:#a9b6c3}
    .tag{font-size:11px;letter-spacing:.14em;color:#7c8b99}
    .tag.now{color:#5fb9de}
    .tag.warn{color:#f0b070}
    .next{display:flex;align-items:center;gap:18px;padding:20px 22px;background:#0e1d24;border:1px solid #1f4a5c;border-radius:12px}
    .next svg{flex-shrink:0}
    .next-text{flex-grow:1;display:flex;flex-direction:column;gap:4px}
    .eyebrow{font-size:11px;letter-spacing:.14em;color:#5fb9de}
    .next-title{font-size:20px;line-height:1.3;font-weight:700}
    .next-note{font-size:14px;line-height:1.5;color:#a9b6c3}
    kbd{flex-shrink:0;font-size:14px;color:#e8edf2;background:#11161c;border:1px solid #2a3540;border-bottom-width:2px;border-radius:7px;padding:6px 10px}
    .closing{margin:0;font-size:15px;line-height:1.6}
    .box{display:flex;flex-direction:column;gap:10px;padding:18px 20px;background:#0e131a;border:1px solid #1a222b;border-radius:10px}
    .box ul{margin:0;padding:0 0 0 18px;display:flex;flex-direction:column;gap:6px;font-size:15px;line-height:1.55}
    .foot{margin:0;max-width:34rem;text-align:center;font-size:13px;line-height:1.6;color:#7c8b99}
    .foot .mono{font-size:12px}
    @media (max-width:480px){.card{padding:28px 22px}.next{flex-wrap:wrap}}
    """
}
