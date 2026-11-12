import CoreAudio
import Foundation
import IOBluetooth

/// Fones Bluetooth pareados que ainda não existem no Core Audio.
///
/// Caso típico: AirPods conectados ao iPhone. Quando uma chamada do iPhone passa para o Mac,
/// os AirPods não aparecem como dispositivo de áudio até alguém pedir a conexão — é isso que
/// o menu de Som do macOS faz. Listamos esses fones e conectamos ao selecionar.
enum BluetoothAudio {
    struct Headset {
        let address: String   // "14-7A-E4-F3-FE-B8" (mesmo formato do UID no Core Audio)
        let name: String
    }

    private static let majorClassAudio: UInt32 = 0x04 // kBluetoothDeviceClassMajorAudio

    /// Endereço Bluetooth embutido no UID de um dispositivo Core Audio ("AA-BB-...:output").
    static func address(fromUID uid: String) -> String? {
        let addr = uid.split(separator: ":").first.map(String.init)?.uppercased() ?? ""
        return addr.count == 17 && addr.filter({ $0 == "-" }).count == 5 ? addr : nil
    }

    static func pairedHeadsets(excluding presentAddresses: Set<String>) -> [Headset] {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.compactMap { dev in
            guard dev.deviceClassMajor == majorClassAudio,
                  let raw = dev.addressString else { return nil }
            let address = raw.replacingOccurrences(of: ":", with: "-").uppercased()
            guard !presentAddresses.contains(address) else { return nil }
            return Headset(address: address, name: dev.name ?? address)
        }
    }

    /// Pede a conexão (bloqueante; chamar fora da main thread).
    /// `reconnect`: se já houver link sem áudio (só controle), fecha e reabre para trazer o áudio.
    static func connect(address: String, reconnect: Bool = false) -> Bool {
        guard let dev = IOBluetoothDevice(addressString: address) else { return false }
        if reconnect && dev.isConnected() {
            dev.closeConnection()
            Thread.sleep(forTimeInterval: 1)
        }
        return dev.openConnection() == kIOReturnSuccess
    }
}
