//
//  OnboardingWindowController.swift
//  EarShot
//

import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private var viewModel: OnboardingViewModel?

    /// Returns true if onboarding is required and was shown.
    @discardableResult
    func presentIfNeeded(onFinished: @escaping () -> Void) -> Bool {
        guard !AppSettings.onboardingCompleted else { return false }
        present(onFinished: onFinished)
        return true
    }

    func present(onFinished: @escaping () -> Void) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = OnboardingViewModel { [weak self] in
            self?.dismiss()
            onFinished()
        }

        let host = NSHostingController(rootView: OnboardingView(viewModel: viewModel))
        let window = NSWindow(contentViewController: host)
        window.title = "EarShot Setup"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.viewModel = viewModel
        self.window = window
    }

    private func dismiss() {
        window?.close()
        window = nil
        viewModel = nil
    }
}
