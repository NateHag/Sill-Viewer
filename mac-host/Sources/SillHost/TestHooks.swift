import Foundation

/// The TEST ONLY variables that bear on who gets in or what pairing needs
/// (docs/home-pairing-plan.md §4.3). Each is read where it acts, and honoured only on a test host
/// (DoorPolicy.isTestHost: one that does not advertise and is not a .app's executable): any process
/// of this user can start Sill.app's own executable with an environment, and it then runs with
/// Sill's Screen Recording and Accessibility grants. Anywhere else each one set is ignored with one
/// line, here. The encoder's variables let nobody in and are not among them;
/// SILL_TEST_REMOTE_DIR is read, and refused, where the identity store is chosen (the CLI and the
/// app).
enum TestHooks {
    static let doorAndPairing = [
        "SILL_TEST_SERVICE_TYPE", "SILL_TEST_SWAP_FAIL", "SILL_TEST_PEER_TO_PEER_INTERFACE", "SILL_TEST_ORIGIN",
        "SILL_TEST_REMOTE_ORIGIN",
        "SILL_TEST_LOOPBACK", "SILL_TEST_BACKOFF_SECONDS", "SILL_TEST_PAIRING_TTL", "SILL_TEST_NO_ROUTER",
        "SILL_TEST_CABLE_INTERFACE", "SILL_TEST_LOCKED", "SILL_TEST_ASK_FROM_THIS_MAC", "SILL_TEST_ASK_QUIET",
        // The device gate's (DeviceGate): a floor above "0" refuses devices.
        "SILL_TEST_MIN_DEVICE_VERSION", "SILL_TEST_GOODBYE",
    ]

    /// One line for each such variable set on a host that does not honour them; nothing on a test
    /// host, and nothing when none is set (so every existing output stays as it was).
    static func reportIgnored(testHost: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard !testHost else { return }
        for name in doorAndPairing where !(environment[name] ?? "").isEmpty {
            print("\(name) ignored: only a test host takes it (one that does not advertise and is not Sill.app itself).")
        }
    }
}
