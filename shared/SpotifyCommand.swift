import Foundation

/// Only supported player commands can cross the device boundary.
struct SpotifyCommand {
    let action: String
    let uri: String?
    let position: Int?
    init?(_ args: [String: Any]) {
        guard let action = args["action"] as? String,
              ["play", "pause", "resume", "next", "previous", "seek", "state"].contains(action) else { return nil }
        self.action = action; uri = args["uri"] as? String; position = args["position_ms"] as? Int
        if action == "play", uri?.range(of: "^spotify:(track|episode|album|playlist):[A-Za-z0-9]{22}$", options: .regularExpression) == nil { return nil }
        if action == "seek", position == nil || !(0...86_400_000).contains(position!) { return nil }
    }

    func matches(_ state: [String: Any], beforeURI: String?) -> Bool {
        guard let playing = state["is_playing"] as? Bool else { return false }
        switch action {
        case "state": return true
        case "play": return playing && (state["uri"] as? String == uri || state["context_uri"] as? String == uri)
        case "resume": return playing
        case "pause": return !playing
        case "seek": return abs((state["position_ms"] as? Int ?? -10000) - (position ?? 0)) < 2000
        case "next", "previous":
            guard let beforeURI, !beforeURI.isEmpty, let afterURI = state["uri"] as? String, !afterURI.isEmpty else { return false }
            return playing && afterURI != beforeURI
        default: return false
        }
    }
}
