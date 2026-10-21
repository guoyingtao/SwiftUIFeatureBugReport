//
//  PrivateReportPresentationTests.swift
//  SwiftUIFeatureBugReportTests
//

import CloudKit
import Testing

@testable import SwiftUIFeatureBugReport

private func identity(_ state: IdentityState, _ user: String?) -> PrivateReportPresentation.Identity {

    PrivateReportPresentation.Identity(state: state, userRecordID: user)
}

private func report(_ name: String) -> PrivateReport {

    PrivateReport(id: CKRecord.ID(recordName: name))
}

/// An open private report or a selection must not outlive the identity that loaded it, or the reload
/// that dropped it - otherwise the previous account's private text stays on screen.
@Suite("Private report presentation")
struct PrivateReportPresentationTests {

    @Test("Shown only to the identity that opened it, once identity is ready")
    func showableToOpener() {

        #expect(PrivateReportPresentation.isShowable(openedBy: "_alice", current: identity(.ready, "_alice")))
    }

    @Test("Hidden after an account switch, a sign-out, a failure, or while identity is resolving")
    func hiddenOtherwise() {

        #expect(!PrivateReportPresentation.isShowable(openedBy: "_alice", current: identity(.ready, "_bob")))
        #expect(!PrivateReportPresentation.isShowable(openedBy: "_alice", current: identity(.noAccount, nil)))
        #expect(!PrivateReportPresentation.isShowable(openedBy: "_alice", current: identity(.failed("x"), nil)))
        #expect(!PrivateReportPresentation.isShowable(openedBy: "_alice", current: identity(.resolving, "_alice")))
    }

    @Test("A report opened before identity resolved is never shown")
    func openedWithoutIdentity() {

        #expect(!PrivateReportPresentation.isShowable(openedBy: nil, current: identity(.ready, "_alice")))
        #expect(!PrivateReportPresentation.isShowable(openedBy: nil, current: identity(.noAccount, nil)))
    }

    @Test("Any change to state or account is an identity change")
    func identityEquality() {

        #expect(identity(.ready, "_alice") == identity(.ready, "_alice"))
        #expect(identity(.ready, "_alice") != identity(.ready, "_bob"))
        #expect(identity(.ready, "_alice") != identity(.resolving, "_alice"))
    }

    @Test("A selection still in the reloaded list is kept")
    func selectionKept() {

        let selected = CKRecord.ID(recordName: "b")

        #expect(PrivateReportPresentation.retainedSelection(selected, in: [report("a"), report("b")]) == selected)
    }

    @Test("A selection the reload dropped, or a reset emptied, is cleared")
    func selectionCleared() {

        let selected = CKRecord.ID(recordName: "b")

        #expect(PrivateReportPresentation.retainedSelection(selected, in: [report("a")]) == nil)
        #expect(PrivateReportPresentation.retainedSelection(selected, in: []) == nil)
        #expect(PrivateReportPresentation.retainedSelection(nil, in: [report("a")]) == nil)
    }
}
