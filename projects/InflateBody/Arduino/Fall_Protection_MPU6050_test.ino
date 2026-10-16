#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>

#define SDA_PIN 21 //SDA -> pin 21 of ESP32
#define SCL_PIN 22 //SDA -> pin 22 of ESP32

Adafruit_MPU6050 mpu; //change when choice another sensor

const float GRAVITY = 9.80665; 
const float RAD_TO_DEGREE = 180.0 / PI;

void setup()
{

  Serial.begin(115200); //baud rate: signal change state 

  delay(1000);
  Wire.begin(SDA_PIN, SCL_PIN);

  if (!mpu.begin(0x68, &Wire)) //change 0x68 to 0x69 if MPU6050 not detect due to AD0 pulled HIGH
  {
    Serial.println("ERROR: MPU6050 not detected!");
    Serial.println();
    Serial.println("Check:");
    Serial.println("1. VIN -> ESP32 3.3V");
    Serial.println("2. GND -> ESP32 GND");
    Serial.println("3. SDA -> GPIO 21");
    Serial.println("4. SCL -> GPIO 22");
    Serial.println("5. MPU6050 I2C address");
    
    while (1)
    {
      delay(100);
    }
  }

  Serial.println("MPU6050 detected successfully!");
  Serial.println();

  mpu.setAccelerometerRange(MPU6050_RANGE_8_G); //Accelerometer range: 2G, 4G, 8G, 16G
  mpu.setGyroRange(MPU6050_RANGE_500_DEG); //Gyroscope range: 250 deg, 500 deg
  mpu.setFilterBandwidth(MPU6050_BAND_21_HZ); //Low pass filter

  Serial.println("Configuration:");
  Serial.println("Accelerometer Range = +/- 8 g");
  Serial.println("Gyroscope Range     = +/- 500 deg/s");
  Serial.println("Filter Bandwidth    = 21 Hz");

  Serial.println();
  Serial.println("...Starting measurements...");
  Serial.println();

  delay(1000);
}

void loop()
{
  sensors_event_t accel;
  sensors_event_t gyro;
  sensors_event_t temp;

  // Read sensor
  mpu.getEvent(&accel, &gyro, &temp);


  float accelX_ms2 = accel.acceleration.x;
  float accelY_ms2 = accel.acceleration.y;
  float accelZ_ms2 = accel.acceleration.z;

  float accelX_g = accelX_ms2 / GRAVITY;
  float accelY_g = accelY_ms2 / GRAVITY;
  float accelZ_g = accelZ_ms2 / GRAVITY;

  float gyroX_rad = gyro.gyro.x;
  float gyroY_rad = gyro.gyro.y;
  float gyroZ_rad = gyro.gyro.z;

  float gyroX_deg = gyroX_rad * RAD_TO_DEGREE;
  float gyroY_deg = gyroY_rad * RAD_TO_DEGREE;
  float gyroZ_deg = gyroZ_rad * RAD_TO_DEGREE;


  Serial.println("--- ACCELEROMETER ---");

  Serial.print("X = ");
  Serial.print(accelX_ms2, 3);
  Serial.print(" m/s^2");
  Serial.print("    ");
  Serial.print(accelX_g, 3);
  Serial.println(" g");

  Serial.print("Y = ");
  Serial.print(accelY_ms2, 3);
  Serial.print(" m/s^2");
  Serial.print("    ");
  Serial.print(accelY_g, 3);
  Serial.println(" g");

  Serial.print("Z = ");
  Serial.print(accelZ_ms2, 3);
  Serial.print(" m/s^2");
  Serial.print("    ");
  Serial.print(accelZ_g, 3);
  Serial.println(" g");

  Serial.println("--- GYROSCOPE ---");

  Serial.print("X = ");
  Serial.print(gyroX_rad, 3);
  Serial.print(" rad/s");
  Serial.print("    ");
  Serial.print(gyroX_deg, 3);
  Serial.println(" deg/s");

  Serial.print("Y = ");
  Serial.print(gyroY_rad, 3);
  Serial.print(" rad/s");
  Serial.print("    ");
  Serial.print(gyroY_deg, 3);
  Serial.println(" deg/s");

  Serial.print("Z = ");
  Serial.print(gyroZ_rad, 3);
  Serial.print(" rad/s");
  Serial.print("    ");
  Serial.print(gyroZ_deg, 3);
  Serial.println(" deg/s");

  Serial.println("--- TEMPERATURE ---");

  Serial.print("Temperature = ");
  Serial.print(temp.temperature, 2);
  Serial.println(" C");

  delay(100); // Sample approximately 10 times per second
}