#if !os(macOS)
import Foundation
import Observation
import SwiftUI
import WebKit

/// What a page is asking for, and the one place a phone can answer it.
///
/// On the Mac each of these is a sheet on the window the page lives in, presented from AppKit where
/// the page is. A phone has one window and no sheet to hang off a column, so the request goes to a
/// queue the window watches: `PhoneContentView` puts up the alert, the answer comes back here, and
/// the page's JavaScript — suspended by WebKit all the while, as `alert()` has always been —
/// carries on. One at a time: a second page asking waits for the first to be answered.
@MainActor
@Observable
final class PageDialogQueue {
    static let shared = PageDialogQueue()

    enum Kind {
        case alert
        case confirm
        case prompt(defaultText: String)
        case file(allowsMultiple: Bool, allowsDirectories: Bool)
    }

    enum Answer {
        case ok(String)
        case cancel
        case files([URL])
    }

    struct Request: Identifiable {
        let id = UUID()
        let host: String
        let message: String
        let kind: Kind
    }

    /// The question on screen, if there is one.
    private(set) var current: Request?
    private var answer: CheckedContinuation<Answer, Never>?
    private var waiting: [(Request, CheckedContinuation<Answer, Never>)] = []

    func ask(_ request: Request) async -> Answer {
        await withCheckedContinuation { continuation in
            if current == nil {
                current = request
                answer = continuation
            } else {
                waiting.append((request, continuation))
            }
        }
    }

    /// Called by the view when the person has answered. SwiftUI dismisses an alert *and* runs the
    /// button that dismissed it, so this arrives twice for one answer; the second time there is
    /// nothing waiting, and taking the next question off the queue then would cancel it unasked.
    func resolve(_ value: Answer) {
        guard let continuation = answer else { return }
        current = nil
        answer = nil
        continuation.resume(returning: value)
        if !waiting.isEmpty {
            let (next, nextContinuation) = waiting.removeFirst()
            current = next
            answer = nextContinuation
        }
    }
}

/// The four dialogs a page can put up, answered through the queue. A `WebPage` with no presenter
/// answers all four itself and always says no — which is a browser that quietly cannot upload a
/// file, so six presents them here too.
@MainActor
struct PageDialogs: WebPage.DialogPresenting {
    func handleJavaScriptAlert(message: String, initiatedBy frame: WebPage.FrameInfo) async {
        _ = await PageDialogQueue.shared.ask(.init(host: Self.host(of: frame), message: message, kind: .alert))
    }

    func handleJavaScriptConfirm(message: String,
                                 initiatedBy frame: WebPage.FrameInfo) async -> WebPage.JavaScriptConfirmResult {
        let answer = await PageDialogQueue.shared.ask(.init(host: Self.host(of: frame), message: message, kind: .confirm))
        if case .ok = answer { return .ok }
        return .cancel
    }

    func handleJavaScriptPrompt(message: String, defaultText: String?,
                                initiatedBy frame: WebPage.FrameInfo) async -> WebPage.JavaScriptPromptResult {
        let answer = await PageDialogQueue.shared.ask(
            .init(host: Self.host(of: frame), message: message, kind: .prompt(defaultText: defaultText ?? "")))
        if case .ok(let text) = answer { return .ok(text) }
        return .cancel
    }

    func handleFileInputPrompt(parameters: WKOpenPanelParameters,
                               initiatedBy frame: WebPage.FrameInfo) async -> WebPage.FileInputPromptResult {
        let answer = await PageDialogQueue.shared.ask(.init(
            host: Self.host(of: frame),
            message: String(localized: "is asking for a file."),
            kind: .file(allowsMultiple: parameters.allowsMultipleSelection,
                        allowsDirectories: parameters.allowsDirectories)))
        if case .files(let urls) = answer, !urls.isEmpty { return .selected(urls) }
        return .cancel
    }

    /// Which site asked. A dialog with no return address is a demand from nowhere, and on a phone
    /// the page that asked is often not the one being looked at.
    private static func host(of frame: WebPage.FrameInfo) -> String {
        let host = frame.securityOrigin.host
        return host.isEmpty ? String(localized: "This page") : host
    }
}
#endif
