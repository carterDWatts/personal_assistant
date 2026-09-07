import Foundation

@main struct OutputStreamCheck {
    static func main() async throws {
        let pipe = Pipe()
        let stream = outputStream(from: pipe.fileHandleForReading)
        let chunks = (0..<10000).map { Data("\($0): What’s on your mind?\n".utf8) }
        let expected = chunks.reduce(into: Data()) { $0.append($1) }
        let writer = Task.detached {
            for chunk in chunks { try pipe.fileHandleForWriting.write(contentsOf: chunk) }
            try pipe.fileHandleForWriting.close()
        }
        var received = Data()
        for await chunk in stream {
            await Task.yield()
            received.append(chunk)
        }
        try await writer.value
        precondition(received == expected, "Streamed bytes were reordered or lost")
        print("10,000 streamed chunks preserved in order.")
    }
}
