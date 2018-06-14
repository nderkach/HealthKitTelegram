// Adapted from https://gist.github.com/phatblat/654ab2b3a135edf905f4a854fdb2d7c8

import HealthKit
import Alamofire

typealias AccessRequestCallback = (_ success: Bool, _ error: Error?) -> Void

/// Helper for reading and writing to HealthKit.
class HealthKitManager {
	private let healthStore = HKHealthStore()
	private var myAnchor: HKQueryAnchor?
	private var meditatedSeconds: Double = 0.0

	/// Requests access to all the data types the app wishes to read/write from HealthKit.
	/// On success, data is queried immediately and observer queries are set up for background
	/// delivery. This is safe to call repeatedly and should be called at least once per launch.
	func requestAccessWithCompletion(completion: @escaping AccessRequestCallback) {
		guard HKHealthStore.isHealthDataAvailable() else {
			debugPrint("Can't request access to HealthKit when it's not supported on the device.")
			return
		}

		let writeDataTypes = dataTypesToWrite()
		let readDataTypes = dataTypesToRead()

		healthStore.requestAuthorization(toShare: writeDataTypes, read: readDataTypes) { [weak self] (success: Bool, error: Error?) in
			guard let strongSelf = self else { return }
			if success {
				debugPrint("Access to HealthKit data has been granted")
				strongSelf.setUpBackgroundDeliveryForDataTypes(types: readDataTypes)
			} else {
				debugPrint("Error requesting HealthKit authorization: \(error)")
			}

			DispatchQueue.main.async {
				completion(success, error)
			}
		}
	}
}

// MARK: - Private
fileprivate extension HealthKitManager {
	/// Sets up the observer queries for background health data delivery.
	///
	/// - parameter types: Set of `HKObjectType` to observe changes to.
	private func setUpBackgroundDeliveryForDataTypes(types: Set<HKObjectType>) {
		for type in types {
			guard let sampleType = type as? HKSampleType else { print("ERROR: \(type) is not an HKSampleType"); continue }

			if let anchorData = UserDefaults.standard.object(forKey: "anchor") as? Data {
				myAnchor = NSKeyedUnarchiver.unarchiveObject(with: anchorData) as? HKQueryAnchor
			}

			let query = HKAnchoredObjectQuery(type: sampleType,
											  predicate: nil,
											  anchor: myAnchor,
											  limit: HKObjectQueryNoLimit) { [weak self] (_, samplesOrNil, _, newAnchor, _)  in
				debugPrint("observer query update handler called for type \(sampleType)")

				guard let samples = samplesOrNil else {
					// Handle the error here.
					return
				}

				guard samples.last != nil else {
					return
				}

				guard let strongSelf = self else { return }

				strongSelf.myAnchor = newAnchor

				if let newAnchor = newAnchor {
					UserDefaults.standard.setValue(NSKeyedArchiver.archivedData(withRootObject: newAnchor), forKey: "anchor")
				}
			}

			// Optionally, add an update handler.
			query.updateHandler = { [weak self] (query, samplesOrNil, deletedObjectsOrNil, newAnchor, errorOrNil) in

				guard let samples = samplesOrNil else {
					// Handle the error here.
					fatalError("*** An error occurred during an update: \(errorOrNil!.localizedDescription) ***")
				}

				print(samples.count)

				guard let lastSample = samples.last else {
					return
				}

				guard let strongSelf = self else { return }

				strongSelf.myAnchor = newAnchor

				if let newAnchor = newAnchor {
					UserDefaults.standard.setValue(NSKeyedArchiver.archivedData(withRootObject: newAnchor), forKey: "anchor")
				}

				strongSelf.handleSample(lastSample)
			}

			healthStore.execute(query)
			healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { (success: Bool, error: Error?) in
				debugPrint("enableBackgroundDeliveryForType handler called for \(type) - success: \(success), error: \(error)")
			}
		}
	}

	/// Initiates HK queries for new data based on the given type
	///
	/// - parameter type: `HKObjectType` which has new data avilable.
	private func handleSample(_ sample: HKSample) {
		switch sample.sampleType {
		case HKObjectType.categoryType(forIdentifier: .sleepAnalysis):
			guard let totalTimeAsleep = sample.metadata?["Asleep"] as? Double else {
				return
			}

			let totalTimeAsleepInHours = totalTimeAsleep / 60.0 / 60.0

			print(String(format: "Slept %f hrs today", totalTimeAsleepInHours))

			self.sendMessageToTelegram(withText: String(format: "Slept %f hrs today", totalTimeAsleepInHours))
		case HKObjectType.categoryType(forIdentifier: .mindfulSession):
			let durationInSeconds = sample.endDate.timeIntervalSince(sample.startDate)
			if durationInSeconds == meditatedSeconds {
				return
			}

			meditatedSeconds = durationInSeconds

			let durationInMinutes = durationInSeconds / 60.0

			print(String(format: "Meditated %f minutes", durationInMinutes))

			self.sendMessageToTelegram(withText: String(format: "Meditated %f minutes", durationInMinutes))
		default:
			debugPrint("Unhandled HKObjectType: \(sample.sampleType)")
		}

	}

	/// Types of data that this app wishes to read from HealthKit.
	///
	/// - returns: A set of HKObjectType.
	private func dataTypesToRead() -> Set<HKObjectType> {
		return Set([
			HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier.sleepAnalysis)!, HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier.mindfulSession)!
			])
	}

	/// Types of data that this app wishes to write to HealthKit.
	///
	/// - returns: A set of HKSampleType.
	private func dataTypesToWrite() -> Set<HKSampleType> {
		return Set()
	}

	private func getMostRecentSample(for sampleType: HKSampleType,
									 completion: @escaping (HKCategorySample?, Error?) -> Swift.Void) {

		//1. Use HKQuery to load the most recent samples.
		let mostRecentPredicate = HKQuery.predicateForSamples(withStart: Date.distantPast,
															  end: Date(),
															  options: .strictEndDate)

		let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
											  ascending: false)

		let limit = 1

		let sampleQuery = HKSampleQuery(sampleType: sampleType,
										predicate: mostRecentPredicate,
										limit: limit,
										sortDescriptors: [sortDescriptor]) { (_, samples, error) in

											//2. Always dispatch to the main thread when complete.
											DispatchQueue.main.async {

												guard let samples = samples,
													let mostRecentSample = samples.first as? HKCategorySample else {

														completion(nil, error)
														return
												}

												completion(mostRecentSample, nil)
											}
		}

		HKHealthStore().execute(sampleQuery)
	}

	private func sendMessageToTelegram(withText text: String) {
		// Send messages on telegram

		let apiToken = "YOUR_TELEGRAM_TOKEN"
		let chatId = "@YOUR_TELEGRAM_CHAT_NAME"
		let strUrl = String(format: "https://api.telegram.org/bot%@/sendMessage?chat_id=%@&text=%@", apiToken, chatId, text.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)!)

		Alamofire.request(strUrl).responseJSON { response in

			if let json = response.result.value {
				print("JSON: \(json)") // serialized json response
			}

			if let data = response.data, let utf8Text = String(data: data, encoding: .utf8) {
				print("Data: \(utf8Text)") // original server data as UTF8 string
			}
		}
	}
}
