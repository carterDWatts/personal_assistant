import Foundation

// A single consumer processes pipe chunks in arrival order.
func outputStream(from handle: FileHandle) -> AsyncStream<Data> {
    AsyncStream { continuation in
        handle.readabilityHandler = { input in
            let data = input.availableData
            if data.isEmpty {
                input.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        continuation.onTermination = { _ in handle.readabilityHandler = nil }
    }
}
