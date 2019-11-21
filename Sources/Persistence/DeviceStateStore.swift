import Foundation

public class DeviceStateStore {
    static let queue = DispatchQueue(label: "deviceStateStoreQueue")
    
    public static func synchronize<T>(f: () -> T) -> T {
        var result: T?
        DeviceStateStore.queue.sync {
            result = f()
        }
        return result!
    }
    
    let service: UserDefaults = UserDefaults(suiteName: PersistenceConstants.UserDefaults.suiteName)!

    func persist(interest: String) -> Bool {
        guard !self.interestExists(interest: interest) else {
            return false
        }

        service.set(interest, forKey: self.prefixInterest(interest))
        return true
    }

    func persist(interests: [String]) -> Bool {
        guard
            let persistedInterests = self.getSubscriptions(),
            persistedInterests.sorted().elementsEqual(interests.sorted())
        else {
            self.removeAllSubscriptions()
            for interest in interests {
                _ = self.persist(interest: interest)
            }

            return true
        }

        return false
    }

    func setUserId(userId: String) -> Bool {
        guard !self.userIdExists(userId: userId) else {
            return false
        }

        service.set(userId, forKey: PersistenceConstants.PersistenceService.userId)
        return true
    }

    func getUserId() -> String? {
        return service.object(forKey: PersistenceConstants.PersistenceService.userId) as? String
    }

    func removeUserId() {
        service.removeObject(forKey: PersistenceConstants.PersistenceService.userId)
    }

    func remove(interest: String) -> Bool {
        guard self.interestExists(interest: interest) else {
            return false
        }

        service.removeObject(forKey: self.prefixInterest(interest))
        return true
    }

    func removeAllSubscriptions() {
        self.removeFromPersistanceStore(prefix: PersistenceConstants.PersistenceService.prefix)
    }

    func removeAll() {
        self.removeFromPersistanceStore(prefix: PersistenceConstants.PersistenceService.globalScopeId)
    }

    func getSubscriptions() -> [String]? {
        return service.dictionaryRepresentation().filter { $0.key.hasPrefix(PersistenceConstants.PersistenceService.prefix) }.map { String(describing: ($0.value)) }
    }

    func persistServerConfirmedInterestsHash(_ hash: String) {
        service.set(hash, forKey: PersistenceConstants.PersistenceService.hashKey)
    }

    func getServerConfirmedInterestsHash() -> String {
        return service.value(forKey: PersistenceConstants.PersistenceService.hashKey) as? String ?? ""
    }

    private func interestExists(interest: String) -> Bool {
        return service.object(forKey: self.prefixInterest(interest)) != nil
    }

    private func userIdExists(userId: String) -> Bool {
        return service.object(forKey: PersistenceConstants.PersistenceService.userId) != nil
    }

    private func prefixInterest(_ interest: String) -> String {
        return "\(PersistenceConstants.PersistenceService.prefix):\(interest)"
    }

    private func removeFromPersistanceStore(prefix: String) {
        for element in service.dictionaryRepresentation() {
            if element.key.hasPrefix(prefix) {
                service.removeObject(forKey: element.key)
            }
        }
    }

    func setStartJobHasBeenEnqueued(flag: Bool) {
        service.set(flag, forKey: PersistenceConstants.PushNotificationsInstancePersistence.startJob)
    }

    func getStartJobHasBeenEnqueued() -> Bool {
        return service.object(forKey: PersistenceConstants.PushNotificationsInstancePersistence.startJob) as? Bool ?? false
    }

    func setUserIdHasBeenCalledWith(userId: String) {
        service.set(userId, forKey: PersistenceConstants.PushNotificationsInstancePersistence.userId)
    }

    func getUserIdPreviouslyCalledWith() -> String? {
        return service.object(forKey: PersistenceConstants.PushNotificationsInstancePersistence.userId) as? String
    }

    func clear() {
        service.removeObject(forKey: PersistenceConstants.PushNotificationsInstancePersistence.startJob)
        service.removeObject(forKey: PersistenceConstants.PushNotificationsInstancePersistence.userId)
    }
    
}
