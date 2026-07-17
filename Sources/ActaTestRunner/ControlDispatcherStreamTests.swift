import ActaControlProtocol
import ActaKit
import ActaRuntime
import Foundation
import Testing

// The two parts of the dispatcher that are about **time** rather than mapping: `stopAndWait`'s
// ownership model (the finalisation outlives the request that asked for it, concurrent requests share
// one stop, a later recording gets a fresh one) and `watch` (initial replay, coalescing to the newest
// pending state, cancellation). The command mappings live in `ControlDispatcherTests`; the fake both
// suites are driven with lives in `ControlDispatcherTestSupport`.
//
// Every wait here is a condition, never a yield count — see `waitUntil`.

// MARK: - stopAndWait

@MainActor
@available(macOS 15.0, *)
@Test
func stopAndWaitAnswersOnlyAfterTheFinalisationCompletes() async {
    let (dispatcher, fake) = makeDispatcher(ControlState(operation: .recording(elapsedSeconds: 5)))

    let request = Task { @MainActor in await dispatcher.handle(.stopAndWait) }
    await waitUntil("the stop to be in flight") { fake.stopIsInFlight }
    #expect(!request.isCancelled)

    fake.finishStop()
    let response = await request.value
    // The one command that claims completion — and it earns the claim: the state it answers with is the
    // one the finished stop settled into.
    #expect(response.state?.operation.kind == .idle)
}

@MainActor
@available(macOS 15.0, *)
@Test
func stopAndWaitWithNothingInFlightAnswersImmediately() async {
    let (dispatcher, fake) = makeDispatcher(ControlState(operation: .idle))
    let response = await dispatcher.handle(.stopAndWait)
    #expect(response.state?.operation.kind == .idle)
    // No task created and no stop started — creating one would stop nothing while parking a task for
    // the next caller to trip over.
    #expect(fake.stopAndWaitEntries == 0)
}

@MainActor
@available(macOS 15.0, *)
@Test
func concurrentStopAndWaitsForOneStopShareTheSameTask() async {
    let (dispatcher, fake) = makeDispatcher(ControlState(operation: .recording(elapsedSeconds: 5)))

    let first = Task { @MainActor in await dispatcher.handle(.stopAndWait) }
    let second = Task { @MainActor in await dispatcher.handle(.stopAndWait) }
    let third = Task { @MainActor in await dispatcher.handle(.stopAndWait) }
    // All three have arrived and the stop is parked. Without this barrier "one stop" would also be true
    // of two requests that had not run yet.
    await waitUntil("all three requests to arrive at a parked stop") {
        fake.stateReads == 3 && fake.stopIsInFlight
    }

    // One underlying stop, however many clients asked. Three would be three stops of one recording.
    #expect(fake.stopAndWaitEntries == 1)

    fake.finishStop()
    for response in [await first.value, await second.value, await third.value] {
        #expect(response.state?.operation.kind == .idle)
    }
}

@MainActor
@available(macOS 15.0, *)
@Test
func aLaterRecordingsStopAndWaitCreatesAFreshTask() async {
    let (dispatcher, fake) = makeDispatcher(ControlState(operation: .recording(elapsedSeconds: 5)))

    let first = Task { @MainActor in await dispatcher.handle(.stopAndWait) }
    await waitUntil("the first stop to be in flight") { fake.stopIsInFlight }
    fake.finishStop()
    _ = await first.value
    #expect(fake.stopAndWaitEntries == 1)

    // A second recording, later. The stored task is cleared when it completes precisely so this one
    // cannot join a finished stop and return instantly having stopped nothing.
    fake.currentState.operation = .recording(elapsedSeconds: 2)
    let second = Task { @MainActor in await dispatcher.handle(.stopAndWait) }
    await waitUntil("a fresh stop to be in flight") { fake.stopIsInFlight }
    #expect(fake.stopAndWaitEntries == 2)

    fake.finishStop()
    #expect(await second.value.state?.operation.kind == .idle)
}

