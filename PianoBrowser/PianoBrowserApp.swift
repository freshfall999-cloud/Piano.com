import AVFoundation
import SwiftUI

@main
struct PianoBrowserApp: App {
    @StateObject private var midi: MIDIManager
    @StateObject private var browser: BrowserModel

    init() {
        let midi = MIDIManager()
        _midi = StateObject(wrappedValue: midi)
        _browser = StateObject(wrappedValue: BrowserModel(midi: midi))

        // Web pages keep making sound with the silent switch on.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(midi)
                .environmentObject(browser)
                .onAppear {
                    // Don't dim the screen in the middle of a piece.
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }
}
