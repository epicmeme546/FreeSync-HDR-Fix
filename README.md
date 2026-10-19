# FreeSync HDR Fix

**Turn off AMD FreeSync Premium Pro HDR without losing FreeSync / VRR.**

On many HDR monitors, an AMD graphics card automatically switches into
*FreeSync Premium Pro* HDR mode. In that mode the **GPU does the HDR tone
mapping**, and the monitor locks you out of its own HDR controls:

- Gamma is stuck on 2.2 / BT.1886, with **ST.2084 greyed out**
- **Game HDR** (or the monitor's equivalent) is greyed out
- Games' own HDR calibration doesn't behave the way it should

The usual workaround is to delete FreeSync in CRU (Custom Resolution Utility).
That kills VRR and can cause driver problems. This script does the precise
version instead: it keeps FreeSync and VRR and removes only the Premium Pro
HDR part. Your games and your monitor go back to handling HDR themselves,
with standard HDR10 / ST.2084.

## Download

Click **Code → Download ZIP** (or grab the latest release), then extract the
folder anywhere.

## How to use

Each `.bat` file asks for administrator rights when you double-click it.

| File | What it does |
|---|---|
| `1 - Check (changes nothing).bat` | Lists monitors that have FreeSync Premium Pro and shows the refresh range that will be kept. **Run this first.** |
| `2 - Remove FreeSync Premium Pro.bat` | Applies the fix and restarts the graphics driver. Your screens go black for a few seconds. |
| `3 - Restore FreeSync Premium Pro.bat` | Undoes the fix and puts the monitor back to stock. |

After applying:

1. Keep **FreeSync enabled** in AMD Software: Adrenalin Edition.
2. Turn on **HDR** in Windows (Settings → System → Display).
3. In your monitor's menu, the VRR status should now read **FreeSync** instead
   of *FreeSync Premium Pro*, and ST.2084 gamma / Game HDR should be
   selectable.
4. Run the **Windows HDR Calibration** app and set up HDR in your games.

> **After an AMD driver update:** a driver update can bring FreeSync Premium
> Pro back. If it does, run `2 - Remove FreeSync Premium Pro.bat` again.

### Restarting the graphics driver

The script uses `restart64.exe` from [CRU](https://www.monitortests.com/forum/Thread-Custom-Resolution-Utility-CRU)
to apply the change without a reboot. It looks for a CRU folder in your
Downloads or on your Desktop, or next to the script. CRU isn't included
here. Download it from its official page, or just **restart your PC**
after running the script. Both work.

## How it works

Your monitor tells the graphics card what it supports through its EDID. The
AMD FreeSync information sits in an AMD vendor-specific data block
(OUI `00-00-1A`):

- **Version 1** of that block means plain FreeSync: VRR with a min/max refresh rate.
- **Version 2/3** adds the FreeSync Premium Pro HDR fields. That's what makes
  the driver take over tone mapping.

The script:

1. Reads each monitor's **original** EDID from the Windows registry.
2. Finds the AMD FreeSync block, and only acts if it's version 2 or higher.
3. Replaces it with a version-1 FreeSync block that has the **same refresh
   range**, then fixes the EDID checksums. Nothing else in the EDID changes.
4. Installs the result as a Windows **EDID override** (the same
   `EDID_OVERRIDE` registry mechanism CRU uses) and restarts the driver.

This is what you'd get in CRU by deleting the *FreeSync range* entry and
adding it back with the same range. The script does the same thing in one step.

### Safety

- **Check mode changes nothing.**
- Before applying, it saves the original EDID, the modified EDID and any
  existing CRU override to a `Backups` folder next to the script. You can
  load the `.bin` files into CRU's *Import* if you ever want to.
- It validates the rebuilt EDID (header, checksums, FreeSync block) and
  refuses to write anything if a check fails.
- **Restore** removes only the override this script created.
- Monitors without FreeSync Premium Pro are left alone.

## Tested on

- Samsung Odyssey OLED G8 (G85SB) with an AMD Radeon GPU:
  VRR kept, ST.2084 and Game HDR unlocked

It should work on any monitor that exposes FreeSync Premium Pro through an
AMD EDID block, but each monitor is different. Run **Check** first. If you
try it on another monitor, please open an issue with the result.

## FAQ

**Will I lose VRR?**
No. FreeSync stays on with the same refresh range. Only the Premium Pro HDR
part is removed.

**Does this flash or modify my monitor?**
No. It's a Windows-side override stored in the registry. The monitor's
firmware isn't touched, and Restore (or CRU's `reset-all.exe`) removes it.

**I already removed FreeSync with CRU. Do I need to undo that first?**
No. The script builds from the monitor's original EDID and replaces any
older override. A copy of the old one goes into `Backups`.

**Why would I want this? Isn't Premium Pro better?**
That depends on your setup. With Premium Pro, AMD's driver does the tone
mapping and the monitor's HDR options are locked. Without it, games and the
monitor control tone mapping and you get the monitor's full HDR menu. If you
prefer AMD's processing, don't use this, or run Restore.

**Command-line use**
```powershell
powershell -ExecutionPolicy Bypass -File .\FreeSyncHDRFix.ps1 -Mode Check
powershell -ExecutionPolicy Bypass -File .\FreeSyncHDRFix.ps1 -Mode Apply  [-RestartExe C:\path\to\restart64.exe]
powershell -ExecutionPolicy Bypass -File .\FreeSyncHDRFix.ps1 -Mode Revert
```

## Disclaimer

Use at your own risk. This only writes a standard EDID override to the
registry and can be fully undone, but you're changing display settings on
your own system. Not affiliated with AMD, Samsung, or the author of CRU.

## License

[MIT](LICENSE)
