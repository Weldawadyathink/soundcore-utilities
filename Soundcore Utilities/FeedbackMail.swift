//
//  FeedbackMail.swift
//  Soundcore Utilities
//
//  Composes a support email with the diagnostic log attached. Falls back to a
//  mailto: link when the Mail app is not set up on the device.
//

import MessageUI
import SwiftUI

enum Feedback {
    static let address = "developer@weldawadyathink.com"
    static let subject = "Headphone Control feedback"

    static var canComposeInApp: Bool { MFMailComposeViewController.canSendMail() }

    /// mailto: URL for devices without Mail configured. Attachments are not possible here.
    static func mailtoURL(body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }

    static func body(diagnostics: String) -> String {
        """
        Describe what happened:



        ----
        Diagnostics
        \(diagnostics)

        The attached log may include your earbuds' serial number and Bluetooth identifiers.
        """
    }
}

struct FeedbackMailView: UIViewControllerRepresentable {
    let diagnostics: String
    let log: String
    let snapshots: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([Feedback.address])
        controller.setSubject(Feedback.subject)
        controller.setMessageBody(Feedback.body(diagnostics: diagnostics), isHTML: false)
        if let data = log.data(using: .utf8), !log.isEmpty {
            controller.addAttachmentData(data, mimeType: "text/plain", fileName: "headphone-control-log.txt")
        }
        if let snapshots, let data = snapshots.data(using: .utf8) {
            controller.addAttachmentData(data, mimeType: "text/plain", fileName: "state-snapshots.txt")
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        nonisolated func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            MainActor.assumeIsolated {
                controller.dismiss(animated: true)
            }
        }
    }
}