@MainActor
@available(macOS 15.0, *)
@Test
func aCancelledStopAndWaitAbandonsItsOwnAwaitAndNotTheStop() async {
    let (dispatcher, fake) = makeDispatcher(ControlState(operation: .recording(elapsedSeconds: 5)))

    let impatient = Task { @MainActor in await dispatcher.handle(.stopAndWait) }
    let patient = Task { @MainActor in await dispatcher.handle(.stopAndWait) }
    await waitUntil("both requests to arrive at a parked stop") {
        fake.stateReads == 2 && fake.stopIsInFlight
    }
    #expect(fake.stopAndWaitEntries == 1)

    // The client gave up (a timeout, a dropped connection). Its await is abandoned…
    impatient.cancel()
    _ = await impatient.value

    // …and the recording is still being finalised. Aborting a real assembly because a client lost
    // patience is the one thing this model exists to prevent.
    #expect(fake.stopIsInFlight)

    fake.finishStop()
    #expect(await patient.value.state?.operation.kind == .idle)
}

// MARK: - openInFinder

@MainActor
@available(macOS 15.0, *)
@Test
func openInFinderResolvesTheOpaqueID() async {
    let (dispatcher, fake) = makeDispatcher(ControlState(recordings: [fixtureRecording("a"), fixtureRecording("b")]))
    let id = RecordingID.make(directoryName: "b")

    #expect(await dispatcher.handle(.openInFinder(id: id)).result == .ok)
    #expect(fake.revealed?.lastPathComponent == "b")
}

@MainActor
@available(macOS 15.0, *)
@Test(arguments: ["v1:bm9wZQ", "not-an-id", ""])
func openInFinderRejectsAnIDThatMatchesNoRecording(id: String) async {
    let (dispatcher, fake) = makeDispatcher(ControlState(recordings: [fixtureRecording("a")]))
    let response = await dispatcher.handle(.openInFinder(id: id))
    #expect(response.wireError == .unknownRecording(id: id))
    #expect(response.wireError?.code == "unknown_recording")
    // Nothing was revealed: the only folder a client can name is one the archive listing already gave it.
    #expect(fake.revealed == nil)
}

// MARK: - Unsupported commands

@MainActor
@available(macOS 15.0, *)
@Test
func anUnsupportedCommandIsAnsweredWithItsRawTag() async {
    let (dispatcher, fake) = makeDispatcher()
    // The payoff of `Command` decoding an unknown tag to data rather than throwing: it reaches here and
    // gets an answer instead of killing the frame.
    let response = await dispatcher.handle(.unsupportedCommand(raw: "teleport"))
    #expect(response.wireError == .unsupportedCommand(raw: "teleport"))
    #expect(response.wireError?.code == "unsupported_command")
    #expect(fake.calls.isEmpty)
}

// MARK: - watch

@MainActor
@available(macOS 15.0, *)
@Test
func watchReplaysTheCurrentStateAsItsFirstEvent() async {
    let (dispatcher, _) = makeDispatcher(ControlState(operation: .recording(elapsedSeconds: 7),
                                                      title: "Weekly sync"))
    guard let events = await dispatcher.handle(.watch).events else {
        Issue.record("expected an events stream")
        return
    }
    var iterator = events.makeAsyncIterator()
    let first = await iterator.next()
    // Element one of `states()` *is* the initial event — not a separate read of `state`, which would
    // risk either a duplicate or a missed transition in the gap before the subscription.
    #expect(first?.sequence == 1)
    #expect(first?.state.operation.kind == .recording)
    #expect(first?.state.title == "Weekly sync")
}

