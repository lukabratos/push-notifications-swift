import Foundation

class ServerSyncProcessHandler {
    private let instanceId: String
    private let sendMessageQueue: DispatchQueue
    private let handleMessageQueue: DispatchQueue
    private let networkService: NetworkService
    private let getTokenProvider: () -> TokenProvider?
    private let handleServerSyncEvent: (ServerSyncEvent) -> Void
    public var jobQueue: ServerSyncJobStore = ServerSyncJobStore()

    init(instanceId: String, getTokenProvider: @escaping () -> TokenProvider?, handleServerSyncEvent: @escaping (ServerSyncEvent) -> Void) {
        self.instanceId = instanceId
        self.getTokenProvider = getTokenProvider
        self.handleServerSyncEvent = handleServerSyncEvent
        self.sendMessageQueue = DispatchQueue(label: "sendMessageQueue")
        self.handleMessageQueue = DispatchQueue(label: "handleMessageQueue")
        let session = URLSession(configuration: .ephemeral)
        self.networkService = NetworkService(session: session)

        self.jobQueue.toList().forEach { job in
            switch job {
            case .SetUserIdJob:
                // Skipping it. If the user is still supposed to logged in, then
                // there should be another setUserIdJob being enqueued upon launch
                return
            default:
                self.handleMessageQueue.async {
                    self.handleMessage(serverSyncJob: job)
                }
            }
        }
    }

    func sendMessage(serverSyncJob: ServerSyncJob) {
        self.sendMessageQueue.async {
            self.jobQueue.append(serverSyncJob)

            self.handleMessageQueue.async {
                self.handleMessage(serverSyncJob: serverSyncJob)
            }
        }
    }

    private func hasStarted() -> Bool {
        return DeviceStateStore.synchronize {
            return Device.idAlreadyPresent()
        }
    }

    private func processStartJob(instanceId: String, token: String) {
        // Register device with Error
        let result = self.networkService.register(instanceId: instanceId, deviceToken: token, metadata: Metadata.getCurrentMetadata(), retryStrategy: WithInfiniteExpBackoff())

        switch result {
        case .error(let error):
            print("[PushNotifications]: Unrecoverable error when registering device with Pusher Beams (Reason - \(error.getErrorMessage()))")
            print("[PushNotifications]: SDK will not start.")
            return
        case .value(let device):
            var outstandingJobs: [ServerSyncJob] = []
            DeviceStateStore.synchronize {
                // Replay sub/unsub/setsub operations in job queue over initial interest set
                var interestsSet = device.initialInterestSet ?? Set<String>()

                for job in jobQueue.toList() {
                    switch job {
                    case .StartJob:
                        break
                    case .SubscribeJob(let interest, _):
                        interestsSet.insert(interest)
                    case .UnsubscribeJob(let interest, _):
                        interestsSet.remove(interest)
                    case .SetSubscriptions(let interests, _):
                        interestsSet = Set(interests)
                    case .StopJob:
                        outstandingJobs.removeAll()
                        // Any subscriptions changes done at this point are just discarded,
                        // and we need to assume the initial interest set as the starting point again
                        interestsSet = device.initialInterestSet ?? Set<String>()
                    case .SetUserIdJob:
                        outstandingJobs.append(job)
                    case .ApplicationStartJob:
                        // ignoring it as we are already going to sync the state anyway
                        continue
                    case .RefreshTokenJob:
                        outstandingJobs.append(job)
                    case .ReportEventJob:
                        // If SDK hasn't started yet we couldn't have receive any remote notifications
                        continue
                    }
                }

                let localInterestsWillChange = Set(DeviceStateStore().getSubscriptions() ?? []) != interestsSet
                if localInterestsWillChange {
                    DeviceStateStore().persist(interests: Array(interestsSet))
                    self.handleServerSyncEvent(.InterestsChangedEvent(interests: Array(interestsSet)))
                }

                Instance.persist(instanceId)
                Device.persistAPNsToken(token: token)
                Device.persist(device.id)
            }

            let localInterests = DeviceStateStore().getSubscriptions() ?? []
            let remoteInterestsWillChange = Set(localInterests) != device.initialInterestSet ?? Set()
            if remoteInterestsWillChange {
                // We don't care about the result at this point.
                _ = self.networkService.setSubscriptions(instanceId: self.instanceId, deviceId: device.id, interests: localInterests, retryStrategy: WithInfiniteExpBackoff())
            }

            for job in outstandingJobs {
                processJob(job)
            }
        }
    }

