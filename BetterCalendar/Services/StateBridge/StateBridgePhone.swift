#if os(iOS)
import Foundation
import HealthKit
import CoreLocation
import CoreMotion
import HomeKit
import UIKit

@MainActor final class StateBridgePhone: NSObject, CLLocationManagerDelegate, HMHomeManagerDelegate, HMAccessoryDelegate {
    static let shared = StateBridgePhone()
    private let health = HKHealthStore()
    private let location = CLLocationManager()
    private let motion = CMMotionActivityManager()
    private var home: HMHomeManager?
    private var healthQueries: [HKQuery] = []
    private var occupancy: [String: BridgeJSON] = [:]
    private var started = false
    private var healthReading = false
    private var healthPending = false
    private var lastHealthFailure: String?
    private let types: [HKSampleType] = [HKObjectType.categoryType(forIdentifier:.sleepAnalysis)!,HKObjectType.quantityType(forIdentifier:.stepCount)!,HKObjectType.quantityType(forIdentifier:.restingHeartRate)!,HKObjectType.workoutType()]
    override private init() { super.init(); location.delegate = self }
    func requestPermissions() async {
        if HKHealthStore.isHealthDataAvailable() { do { try await health.requestAuthorization(toShare:[],read:Set(types)) } catch { StateBridgeClient.shared.emit("health.status",value:.object(["availability":.string("permission-request-failed")]),validFor:86400) } }
        // Always access is a separate native prompt; accept it for location updates while the App is closed.
        location.requestWhenInUseAuthorization()
        home = HMHomeManager(); home?.delegate = self
        startIfAuthorized()
        await readHealth()
    }
    func requestAlwaysLocation() { location.requestAlwaysAuthorization() }
    func startIfAuthorized() {
        guard StateBridgeCollector.shared.enabled, StateBridgeClient.shared.configured, !TestHost.isActive else { return }
        if !started {
            started = true
            if HKHealthStore.isHealthDataAvailable() {
                for type in types {
                    let query = HKObserverQuery(sampleType:type,predicate:nil) { _,completion,error in
                        guard error == nil else {
                            Task { @MainActor in
                                StateBridgePhone.shared.recordHealthFailure("health.status")
                                completion()
                            }
                            return
                        }
                        Task { @MainActor in
                            defer { completion() }
                            guard StateBridgeCollector.shared.enabled else { return }
                            await StateBridgePhone.shared.readHealth(); await StateBridgeClient.shared.uploadAndFlush()
                        }
                    }
                    health.execute(query); healthQueries.append(query)
                    health.enableBackgroundDelivery(for:type,frequency:.immediate) { success,error in
                        if !success || error != nil { Task { @MainActor in
                            guard StateBridgeCollector.shared.enabled else { return }
                            StateBridgeClient.shared.emit("health.status",value:.object(["availability":.string("notification-unavailable"),"queryStatus":.string("unknown"),"backgroundDelivery":.string("unavailable")]),validFor:3600)
                            DevLog.shared.warn("StateBridge","健康后台订阅不可用；前台查询仍可用，请以每项来源为准。")
                        } }
                    }
                }
            }
            if CMMotionActivityManager.isActivityAvailable() {
                motion.startActivityUpdates(to:.main) { activity in
                    guard let a = activity else { return }
                    Task { @MainActor in
                        guard StateBridgeCollector.shared.enabled else { return }
                        StateBridgeClient.shared.emit("ios.motion",value:.object(["stationary":.bool(a.stationary),"walking":.bool(a.walking),"running":.bool(a.running),"cycling":.bool(a.cycling),"automotive":.bool(a.automotive),"confidence":.number(Double(a.confidence.rawValue))]),validFor:1800,observedAt:a.startDate)
                        await StateBridgeClient.shared.uploadAndFlush()
                    }
                }
            }
            home = HMHomeManager(); home?.delegate = self
        }
        if [.authorizedAlways,.authorizedWhenInUse].contains(location.authorizationStatus) {
            location.desiredAccuracy = kCLLocationAccuracyHundredMeters
            location.startMonitoringSignificantLocationChanges(); location.startMonitoringVisits(); location.requestLocation()
        }
    }
    func stop() {
        for query in healthQueries { health.stop(query) }; healthQueries.removeAll(); health.disableAllBackgroundDelivery { _,_ in }
        location.stopMonitoringSignificantLocationChanges(); location.stopMonitoringVisits(); motion.stopActivityUpdates()
        for h in home?.homes ?? [] { for accessory in h.accessories { for service in accessory.services { for c in service.characteristics where c.isNotificationEnabled { c.enableNotification(false) { _ in } } } } }
        home = nil; started = false
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { if StateBridgeCollector.shared.enabled { startIfAuthorized() } }
    func locationManager(_ manager: CLLocationManager,didUpdateLocations locations:[CLLocation]) {
        guard StateBridgeCollector.shared.enabled, let l = locations.last, l.horizontalAccuracy >= 0 else { return }
        StateBridgeClient.shared.emit("ios.location",value:.object(["latitude":.number((l.coordinate.latitude*1000).rounded()/1000),"longitude":.number((l.coordinate.longitude*1000).rounded()/1000),"accuracyMeters":.number(l.horizontalAccuracy),"speedMetersPerSecond":l.speed >= 0 ? .number(l.speed) : .null]),validFor:1800,observedAt:l.timestamp)
        Task { await StateBridgeClient.shared.uploadAndFlush() }
    }
    func locationManager(_ manager: CLLocationManager,didVisit visit:CLVisit) {
        guard StateBridgeCollector.shared.enabled else { return }
        let f = ISO8601DateFormatter()
        StateBridgeClient.shared.emit("ios.visit",value:.object(["latitude":.number((visit.coordinate.latitude*1000).rounded()/1000),"longitude":.number((visit.coordinate.longitude*1000).rounded()/1000),"arrival":visit.arrivalDate == .distantPast ? .null : .string(f.string(from:visit.arrivalDate)),"departure":visit.departureDate == .distantFuture ? .null : .string(f.string(from:visit.departureDate)),"accuracyMeters":.number(visit.horizontalAccuracy)]),validFor:3600)
        Task { await StateBridgeClient.shared.uploadAndFlush() }
    }
    func locationManager(_ manager: CLLocationManager,didFailWithError error:Error) {
        guard StateBridgeCollector.shared.enabled else { return }
        StateBridgeClient.shared.emit("ios.location",value:.object(["availability":.string("location-unavailable")]),validFor:1800)
    }
    func homeManagerDidUpdateHomes(_ manager:HMHomeManager) {
        guard StateBridgeCollector.shared.enabled else { return }
        occupancy.removeAll()
        for h in manager.homes { for a in h.accessories {
            a.delegate = self
            for s in a.services { for c in s.characteristics where [HMCharacteristicTypeOccupancyDetected,HMCharacteristicTypeMotionDetected].contains(c.characteristicType) {
                c.readValue { _ in Task { @MainActor in StateBridgePhone.shared.recordCharacteristic(a,c) } }
                c.enableNotification(true) { error in
                    if error != nil { Task { @MainActor in StateBridgeClient.shared.emit("home.status",value:.object(["availability":.string("notification-unavailable")]),validFor:3600) } }
                }
            } }
        } }
        if manager.homes.isEmpty { StateBridgeClient.shared.emit("home.status",value:.object(["availability":.string("no-visible-home-or-permission")]),validFor:3600) }
    }
    func accessory(_ accessory:HMAccessory,service:HMService,didUpdateValueFor characteristic:HMCharacteristic) { recordCharacteristic(accessory,characteristic) }
    private func recordCharacteristic(_ accessory:HMAccessory,_ characteristic:HMCharacteristic) {
        guard StateBridgeCollector.shared.enabled else { return }
        let id = characteristic.uniqueIdentifier.uuidString
        occupancy[id] = .object(["id":.string(id),"accessory":.string(accessory.name),"room":.text(accessory.room?.name),"service":.text(characteristic.service?.name),"type":.string(characteristic.characteristicType),"value":(characteristic.value as? NSNumber).map { .bool($0.boolValue) } ?? .null,"observedAt":.string(ISO8601DateFormatter().string(from:Date())),"expiresAt":.string(ISO8601DateFormatter().string(from:Date().addingTimeInterval(600)))])
        StateBridgeClient.shared.emit("home.occupancy",value:.array(occupancy.keys.sorted().compactMap { occupancy[$0] }),validFor:600)
        Task { await StateBridgeClient.shared.uploadAndFlush() }
    }
    private func samples(_ type:HKSampleType,days:Double,limit:Int) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType:type,predicate:HKQuery.predicateForSamples(withStart:Date().addingTimeInterval(-days*86400),end:Date()),limit:limit,sortDescriptors:[NSSortDescriptor(key:HKSampleSortIdentifierEndDate,ascending:false)]) { _,values,error in
                if let error { continuation.resume(throwing:error) } else { continuation.resume(returning:values ?? []) }
            }; health.execute(query)
        }
    }
    func readHealth() async {
        guard StateBridgeCollector.shared.enabled, HKHealthStore.isHealthDataAvailable() else { return }
        if healthReading { healthPending = true; return }; healthReading = true
        defer { healthReading = false; if healthPending { healthPending = false; Task { await readHealth() } } }
        let client = StateBridgeClient.shared, f = ISO8601DateFormatter()
        var failed: [String] = []
        do {
            let sleep = try await samples(types[0],days:3,limit:100)
            client.emit("health.sleep",value:.object(["samples":.array(sleep.compactMap { sample in guard let s = sample as? HKCategorySample else { return nil }; return .object(["id":.string(s.uuid.uuidString),"start":.string(f.string(from:s.startDate)),"end":.string(f.string(from:s.endDate)),"stage":.number(Double(s.value)),"source":.string(s.sourceRevision.source.name)]) }),"availability":.string(sleep.isEmpty ? "no-readable-samples-not-proof-of-no-sleep" : "readable"),"snapshot":.bool(true)]),validFor:36*3600)
        } catch { failed.append("health.sleep"); recordHealthFailure("health.sleep") }
        do {
            let stepType = HKObjectType.quantityType(forIdentifier:.stepCount)!
            // Freeze the window before awaiting HealthKit; midnight/timezone
            // changes must not label the returned sum with another day's start.
            let window = BridgeHealthWindow(at: Date())
            let result: (Double?, [String]?) = try await withCheckedThrowingContinuation { c in
                let q = HKStatisticsQuery(quantityType:stepType,quantitySamplePredicate:HKQuery.predicateForSamples(withStart:window.start,end:window.end),options:.cumulativeSum) { _,stats,error in if let error { c.resume(throwing:error) } else { c.resume(returning:(stats?.sumQuantity()?.doubleValue(for:.count()),stats?.sources?.map(\.bundleIdentifier).sorted())) } }; health.execute(q)
            }
            client.emit("health.steps",value:window.steps(result.0,sources:result.1),validFor:300,observedAt:window.end)
        } catch { failed.append("health.steps"); recordHealthFailure("health.steps") }
        do {
            let resting = try await samples(types[2],days:3,limit:5)
            client.emit("health.resting-heart-rate",value:.array(resting.compactMap { s in guard let q = s as? HKQuantitySample else { return nil }; return .object(["id":.string(q.uuid.uuidString),"end":.string(f.string(from:q.endDate)),"bpm":.number(q.quantity.doubleValue(for:HKUnit.count().unitDivided(by:.minute())))]) }),validFor:36*3600)
        } catch { failed.append("health.resting-heart-rate"); recordHealthFailure("health.resting-heart-rate") }
        do {
            let workouts = try await samples(types[3],days:14,limit:30)
            client.emit("health.workouts",value:.array(workouts.compactMap { s in guard let w = s as? HKWorkout else { return nil }; return .object(["id":.string(w.uuid.uuidString),"start":.string(f.string(from:w.startDate)),"end":.string(f.string(from:w.endDate)),"durationSeconds":.number(w.duration),"activityType":.number(Double(w.workoutActivityType.rawValue))]) }),validFor:36*3600)
        } catch { failed.append("health.workouts"); recordHealthFailure("health.workouts") }
        // Every source is queried independently. One failed query must not stop
        // later sources or negate successful reads; empty reads remain unknown.
        client.emit("health.status",value:.object([
            "availability":.string(failed.isEmpty ? "queries-completed" : failed.count == types.count ? "read-unavailable" : "partial"),
            "failedSources":.array(failed.map(BridgeJSON.string)),
            "emptySamplesAreUnknown":.bool(true)
        ]),validFor:3600)
        if failed.isEmpty { lastHealthFailure = nil }
    }
    private func recordHealthFailure(_ source: String) {
        guard StateBridgeCollector.shared.enabled else { return }
        StateBridgeClient.shared.emit(source,value:.object(["availability":.string("read-unavailable")]),validFor:3600)
        if lastHealthFailure != source {
            DevLog.shared.warn("StateBridge","健康来源 \(source) 查询失败；其他来源仍分别读取，不能推断未授权或没有活动。")
            lastHealthFailure = source
        }
    }
}
#endif