@MainActor
@available(macOS 15.0, *)
@Test
func watchCoalescesToTheNewestPendingStateAndNumbersTheGap() async {
    let fake = FakeControlServing()
    // A client that is not reading yet — a slow socket writer, in production — while four states go by.
    fake.scriptStates([ControlState(operation: .idle),
                       ControlState(operation: .starting),
                       ControlState(operation: .recording(elapsedSeconds: 1)),
                       ControlState(operation: .recording(elapsedSeconds: 2), title: "Newest")])
    let dispatcher = ControlDispatcher(service: fake)
    guard let events = await dispatcher.handle(.watch).events else {
        Issue.record("expected an events stream")
        return
    }

    // Five pulls: the four states, then the one that finds the script exhausted — so the fourth event
    // has provably been yielded downstream. The pump's own progress, not a yield count.
    await waitUntil("the pump drains the upstream") { fake.pulls == 5 }

    var iterator = events.makeAsyncIterator()
    let event = await iterator.next()
    // Only the newest survived the single slot. A stale state has no value once a newer one exists —
    // and an unbounded buffer here would be a process that must not fall over mid-recording holding
    // unbounded memory for a client that stopped reading.
    #expect(event?.state.title == "Newest")
    #expect(event?.state.operation.elapsedSeconds == 2)
    // The sequence is assigned *before* the coalescing, so the client is told that three states it never
    // saw existed rather than being handed a gapless number that lies about the history.
    #expect(event?.sequence == 4)
    // And nothing else: three states were genuinely dropped, not merely delayed.
    #expect(await iterator.next() == nil)
}

@MainActor
@available(macOS 15.0, *)
@Test
func watchStreamsEveryStateAClientKeepsUpWith() async {
    let (dispatcher, fake) = makeDispatcher(ControlState(operation: .idle))
    guard let events = await dispatcher.handle(.watch).events else {
        Issue.record("expected an events stream")
        return
    }
    var iterator = events.makeAsyncIterator()

    #expect(await iterator.next()?.state.operation.kind == .idle)
    fake.emit(ControlState(operation: .starting))
    let second = await iterator.next()
    #expect(second?.state.operation.kind == .starting)
    #expect(second?.sequence == 2)
    fake.emit(ControlState(operation: .recording(elapsedSeconds: 1)))
    let third = await iterator.next()
    #expect(third?.state.operation.kind == .recording)
    #expect(third?.sequence == 3)
}

@MainActor
@available(macOS 15.0, *)
@Test
func aCancelledWatchLetsGoOfTheUpstreamSubscription() async {
    let (dispatcher, fake) = makeDispatcher(ControlState(operation: .idle))
    guard let events = await dispatcher.handle(.watch).events else {
        Issue.record("expected an events stream")
        return
    }

    let consumer = Task { @MainActor in
        for await _ in events { /* drain until the client goes away */ }
    }
    await waitUntil("the subscription to be live") { fake.subscriberCount == 1 }

    consumer.cancel()
    await consumer.value
    await waitUntil("the upstream subscription to be let go") { fake.subscriberCount == 0 }
    // Without the pump's cancellation the subscription would outlive every reader — one leaked stream
    // per `watch` in a process that must stay up for hours.
    #expect(fake.subscriberCount == 0)
}

// MARK: - The isolation claim

@MainActor
@available(macOS 15.0, *)
@Test
func everyControlServingAccessHappensOnTheMainActor() async {
    let (dispatcher, fake) = makeDispatcher(ControlState(operation: .recording(elapsedSeconds: 1),
                                                         recordings: [fixtureRecording("a")]))
    // Every command, including the ones that cross a suspension point — which is exactly where an
    // "the actor serializes it" assumption would have been wrong.
    _ = await dispatcher.handle(.status)
    _ = await dispatcher.handle(.list)
    _ = await dispatcher.handle(.titleGet)
    _ = await dispatcher.handle(.titleSet("Weekly sync"))
    _ = await dispatcher.handle(.settingsGet)
    _ = await dispatcher.handle(.settingsSet(WireSettings(.default)))
    _ = await dispatcher.handle(.settingsSave)
    _ = await dispatcher.handle(.openInFinder(id: RecordingID.make(directoryName: "a")))
    _ = await dispatcher.handle(.recover)
    _ = await dispatcher.handle(.refresh)
    _ = await dispatcher.handle(.openArchive)
    _ = await dispatcher.handle(.dismissRecoveryNotice)
    _ = await dispatcher.handle(.stop)

    let stopping = Task { @MainActor in await dispatcher.handle(.stopAndWait) }
    await waitUntil("the stop to be in flight") { fake.stopIsInFlight }
    fake.finishStop()
    _ = await stopping.value

    #expect(!fake.sawOffMainActorAccess)
    #expect(!fake.calls.isEmpty)
}