    private func processStopJob() {
        _ = self.networkService.deleteDevice(instanceId: self.instanceId, deviceId: Device.getDeviceId()!, retryStrategy: WithInfiniteExpBackoff())
//        Instance.delete()
        Device.delete()
        Device.deleteAPNsToken()
        Metadata.delete()
        DeviceStateStore().persistServerConfirmedInterestsHash("")
        DeviceStateStore().removeUserId()
        self.handleServerSyncEvent(.StopEvent)
    }

    private func processApplicationStartJob(metadata: Metadata) {
        let localMetadata = Metadata.load()
        if metadata != localMetadata {
            let result = self.networkService.syncMetadata(instanceId: self.instanceId, deviceId: Device.getDeviceId()!, metadata: metadata, retryStrategy: JustDont())
            if case .value(()) = result {
                Metadata.save(metadata: metadata)
            }
        }

        let localInterests = DeviceStateStore().getSubscriptions() ?? []
        let localInterestsHash = localInterests.calculateMD5Hash()

        if localInterestsHash != DeviceStateStore().getServerConfirmedInterestsHash() {
            let result = self.networkService.setSubscriptions(instanceId: self.instanceId, deviceId: Device.getDeviceId()!, interests: localInterests, retryStrategy: JustDont())
            if case .value(()) = result {
                DeviceStateStore().persistServerConfirmedInterestsHash(localInterestsHash)
            }
        }
    }

    private func processJob(_ job: ServerSyncJob) {
        let result: Result<Void, PushNotificationsAPIError> = {
            switch job {
            case .SubscribeJob(_, localInterestsChanged: false), .UnsubscribeJob(_, localInterestsChanged: false), .SetSubscriptions(_, localInterestsChanged: false):
                return .value(()) // if local interests haven't changed, then we don't need to sync with server
            case .SubscribeJob(let interest, localInterestsChanged: true):
                return self.networkService.subscribe(instanceId: self.instanceId, deviceId: Device.getDeviceId()!, interest: interest, retryStrategy: WithInfiniteExpBackoff())
            case .UnsubscribeJob(let interest, localInterestsChanged: true):
                return self.networkService.unsubscribe(instanceId: self.instanceId, deviceId: Device.getDeviceId()!, interest: interest, retryStrategy: WithInfiniteExpBackoff())
            case .SetSubscriptions(let interests, localInterestsChanged: true):
                return self.networkService.setSubscriptions(instanceId: self.instanceId, deviceId: Device.getDeviceId()!, interests: interests, retryStrategy: WithInfiniteExpBackoff())
            case .ReportEventJob(let eventType):
                return self.networkService.track(instanceId: eventType.getInstanceId(), deviceId: Device.getDeviceId()!, eventType: eventType, retryStrategy: WithInfiniteExpBackoff())
            case .ApplicationStartJob(let metadata):
                processApplicationStartJob(metadata: metadata)
                return .value(()) // this was always a best effort operation
            case .SetUserIdJob(let userId):
                processSetUserIdJob(userId: userId)
                return .value(()) // errors were already handled at this point
            case .StartJob, .StopJob:
                return .value(()) // already handled in `handleMessage`
            case .RefreshTokenJob:
                // TODO: Implement refresh token
                return .value(())
            }
        }()

        switch result {
        case .value:
            return
        case .error(PushNotificationsAPIError.DeviceNotFound):
            if recreateDevice(token: Device.getAPNsToken()!) {
                processJob(job)
            } else {
                print("[PushNotifications]: Not retrying, skipping job: \(job).")
            }
        case .error(let error):
            // not really recoverable, so log it here and also monitor 400s closely on our backend
            // (this really shouldn't happen)
            print("[PushNotifications]: Fail to make a valid request to the server for job \(job), skipping it. Error: \(error)")
            return
        }
    }

