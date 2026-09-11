import ActaKit
import Foundation

/// Which build this is: the stable app or the experimental one.
///
/// The two flavors are separate apps on purpose (`Scripts/bundle.sh stable|dev`): different bundle
/// identifiers so TCC grants do not fight — an ad-hoc signature has no stable Team ID, so every
/// rebuild changes the cdhash and would revoke Screen Recording from the other build — and different
/// default archives so an experimental build can never write into real recordings.
///
/// Read from the `ActaBuildFlavor` key that `bundle.sh` stamps into `Info.plist`. Running outside a
/// bundle (tests, `swift run`) has no plist, so the fallback is `.dev`: the safe answer, since it
/// keeps such a run away from `~/Acta`.
public enum BuildFlavor: String {
    case stable
    case dev

    public static var current: BuildFlavor {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "ActaBuildFlavor") as? String,
              let flavor = BuildFlavor(rawValue: raw)
        else {
            return .dev
        }
        return flavor
    }

    /// The name shown in the menu bar and panel header. The dev build carries a visible suffix so two
    /// flavors running side by side are never confused — the whole reason the split exists.
    public var appDisplayName: String {
        switch self {
        case .stable: return AppInfo.name
        case .dev: return "\(AppInfo.name) Dev"
        }
    }

    /// The default archive folder under the home directory when no explicit path is set.
    var defaultArchiveFolderName: String {
        switch self {
        case .stable: return "Acta"
        case .dev: return "Acta-dev"
        }
    }

    /// The `os.Logger` subsystem: the bundle identifier this binary actually runs under.
    ///
    /// Not `AppInfo.bundleID`, which is hardcoded: the stable and dev builds are deliberately
    /// separate apps with separate identifiers, and logging both under the same subsystem made their
    /// lines indistinguishable in `log show` — exactly when telling them apart matters most. Outside
    /// a bundle (tests, `swift run`) there is no `Bundle.main.bundleIdentifier`, so we fall back to
    /// the constant.
    public static var logSubsystem: String {
        Bundle.main.bundleIdentifier ?? AppInfo.bundleID
    }

    /// The build this binary was made from (`git describe`), stamped by `bundle.sh`.
    /// With two apps installed, "which build produced this recording?" needs an answer.
    public static var revision: String {
        Bundle.main.object(forInfoDictionaryKey: "ActaBuildRevision") as? String ?? "unknown"
    }
}
