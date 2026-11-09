import Combine
import Foundation
import JSONRPC
import XCTest
@testable import WalletConnectSign
@testable import WalletConnectUtils

@MainActor
final class RequestsExpiryWatcherTests: XCTestCase {
    func testHistoryScanRunsOffMainAndCoalescesWhileBusy() async throws {
        let fixture = ExpiryFixture()
        let request = try fixture.insertRequest(expiry: 1)
        let started = expectation(description: "background snapshot")
        let expired = expectation(description: "main-thread expiration")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        fixture.storage.dictionaryHook = {
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            _ = gate.wait(timeout: .now() + 3)
        }
        var expirations = 0
        let token = fixture.watcher!.requestExpirationPublisher.sink { id in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(id, request.id)
            expirations += 1
            expired.fulfill()
        }
        for _ in 0..<20 { fixture.watcher!.checkForRequestExpiry() }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(fixture.storage.dictionaryReadCount, 1)
        fixture.storage.dictionaryHook = nil
        gate.signal()
        await fulfillment(of: [expired], timeout: 2)
        XCTAssertEqual(expirations, 1)
        XCTAssertNil(fixture.history.get(recordId: try XCTUnwrap(request.id)))

        let next = expectation(description: "next scan is allowed")
        fixture.storage.dictionaryHook = { next.fulfill() }
        fixture.watcher!.checkForRequestExpiry()
        await fulfillment(of: [next], timeout: 1)
        XCTAssertEqual(fixture.storage.dictionaryReadCount, 2)
        withExtendedLifetime(token) {}
    }

    func testResolvedRequestIsRecheckedBeforeExpirationDelivery() async throws {
        let fixture = ExpiryFixture()
        let request = try fixture.insertRequest(expiry: 1)
        let started = expectation(description: "captured pending snapshot")
        let rechecked = expectation(description: "fresh record lookup")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        fixture.storage.dictionaryHook = {
            started.fulfill()
            _ = gate.wait(timeout: .now() + 3)
        }
        var expirations = 0
        let token = fixture.watcher!.requestExpirationPublisher.sink { _ in expirations += 1 }
        fixture.watcher!.checkForRequestExpiry()
        await fulfillment(of: [started], timeout: 1)
        fixture.storage.dictionaryHook = nil
        try fixture.history.resolve(RPCResponse(matchingRequest: request, result: true))
        fixture.storage.objectHook = {
            XCTAssertTrue(Thread.isMainThread)
            rechecked.fulfill()
        }
        gate.signal()
        await fulfillment(of: [rechecked], timeout: 2)
        fixture.storage.objectHook = nil
        XCTAssertEqual(expirations, 0)
        XCTAssertNil(fixture.history.get(recordId: try XCTUnwrap(request.id)))
        withExtendedLifetime(token) {}
    }

    func testFreshNonexpiredReplacementSurvivesAnOldSnapshot() async throws {
        let fixture = ExpiryFixture()
        let request = try fixture.insertRequest(expiry: 1)
        let started = expectation(description: "old request snapshot")
        let rechecked = expectation(description: "replacement rechecked")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        fixture.storage.dictionaryHook = {
            started.fulfill()
            _ = gate.wait(timeout: .now() + 3)
        }
        var expirations = 0
        let token = fixture.watcher!.requestExpirationPublisher.sink { _ in expirations += 1 }
        fixture.watcher!.checkForRequestExpiry()
        await fulfillment(of: [started], timeout: 1)
        fixture.storage.dictionaryHook = nil
        let id = try XCTUnwrap(request.id)
        fixture.history.delete(id: id)
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        var params = try XCTUnwrap(data["params"] as? [String: Any])
        var nested = try XCTUnwrap(params["request"] as? [String: Any])
        nested["expiryTimestamp"] = UInt64(Date().timeIntervalSince1970) + 3600
        params["request"] = nested
        data["params"] = params
        let replacement = try JSONDecoder().decode(RPCRequest.self, from: JSONSerialization.data(withJSONObject: data))
        try fixture.history.set(replacement, forTopic: "replacement", emmitedBy: .remote, transportType: .relay)
        fixture.storage.objectHook = { rechecked.fulfill() }
        gate.signal()
        await fulfillment(of: [rechecked], timeout: 2)
        fixture.storage.objectHook = nil
        XCTAssertEqual(expirations, 0)
        XCTAssertEqual(fixture.history.get(recordId: id)?.topic, "replacement")
        withExtendedLifetime(token) {}
    }

    func testOnlyExpiredRequestsAreEmittedAndRemoved() async throws {
        let fixture = ExpiryFixture()
        let future = try fixture.insertRequest(expiry: UInt64(Date().timeIntervalSince1970) + 3600)
        let noExpiry = try fixture.insertRequest(expiry: nil)
        let expired = try fixture.insertRequest(expiry: 1)
        let delivered = expectation(description: "expired request only")
        var ids: [JSONRPC.RPCID] = []
        let token = fixture.watcher!.requestExpirationPublisher.sink { id in
            XCTAssertTrue(Thread.isMainThread)
            ids.append(id)
            delivered.fulfill()
        }
        fixture.watcher!.checkForRequestExpiry()
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(ids, [try XCTUnwrap(expired.id)])
        XCTAssertNil(fixture.history.get(recordId: try XCTUnwrap(expired.id)))
        XCTAssertNotNil(fixture.history.get(recordId: try XCTUnwrap(future.id)))
        XCTAssertNotNil(fixture.history.get(recordId: try XCTUnwrap(noExpiry.id)))
        withExtendedLifetime(token) {}
    }

