import CoreAudio
import Foundation

final class CoreAudioDeviceMonitor {
    enum Event: String {
        case devicesChanged = "devices_changed"
        case defaultOutputChanged = "default_output_changed"
    }

    var onEvent: ((Event) -> Void)?

    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private let callbackQueue = DispatchQueue.main
    private var listener: AudioObjectPropertyListenerBlock?
    private var registeredSelectors = Set<AudioObjectPropertySelector>()
    private var started = false
    private var generation: UInt64 = 0

    func start() {
        guard !started else { return }
        generation &+= 1
        let generation = generation
        started = true

        let listener: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
            guard let self,
                  self.started,
                  self.generation == generation
            else { return }
            let changedAddresses = UnsafeBufferPointer(
                start: addresses,
                count: Int(count)
            )
            let selectors = Set(changedAddresses.map(\.mSelector))
            // A single callback may contain both selectors. Default-output changes
            // require a bound-engine restart, so they take priority over a list refresh.
            if selectors.contains(kAudioHardwarePropertyDefaultOutputDevice) {
                self.onEvent?(.defaultOutputChanged)
            } else if selectors.contains(kAudioHardwarePropertyDevices) {
                self.onEvent?(.devicesChanged)
            }
        }
        self.listener = listener

        register(
            selector: kAudioHardwarePropertyDevices,
            listener: listener
        )
        register(
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            listener: listener
        )
        if registeredSelectors.isEmpty {
            started = false
            self.listener = nil
        }
    }

    func stop() {
        guard started else { return }
        generation &+= 1
        started = false

        if let listener {
            for selector in registeredSelectors {
                var address = propertyAddress(selector: selector)
                let result = AudioObjectRemovePropertyListenerBlock(
                    systemObject,
                    &address,
                    callbackQueue,
                    listener
                )
                if result != noErr {
                    AppLogger.shared.write(
                        "AUDIO MONITOR ERROR remove_listener selector=\(selector) error=\(result)"
                    )
                }
            }
        }

        registeredSelectors.removeAll()
        listener = nil
    }

    private func register(
        selector: AudioObjectPropertySelector,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = propertyAddress(selector: selector)
        let result = AudioObjectAddPropertyListenerBlock(
            systemObject,
            &address,
            callbackQueue,
            listener
        )
        guard result == noErr else {
            AppLogger.shared.write(
                "AUDIO MONITOR ERROR add_listener selector=\(selector) error=\(result)"
            )
            return
        }
        registeredSelectors.insert(selector)
    }

    private func propertyAddress(
        selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
