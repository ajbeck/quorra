import Foundation
import LoopbackCallback

/// The page the browser shows after it hands an Identity Center sign-in back to Quorra.
enum SignInCallbackPage: Equatable {
    /// The browser returned an authorization code; Quorra is exchanging it.
    case received(sessionName: String)
    /// IAM Identity Center returned `access_denied`.
    case declined(sessionName: String)
    /// A request that doesn't match the sign-in in progress (wrong state, stray path).
    case notAccepted

    static var contentSecurityPolicy: String { CallbackPage.contentSecurityPolicy }

    var html: String { page.html }

    var page: CallbackPage {
        switch self {
        case .received(let sessionName):
            CallbackPage(accepted: true, title: "Sign-in received", tone: .ok, statusLabel: "RECEIVED", content: """
            <div><h1>Sign-in received</h1><p class="lead">IAM Identity Center approved the sign-in for <span class="session mono">\(CallbackPage.escaped(sessionName))</span>. Quorra is finishing it now.</p></div>
            <ol>
            <li>\(CallbackPage.doneIcon)<span class="label">You approved access in the browser</span><span class="tag mono">DONE</span></li>
            <li>\(CallbackPage.nowIcon)<span class="label">Quorra saves the session in your Keychain</span><span class="tag mono now">NOW</span></li>
            <li>\(CallbackPage.pendingIcon)<span class="label later">Your AWS tools pick up credentials from Quorra</span><span class="tag mono">NEXT</span></li>
            </ol>
            \(CallbackPage.closeTabStep(note: "Nothing else to do here. Quorra shows the session as signed in when it’s done."))
            """)
        case .declined(let sessionName):
            CallbackPage(accepted: false, title: "Sign-in declined", tone: .warn, statusLabel: "DECLINED", content: """
            <div><h1>Sign-in was declined</h1><p class="lead">IAM Identity Center didn’t give Quorra access to <span class="session mono">\(CallbackPage.escaped(sessionName))</span>, so nothing was saved.</p></div>
            <ol>
            <li>\(CallbackPage.stoppedIcon)<span class="label">Access was denied in the browser</span><span class="tag mono warn">STOPPED</span></li>
            <li>\(CallbackPage.pendingIcon)<span class="label later">No session or credentials were stored</span><span class="tag mono">SKIPPED</span></li>
            </ol>
            <p class="closing">You can close this tab. To try again, choose Sign In for the session in Quorra. If it’s declined again, check with your AWS administrator that you’re assigned to this account.</p>
            """)
        case .notAccepted:
            CallbackPage(accepted: false, title: "Sign-in response not accepted", tone: .idle, statusLabel: "IGNORED", content: """
            <div><h1>This response wasn’t accepted</h1><p class="lead">It doesn’t match the sign-in Quorra is waiting for, so Quorra ignored it. Any sign-in in progress carries on, and nothing was saved from this page.</p></div>
            <div class="box"><div class="tag mono">THIS USUALLY MEANS</div><ul><li>The tab is from an earlier sign-in that has since been replaced.</li><li>The sign-in took too long and Quorra stopped waiting.</li></ul></div>
            <p class="closing">You can close this tab. To sign in, start again from Quorra and finish in the tab it opens.</p>
            """)
        }
    }
}
