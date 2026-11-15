# -*- coding: utf-8 -*-
"""探针：通过 pythonnet 直接调用 LibreHardwareMonitorLib 读取 CPU/GPU 温度。

用途：验证本机是否能在不依赖 GUI/Web 服务的前提下拿到真实温度传感器，
为 PowerFocus 的温度落盘能力选型。只读，不修改任何系统状态。
"""
import sys
import traceback

LIB_DIR = r"E:\Program Files\LibreHardwareMonitor"
sys.path.insert(0, LIB_DIR)

print("[1] 检查 pythonnet")
try:
    import clr  # noqa: F401
    print("    OK pythonnet 可用")
except Exception as exc:
    print("    FAIL 无 pythonnet:", exc)
    sys.exit(2)

print("[2] 加载 LibreHardwareMonitorLib.dll")
try:
    clr.AddReference("LibreHardwareMonitorLib")
    from LibreHardwareMonitor.Hardware import Computer, SensorType
    print("    OK 程序集已加载")
except Exception:
    traceback.print_exc()
    sys.exit(3)

print("[3] 枚举硬件")
c = Computer()
c.IsCpuEnabled = True
c.IsGpuEnabled = True
c.IsMotherboardEnabled = True
c.IsMemoryEnabled = True
c.IsStorageEnabled = False
c.IsControllerEnabled = False
c.IsNetworkEnabled = False
c.IsPsuEnabled = False
c.IsBatteryEnabled = False

try:
    c.Open()
except Exception:
    traceback.print_exc()
    print("    FAIL Open() 失败（内核驱动可能未加载）")
    sys.exit(4)

rows = []
try:
    for hw in c.Hardware:
        try:
            hw.Update()
        except Exception as exc:
            print("    WARN hw.Update:", exc)
        temps = [s for s in hw.Sensors if str(s.SensorType) == "Temperature"]
        print("  HW:", str(hw.HardwareType), "|", hw.Name, "| 温度项", len(temps))
        for s in temps:
            val = s.Value
            print("      %-34s %s" % (s.Name, "N/A" if val is None else round(float(val), 1)))
            if val is not None:
                rows.append((hw.Name, s.Name, float(val)))
        for sub in hw.SubHardware:
            try:
                sub.Update()
            except Exception:
                continue
            subtemps = [s for s in sub.Sensors if str(s.SensorType) == "Temperature"]
            for s in subtemps:
                val = s.Value
                print("      [%s] %-28s %s" % (sub.Name, s.Name, "N/A" if val is None else round(float(val), 1)))
                if val is not None:
                    rows.append((sub.Name, s.Name, float(val)))
finally:
    try:
        c.Close()
    except Exception:
        pass

print("[4] 汇总：可用温度传感器 %d 个" % len(rows))
if rows:
    hottest = max(rows, key=lambda r: r[2])
    print("    当前最高读数: %s / %s = %.1f C" % (hottest[0], hottest[1], hottest[2]))
