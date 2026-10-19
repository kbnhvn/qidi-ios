public struct UIBackgroundTaskIdentifier: Equatable { public init() {}; public static let invalid = UIBackgroundTaskIdentifier() }
public final class UIApplication {
    public static let shared = UIApplication()
    public var isIdleTimerDisabled = false
    public func beginBackgroundTask(withName: String?, expirationHandler: (() -> Void)?) -> UIBackgroundTaskIdentifier { .invalid }
    public func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {}
}
