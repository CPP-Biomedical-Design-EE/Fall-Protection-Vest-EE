#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>

#define SDA_PIN 21
#define SCL_PIN 22

Adafruit_MPU6050 mpu1;
Adafruit_MPU6050 mpu2;

void setup()
{
  Serial.begin(115200);
  Wire.begin(SDA_PIN, SCL_PIN);
  if (!mpu1.begin(0x68, &Wire))
  {
    Serial.println("MPU6050 #1 not found!");

    while (1)
    {
      delay(10);
    }
  }

  Serial.println("MPU6050 #1 detected!");
  if (!mpu2.begin(0x69, &Wire))
  {
    Serial.println("MPU6050 #2 not found!");

    while (1)
    {
      delay(10);
    }
  }

  Serial.println("MPU6050 #2 detected!");

  // Sensor #1 settings
  mpu1.setAccelerometerRange(MPU6050_RANGE_8_G);
  mpu1.setGyroRange(MPU6050_RANGE_500_DEG);
  mpu1.setFilterBandwidth(MPU6050_BAND_21_HZ);

  // Sensor #2 settings
  mpu2.setAccelerometerRange(MPU6050_RANGE_8_G);
  mpu2.setGyroRange(MPU6050_RANGE_500_DEG);
  mpu2.setFilterBandwidth(MPU6050_BAND_21_HZ);

  Serial.println();
  Serial.println("Both MPU6050 sensors ready!");
  Serial.println();

  delay(1000);
}

void loop()
{

  sensors_event_t a1, g1, t1;
  sensors_event_t a2, g2, t2;

  mpu1.getEvent(&a1, &g1, &t1);

  mpu2.getEvent(&a2, &g2, &t2);

  Serial.println("            MPU6050 #1");

  Serial.println("Accelerometer:");

  Serial.print("X = ");
  Serial.print(a1.acceleration.x, 3);
  Serial.println(" m/s^2");

  Serial.print("Y = ");
  Serial.print(a1.acceleration.y, 3);
  Serial.println(" m/s^2");

  Serial.print("Z = ");
  Serial.print(a1.acceleration.z, 3);
  Serial.println(" m/s^2");

  Serial.println();

  Serial.println("Gyroscope:");

  Serial.print("X = ");
  Serial.print(g1.gyro.x, 3);
  Serial.println(" rad/s");

  Serial.print("Y = ");
  Serial.print(g1.gyro.y, 3);
  Serial.println(" rad/s");

  Serial.print("Z = ");
  Serial.print(g1.gyro.z, 3);
  Serial.println(" rad/s");

  Serial.println();

  Serial.print("Temperature = ");
  Serial.print(t1.temperature, 2);
  Serial.println(" C");

  // MPU6050 #2
  Serial.println();
  Serial.println("            MPU6050 #2");

  Serial.println("Accelerometer:");

  Serial.print("X = ");
  Serial.print(a2.acceleration.x, 3);
  Serial.println(" m/s^2");

  Serial.print("Y = ");
  Serial.print(a2.acceleration.y, 3);
  Serial.println(" m/s^2");

  Serial.print("Z = ");
  Serial.print(a2.acceleration.z, 3);
  Serial.println(" m/s^2");

  Serial.println();

  Serial.println("Gyroscope:");

  Serial.print("X = ");
  Serial.print(g2.gyro.x, 3);
  Serial.println(" rad/s");

  Serial.print("Y = ");
  Serial.print(g2.gyro.y, 3);
  Serial.println(" rad/s");

  Serial.print("Z = ");
  Serial.print(g2.gyro.z, 3);
  Serial.println(" rad/s");

  Serial.println();

  Serial.print("Temperature = ");
  Serial.print(t2.temperature, 2);
  Serial.println(" C");

  delay(500);
}