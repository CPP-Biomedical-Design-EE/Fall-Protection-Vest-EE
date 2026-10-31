# Firmware tests

Put PlatformIO unit tests here. Start with sensor connection checks and safe logic tests that do not use a real inflation device.

## Classic ESP32 MPU6050 collector

[`MPU6050_100Hz/MPU6050_100Hz.ino`](MPU6050_100Hz/MPU6050_100Hz.ino)
is the 100 Hz, six-axis sketch uploaded to the Classic ESP32. It is separate
from the ESP32-S3 PlatformIO starter in `firmware/src/`.

Calibration `p01_six_face_20261030_v2` was fitted from six stationary positions
of one physical MPU6050. After upload, a separate 30-second still recording
measured 0.9992 g average total acceleration, 100.21 Hz, and zero sequence
gaps. This checks stationary sensor readings and timing only; it does not
validate fall detection or deployment.

The calibration constants belong to that sensor. Calibrate a different
MPU6050 separately. Full calibration recordings remain on the collection
computer. Earlier CSVs retain the old calibration; keep their version separate
from new v2 recordings during analysis and model training.
