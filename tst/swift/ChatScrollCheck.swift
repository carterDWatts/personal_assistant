import SwiftUI

@main struct ChatScrollCheck {
    static func main() {
        var position = ChatScrollPosition()
        func metrics(_ top: CGFloat, _ height: CGFloat, _ viewport: CGFloat = 500) -> ChatScrollMetrics {
            ChatScrollMetrics(frame: CGRect(x: 0, y: top, width: 600, height: height), viewport: viewport)
        }
        var measured = ChatScrollMetrics()
        ChatScrollPreference.reduce(value: &measured) { metrics(0, 2000) }
        ChatScrollPreference.reduce(value: &measured) { ChatScrollMetrics() }
        precondition(measured.viewport == 500, "Unmeasured siblings must not erase the content geometry")
        precondition(position.layout(metrics(0, 2000)), "Loaded history must scroll to its end")
        precondition(!position.layout(metrics(-1500, 2000)) && position.following)
        precondition(position.layout(metrics(-1500, 2500)), "Streaming growth must not switch following off")
        _ = position.layout(metrics(-2000, 2500))
        precondition(position.layout(metrics(-2000, 2500, 400)), "A taller composer must keep the last line visible")
        _ = position.layout(metrics(-2100, 2500, 400))
        _ = position.layout(metrics(-1500, 2500, 400))
        precondition(!position.following, "Reading earlier messages must suspend automatic scrolling")
        precondition(!position.layout(metrics(-1500, 3000, 400)), "New text must not pull readers away")
        _ = position.layout(metrics(-2600, 3000, 400))
        precondition(position.following, "Scrolling to the bottom must resume following")
        print("Chat follows layout changes and preserves manual scroll position.")
    }
}
