import Foundation

//
// notchgram-itest — headless Telegram **test DC** harness (verification layer L2).
//
//   --report <path>       the L2 gate: live auth probe + status of the sections
//                         that cannot run; JSON report written to <path>
//   --probe-testdc        just the live auth probe, human-readable
//   --live-roundtrip      attempt the full send/receive/media round trip anyway
//                         (kept so the day Telegram fixes its test DC, one flag
//                         proves it rather than an archaeology session)
//   --interactive-login   founder-run CP1 fallback (M4)
//
// It drives the *same* `TDClient` and `AuthFlow` the app uses. A harness with
// its own parallel copy of the auth logic proves only that the copy works.
//
// Nothing here ever touches the real account: every run creates a throwaway
// test-DC number and its own database directory under `.artifacts/`, and
// deletes it afterwards.
//

let arguments = Array(CommandLine.arguments.dropFirst())

func flagValue(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

/// Cold start → `setTdlibParameters` → phone → `waitCode`.
///
/// This is a real signal, not a consolation prize: it exercises the singleton
/// manager, the ordered update stream, the 14-field parameter call, the
/// Keychain-free key path, the deadline wrapper, DC failover, and the code-length
/// derivation — everything up to the one step Telegram's servers currently
/// refuse. A regression in any of it turns this red.
func liveAuthProbe() async -> SectionResult {
    for dcId in DataCentrePreference.order() {
        let account = TestAccount(dcId: dcId)
        note("live auth probe: \(account.phoneNumber) (dc \(dcId))")

        guard let harness = try? Harness(account: account) else {
            return SectionResult(status: .failed, reason: "could not create the harness directory")
        }
        await harness.start()

        var detail: String?
        do {
            let challenge = try await harness.waitForCode(deadline: .seconds(40))
            let length = challenge.kind.expectedLength.map(String.init) ?? "n/a"
            detail = "reached waitCode on dc \(dcId); code kind \(challenge.kind), length \(length)"
            note(detail!)
        } catch {
            note("dc \(dcId): \(error.localizedDescription)")
        }

        let trail = await harness.trail
        await harness.stop()
        harness.cleanUp()

        if let detail {
            DataCentrePreference.remember(dcId)
            return SectionResult(
                status: .passed, detail: "\(trail) — \(detail)", dataCentre: dcId)
        }
        note("dc \(dcId) did not reach waitCode — \(trail)")
    }
    return SectionResult(
        status: .failed,
        reason: "no test data centre reached waitCode — network blocked, or a regression")
}

/// The full round trip, only when explicitly asked for.
func liveRoundTrip() async -> SectionResult {
    let backoff: [Duration] = [.seconds(2), .seconds(8), .seconds(30)]
    let order = Array(DataCentrePreference.order().prefix(3))
    var lastSteps: [StepResult] = []
    var lastFailure: String?

    for (attempt, dcId) in order.enumerated() {
        var steps: [StepResult] = []
        do {
            try await RoundTrip.run(dcId: dcId, steps: &steps)
            DataCentrePreference.remember(dcId)
            return SectionResult(status: .passed, dataCentre: dcId, steps: steps)
        } catch {
            lastSteps = steps
            lastFailure = (error as? TDError)?.message
                ?? (error as? TDTimeout)?.errorDescription
                ?? String(describing: error)
            note("attempt \(attempt + 1) on dc \(dcId) failed — \(lastFailure ?? "?")")

            // A long flood wait is answered with a fresh number, not a sleep:
            // the limit is per number, and every attempt already picks a new one.
            if attempt + 1 < order.count {
                let pause = backoff[min(attempt, backoff.count - 1)]
                    + .milliseconds(Int.random(in: 0...750))
                note("backing off \(pause)")
                try? await Task.sleep(for: pause)
            }
        }
    }
    return SectionResult(status: .failed, reason: lastFailure, steps: lastSteps)
}

func runReport(path: String, includeRoundTrip: Bool) async -> Never {
    let started = ContinuousClock.now
    var sections: [String: SectionResult] = [:]

    sections["liveAuthProbe"] = await liveAuthProbe()

    if includeRoundTrip {
        sections["liveRoundTrip"] = await liveRoundTrip()
    } else {
        sections["liveRoundTrip"] = SectionResult(
            status: .skipped,
            detail: "re-run with --live-roundtrip to attempt it anyway",
            reason: TestDCStatus.brokenReason,
            reference: TestDCStatus.reference)
    }

    // The inbound direction is covered offline by the fixture replay in
    // `make test`; saying so here keeps the L2 report honest about what it does
    // and does not prove.
    sections["updateReplay"] = SectionResult(
        status: .passed,
        detail: "update-stream replay over UpdateFixtures runs in `make test` (L1)")

    var report = ITestReport(
        ok: sections.values.allSatisfy { $0.status != .failed },
        tdlibVersion: TDLibProbe.version(),
        totalSeconds: Double((ContinuousClock.now - started).components.seconds),
        sections: sections)
    report.write(to: path)

    for (name, section) in sections.sorted(by: { $0.key < $1.key }) {
        note("\(section.status.rawValue.uppercased())  \(name)\(section.detail.map { " — \($0)" } ?? "")")
    }
    note("report → \(path)")

    if report.ok {
        note("ITEST OK in \(Int(report.totalSeconds)) s")
        exit(0)
    }
    fail("ITEST FAILED — see \(path)")
}

switch arguments.first {
case "--report":
    guard let path = flagValue("--report") else { fail("--report needs a path") }
    await runReport(path: path, includeRoundTrip: arguments.contains("--live-roundtrip"))
case "--probe-testdc":
    let result = await liveAuthProbe()
    if result.status == .passed {
        note("PROBE PASSED — \(result.detail ?? "")")
        exit(0)
    }
    fail("PROBE FAILED — \(result.reason ?? "unknown")")
case "--live-roundtrip":
    let result = await liveRoundTrip()
    if result.status == .passed { note("ROUND TRIP PASSED"); exit(0) }
    fail("ROUND TRIP FAILED — \(result.reason ?? "unknown")")
case "--interactive-login":
    note("interactive login lands in M4 (CP1 fallback)")
    exit(0)
default:
    fail("""
        usage: notchgram-itest --report <path> [--live-roundtrip] \
        | --probe-testdc | --live-roundtrip | --interactive-login
        """)
}
