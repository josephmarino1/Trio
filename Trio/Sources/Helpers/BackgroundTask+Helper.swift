import UIKit

/// Ends a background task safely and ensures it is not called multiple times.
///
/// - Parameter taskID: The background task identifier to be ended.
func endBackgroundTaskSafely(_ taskID: inout UIBackgroundTaskIdentifier, taskName: String = "Unnamed Task") {
    if taskID != .invalid {
        UIApplication.shared.endBackgroundTask(taskID)
        debug(.default, "Background task '\(taskName)' ended successfully.")
        taskID = .invalid
    } else {
        debug(.default, "Background task '\(taskName)' was already invalid or ended.")
    }
}

/// Starts a background task and handles its expiration safely.
///
/// - Parameter name: The background task name.
func startBackgroundTask(withName name: String) -> UIBackgroundTaskIdentifier {
    // Box the identifier so the expiration handler sees the real task ID.
    // A capture-list copy would be pinned to `.invalid`, the handler would
    // never end the task, and iOS terminates apps whose expiration handlers
    // return without ending their background task.
    final class TaskIDBox {
        var value: UIBackgroundTaskIdentifier = .invalid
    }
    let box = TaskIDBox()

    box.value = UIApplication.shared.beginBackgroundTask(withName: name) {
        if box.value != .invalid {
            UIApplication.shared.endBackgroundTask(box.value)
            box.value = .invalid
            debug(.default, "Background task '\(name)' ended in expiration handler.")
        }
    }

    debug(.default, "Background task '\(name)' started with ID: \(box.value)")
    return box.value
}
