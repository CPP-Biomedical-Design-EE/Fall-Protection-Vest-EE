# InflateBody MPU6050 tools

These Python files support the Classic ESP32 and MPU6050 lower-back data
collection project.

Preview a labeled sample recording from the repository root:

```bash
python python/replay_recording.py --input python/data/inflatebody_samples/adl_T01_standing/adl_T01_standing_lower_back_center_waist_20261014T060749_492248Z.csv
```

Sample data is in `python/data/inflatebody_samples/`. Full recordings,
calibration files, generated graphs, and trained models remain outside GitHub.

Current tested ESP32 firmware: [`MPU6050_100Hz.ino`](../firmware/test/MPU6050_100Hz/MPU6050_100Hz.ino).
Its v2 acceleration constants are specific to the sensor used for the
six-position calibration; use a separate calibration for another sensor.
