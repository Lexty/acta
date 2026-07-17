import ActaKit
import Foundation

/// The **narrow** surface the transport needs from the recorder — nothing more.
///
/// `ControlAPI` conforms to it (see below) and is the only production implementation. Its purpose is
/// not abstraction for its own sake: the dispatcher's policy — a busy `start` rejected before the title
/// is touched, `stopAndWait`'s ownership model, `watch`'s coalescing — is the part of the transport
/// that can be wrong, and this protocol is what lets all of it be driven by a fake, on a temp archive,
/// with no socket, no TCC and no wall clock. Every test injects a fake; none may touch
/// `ControlAPI.shared`, which reaches for the real `~/Acta`, real TCC and real time.
///
/// ⚠️ **`@MainActor`, and that is the whole ordering claim.** Main-actor isolation serializes access
/// only *between* suspension points, and the dispatcher's `stopAndWait` is `async` — so it is
/// reentrant, and this annotation does **not** mean a request runs to completion before the next one
/// starts. What it does mean, exactly: *every* access below happens on `MainActor`. Any ordering the
/// dispatcher actually needs across an `await` is provided by its stored-task model, never by assuming
/// the actor supplies it.
@available(macOS 15.0, *)
@MainActor
public protocol ControlServing: AnyObject {
    /// The current typed state.
    var state: ControlState { get }
    /// A stream of typed states, the current one first. See `ControlAPI.states()` for what sampling can
    /// and cannot promise — and note it is **unbounded**, which is why the dispatcher puts a bounded
    /// primitive between it and a writer.
    func states() -> AsyncStream<ControlState>

    /// The editable meeting title.
    var title: String { get set }
    /// The current settings.
    var settings: RecordingSettings { get set }
    /// Normalise and persist the settings.
    func saveSettings()

    /// Start recording. A `title` sets the field first — which is exactly why the dispatcher checks
    /// `canStart` *before* calling this.
    func start(title: String?)
    /// Stop, fire-and-forget.
    func stop()
    /// Stop and wait until the recording is saved.
    func stopAndWait() async
    /// Recover crash-interrupted recordings (once per controller).
    func recover()
    /// Refresh the suggested title and the recordings list. Does not recover.
    func refresh()
    /// Reveal the archive root in Finder.
    func openArchive()
    /// Reveal one recording's folder in Finder.
    func openInFinder(_ url: URL)
    /// Dismiss the recovery banner.
    func dismissRecoveryNotice()
}

/// The production conformance: the façade already **is** this surface, so the protocol adds no
/// behaviour — it only names the subset the transport is allowed to reach for.
///
/// ⚠️ The privacy invariant travels with it: the dispatcher must be given `ControlAPI.shared`, which
/// wraps `RecordingController.shared` — the menu's own controller. A dispatcher over any other
/// controller would record into the archive with the menu showing nothing.
@available(macOS 15.0, *)
extension ControlAPI: ControlServing {}
