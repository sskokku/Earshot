//
//  SurvivalMonitors.swift
//  EarShot
//
//  Small helpers that implement the CLAUDE.md "Long-run survival checklist":
//  - ProcessInfo.beginActivity assertion to defeat App Nap
//  - IOPMAssertion to prevent system sleep on AC while listening
//  - Power source watcher (AC vs battery)
//  - Thermal state watcher (widens VAD gating under .serious)
//  - NSWorkspace sleep/wake watcher (gap markers on battery wake)
//  - Resident-memory sampler for the peak-memory metric
//
//  Everything here is small and stateful; no clear win to splitting across
//  six files when the call sites all live in AppDelegate.
//

import AppKit
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import os

// MARK: App Nap

/// Wraps `ProcessInfo.beginActivity`. Held while the app is in any state
/// other than idle/error — we want the scheduler to keep our audio threads
/// hot so the input tap callback fires on time.
@MainActor
final class AppNapAssertion {
    private var token: NSObjectProtocol?

    func acquire(reason: String) {
        guard token == nil else { return }
        // `.userInitiated` keeps the process active; `.latencyCritical` is
        // the audio-thread hint that App Nap really must stay out of the way.
        // `.idleSystemSleepDisabled` is set via IOPMAssertion separately so
        // we can scope it to AC power only.
        token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: reason
        )
    }

    func release() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }
}

// MARK: Sleep assertion

/// IOPMAssertion wrapper. CLAUDE.md: hold only while listening AND on AC. On
/// battery we WANT the system to be allowed to sleep so the laptop doesn't
/// burn through its battery; gap markers cover the resulting downtime.
@MainActor
final class SleepAssertion {
    private var id: IOPMAssertionID = 0
    private var held = false
    private let log = Logger(subsystem: "com.earshot.app", category: "SleepAssertion")

    func acquire(reason: String) {
        guard !held else { return }
        let name = reason as CFString
        let res = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name,
            &id
        )
        if res == kIOReturnSuccess {
            held = true
        } else {
            log.error("IOPMAssertionCreateWithName failed: \(res)")
        }
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(id)
        held = false
        id = 0
    }

    var isHeld: Bool { held }
}

// MARK: Power source

/// Polls IOPS to decide whether we're plugged in. Polling is cheap and
/// avoids the CFRunLoop bridge required by `IOPSNotificationCreateRunLoopSource`.
/// AppDelegate's 30 s tick consults this — battery changes are not high
/// frequency.
enum PowerSource {
    static func isOnAC() -> Bool {
        guard let unmanagedSnapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            // Conservative default: assume AC. We'd rather hold the sleep
            // assertion accidentally for a moment than drain the battery.
            return true
        }
        guard let providing = IOPSGetProvidingPowerSourceType(unmanagedSnapshot)?.takeUnretainedValue() as String? else {
            return true
        }
        return providing == kIOPMACPowerKey
    }
}

// MARK: Thermal monitor

/// Observes `ProcessInfo.thermalStateDidChangeNotification`. When the system
/// climbs to `.serious` or higher we widen the mic pipeline's gating: the
/// pipeline backs off provisional ASR cadence so we generate less ANE work.
/// Phase 4's correction pass will use the same flag to pause itself.
@MainActor
final class ThermalMonitor {
    private var observer: NSObjectProtocol?
    private let onChange: (ProcessInfo.ThermalState) -> Void

    init(onChange: @escaping (ProcessInfo.ThermalState) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` only guarantees the foundation queue, not the
            // MainActor — Swift 6 wants the actor hop spelled out.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onChange(ProcessInfo.processInfo.thermalState)
            }
        }
        // Emit the current state so callers can configure themselves up front.
        onChange(ProcessInfo.processInfo.thermalState)
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

// MARK: Sleep / wake

/// NSWorkspace sleep + wake. AppDelegate uses the wake notification together
/// with `PowerSource.isOnAC()` and `lastListeningAt`: on battery, the system
/// is allowed to sleep, so a wake event means we missed audio between
/// `willSleep` and `didWake` — write a single gap marker and resume.
@MainActor
final class SleepWakeMonitor {
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private let onSleep: () -> Void
    private let onWake: () -> Void

    init(onSleep: @escaping () -> Void, onWake: @escaping () -> Void) {
        self.onSleep = onSleep
        self.onWake = onWake
    }

    func start() {
        guard sleepObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSleep() }
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onWake() }
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        if let s = sleepObserver { center.removeObserver(s) }
        if let w = wakeObserver { center.removeObserver(w) }
        sleepObserver = nil
        wakeObserver = nil
    }
}

// MARK: Memory sampler

/// Reads resident memory via `mach_task_basic_info`. Returns 0 on failure
/// rather than throwing — the MetricsCollector tolerates "no sample" by
/// keeping the prior peak.
enum MemorySampler {
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPtr,
                    &count
                )
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }
}
