import AppKit
import Foundation
import Observation
import UserNotifications

private enum DefaultIMDSNotification {
    nonisolated static let requestIdentifier = "default-imds-endpoint-authentication-required"
    nonisolated static let categoryIdentifier = "DEFAULT_IMDS_ENDPOINT_AUTHENTICATION_REQUIRED"
}

/// Coordinates the Default IMDS Endpoint's local notification with in-app navigation.
/// Foreground delivery is suppressed because MainView presents the richer sign-in alert.
@MainActor
@Observable
final class DefaultIMDSNotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    private(set) var endpointOpenRequestID: UUID?

    @ObservationIgnored private let notificationCenter: UNUserNotificationCenter

    init(notificationCenter: UNUserNotificationCenter = .current()) {
        self.notificationCenter = notificationCenter
        super.init()
        notificationCenter.delegate = self
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

    func notifyAuthenticationRequired(profileName: String) async {
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
        content.body = "Sign in to the active profile \(profileName) so Quorra can resume serving credentials on 127.0.0.1:7114."
        content.categoryIdentifier = DefaultIMDSNotification.categoryIdentifier
        content.threadIdentifier = DefaultIMDSNotification.categoryIdentifier
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
        if notification.request.content.categoryIdentifier == DefaultIMDSNotification.categoryIdentifier {
            completionHandler([])
        } else {
            completionHandler([.banner, .sound])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard response.notification.request.content.categoryIdentifier
                == DefaultIMDSNotification.categoryIdentifier,
              response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
            completionHandler()
            return
        }

        Task { @MainActor [weak self] in
            self?.requestEndpointOpen()
            NSWorkspace.shared.open(AppNavigationRoute.defaultIMDSEndpointURL)
        }
        completionHandler()
    }
}
