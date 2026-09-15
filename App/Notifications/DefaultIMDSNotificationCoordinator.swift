import AppKit
import Foundation
import Observation
import QuorraAppLogic
import UserNotifications

private enum DefaultIMDSNotification {
    nonisolated static let requestIdentifier = "default-imds-endpoint-authentication-required"
    nonisolated static let categoryIdentifier = "DEFAULT_IMDS_ENDPOINT_AUTHENTICATION_REQUIRED"
    nonisolated static let signInActionIdentifier = "DEFAULT_IMDS_ENDPOINT_SIGN_IN"
    nonisolated static let sessionNameKey = "sessionName"
}

/// Coordinates the Default IMDS Endpoint's local notification with in-app navigation.
///
/// The notification is the app's only unprompted signal that the served profile needs sign-in; it
/// is shown in the foreground too, and its Sign In action starts the device flow without opening the
/// main window. Clicking the notification body opens the endpoint detail.
@MainActor
@Observable
final class DefaultIMDSNotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    private(set) var endpointOpenRequestID: UUID?

    /// Starts a sign-in for the session named in a notification's Sign In action.
    @ObservationIgnored var signInHandler: (@MainActor (String) -> Void)?

    @ObservationIgnored private let notificationCenter: UNUserNotificationCenter

    init(notificationCenter: UNUserNotificationCenter = .current()) {
        self.notificationCenter = notificationCenter
        super.init()
        notificationCenter.delegate = self
        notificationCenter.setNotificationCategories([
            UNNotificationCategory(
                identifier: DefaultIMDSNotification.categoryIdentifier,
                actions: [
                    UNNotificationAction(
                        identifier: DefaultIMDSNotification.signInActionIdentifier,
                        title: "Sign In",
                        options: []
                    )
                ],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    /// Requests permission at the moment the user enables the persistent endpoint,
    /// which gives the system prompt useful context.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await notificationCenter.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await notificationCenter.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default:
            return false
        }
    }

    func notifyAuthenticationRequired(profileName: String, sessionName: String) async {
        let settings = await notificationCenter.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: [DefaultIMDSNotification.requestIdentifier]
        )
        notificationCenter.removeDeliveredNotifications(
            withIdentifiers: [DefaultIMDSNotification.requestIdentifier]
        )

        let content = UNMutableNotificationContent()
        content.title = "Default IMDS Endpoint needs sign-in"
        content.body = "Sign in to \(sessionName) so Quorra can keep serving credentials for \(profileName) on \(DefaultIMDSEndpoint.bindAddress):\(DefaultIMDSEndpoint.port)."
        content.categoryIdentifier = DefaultIMDSNotification.categoryIdentifier
        content.threadIdentifier = DefaultIMDSNotification.categoryIdentifier
        content.userInfo = [DefaultIMDSNotification.sessionNameKey: sessionName]
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: DefaultIMDSNotification.requestIdentifier,
            content: content,
            trigger: nil
        )
        try? await notificationCenter.add(request)
    }

    func clearAuthenticationRequiredNotification() {
        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: [DefaultIMDSNotification.requestIdentifier]
        )
        notificationCenter.removeDeliveredNotifications(
            withIdentifiers: [DefaultIMDSNotification.requestIdentifier]
        )
    }

    func consumeEndpointOpenRequest() {
        endpointOpenRequestID = nil
    }

    func requestEndpointOpen() {
        endpointOpenRequestID = UUID()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        guard content.categoryIdentifier == DefaultIMDSNotification.categoryIdentifier else {
            completionHandler()
            return
        }

        switch response.actionIdentifier {
        case DefaultIMDSNotification.signInActionIdentifier:
            let sessionName = content.userInfo[DefaultIMDSNotification.sessionNameKey] as? String
            Task { @MainActor [weak self] in
                guard let sessionName else { return }
                self?.signInHandler?(sessionName)
            }
        case UNNotificationDefaultActionIdentifier:
            Task { @MainActor [weak self] in
                self?.requestEndpointOpen()
                NSWorkspace.shared.open(AppNavigationRoute.defaultIMDSEndpointURL)
            }
        default:
            break
        }
        completionHandler()
    }
}
