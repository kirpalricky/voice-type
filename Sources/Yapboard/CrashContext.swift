import Foundation
import Sentry
import Darwin
import AVFoundation

enum CrashContext {
    /// Reads physical memory footprint in bytes via task_vm_info.
    /// Returns nil if unable to read (e.g., on error or unsupported platform).
    static func physicalMemoryFootprint() -> UInt64? {
        var info = task_vm_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size/MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            task_info(
                mach_task_self_,
                task_flavor_t(TASK_VM_INFO),
                UnsafeMutableRawPointer(infoPtr).assumingMemoryBound(to: integer_t.self),
                &count
            )
        }

        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// Updates the "memory" context with current physical memory footprint.
    static func updateMemoryContext() {
        guard let footprint = physicalMemoryFootprint() else { return }
        SentrySDK.configureScope { scope in
            scope.setContext(value: ["physFootprintBytes": footprint], key: "memory")
        }
    }

    /// Updates the "permissions" context with current microphone permission state.
    static func updatePermissionsContext() {
        let micStatus: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micStatus = "authorized"
        case .notDetermined:
            micStatus = "notDetermined"
        case .denied:
            micStatus = "denied"
        case .restricted:
            micStatus = "restricted"
        @unknown default:
            micStatus = "unknown"
        }
        SentrySDK.configureScope { scope in
            scope.setContext(value: ["microphone": micStatus], key: "permissions")
        }
    }
}
