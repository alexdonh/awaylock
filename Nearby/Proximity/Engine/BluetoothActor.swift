import Dispatch

/// The actor's executor *is* the queue CoreBluetooth calls back on, so delegate
/// callbacks already run isolated: no hops, no locks.
@globalActor
actor BluetoothActor {
    static let shared = BluetoothActor()
    nonisolated static let queue = DispatchSerialQueue(label: "nearby.bluetooth", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { Self.queue.asUnownedSerialExecutor() }
}
