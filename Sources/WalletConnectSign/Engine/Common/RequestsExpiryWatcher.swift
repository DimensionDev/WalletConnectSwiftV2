import Foundation
import Combine

class RequestsExpiryWatcher {
    private let requestExpirationPublisherSubject: PassthroughSubject<RPCID, Never> = .init()
    private let rpcHistory: RPCHistory
    private let historyService: HistoryService
    private let scanQueue = DispatchQueue(label: "com.walletconnect.sign.request-expiry", qos: .utility)
    private let checkLock = NSLock()
    private var checkInFlight = false
    private var checkTimer: Timer?

    var requestExpirationPublisher: AnyPublisher<RPCID, Never> {
        requestExpirationPublisherSubject.eraseToAnyPublisher()
    }

    internal init(
        proposalPayloadsStore: CodableStore<RequestSubscriptionPayload<SessionType.ProposeParams>>,
        rpcHistory: RPCHistory,
        historyService: HistoryService
    ) {
        self.rpcHistory = rpcHistory
        self.historyService = historyService
        setUpExpiryCheckTimer()
    }

    deinit {
        checkTimer?.invalidate()
    }

    func setUpExpiryCheckTimer() {
        checkTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkForRequestExpiry()
        }
    }

    func checkForRequestExpiry() {
        checkLock.lock()
        guard !checkInFlight else {
            checkLock.unlock()
            return
        }
        checkInFlight = true
        checkLock.unlock()

        let historyService = historyService
        scanQueue.async { [weak self] in
            guard self != nil else { return }
            // History reads decode every pending JSON-RPC record. Keep that work
            // off the timer's run loop, and never enqueue overlapping scans.
            let expiredIDs = historyService.getPendingExpirableRequestsWithId().compactMap { request, id in
                request.isExpired() ? id : nil
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer { self.finishCheck() }
                for id in expiredIDs {
                    // A request may have completed or been removed during the scan.
                    // Only re-read candidates; preserve main-thread event delivery.
                    guard let request = historyService.getPendingExpirableRequest(id: id),
                          request.isExpired() else { continue }
                    self.requestExpirationPublisherSubject.send(id)
                    self.rpcHistory.delete(id: id)
                }
            }
        }
    }

    private func finishCheck() {
        checkLock.lock()
        checkInFlight = false
        checkLock.unlock()
    }
}
