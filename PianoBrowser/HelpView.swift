import SwiftUI

/// A short guide, shown the first time the app opens and from the AA menu.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Step: Identifiable {
        let id = UUID()
        let symbol: String
        let color: Color
        let title: String
        let text: String
    }

    private let steps = [
        Step(symbol: "cable.connector", color: .orange, title: "Connect your instrument",
             text: "Plug it in with a USB cable (USB-C, or Apple’s Lightning to USB Camera Adapter). For Bluetooth instruments, tap AA in the address bar, then Instruments › Bluetooth MIDI."),
        Step(symbol: "pianokeys", color: .purple, title: "Check it works",
             text: "Open Test Keyboard from the start page and play a few notes. The keys light up and you hear sound."),
        Step(symbol: "globe", color: .blue, title: "Open your piano app",
             text: "Tap the address bar, type the website and press Go. When the site asks to use your MIDI instruments, tap Allow."),
        Step(symbol: "house.fill", color: .green, title: "Keep it handy",
             text: "On your piano app, tap AA › Set as Home Page so every new tab opens it, or AA › Add Bookmark to put it on the start page."),
        Step(symbol: "square.on.square", color: .indigo, title: "Browse like Safari",
             text: "Back, forward, share, bookmarks and tabs are in the bottom bar. Swipe across the address bar to change tab. The bar shrinks as you scroll; tap it to bring it back."),
        Step(symbol: "shield.lefthalf.filled", color: .teal, title: "Protection is on",
             text: "Unsafe and adult websites, trackers and ads are blocked automatically. You can change this in AA › Settings.")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Welcome to Piano Browser").font(.largeTitle.bold())
                        Text("A browser that lets websites hear your piano, keyboard or other MIDI instrument.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(steps) { step in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: step.symbol)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(step.color.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(step.title).font(.headline)
                                Text(step.text).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                Button { dismiss() } label: {
                    Text("Start Browsing").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.bar)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
