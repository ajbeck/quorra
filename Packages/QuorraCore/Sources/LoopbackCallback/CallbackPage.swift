import CryptoKit
import Foundation

/// The page a browser shows after it hands a sign-in back to Quorra's loopback listener.
///
/// Designed on the Quorra Site Design canvas ("Browser sign-in pages"). One stylesheet and inline
/// SVG only: no scripts, images, fonts or network loads. The response's Content Security Policy
/// allows that stylesheet by its hash and nothing else. Features supply the title, status and
/// body; this type supplies the frame.
package struct CallbackPage: Equatable, Sendable {
    package enum Tone: String, Sendable {
        case ok, warn, idle
    }

    /// Whether the request was the sign-in Quorra expected: 200 if so, 400 if not.
    package let accepted: Bool
    package let title: String
    package let tone: Tone
    package let statusLabel: String
    /// Trusted markup. Escape anything that came from outside with `escaped(_:)`.
    package let content: String

    package init(accepted: Bool, title: String, tone: Tone, statusLabel: String, content: String) {
        self.accepted = accepted
        self.title = title
        self.tone = tone
        self.statusLabel = statusLabel
        self.content = content
    }

    package var statusLine: String { accepted ? "200 OK" : "400 Bad Request" }

    /// The `Content-Security-Policy` header value: the page's one `<style>` element, by hash.
    package static let contentSecurityPolicy = "default-src 'none'; style-src 'sha256-\(Data(SHA256.hash(data: Data(stylesheet.utf8))).base64EncodedString())'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

    package var html: String {
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
        <div class="top"><div class="brand mono">\(Self.mark)QUORRA</div><span class="status mono \(tone.rawValue)">\(statusLabel)</span></div>
        \(content)
        </div>
        <p class="foot">This page comes from Quorra at <span class="mono">127.0.0.1</span>, on this Mac only. It loads nothing from the internet.</p>
        </main>
        </body>
        </html>

        """
    }

    /// The complete HTTP response, which closes the connection.
    package var response: Data {
        let body = html
        return Data("HTTP/1.1 \(statusLine)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: \(Self.contentSecurityPolicy)\r\nConnection: close\r\n\r\n\(body)".utf8)
    }

    /// The "Close this tab" callout that ends a received page.
    package static func closeTabStep(note: String) -> String {
        #"<div class="next">\#(closeTabIcon)<div class="next-text"><div class="eyebrow mono">YOUR NEXT STEP</div><div class="next-title">Close this tab</div><div class="next-note">\#(note)</div></div><kbd class="mono">⌘W</kbd></div>"#
    }

    /// Escapes text for an HTML text node.
    package static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static let mark = ##"<svg width="28" height="28" viewBox="0 0 28 28" aria-hidden="true"><circle cx="13" cy="13" r="9.5" fill="none" stroke="#5fb9de" stroke-width="2.5"/><path d="M19.5 19.5 L25 25" stroke="#5fb9de" stroke-width="2.5" stroke-linecap="round"/></svg>"##
    package static let doneIcon = ##"<svg width="20" height="20" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="9" fill="#0f1d16" stroke="#4ade80" stroke-width="1.5"/><path d="M6 10.2 L8.8 13 L14 7.5" fill="none" stroke="#4ade80" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>"##
    package static let nowIcon = ##"<svg width="20" height="20" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="9" fill="#0e1d24" stroke="#5fb9de" stroke-width="1.5"/><circle cx="10" cy="10" r="3" fill="#5fb9de"/></svg>"##
    package static let pendingIcon = ##"<svg width="20" height="20" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="9" fill="none" stroke="#2a3540" stroke-width="1.5"/></svg>"##
    package static let stoppedIcon = ##"<svg width="20" height="20" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="9" fill="#1d1710" stroke="#f0b070" stroke-width="1.5"/><path d="M7 7 L13 13 M13 7 L7 13" fill="none" stroke="#f0b070" stroke-width="1.8" stroke-linecap="round"/></svg>"##
    private static let closeTabIcon = ##"<svg width="36" height="36" viewBox="0 0 36 36" aria-hidden="true"><rect x="3" y="7" width="30" height="22" rx="4" fill="none" stroke="#5fb9de" stroke-width="2"/><path d="M3 13 H33" stroke="#5fb9de" stroke-width="2"/><path d="M14.5 17.5 L21.5 24.5 M21.5 17.5 L14.5 24.5" stroke="#5fb9de" stroke-width="2.2" stroke-linecap="round"/></svg>"##

    /// Colours from the site's foundations (`docs/assets/css/main.css`); system fonts, as in the app.
    package static let stylesheet = """
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
