// ESP32 + MPU6050 six-axis acquisition, target 100 Hz.
// Mount: center lower back, fixed orientation. No fall/inflation control.
// CSV: device_time_us,sequence,ax,ay,az,gx,gy,gz (m/s^2, rad/s).
// Device time is the ESP32 read time, not a sensor-internal timestamp.
#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>

constexpr uint8_t MPU_ADDRESS = 0x68;  // 0x69 only if AD0 is HIGH.
constexpr int SDA_PIN = 21;
constexpr int SCL_PIN = 22;
constexpr uint32_t BAUD_RATE = 115200;
constexpr uint8_t SAMPLE_DIVISOR = 9;  // DLPF enabled: 1000/(1+9) = 100 Hz.
constexpr float ACCEL_COUNTS_PER_G = 2048.0f;  // +/-16 g.
constexpr float GYRO_COUNTS_PER_DPS = 65.5f;   // +/-500 deg/s, unchanged range.
constexpr uint32_t GYRO_CALIBRATION_MS = 2500;
// Six-face accelerometer calibration from P01 calibration recordings.
// Corrected value = (measured value - bias) * scale.
constexpr float ACCEL_BIAS_X_MPS2 = 0.610000f;
constexpr float ACCEL_BIAS_Y_MPS2 = -0.067950f;
constexpr float ACCEL_BIAS_Z_MPS2 = -1.407850f;
constexpr float ACCEL_SCALE_X = 1.004419522f;
constexpr float ACCEL_SCALE_Y = 1.006848084f;
constexpr float ACCEL_SCALE_Z = 0.990015698f;
Adafruit_MPU6050 mpu;
uint32_t sequenceNumber = 0;
uint32_t lastReadyMs = 0;
uint32_t lastWarningMs = 0;
float gyroBiasXCounts = 0.0f;
float gyroBiasYCounts = 0.0f;
float gyroBiasZCounts = 0.0f;

bool readRegisters(uint8_t reg, uint8_t *buffer, uint8_t count) {
  Wire.beginTransmission(MPU_ADDRESS);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) return false;
  if (Wire.requestFrom(MPU_ADDRESS, count) != count) {
    while (Wire.available()) Wire.read();
    return false;
  }
  for (uint8_t i = 0; i < count; ++i) buffer[i] = Wire.read();
  return true;
}

bool writeRegister(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(MPU_ADDRESS);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

int16_t signedWord(const uint8_t *bytes) {
  return static_cast<int16_t>((static_cast<uint16_t>(bytes[0]) << 8) | bytes[1]);
}

void stopWithError(const char *message);

void calibrateGyro() {
  const uint32_t startMs = millis();
  uint32_t sampleCount = 0;
  double sumX = 0.0;
  double sumY = 0.0;
  double sumZ = 0.0;
  uint8_t status = 0;
  uint8_t raw[14];

  while (millis() - startMs < GYRO_CALIBRATION_MS) {
    if (!readRegisters(MPU6050_INT_STATUS, &status, 1)) {
      delay(1);
      continue;
    }
    if (!(status & 0x01)) {
      delay(1);
      continue;
    }
    if (!readRegisters(MPU6050_ACCEL_OUT, raw, sizeof(raw))) {
      delay(1);
      continue;
    }
    sumX += signedWord(raw + 8);
    sumY += signedWord(raw + 10);
    sumZ += signedWord(raw + 12);
    ++sampleCount;
  }

  if (sampleCount < 50) stopWithError("Gyro calibration received too few samples.");
  gyroBiasXCounts = static_cast<float>(sumX / sampleCount);
  gyroBiasYCounts = static_cast<float>(sumY / sampleCount);
  gyroBiasZCounts = static_cast<float>(sumZ / sampleCount);
}

void stopWithError(const char *message) {
  while (true) {
    Serial.print("ERROR: ");
    Serial.println(message);
    delay(1000);
  }
}

void setup() {
  Serial.begin(BAUD_RATE);
  delay(1000);
  Wire.begin(SDA_PIN, SCL_PIN);
  if (!mpu.begin(MPU_ADDRESS, &Wire)) {
    stopWithError("MPU6050 not detected. Check 3.3V/GND/SDA21/SCL22 and address.");
  }
  Wire.setClock(400000);
  Wire.setTimeOut(20);
  mpu.setAccelerometerRange(MPU6050_RANGE_16_G);
  mpu.setGyroRange(MPU6050_RANGE_500_DEG);
  // Filter cutoff is NOT the output rate. Retain 21 Hz for now; validate its
  // attenuation and latency separately before any protection application.
  mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);
  mpu.setSampleRateDivisor(SAMPLE_DIVISOR);
  // Enable data-ready status. Poll it over I2C; no extra INT wire is required.
  if (!writeRegister(MPU6050_INT_ENABLE, 0x01)) stopWithError("Cannot enable data ready.");
  uint8_t config[4];
  // ACCEL_CONFIG AFS_SEL[4:3] = 0b11 (0x18) for the configured +/-16 g range.
  if (!readRegisters(MPU6050_SMPLRT_DIV, config, 4) || config[0] != SAMPLE_DIVISOR ||
      (config[1] & 0x07) != 4 || (config[2] & 0x18) != 0x08 || (config[3] & 0x18) != 0x18) {
    stopWithError("Sensor settings readback failed.");
  }
  delay(100);  // One-time settling, never a 100 ms delay inside acquisition.
  calibrateGyro();
  const float gyroBiasScale = (PI / 180.0f) / GYRO_COUNTS_PER_DPS;
  Serial.print("# gyro_bias_rad_s=");
  Serial.print(gyroBiasXCounts * gyroBiasScale, 6);
  Serial.print(",");
  Serial.print(gyroBiasYCounts * gyroBiasScale, 6);
  Serial.print(",");
  Serial.println(gyroBiasZCounts * gyroBiasScale, 6);
  Serial.print("# accel_calibration_bias_mps2=");
  Serial.print(ACCEL_BIAS_X_MPS2, 6);
  Serial.print(",");
  Serial.print(ACCEL_BIAS_Y_MPS2, 6);
  Serial.print(",");
  Serial.print(ACCEL_BIAS_Z_MPS2, 6);
  Serial.print(" scale=");
  Serial.print(ACCEL_SCALE_X, 6);
  Serial.print(",");
  Serial.print(ACCEL_SCALE_Y, 6);
  Serial.print(",");
  Serial.println(ACCEL_SCALE_Z, 6);
  Serial.println("# inflatebody_mpu6050_v2 target_hz=100 units=mps2/rads placement=lower_back_center_waist");
  Serial.println("device_time_us,sequence,ax,ay,az,gx,gy,gz");
  uint8_t status;
  readRegisters(MPU6050_INT_STATUS, &status, 1);  // Clear old ready status.
  lastReadyMs = millis();
}

