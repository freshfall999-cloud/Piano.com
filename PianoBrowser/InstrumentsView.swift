import CoreAudioKit
import SwiftUI

/// The sheet behind the piano button: what's connected, and Bluetooth pairing.
struct InstrumentsView: View {
    @EnvironmentObject private var browser: BrowserModel
    @EnvironmentObject private var midi: MIDIManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let error = midi.startupError {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }

                Section {
                    if midi.inputs.isEmpty {
                        Text("Nothing connected. Plug your instrument in with USB, or pair it over Bluetooth below.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(midi.inputs) { device in row(device) }
                } header: {
                    Text("Instruments you can play")
                }

                if !midi.outputs.isEmpty {
                    Section {
                        ForEach(midi.outputs) { device in row(device) }
                    } header: {
                        Text("Instruments web apps can play")
                    }
                }

                Section {
                    NavigationLink {
                        BluetoothMIDIView()
                            .navigationTitle("Bluetooth MIDI")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Bluetooth MIDI", systemImage: "dot.radiowaves.left.and.right")
                    }
                    Button {
                        browser.loadStartPage()
                        dismiss()
                    } label: {
                        Label("Open Test Keyboard", systemImage: "pianokeys")
                    }
                } footer: {
                    Text("USB instruments appear by themselves. Use a USB-C cable, or Apple’s Lightning to USB Camera Adapter on older iPhones.")
                }

                if browser.hasMIDIPermissions {
                    Section {
                        Button("Forget Allowed Websites", role: .destructive) { browser.resetMIDIPermissions() }
                    } footer: {
                        Text("Websites will have to ask again before using your instruments.")
                    }
                }
            }
            .navigationTitle("Instruments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { midi.refresh() }
        }
    }

    private func row(_ device: MIDIDevice) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(device.name)
            if !device.manufacturer.isEmpty {
                Text(device.manufacturer).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// Apple's built-in screen for finding and pairing Bluetooth MIDI instruments.
struct BluetoothMIDIView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> CABTMIDICentralViewController {
        CABTMIDICentralViewController()
    }

    func updateUIViewController(_ controller: CABTMIDICentralViewController, context: Context) {}
}
