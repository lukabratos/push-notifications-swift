import Foundation

struct ServerSyncJobStore {
    private let syncJobStoreFileName = "syncJobStore"
    private var jobStoreArray: [ServerSyncJob] = []
    private let syncJobStoreQueue = DispatchQueue(label: "syncJobStoreQueue")

    init() {
        self.jobStoreArray = self.loadOperations()
    }

    private func loadOperations() -> [ServerSyncJob] {
        guard let operations = NSData(contentsOfFile: syncJobStoreFileName) else {
            // Assuming a fresh installation here
            return []
        }

        let jsonDecoder = JSONDecoder()
        guard let operationsArray = try? jsonDecoder.decode([ServerSyncJob].self, from: (operations as Data)) else {
            print("[PushNotifications] - Failed to load previously stored operations, continuing without them.")
            return []
        }

        return operationsArray
    }

    private func persistOperations(_ jobStoreArray: [ServerSyncJob]) {
        let jsonEncoder = JSONEncoder()
        guard let data = try? jsonEncoder.encode(jobStoreArray) else {
            print("[PushNotifications] - Failed to encode operations, continuing without persisting them.")
            return
        }
        do {
            try (data as NSData).write(toFile: syncJobStoreFileName, options: .atomic)
        } catch {
            print("[PushNotifications] - Failed to persist operations, continuing ...")
        }
    }

    var isEmpty: Bool {
        get {
            return syncJobStoreQueue.sync {
                return self.jobStoreArray.isEmpty
            }
        }
    }

    var first: ServerSyncJob? {
        get {
            return syncJobStoreQueue.sync {
                return jobStoreArray.first
            }
        }
    }

    func toList() -> [ServerSyncJob] {
        return syncJobStoreQueue.sync {
            return self.jobStoreArray
        }
    }

    mutating func append(_ job: ServerSyncJob) {
        syncJobStoreQueue.sync {
            self.jobStoreArray.append(job)
            self.persistOperations(self.jobStoreArray)
        }
    }

    mutating func removeFirst() {
        syncJobStoreQueue.sync {
            if (self.jobStoreArray.count > 0) {
                self.jobStoreArray.removeFirst()
                self.persistOperations(self.jobStoreArray)
            }
        }
    }
}
