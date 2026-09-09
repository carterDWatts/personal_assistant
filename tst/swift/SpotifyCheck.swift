import Foundation

@main struct SpotifyCheck {
    static func main() {
        let uri = "spotify:episode:" + String(repeating: "a", count: 22)
        let play = SpotifyCommand(["action": "play", "uri": uri])!
        precondition(!play.matches(["is_playing": true, "uri": "different"], beforeURI: nil))
        precondition(play.matches(["is_playing": true, "uri": uri], beforeURI: nil))
        precondition(!play.matches(["is_playing": false, "uri": uri], beforeURI: nil))
        precondition(SpotifyCommand(["action": "play", "uri": "https://attacker.example"]) == nil)
        precondition(SpotifyCommand(["action": "open_url"]) == nil)
        precondition(SpotifyCommand(["action": "seek", "position_ms": -1]) == nil)
        precondition(SpotifyCommand(["action": "seek"]) == nil)
        let next = SpotifyCommand(["action": "next"])!
        precondition(!next.matches(["is_playing": true, "uri": uri], beforeURI: uri))
        precondition(!next.matches(["is_playing": true], beforeURI: uri))
        precondition(next.matches(["is_playing": true, "uri": uri], beforeURI: "old"))
        precondition(!SpotifyCommand(["action": "pause"])!.matches([:], beforeURI: nil))
        print("Spotify command checks passed")
    }
}
