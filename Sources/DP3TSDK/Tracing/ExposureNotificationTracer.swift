/*
 * Copyright (c) 2020 Ubique Innovation AG <https://www.ubique.ch>
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * SPDX-License-Identifier: MPL-2.0
 */

import ExposureNotification
import Foundation
import UIKit.UIApplication

class ExposureNotificationTracer: Tracer {
    private let manager: ENManager

    private var stateObservation: NSKeyValueObservation?
    private var enabledObservation: NSKeyValueObservation?

    var delegate: TracerDelegate?

    private let queue = DispatchQueue(label: "org.dpppt.tracer")

    private var initializationCallbacks: [ () -> Void ] = []

    private let logger = Logger(ExposureNotificationTracer.self, category: "exposureNotificationTracer")

    private let managerClass: ENManager.Type

    private(set) var state: TrackingState {
        didSet {
            guard oldValue != state else { return }
            logger.log("state did change from %{public}@ to %{public}@", oldValue.debugDescription, state.debugDescription)
            delegate?.stateDidChange()
        }
    }

    init(manager: ENManager, managerClass: ENManager.Type = ENManager.self) {
        self.manager = manager
        self.managerClass = managerClass

        state = .initialization

        logger.log("calling ENMananger.activate")
        manager.activate { [weak self] error in
            guard let self = self else { return }
            self.queue.async {
                if let error = error {
                    self.logger.error("ENMananger.activate failed error: %{public}@", error.localizedDescription)
                } else {
                    self.initializeObservers()
                }
                self.logger.log("notify callbacks after initialisation (count: %d)", self.initializationCallbacks.count)
                self.initializationCallbacks.forEach {
                    DispatchQueue.main.async(execute: $0)
                }
                self.initializationCallbacks.removeAll()
            }
        }
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(willEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification,
                                               object: nil)
    }

    func addInitialisationCallback(callback: @escaping  ()-> Void ){
        queue.sync {
            self.logger.trace()
            guard self.state == .initialization else {
                DispatchQueue.main.async(execute: callback)
                return
            }
            initializationCallbacks.append(callback)
        }
    }

    deinit {
        manager.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    var isAuthorized: Bool { ENManager.authorizationStatus == .authorized }

    @objc func willEnterForeground(){
        updateState()
    }

    func initializeObservers() {
        updateState()

        stateObservation = manager.observe(\.exposureNotificationStatus, options: [.new]) { [weak self] _, _ in
            self?.updateState()
        }

        enabledObservation = manager.observe(\.exposureNotificationEnabled, options: [.new]) { [weak self] _, _ in
            self?.updateState()
        }
    }

    func updateState() {
        state = .init(state: manager.exposureNotificationStatus,
                      authorizationStatus: managerClass.authorizationStatus,
                      enabled: manager.exposureNotificationEnabled)
    }

    func setEnabled(_ enabled: Bool, completionHandler: ((Error?) -> Void)?) {
        logger.log("calling ENMananger.setExposureNotificationEnabled %{public}@", enabled ? "true" : "false")

        manager.setExposureNotificationEnabled(enabled) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.logger.error("ENMananger.setExposureNotificationEnabled failed error: %{public}@", error.localizedDescription)
                self.state = .inactive(error: .exposureNotificationError(error: error))
            }
            self.updateState()
            completionHandler?(error)
        }
    }
}

extension TrackingState {
    init(state: ENStatus, authorizationStatus: ENAuthorizationStatus, enabled: Bool) {
        if authorizationStatus == .unknown {
            self = .stopped
            return
        }

        guard authorizationStatus == .authorized else {
            self = .inactive(error: .permissonError)
            return
        }
        switch state {
        case .active:
            if enabled {
                self = .active
            } else {
                self = .stopped
            }
        case .unknown, .disabled:
            self = .stopped
        case .bluetoothOff:
            self = .inactive(error: .bluetoothTurnedOff)
        case .restricted:
            self = .inactive(error: .permissonError)
        @unknown default:
            fatalError()
        }
    }
}

extension TrackingState: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .initialization:
            return "initialization"
        case .active:
            return "active"
        case .stopped:
            return "stopped"
        case let .inactive(error: error):
            return "inactive \(error.localizedDescription)"
        }
    }
}
