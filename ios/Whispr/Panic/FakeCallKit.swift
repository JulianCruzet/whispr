// PANIC (owner: Julian + Claude)
// Rings the phone through CallKit when Whispr isn't on screen. Nothing is actually
// connected: answering just tells the app to show its own in-call screen, which is what
// the system opens when its call pill is tapped. iOS labels these calls "Whispr Audio".

import CallKit
import Foundation

final class FakeCallKit: NSObject, CXProviderDelegate {
    /// Called on the main queue when the fake call is answered.
    var onAnswered: (() -> Void)?
    /// Called on the main queue when the fake call is declined or hung up.
    var onEnded: (() -> Void)?

    private let provider: CXProvider
    private var currentCall: UUID?

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    func ring(from callerName: String, completion: @escaping (Error?) -> Void) {
        let id = UUID()
        currentCall = id
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = callerName
        update.hasVideo = false
        provider.reportNewIncomingCall(with: id, update: update) { error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    func hangUp() {
        guard let id = currentCall else { return }
        provider.reportCall(with: id, endedAt: .now, reason: .remoteEnded)
        currentCall = nil
    }

    // MARK: CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        currentCall = nil
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // Pretend it connected.
        provider.reportOutgoingCall(with: action.callUUID, connectedAt: .now)
        action.fulfill()
        onAnswered?()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        currentCall = nil
        onEnded?()
    }
}
