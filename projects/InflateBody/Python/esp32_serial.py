"""Open the ESP32 UART without deliberately asserting reset/boot controls."""

import serial


def open_esp32(port, baudrate=115200, timeout=1):
    # Supplying port=None delays opening until both control lines are configured.
    # Drivers can still briefly toggle these lines during open; no reset pulse
    # is intentionally sent here.
    device = serial.Serial(port=None, baudrate=baudrate, timeout=timeout)
    try:
        device.dtr = False
        device.rts = False
        device.port = port
        device.open()
    except BaseException:
        device.close()
        raise
    return device
