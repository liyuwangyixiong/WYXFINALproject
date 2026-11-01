# Project rules

- Preserve the existing four-channel health logic and the protected RTL hashes unless explicitly requested otherwise.
- Keep source parameters and signal scaling documented in their RTL comments.
- Missing or stale sensor data remains unavailable; do not substitute stored old readings.
- Distinguish a successful Vivado build from programming the board and validating physical sensors.
- Do not include simulated capture files, personal health records, credentials, or Vivado cache/run outputs in releases.
- Do not add live public website forwarding; the user deferred that feature.
