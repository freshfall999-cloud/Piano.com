import AVFoundation
import SwiftUI

@main
struct PianoBrowserApp: App {
    @StateObject private var midi: MIDIManager
    @StateObject private var browser: Browser
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let midi = MIDIManager()
        _midi = StateObject(wrappedValue: midi)
        _browser = StateObject(wrappedValue: Browser(midi: midi))

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
        .onChange(of: scenePhase) { phase in
            if phase != .active { browser.saveTabs() }
        }
    }
}