    private func recreateDevice(token: String) -> Bool {
        // Register device with Error
        let result = self.networkService.register(instanceId: self.instanceId, deviceToken: token, metadata: Metadata.getCurrentMetadata(), retryStrategy: WithInfiniteExpBackoff())

        switch result {
        case .error(let error):
            print("[PushNotifications]: Unrecoverable error when registering device with Pusher Beams (Reason - \(error.getErrorMessage()))")
            return false
        case .value(let device):
            let localIntersets: [String] = DeviceStateStore.synchronize {
                Device.persist(device.id)
                Device.persistAPNsToken(token: token)
                return DeviceStateStore().getSubscriptions() ?? []
            }

            if !localIntersets.isEmpty {
                _ = self.networkService.setSubscriptions(instanceId: self.instanceId, deviceId: device.id, interests: localIntersets, retryStrategy: WithInfiniteExpBackoff())
            }

            if let userId = DeviceStateStore().getUserId() {
                let tokenProvider = self.getTokenProvider()
                if tokenProvider == nil {
                    // Any failures during this process are equivalent to de-authing the user e.g. setUserId(null)
                    // If the user session is indeed over, there should be a Stop in the backlog eventually
                    // If the user session is still valid, there should be a setUserId in the backlog

                    print("[PushNotifications]: Warning - Failed to set the user id due token provider not being present")
                    DeviceStateStore().removeUserId()
                } else {
                    let semaphore = DispatchSemaphore(value: 0)
                    do {
                        try tokenProvider!.fetchToken(userId: userId, completionHandler: { jwt, error in
                            if error != nil {
                                print("[PushNotifications]: Warning - Unexpected customer error: \(error!.localizedDescription)")
                                DeviceStateStore().removeUserId()
                                semaphore.signal()
                                return
                            }

                            let result = self.networkService.setUserId(instanceId: self.instanceId, deviceId: Device.getDeviceId()!, token: jwt, retryStrategy: WithInfiniteExpBackoff())

                            switch result {
                            case .value:
                                DeviceStateStore().setUserId(userId: userId)
                            case .error(let error):
                                print("[PushNotifications]: Warning - Unexpected error: \(error.getErrorMessage())")
                                DeviceStateStore().removeUserId()
                                semaphore.signal()
                                return
                            }

                            semaphore.signal()
                        })
                        semaphore.wait()
                    } catch (let error) {
                        print("[PushNotifications]: Warning - Unexpected error: \(error.localizedDescription)")
                        DeviceStateStore().removeUserId()
                    }
                }
            }

            return true
        }
    }

    func processSetUserIdJob(userId: String) {
        guard let tokenProvider = self.getTokenProvider() else {
            let error = TokenProviderError.error("[PushNotifications] - Token provider missing")
            self.handleServerSyncEvent(.UserIdSetEvent(userId: userId, error: error))
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        do {
            try tokenProvider.fetchToken(userId: userId, completionHandler: { jwt, error in
                if error != nil {
                    let error = TokenProviderError.error("[PushNotifications] - Error when fetching token: \(error!)")
                    self.handleServerSyncEvent(.UserIdSetEvent(userId: userId, error: error))
                    semaphore.signal()
                    return
                }

                let result = self.networkService.setUserId(instanceId: self.instanceId, deviceId: Device.getDeviceId()!, token: jwt, retryStrategy: WithInfiniteExpBackoff())

                switch result {
                case .value:
                    DeviceStateStore().setUserId(userId: userId)
                    self.handleServerSyncEvent(.UserIdSetEvent(userId: userId, error: nil))
                case .error(let error):
                    let error = TokenProviderError.error("[PushNotifications] - Error when synchronising with server: \(error)")
                    self.handleServerSyncEvent(.UserIdSetEvent(userId: userId, error: error))
                    semaphore.signal()
                    return
                }

                semaphore.signal()
            })
            semaphore.wait()
        } catch (let error) {
            let error = TokenProviderError.error("[PushNotifications] - Error when executing `fetchToken` method: \(error)")
            self.handleServerSyncEvent(.UserIdSetEvent(userId: userId, error: error))
        }
    }

    func handleMessage(serverSyncJob: ServerSyncJob) {
        // If the SDK hasn't started yet we can't do anything, so skip
        var shouldSkip: Bool
        if case .StartJob(_) = serverSyncJob {
            shouldSkip = false
        } else {
            shouldSkip = !hasStarted()
        }

        if shouldSkip {
            return
        }

        switch serverSyncJob {
        case .StartJob(let instanceId, let token):
            processStartJob(instanceId: instanceId, token: token)

            // Clear up the queue up to the StartJob.
            while(!jobQueue.isEmpty) {
                switch jobQueue.first! {
                case .StartJob:
                    jobQueue.removeFirst()
                    return
                default:
                    jobQueue.removeFirst()
                }
            }

        case .StopJob:
            processStopJob()
            jobQueue.removeFirst()

        default:
            processJob(serverSyncJob)
            jobQueue.removeFirst()
        }
    }
}
