# Four-channel liveness check, 2026-11-03

Firmware: `board/wyxfinalproject.bit`, SHA-256 `a9e3cbc179b8791e5b6e3b4caee54ab4e888b544130340f90af4ba30c5bdb74b`.
Target: PYNQ-Z2 `xc7z020clg400-1`. The image was loaded over JTAG, `DONE=1`, and PS FCLK0 was initialized to 25 MHz before the capture. This check did not write an SD card.

Twelve coherent snapshots were read through the version-3 PS GPIO bridge over 32.25 seconds, from 01:43:21 to 01:43:54 China Standard Time. The GPIO direction, enable, and data registers were restored after capture. This public record contains counts and status bits only; the private raw capture and personal readings are not distributed.

| Signal | First | Last | Observation |
| --- | ---: | ---: | --- |
| Heart-rate UART frame count, page 21 | 1775 | 1808 | 33 new frames |
| Heart-rate filtered result count, page 3 | 579 | 611 | 32 new results |
| MAX30102 PPG raw pair count, page 24 | 169769 | 173005 | 3236 new pairs, about 100/s |
| SpO2 filtered result count, page 13 | 306 | 338 | 32 new results |
| Probe TMP117 raw/result counts, pages 22/4 | 1679 / 1670 | 1712 / 1703 | Both advanced by 33 |
| Room TMP117 raw/result counts, pages 23/14 | 1775 / 1772 | 1808 / 1805 | Both advanced by 33 |
| Available mask, low nibble of page 5 | `0xF` | `0xF` | All four marked available in all 12 snapshots |
| Isolated mask, next nibble of page 5 | `0x0` | `0x0` | No confirmed device isolation in these snapshots |
| Heart-rate UART error count, page 8 | 1119 | 1120 | One additional error; frames and results still advanced |
| Probe / SpO2 / room error counts, pages 9/17/18 | 96 / 83 / 0 | 96 / 83 / 0 | No increase during this capture |

Maximum observed result ages were 890 ms (heart rate), 875 ms (SpO2), 834 ms (probe), and 834 ms (room). Page 28 remained `0x1007`, including online and filter-settled flags. These observations establish four simultaneous live channels and fresh filtered result production for this firmware. They do **not** establish numerical accuracy against an independent reference, SpO2 calibration, fault-injection response, ARM live ingestion, or persistent SD boot. The heart-rate error counter increase is recorded rather than hidden.
