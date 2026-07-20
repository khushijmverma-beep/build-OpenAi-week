# Performance report

Targets: overlay <100 ms, microphone listening <250 ms, local partial normally <500 ms, and cancellation <150 ms. The code timestamps core state transitions and keeps model loading/network/audio work out of the overlay path.

No measured performance values are reported yet. The available hardware is an Apple Silicon Mac running macOS 12.5 with no Xcode app and is below the deployment target. Measurements must be taken on a supported macOS 14+ machine after microphone/Accessibility permissions and a local speech model are available. This document intentionally does not fabricate benchmarks.
