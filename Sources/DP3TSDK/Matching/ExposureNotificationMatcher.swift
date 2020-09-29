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
import ZIPFoundation

class ExposureNotificationMatcher: Matcher {
    weak var timingManager: ExposureDetectionTimingManager?

    private let manager: ENManager

    private let exposureDayStorage: ExposureDayStorage

    private let logger = Logger(ExposureNotificationMatcher.self, category: "matcher")

    private let defaults: DefaultStorage

    let synchronousQueue = DispatchQueue(label: "org.dpppt.matcher")

    init(manager: ENManager, exposureDayStorage: ExposureDayStorage, defaults: DefaultStorage = Default.shared) {
        self.manager = manager
        self.exposureDayStorage = exposureDayStorage
        self.defaults = defaults
    }

    func receivedNewData(_ data: Data, keyDate: Date, now: Date = .init()) throws -> Bool {
        logger.trace()
        return try synchronousQueue.sync {
            var urls: [URL] = []
            let tempDirectory = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent(UUID().uuidString)
            if let archive = Archive(data: data, accessMode: .read) {
                logger.debug("unarchived archive")
                for entry in archive {
                    let localURL = tempDirectory.appendingPathComponent(entry.path)
                    do {
                        _ = try archive.extract(entry, to: localURL)
                    } catch {
                        throw DP3TNetworkingError.couldNotParseData(error: error, origin: 1)
                    }
                    self.logger.debug("found %@ item in archive", entry.path)
                    urls.append(localURL)
                }
            }

            guard urls.isEmpty == false else { return false }

            let configuration: ENExposureConfiguration = .configuration()

            let semaphore = DispatchSemaphore(value: 0)
            var exposureSummary: ENExposureDetectionSummary?
            var exposureDetectionError: Error? = DP3TTracingError.cancelled

            logger.log("calling detectExposures for day %{public}@ and description: %{public}@", keyDate.description, configuration.stringVal)
            manager.detectExposures(configuration: configuration, diagnosisKeyURLs: urls) { summary, error in
                exposureSummary = summary
                exposureDetectionError = error
                semaphore.signal()
            }
            
            // Wait for 3min and abort if detectExposures did not return in time
            if semaphore.wait(timeout: .now() + 180) == .timedOut {
                // This should never be the case but it protects us from errors
                // in ExposureNotifications.frameworks which cause the completion
                // handler to never get called.
                // If ENManager would return after 3min, the app gets kill before
                // that because we are only allowed to run for 2.5min in background
                logger.error("ENManager.detectExposures() failed to return in time")
            }

            if let error = exposureDetectionError {
                logger.error("ENManager.detectExposures failed error: %{public}@", error.localizedDescription)
                try? urls.forEach(deleteDiagnosisKeyFile(at:))
                throw DP3TTracingError.exposureNotificationError(error: error)
            }

            timingManager?.addDetection(timestamp: now)

            try? FileManager.default.removeItem(at: tempDirectory)

            if let summary = exposureSummary {
                let computedThreshold: Double = (Double(truncating: summary.attenuationDurations[0]) * defaults.parameters.contactMatching.factorLow + Double(truncating: summary.attenuationDurations[1]) * defaults.parameters.contactMatching.factorHigh) / TimeInterval.minute

                logger.log("reiceived exposureSummary for day %{public}@ : %{public}@ computed threshold: %{public}.2f (low:%{public}.2f, high: %{public}.2f) required %{public}d",
                           keyDate.description, summary.debugDescription, computedThreshold, defaults.parameters.contactMatching.factorLow, defaults.parameters.contactMatching.factorHigh, defaults.parameters.contactMatching.triggerThreshold)

                if computedThreshold >= Double(defaults.parameters.contactMatching.triggerThreshold) {
                    logger.log("exposureSummary meets requiremnts")
                    let day: ExposureDay = ExposureDay(identifier: UUID(), exposedDate: keyDate, reportDate: Date(), isDeleted: false)
                    exposureDayStorage.add(day)
                    return true
                } else {
                    logger.log("exposureSummary does not meet requirements")
                }
            }
            return false
        }
    }

    func deleteDiagnosisKeyFile(at localURL: URL) throws {
        logger.trace()
        try FileManager.default.removeItem(at: localURL)
    }
}

extension ENExposureConfiguration {
    static var thresholdsKey: String = "attenuationDurationThresholds"

    static func configuration(parameters: DP3TParameters = Default.shared.parameters) -> ENExposureConfiguration {
        let configuration = ENExposureConfiguration()
        configuration.minimumRiskScore = 0
        configuration.attenuationLevelValues = [1, 2, 3, 4, 5, 6, 7, 8]
        configuration.daysSinceLastExposureLevelValues = [1, 2, 3, 4, 5, 6, 7, 8]
        configuration.durationLevelValues = [1, 2, 3, 4, 5, 6, 7, 8]
        configuration.transmissionRiskLevelValues = [1, 2, 3, 4, 5, 6, 7, 8]
        configuration.metadata = [Self.thresholdsKey: [parameters.contactMatching.lowerThreshold,
                                                       parameters.contactMatching.higherThreshold]]
        return configuration
    }

    var stringVal: String {
        if let thresholds = metadata?[Self.thresholdsKey] as? [Int] {
            return "<ENExposureConfiguration attenuationDurationThresholds: [\(thresholds[0]),\(thresholds[1])]>"
        }
        return "<ENExposureConfiguration attenuationDurationThresholds: nil>"
    }
}
