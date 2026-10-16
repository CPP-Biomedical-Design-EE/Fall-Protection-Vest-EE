# InflateBody MPU6050 Data and Analysis

Current lower-back data-collection and analysis software for the Classic ESP32 and MPU6050.

## Hardware

- MPU6050 mounted at the center lower back
- I2C: SDA 21, SCL 22, address `0x68`
- Serial: 115200 baud
- Target sampling rate: 100 Hz
- Timestamped columns: `device_time_us,sequence,ax,ay,az,gx,gy,gz`

## Preview a saved recording

From this folder:

```bash
python Python/replay_recording.py --choose
```

Enter a recording such as `T01 1`. The graph includes acceleration, gyro speed,
total acceleration, and Euler-angle estimates. Hover over a line to inspect a
sample.

## Important limits

The included code is for data collection and research analysis. It is not a
validated fall alarm and does not control a servo or inflation mechanism.
Private recordings, calibration files, virtual environments, and generated
graphs stay outside this repository.
