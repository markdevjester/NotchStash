import AppKit

let app = NSApplication.shared

// второй экземпляр не запускаем
let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if !others.isEmpty && ProcessInfo.processInfo.environment["NOTCHSTASH_DATA_DIR"] == nil {
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