void loop() {
  uint8_t status = 0;
  uint8_t raw[14];
  if (!readRegisters(MPU6050_INT_STATUS, &status, 1)) {
    if (millis() - lastWarningMs >= 1000) {
      Serial.println("ERROR: I2C status read failed.");
      lastWarningMs = millis();
    }
    delay(1);
    return;
  }
  if (!(status & 0x01)) {
    if (millis() - lastReadyMs >= 1000 && millis() - lastWarningMs >= 1000) {
      Serial.println("ERROR: No fresh MPU6050 samples.");
      lastWarningMs = millis();
    }
    delay(1);
    return;
  }
  const uint32_t timestamp = micros();
  if (!readRegisters(MPU6050_ACCEL_OUT, raw, sizeof(raw))) {
    if (millis() - lastWarningMs >= 1000) {
      Serial.println("ERROR: Incomplete sensor read; sample skipped.");
      lastWarningMs = millis();
    }
    return;
  }
  lastReadyMs = millis();
  const float accelScale = 9.80665f / ACCEL_COUNTS_PER_G;
  const float gyroScale = (PI / 180.0f) / GYRO_COUNTS_PER_DPS;
  const float rawAxMps2 = signedWord(raw) * accelScale;
  const float rawAyMps2 = signedWord(raw + 2) * accelScale;
  const float rawAzMps2 = signedWord(raw + 4) * accelScale;
  char line[128];
  const int length = snprintf(line, sizeof(line), "%lu,%lu,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f\n",
      static_cast<unsigned long>(timestamp), static_cast<unsigned long>(sequenceNumber++),
      (rawAxMps2 - ACCEL_BIAS_X_MPS2) * ACCEL_SCALE_X,
      (rawAyMps2 - ACCEL_BIAS_Y_MPS2) * ACCEL_SCALE_Y,
      (rawAzMps2 - ACCEL_BIAS_Z_MPS2) * ACCEL_SCALE_Z,
      (signedWord(raw + 8) - gyroBiasXCounts) * gyroScale,
      (signedWord(raw + 10) - gyroBiasYCounts) * gyroScale,
      (signedWord(raw + 12) - gyroBiasZCounts) * gyroScale);
  // Keep acquisition from waiting on a congested USB/UART transmitter. A
  // skipped transmission appears as a sequence gap in the Python recorder.
  if (length > 0 && length < static_cast<int>(sizeof(line)) && Serial.availableForWrite() >= length) {
    Serial.write(reinterpret_cast<const uint8_t *>(line), length);
  }
}
