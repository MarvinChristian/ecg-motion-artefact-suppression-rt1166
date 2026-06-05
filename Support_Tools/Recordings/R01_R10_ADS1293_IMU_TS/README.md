# R01-R10 ADS1293/IMU Recordings

Curated current ADS1293 CH1/CH2 plus timestamped three-IMU recording set used
for the MAS/ML evaluation.

## Files

| Recording | File | Condition |
|---|---|---|
| R01 | `R01_Resting_2min_rec_1_20260507_011203.txt` | Resting, 2 min, repeat 1 |
| R01 | `R01_Resting_2min_rec_2_20260507_011432.txt` | Resting, 2 min, repeat 2 |
| R02 | `R02_Standing_2min_20260507_011728.txt` | Standing, 2 min |
| R03 | `R03_Breathing_2min_20260507_012029.txt` | Breathing, 2 min |
| R04 | `R04_RA_Movement_2min_20260507_012310.txt` | RA-side movement, 2 min |
| R05 | `R05_LA_Movement_2min_20260507_012544.txt` | LA-side movement, 2 min |
| R06 | `R06_LR_Sway_2min_20260507_012830.txt` | Left-right sway, 2 min |
| R07 | `R07_FB_Swaying_2min_20260507_013218.txt` | Front-back sway, 2 min |
| R08 | `R08_Walking_2min_20260507_014010.txt` | Walking, 2 min |
| R09 | `R09_Cable_Movement_1min_20260507_014327.txt` | Cable movement, 1 min |
| R10 | `R10_Bus_recording_1_20260507_134205.txt` | Bus recording, part 1 |
| R10 | `R10_Bus_recording_2_20260507_140027.txt` | Bus recording, part 2 |

## Notes

- These files were curated from the larger local recording workspace.
- `ads1293_recording_manifest.csv` points the final MATLAB extractor at these
  moved files from the repository root.
- Session-wide `session_raw_*.txt` files and earlier bank/debug recordings were not
  moved into this curated support set.
- Derive sample rate from the `t_us` column for each recording. Do not assume a
  nominal firmware sample rate.
