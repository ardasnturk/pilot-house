import Foundation

/// XPC interface of the privileged helper (`RemoteCodeHelper`).
///
/// The helper exists only to toggle `pmset -a disablesleep` for the optional
/// "stay awake with the lid closed" mode, which needs root. It exposes nothing
/// else and accepts connections only from the Remote Code Mac app signed by the
/// same team (see `HelperConstants.clientRequirement`).
@objc public protocol RemoteCodeHelperProtocol {
    /// Runs `pmset -a disablesleep 1` (`true`) or `0` (`false`).
    func setSleepDisabled(_ disabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)
    /// Reads the current `SleepDisabled` value from `pmset -g`.
    func isSleepDisabled(withReply reply: @escaping (Bool) -> Void)
    func helperVersion(withReply reply: @escaping (String) -> Void)
}

public enum HelperConstants {
    public static let machServiceName = "com.ardasenturk.Pilothouse.Helper"
    public static let plistName = "com.ardasenturk.Pilothouse.Helper.plist"
    public static let teamIdentifier = "5JMD3VSD7N"
    public static let appBundleIdentifier = "com.ardasenturk.Pilothouse.Mac"
    public static let version = "1"

    /// Code-signing requirement the helper imposes on its clients.
    public static let clientRequirement =
        "anchor apple generic and identifier \"\(appBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    /// Requirement the app imposes on the helper it talks to.
    public static let helperRequirement =
        "anchor apple generic and identifier \"\(machServiceName)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
}
