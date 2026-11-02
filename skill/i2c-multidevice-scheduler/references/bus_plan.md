# Shared-bus plan and acceptance record

Copy the blank tables for a new design. Fill values from the actual datasheets, source, configuration, and measured board capture. A blank cell means **not established**, not zero.

## Device and electrical plan

| Bus or mux branch | Physical device | Seven-bit address | Address strap evidence | Supply / pull-up voltage measured | Target update rate | New-conversion evidence |
| --- | --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |  |

Stop if two devices have the same address on the same unmultiplexed bus, if a module's logic level is unknown, or if a required pull-up is absent. Recheck the physical module rather than assuming its address from an example design.

## Transaction schedule

| Job | Trigger and priority | Required transactions and bytes | Worst-case bus time | Completion event | Error event | Bounded retry / recovery | Starvation check |
| --- | --- | --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |  |  |

Check that the sum of worst-case bus times, including retries and clock stretching, leaves room for each deadline. If transaction sizes or stretch bounds are unknown, mark the utilization estimate pending. A polling tick is not evidence that a new conversion was read.

## Board acceptance

| Device | Exact firmware hash | ACK/error trace | New-sample timestamps | Observed rate | Missing/overflow behavior | Recovery result | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |  |  |

Status is one of `source-reviewed`, `build-checked`, `board-observed`, or `pending`. The first two do not imply that the electrical bus works on the target board.

## Applied source review in this repository

The current `src/drivers/sensor_acquire.v` instantiates one `i2c_reg_master` and declares seven-bit addresses `0x57` (MAX30102), `0x48` (room TMP117), and `0x49` (probe TMP117). Source parameters request 100 Hz PPG reads and 1 Hz temperature reads; `src/rtl/wyx_final_board_top.sv` sets the bus to 100 kHz. `src/drivers/i2c_reg_master.v` exposes completion/error codes and an open-drain, bounded bus-clear path. These are **source observations**. The exact-image [board capture](../../../data/board_validation_20261103.md) observed application-level raw sample rates near 100/s and 1/s, respectively. It did not measure ACK timing, bus waveform, voltage, or recovery under an injected fault.

## Agent prompt

> Inspect the supplied I2C master, scheduler, constraints, and exact firmware evidence. Fill the device and transaction tables above. Separate due timers, completed transactions, and genuinely new samples. Identify address collisions, unbounded retries, stale-data paths, and shared-bus starvation. Quote file locations for source claims and timestamps for board claims. If a transaction length or measured voltage is unavailable, mark it pending; do not invent bus utilization or declare a device damaged.
