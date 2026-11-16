import AppleCore
import Foundation
import Testing
@testable import WebRemoteSupport

@MainActor
private final class PairingFixture {
    var time: TimeInterval = 0
    var unlocked = true
    var issued = 0
    var codes = 1000
    lazy var coordinator = WebPairingCoordinator(
        isUnlocked: { self.unlocked }, canPair: { true },
        authorize: { _ in
            self.issued += 1; return try PairingSecurity.randomToken()
        },
        now: { self.time },
        makeCode: {
            self.codes += 1; return String(self.codes)
        })
}

@Test @MainActor func onlyThePendingBrowserCanCancelItsPairing() throws {
    let fixture = PairingFixture()
    let start = try fixture.coordinator.start(name: "Browser", ownerCookie: nil)
    fixture.coordinator.cancel(ownerCookie: nil)
    #expect(fixture.coordinator.prompt != nil)
    fixture.coordinator.cancel(ownerCookie: start.ownerCookie)
    #expect(fixture.coordinator.prompt == nil)
}

@Test @MainActor func browserPINIsBoundToOwnerAndConsumedExactlyOnce() throws {
    let fixture = PairingFixture()
    let coordinator = fixture.coordinator
    let start = try coordinator.start(name: "Browser", ownerCookie: nil)
    let code = try #require(coordinator.prompt?.code)
    #expect(throws: WebPairingFailure.expired) {
        try coordinator.confirm(id: start.requestID, ownerCookie: nil, code: code)
    }
    _ = try coordinator.confirm(id: start.requestID, ownerCookie: start.ownerCookie, code: code)
    #expect(fixture.issued == 1)
    #expect(throws: WebPairingFailure.expired) {
        try coordinator.confirm(id: start.requestID, ownerCookie: start.ownerCookie, code: code)
    }
    #expect(fixture.issued == 1)
}

@Test @MainActor func anotherBrowserCannotReplaceAPendingRequest() throws {
    let fixture = PairingFixture()
    let coordinator = fixture.coordinator
    let start = try coordinator.start(name: "Browser", ownerCookie: nil)
    #expect(throws: WebPairingFailure.busy) {
        try coordinator.start(name: "Other", ownerCookie: nil)
    }
    let resumed = try coordinator.start(name: "Browser", ownerCookie: start.ownerCookie)
    #expect(resumed.requestID == start.requestID)
}

@Test @MainActor func threeMistakesRotateTheCodeWithoutExtendingItsDeadline() throws {
    let fixture = PairingFixture()
    let coordinator = fixture.coordinator
    let start = try coordinator.start(name: "Browser", ownerCookie: nil)
    let original = try #require(coordinator.prompt)
    for _ in 0..<2 {
        #expect(throws: WebPairingFailure.incorrectCode) {
            try coordinator.confirm(id: start.requestID, ownerCookie: start.ownerCookie, code: "")
        }
    }
    #expect(throws: WebPairingFailure.codeChanged) {
        try coordinator.confirm(id: start.requestID, ownerCookie: start.ownerCookie, code: "")
    }
    let rotated = try #require(coordinator.prompt)
    #expect(rotated.code != original.code)
    #expect(rotated.expiresAt == original.expiresAt)
    #expect(throws: WebPairingFailure.rateLimited) {
        try coordinator.confirm(
            id: start.requestID, ownerCookie: start.ownerCookie, code: rotated.code)
    }
    fixture.time = 61
    _ = try coordinator.confirm(
        id: start.requestID, ownerCookie: start.ownerCookie, code: rotated.code)
    #expect(fixture.issued == 1)
}

@Test @MainActor func sleepAndMacLockInvalidatePendingPairing() throws {
    for locks in [true, false] {
        let fixture = PairingFixture()
        let coordinator = fixture.coordinator
        let start = try coordinator.start(name: "Browser", ownerCookie: nil)
        let code = try #require(coordinator.prompt?.code)
        if locks { fixture.unlocked = false } else { fixture.time = 121 }
        #expect(throws: locks ? WebPairingFailure.unavailable : WebPairingFailure.expired) {
            try coordinator.confirm(id: start.requestID, ownerCookie: start.ownerCookie, code: code)
        }
        #expect(coordinator.prompt == nil)
        #expect(fixture.issued == 0)
    }
}
