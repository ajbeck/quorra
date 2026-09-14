import AppKit
import SwiftUI

struct InteractiveWindowRegistration: NSViewRepresentable {
    let presentationController: AppPresentationController

    func makeNSView(context: Context) -> RegistrationView {
        RegistrationView(presentationController: presentationController)
    }

    func updateNSView(_ nsView: RegistrationView, context: Context) {
        nsView.presentationController = presentationController
        nsView.registerWindowIfAvailable()
    }
}

extension InteractiveWindowRegistration {
    @MainActor
    final class RegistrationView: NSView {
        weak var presentationController: AppPresentationController?

        init(presentationController: AppPresentationController) {
            self.presentationController = presentationController
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            registerWindowIfAvailable()
        }

        func registerWindowIfAvailable() {
            guard let window else { return }
            presentationController?.registerInteractiveWindow(window)
        }
    }
}
