---
name: i2c-multidevice-scheduler
description: Plan and review one I2C controller serving several physical devices at different update rates, with explicit transaction, freshness, retry, and bus-recovery evidence.
---

# Shared I2C scheduling

Use this skill when two or more physical devices share one I2C bus and the design must preserve each device's own update rate and fault status. It applies to FPGA RTL or firmware. For separate buses or an address multiplexer, record each independent bus or mux branch before using the address-collision check.

1. Inventory the physical bus first: seven-bit addresses, voltage domain, pull-ups, address straps, clock source, target update rate, read/write sequence, and how a genuinely new conversion is recognized. Do not infer a pin's electrical level from wire color or a photograph.
2. Build the transaction plan using [references/bus_plan.md](references/bus_plan.md). Name one bus owner. A due timer may request a job, but it must not count as a completed transaction or a new sample. Bound retries and verify that a long or failed job cannot starve the other devices indefinitely.
3. Distinguish `transaction_done`, `transaction_error`, `new_sample`, FIFO overflow, and online state for each device. Emit a successful sample event only after the full expected payload is accepted. Record the actual effective rate and worst-case bus time when transaction lengths are available; otherwise mark bandwidth unverified.
4. Review the electrical recovery path separately. Open-drain outputs release high; a timeout or bus-clear attempt must end with a failure result if the line remains stuck. Recovery must not manufacture a successful sample or retain an old value as fresh.
5. On hardware, capture bus-level ACK/error and each device's sample event with timestamps. Compare them to the configured schedule. If no board capture for the exact firmware exists, report only source/build review.

**Output:** a filled bus plan, a per-device evidence table, the first observed scheduling or electrical failure, and the next single discriminating measurement. Do not label an unresponsive device broken until its supply, address, pull-ups, and transaction result are measured.

**Use outside this project:** replace the device names, addresses, rates, and error codes. The method does not require a PYNQ board or a health-monitor application. It does not prove the electrical waveform, signal integrity, or application algorithm from RTL inspection alone.
