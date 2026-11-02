# Room-channel and display board check, 2026-11-02

Firmware: `board/wyxfinalproject.bit`, SHA-256 `a9e3cbc179b8791e5b6e3b4caee54ab4e888b544130340f90af4ba30c5bdb74b`.
Target: PYNQ-Z2 `xc7z020clg400-1`, programmed into PL over JTAG. Vivado reported `DONE=1`. This JTAG configuration is volatile; this check did not update the SD boot image.

The immediately preceding image showed room TMP117 (`0x48`) raw samples advancing but no valid filtered result: raw count 216 to 218, filtered count 0, age `0xFFFFFFFF`, and room sequence/freeze fault set. The top-level port `room_sample_sequence` was connected to the filtered-output counter, creating a circular validity dependency. It was reconnected to `room_raw_samples`, the counter that advances on each `room_valid` input. No filter coefficients or health thresholds were changed.

With the rebuilt image, two coherent PS/PL snapshots about two seconds apart reported:

| Signal | First snapshot | Second snapshot | Interpretation |
| --- | ---: | ---: | --- |
| Room raw sample count (page 23) | 14 | 16 | Source continued sampling. |
| Room filtered result count (page 14) | 11 | 13 | Filter delivered new valid results. |
| Room result age (page 16) | 26 ms | 218 ms | Fresh, not expired. |
| Room I2C error count (page 18) | 0 | 0 | No error counted during this boot. |
| Room fault reason (page 30) | 0 | 0 | The previous sequence/freeze fault cleared. |
| Room filtered value (high half of page 12) | `0x0C80` | `0x0C7F` | About 25.00°C and 24.99°C in signed Q7. |

The user separately confirmed that the Nextion screen displayed a numeric room value and refreshed normally without restarting. Snapshot access used the 32-page PS GPIO diagnostic interface; all registers were restored after reading.

The MAX30102 raw red/IR sample counter advanced by about 550 samples in 5.5 seconds, consistent with the configured 100 samples/s. Without a stable finger contact, its quality gate rejected new SpO2 estimates for more than two minutes; the latest reject bits indicated insufficient periodicity and red/IR correlation. After the user held a finger on the optical window, the reject code cleared and the accepted-result counter advanced from 18 to 21 during the short observation. The most recent result was 512 ms old. The estimator uses a four-second window and a one-second hop, so a few seconds of initial settling and at most one new estimate per second are expected. These are transport/validity checks, not a reference accuracy result. The personal measurement value is intentionally omitted.

Scope: this establishes live room acquisition, filtering/freshness, and display, plus MAX30102 raw sampling and resumed SpO2 estimate production after optical contact. It does not establish four-channel measurement accuracy, fault-recovery performance, SpO2 calibration, ARM live-data ingestion, or persistent SD boot behavior. No personal measurements are included.
