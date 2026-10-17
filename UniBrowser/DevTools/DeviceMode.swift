import Observation

/// «Режим устройства» of one tab (spec «Режим устройства»): stays on with the panel closed,
/// so it lives on `BrowserTab`, not on the session. Stub: ⇧⌘M and the header button toggle it.
@MainActor
@Observable
final class DeviceMode {
    var isOn = false
}
