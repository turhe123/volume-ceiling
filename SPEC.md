# VolumeCeiling — specification

**Tagline:** Set a maximum volume for each output device so headphones can never blast your ears.

**Category:** Audio

**Inspired by (paid):** Hear Volume Limiter ($5.99 one-time)

**Frameworks:** SwiftUI, AppKit, CoreAudio, ServiceManagement, UserNotifications

**Donation URL (Support button):** https://ko-fi.com/leodavidai

## Spec

What the paid app does: Hear is a Mac App Store menu bar utility sold for 5.99 dollars that caps the maximum volume of each audio output device, with percentage limits, a global limit, and presets for safe listening. Its listing mentions protecting hearing, and a similar Volume Limiter app also exists, which shows people want a guard against sudden loud audio when switching to headphones. The store page shows few ratings, so the demand signal is the category itself and repeated listings of competing limiters. Our clean-room VolumeCeiling covers the same core job.

Feature set: list all output devices that support a settable volume, store a ceiling per device as a percentage with a slider, a default ceiling for devices that have none, a master on and off switch, an indicator in the menu bar showing the current device and its ceiling, a one-time clamp that lowers volume immediately when a device connects above its limit, and a notification when the limiter intervenes. Add a Safe preset that sets 60 percent for headphone type devices. Optionally lock the settings behind a confirmation click so a child cannot change them casually. This is about 300 to 400 lines.

UI spec: a MenuBarExtra window showing the active output device, its current volume, and a ceiling slider with a tick mark. Below it, a scrolling list of other known devices each with their own ceiling slider and a reset button. Footer: Settings, Pause limiter for one hour, Quit. Settings window fields: global default ceiling, apply Safe preset to headphones, show notifications, clamp on connect, launch at login. Empty state: if no device with software volume is found, explain that some digital outputs cannot be limited by software. States: active, paused, and unsupported device shown greyed with a short reason.

Technical approach: CoreAudio. Enumerate devices with kAudioHardwarePropertyDevices, filter to those with output streams, and read names and unique identifiers for persistence. Read and write kAudioHardwareServiceDeviceProperty_VirtualMainVolume (or per channel kAudioDevicePropertyVolumeScalar when the main volume is missing). Register property listeners for volume changes on the default output device and for default device changes (kAudioHardwarePropertyDefaultOutputDevice) using AudioObjectAddPropertyListenerBlock. In the volume listener, if the new scalar exceeds the ceiling, set it back immediately, guarding against feedback loops with a flag and a very short debounce. When the default device changes, apply the clamp to the newly active device. Persist ceilings in UserDefaults keyed by device UID. No permission is needed for volume control. UserNotifications needs a one-time authorization request, requested lazily the first time the user enables notifications. Launch at login uses SMAppService.mainApp.

Edge cases: devices with no volume control such as some HDMI or USB DACs should be flagged unsupported rather than silently ignored. Devices with separate left and right volume need both channels clamped. A device unplugged during a write should be handled by catching the OSStatus error and ignoring it. Rapid key repeats on the volume keys may trigger many callbacks, so the debounce prevents flicker. If the user raises the ceiling while paused, nothing changes until resumed. Remember the last known volume so reconnecting a device does not start louder than the ceiling. Be honest in the UI that the limit is software enforced and brief spikes within the callback latency may occur.