    func testAuthenticationRequestsStillExpire() async throws {
        let fixture = ExpiryFixture()
        let requester = Participant(publicKey: "expiry-test", metadata: AppMetadata(name: "Expiry test", description: "", url: "https://example.com", icons: []))
        let payload = AuthPayload(domain: "example.com", aud: "https://example.com", version: "1", nonce: "1", chains: ["eip155:1"], type: "eip4361", iat: "2026-11-09T00:00:00Z")
        let params = SessionAuthenticateRequestParams(requester: requester, authPayload: payload, ttl: 0)
        let request = RPCRequest(method: "wc_sessionAuthenticate", params: params)
        try fixture.history.set(request, forTopic: "auth-test", emmitedBy: .remote, transportType: .relay)
        let delivered = expectation(description: "authentication expiration")
        let token = fixture.watcher!.requestExpirationPublisher.sink { id in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(id, request.id)
            delivered.fulfill()
        }
        fixture.watcher!.checkForRequestExpiry()
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertNil(fixture.history.get(recordId: try XCTUnwrap(request.id)))
        withExtendedLifetime(token) {}
    }

    func testReleasedWatcherDoesNotDeliverAScanResult() async throws {
        let fixture = ExpiryFixture()
        let request = try fixture.insertRequest(expiry: 1)
        let started = expectation(description: "scan started")
        let scanReturned = expectation(description: "scan returned")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        fixture.storage.dictionaryHook = {
            started.fulfill()
            _ = gate.wait(timeout: .now() + 3)
            scanReturned.fulfill()
        }
        let delivered = expectation(description: "no delivery after release")
        delivered.isInverted = true
        let token = fixture.watcher!.requestExpirationPublisher.sink { _ in delivered.fulfill() }
        fixture.watcher!.checkForRequestExpiry()
        await fulfillment(of: [started], timeout: 1)
        weak var watcher = fixture.watcher
        fixture.watcher = nil
        XCTAssertNil(watcher)
        gate.signal()
        await fulfillment(of: [scanReturned], timeout: 2)
        await fulfillment(of: [delivered], timeout: 0.1)
        XCTAssertNotNil(fixture.history.get(recordId: try XCTUnwrap(request.id)))
        withExtendedLifetime(token) {}
    }
}

@MainActor
private final class ExpiryFixture {
    let storage = ExpiryStorage()
    let history: RPCHistory
    var watcher: RequestsExpiryWatcher?

    init() {
        history = RPCHistory(keyValueStore: CodableStore(defaults: storage, identifier: "history"))
        let service = HistoryService(history: history, verifyContextStore: .init(defaults: storage, identifier: "verify"))
        watcher = RequestsExpiryWatcher(proposalPayloadsStore: .init(defaults: storage, identifier: "proposals"), rpcHistory: history, historyService: service)
        storage.resetReadCount()
    }

    func insertRequest(expiry: UInt64?) throws -> RPCRequest {
        let chain = try XCTUnwrap(Blockchain("eip155:1"))
        let params = SessionType.RequestParams(request: .init(method: "personal_sign", params: AnyCodable(["message"]), expiryTimestamp: expiry), chainId: chain)
        let request = RPCRequest(method: "wc_sessionRequest", params: params)
        try history.set(request, forTopic: "expiry-test", emmitedBy: .remote, transportType: .relay)
        return request
    }
}

private final class ExpiryStorage: KeyValueStorage {
    private let base = RuntimeKeyValueStorage()
    private let lock = NSLock()
    private var count = 0
    private var readHook: (() -> Void)?
    private var lookupHook: (() -> Void)?

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var dictionaryReadCount: Int { locked { count } }
    var dictionaryHook: (() -> Void)? { get { locked { readHook } } set { locked { readHook = newValue } } }
    var objectHook: (() -> Void)? { get { locked { lookupHook } } set { locked { lookupHook = newValue } } }
    func resetReadCount() { locked { count = 0 } }
    func set(_ value: Any?, forKey name: String) { base.set(value, forKey: name) }
    func object(forKey name: String) -> Any? { let value = base.object(forKey: name); objectHook?(); return value }
    func data(forKey name: String) -> Data? { base.data(forKey: name) }
    func bool(forKey name: String) -> Bool { base.bool(forKey: name) }
    func removeObject(forKey name: String) { base.removeObject(forKey: name) }
    func dictionaryRepresentation() -> [String: Any] {
        let snapshot = base.dictionaryRepresentation()
        let hook = locked { count += 1; return readHook }
        hook?()
        return snapshot
    }
}
