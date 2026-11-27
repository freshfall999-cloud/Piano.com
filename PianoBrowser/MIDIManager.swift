import CoreMIDI
import Foundation

struct MIDIDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let manufacturer: String

    var payload: [String: String] {
        ["id": id, "name": name, "manufacturer": manufacturer]
    }
}

/// Talks to CoreMIDI: every connected source (USB, Bluetooth, network, other
/// apps) is listened to, and every destination can be sent to.
final class MIDIManager: ObservableObject {
    @Published private(set) var inputs: [MIDIDevice] = []
    @Published private(set) var outputs: [MIDIDevice] = []
    /// Bumped (at most a few times a second) while messages arrive.
    @Published private(set) var activityTick = 0
    @Published private(set) var startupError: String?

    /// Called on the main thread with the source id and one raw CoreMIDI packet.
    var onMessage: ((String, [UInt8]) -> Void)?
    var onDevicesChanged: (() -> Void)?

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var connectedSources = Set<MIDIEndpointRef>()
    private var destinations: [String: MIDIEndpointRef] = [:]
    private var lastTick: TimeInterval = 0

    private static let lengthOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.length) ?? 8
    private static let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data) ?? 10
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    init() {
        start()
    }

    private func start() {
        var status = MIDIClientCreateWithBlock("PianoBrowser" as CFString, &client) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        guard status == noErr else {
            startupError = "Could not start MIDI (error \(status))."
            return
        }

        status = MIDIInputPortCreateWithBlock(client, "PianoBrowser In" as CFString, &inPort) { [weak self] packetList, refCon in
            let id = String(Int32(truncatingIfNeeded: Int(bitPattern: refCon)))
            var packets: [[UInt8]] = []
            for packet in packetList.unsafeSequence() {
                let raw = UnsafeRawPointer(packet)
                let length = Int(raw.loadUnaligned(fromByteOffset: MIDIManager.lengthOffset, as: UInt16.self))
                guard length > 0 else { continue }
                packets.append(Array(UnsafeRawBufferPointer(start: raw + MIDIManager.dataOffset, count: length)))
            }
            guard !packets.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                for bytes in packets { self.onMessage?(id, bytes) }
                let now = ProcessInfo.processInfo.systemUptime
                if now - self.lastTick > 0.12 {
                    self.lastTick = now
                    self.activityTick &+= 1
                }
            }
        }
        if status != noErr { startupError = "Could not open MIDI input (error \(status))." }

        status = MIDIOutputPortCreate(client, "PianoBrowser Out" as CFString, &outPort)
        if status != noErr { startupError = "Could not open MIDI output (error \(status))." }

        refresh()
    }

    /// Re-reads the device list and starts listening to anything new.
    func refresh() {
        var newInputs: [MIDIDevice] = []
        var present = Set<MIDIEndpointRef>()
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            guard source != 0 else { continue }
            let uid = uniqueID(of: source)
            newInputs.append(describe(source, uid: uid))
            present.insert(source)
            if !connectedSources.contains(source),
               MIDIPortConnectSource(inPort, source, UnsafeMutableRawPointer(bitPattern: Int(uid))) == noErr {
                connectedSources.insert(source)
            }
        }
        connectedSources.formIntersection(present)

        var newOutputs: [MIDIDevice] = []
        var newDestinations: [String: MIDIEndpointRef] = [:]
        for index in 0..<MIDIGetNumberOfDestinations() {
            let destination = MIDIGetDestination(index)
            guard destination != 0 else { continue }
            let device = describe(destination, uid: uniqueID(of: destination))
            newOutputs.append(device)
            newDestinations[device.id] = destination
        }
        destinations = newDestinations

        if newInputs != inputs || newOutputs != outputs {
            inputs = newInputs
            outputs = newOutputs
            onDevicesChanged?()
        }
    }

    /// Sends raw MIDI bytes to an output, optionally `delayMs` in the future.
    func send(to id: String, bytes: [UInt8], delayMs: Double) {
        guard let destination = destinations[id], !bytes.isEmpty else { return }

        var timestamp: MIDITimeStamp = 0 // 0 = now
        if delayMs > 0 {
            let nanos = min(delayMs, 60_000) * 1_000_000
            let ticks = nanos * Double(MIDIManager.timebase.denom) / Double(MIDIManager.timebase.numer)
            timestamp = mach_absolute_time() + UInt64(ticks)
        }

        // Long sysex dumps go out in pieces; everything else is one packet.
        let chunkSize = 1024
        var offset = 0
        while offset < bytes.count {
            let chunk = Array(bytes[offset..<min(offset + chunkSize, bytes.count)])
            offset += chunk.count
            let size = MemoryLayout<MIDIPacketList>.size + chunk.count + 64
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<MIDIPacketList>.alignment)
            defer { buffer.deallocate() }
            let list = buffer.assumingMemoryBound(to: MIDIPacketList.self)
            let packet = MIDIPacketListInit(list)
            _ = MIDIPacketListAdd(list, size, packet, timestamp, chunk.count, chunk)
            MIDISend(outPort, destination, list)
        }
    }

    /// Drops anything scheduled but not yet sent to an output.
    func clear(id: String) {
        if let destination = destinations[id] { MIDIFlushOutput(destination) }
    }

    private func uniqueID(of object: MIDIObjectRef) -> MIDIUniqueID {
        var uid: MIDIUniqueID = 0
        MIDIObjectGetIntegerProperty(object, kMIDIPropertyUniqueID, &uid)
        return uid
    }

    private func describe(_ endpoint: MIDIEndpointRef, uid: MIDIUniqueID) -> MIDIDevice {
        var name = string(endpoint, kMIDIPropertyDisplayName)
        if name.isEmpty { name = string(endpoint, kMIDIPropertyName) }
        if name.isEmpty { name = "MIDI device" }
        return MIDIDevice(id: String(uid), name: name, manufacturer: string(endpoint, kMIDIPropertyManufacturer))
    }

    private func string(_ object: MIDIObjectRef, _ property: CFString) -> String {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, property, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }
}
