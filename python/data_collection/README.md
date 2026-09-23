# Data collection

Use `serial_monitor.py` to check the ESP-WROOM-32 serial connection before
recording data. It expects this 9-axis IMU format at 115200 baud:

```text
ax,ay,az,gx,gy,gz,mx,my,mz
```

Run it from the repository root:

```bash
python python/data_collection/serial_monitor.py
```

Record the sample rate, sensor position, activity label, and test conditions
when saving labeled activity recordings.
