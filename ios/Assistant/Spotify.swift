import Foundation
import UIKit
import SpotifyiOS

/// Commands go to the installed Spotify app. No audio or player UI lives here.
@MainActor final class Spotify: NSObject, @preconcurrency SPTAppRemoteDelegate {
    static let shared = Spotify()
    private var remote: SPTAppRemote?
    private var completion: CheckedContinuation<[String: Any], Never>?
    private var deadline: Task<Void, Never>?
    private var command: SpotifyCommand?
    private var woke = false
    private var issued = false
    private var attempt = UUID()
    private var tokenKey = ""

    func run(_ args: [String: Any], clientID: String) async -> [String: Any] {
        guard completion == nil, let command = SpotifyCommand(args), !clientID.isEmpty else {
            return ["error": "The Spotify command was not valid or another command is still running."]
        }
        guard UIApplication.shared.applicationState == .active,
              UIApplication.shared.canOpenURL(URL(string: "spotify:")!) else {
            return ["error": "Open Spotify on this phone and sign in, then return here."]
        }
        let key = "spotify:\(Account.shared.deviceID):\(clientID)"
        if remote == nil || tokenKey != key {
            remote?.disconnect()
            let config = SPTConfiguration(clientID: clientID, redirectURL: URL(string: "personal-assistant://spotify")!)
            remote = SPTAppRemote(configuration: config, logLevel: .none)
            remote?.delegate = self
            tokenKey = key
            remote?.connectionParameters.accessToken = Keychain.get(key).flatMap { String(data: $0, encoding: .utf8) }
        }
        self.command = command; woke = false; issued = false; attempt = UUID()
        return await withCheckedContinuation { continuation in
            completion = continuation
            let current = attempt
            deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(75))
                guard !Task.isCancelled, self?.attempt == current else { return }
                self?.finish(["error": "Spotify did not confirm playback. Check Spotify before trying again."])
            }
            if remote?.isConnected == true { perform() }
            else if remote?.connectionParameters.accessToken != nil { remote?.connect() }
            else { wake() }
        }
    }

    func receive(_ url: URL) -> Bool {
        guard url.scheme == "personal-assistant", url.host == "spotify" else { return false }
        guard completion != nil, woke, let remote else { return true }
        let values = remote.authorizationParameters(from: url)
        guard let token = values?[SPTAppRemoteAccessTokenKey], !token.isEmpty else {
            finish(["error": "Spotify access was not granted."]); return true
        }
        remote.connectionParameters.accessToken = token
        Keychain.set(tokenKey, Data(token.utf8))
        remote.connect()
        return true
    }

    func cancel() {
        finish(["error": "Spotify control was interrupted. Check the player before retrying."])
        remote?.disconnect()
    }

    func disconnect() {
        cancel()
        if !tokenKey.isEmpty { Keychain.delete(tokenKey) }
        remote = nil
    }

    private func wake() {
        guard !woke, let command, command.action == "play" || command.action == "resume" else {
            finish(["error": "Spotify is not available for that command. Open Spotify on this phone first."]); return
        }
        woke = true
        let current = attempt
        remote?.authorizeAndPlayURI(command.uri ?? "") { [weak self] opened in
            Task { @MainActor in
                guard self?.attempt == current else { return }
                if !opened { self?.finish(["error": "Spotify could not be opened on this phone."]) }
            }
        }
    }

    func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        guard appRemote === remote, completion != nil else { return }
        perform()
    }

    func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        guard appRemote === remote, completion != nil else { return }
        if woke { finish(["error": "Spotify could not connect. Check its account and playback permissions."]) }
        else { wake() }
    }

    func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        guard appRemote === remote, completion != nil, issued else { return }
        finish(["error": "Spotify disconnected before confirming the command. Check playback before retrying."])
    }

    private func perform() {
        guard !issued, let api = remote?.playerAPI, let command else { return }
        issued = true
        let current = attempt
        api.getPlayerState { [weak self] value, error in
            guard let self, self.completion != nil, self.attempt == current else { return }
            guard error == nil, let before = value as? SPTAppRemotePlayerState else {
                self.finish(["error": "Spotify could not report its player state."]); return
            }
            // Waking Spotify can already start the requested item. Do not restart it.
            if command.action == "state" || (self.woke && command.matches(self.state(before), beforeURI: nil)) {
                self.finish(self.state(before).merging(["accepted": true, "verified": true]) { _, new in new }); return
            }
            let done: SPTAppRemoteCallback = { [weak self] _, error in
                guard let self, self.completion != nil, self.attempt == current else { return }
                if error != nil { self.finish(["error": "Spotify rejected that playback command. Check Premium and the player's restrictions."]); return }
                self.verify(beforeURI: before.track.uri, attempt: current, tries: 8)
            }
            switch command.action {
            case "play": api.play(command.uri!, callback: done)
            case "resume": api.resume(done)
            case "pause": api.pause(done)
            case "next": api.skip(toNext: done)
            case "previous": api.skip(toPrevious: done)
            case "seek": api.seek(toPosition: command.position!, callback: done)
            default: break
            }
        }
    }

    private func state(_ value: SPTAppRemotePlayerState) -> [String: Any] {
        ["is_playing": !value.isPaused, "uri": value.track.uri, "title": value.track.name,
         "context_uri": value.contextURI.absoluteString, "position_ms": value.playbackPosition]
    }

    private func verify(beforeURI: String, attempt: UUID, tries: Int) {
        guard completion != nil, self.attempt == attempt else { return }
        remote?.playerAPI?.getPlayerState { [weak self] value, error in
            guard let self, self.completion != nil, self.attempt == attempt else { return }
            guard error == nil, let value = value as? SPTAppRemotePlayerState else {
                self.finish(["accepted": true, "verified": false]); return
            }
            let state = self.state(value)
            let verified = self.command?.matches(state, beforeURI: beforeURI) == true
            if verified || tries == 0 {
                self.finish(state.merging(["accepted": true, "verified": verified]) { _, new in new })
            } else {
                Task { try? await Task.sleep(for: .milliseconds(150)); self.verify(beforeURI: beforeURI, attempt: attempt, tries: tries - 1) }
            }
        }
    }

    private func finish(_ result: [String: Any]) {
        deadline?.cancel(); deadline = nil
        let pending = completion; completion = nil; command = nil
        if result["error"] != nil { remote?.disconnect(); remote = nil }
        pending?.resume(returning: result)
    }
}
