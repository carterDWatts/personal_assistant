import SwiftUI

struct ChatScrollMetrics: Equatable {
    var frame: CGRect = .zero
    var viewport: CGFloat = 0
    var atBottom: Bool { frame.maxY <= viewport + 24 }
}

struct ChatScrollPosition {
    private var previous = ChatScrollMetrics()
    var following = true

    // Content growth is not a user scroll. Keep following through streamed text,
    // image loading, and changes to the composer or window size.
    mutating func layout(_ metrics: ChatScrollMetrics) -> Bool {
        let resized = previous.frame.size != metrics.frame.size || previous.viewport != metrics.viewport
        previous = metrics
        if resized { return following }
        following = metrics.atBottom
        return false
    }
}

struct ChatScrollPreference: PreferenceKey {
    static var defaultValue = ChatScrollMetrics()
    static func reduce(value: inout ChatScrollMetrics, nextValue: () -> ChatScrollMetrics) {
        let next = nextValue()
        if next.viewport > 0 { value = next }
    }
}

struct ChatScrollView<Content: View>: View {
    let latestInput: UUID?
    let focusedMessage: UUID?
    @ViewBuilder var content: () -> Content
    @State private var position = ChatScrollPosition()
    @Namespace private var coordinateSpace
    @Namespace private var bottom

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        content()
                        Color.clear.frame(height: 1).id(bottom)
                    }
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: ChatScrollPreference.self, value: ChatScrollMetrics(
                            frame: geometry.frame(in: .named(coordinateSpace)), viewport: viewport.size.height))
                    })
                }
                .coordinateSpace(name: coordinateSpace)
                .onPreferenceChange(ChatScrollPreference.self) { metrics in
                    if position.layout(metrics) {
                        // ScrollViewReader updates its anchors after this layout callback.
                        DispatchQueue.main.async {
                            if position.following { proxy.scrollTo(bottom, anchor: .bottom) }
                        }
                    }
                }
                .onChange(of: latestInput) { _ in
                    position.following = true
                    proxy.scrollTo(bottom, anchor: .bottom)
                }
                .onChange(of: focusedMessage) { id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .overlay(alignment: .bottom) {
                    if !position.following {
                        Button {
                            position.following = true
                            proxy.scrollTo(bottom, anchor: .bottom)
                        } label: { Image(systemName: "arrow.down") }
                        .buttonStyle(.bordered).padding(.bottom, 8).accessibilityLabel("Scroll to latest")
                    }
                }
            }
        }
    }
}
