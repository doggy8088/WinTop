# WinTop — Interactive `top` for Windows PowerShell

[![PowerShell Gallery Version](https://img.shields.io/powershellgallery/v/WinTop?logo=powershell)](https://www.powershellgallery.com/packages/WinTop)
[![PowerShell Gallery Downloads](https://img.shields.io/powershellgallery/dt/WinTop?logo=powershell)](https://www.powershellgallery.com/packages/WinTop)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

English | [繁體中文](README.zh-TW.md)

**WinTop** brings a fast, zero-flicker, full-screen Terminal User Interface (TUI) `top` experience to Windows (PowerShell 5.1 & PowerShell 7+).

Once installed, simply type **`top`** in any PowerShell window!

---

## Features

- **`top` & `wintop` Aliases Out of the Box**: Auto-loads via `$env:PSModulePath`—no manual `PATH` configuration required.
- **Responsive Full-Screen Layout**: Automatically adapts to 100% of your terminal's width and height (including live window resizing and ConPTY / Windows Terminal support).
- **5-Minute Multi-Row Trend Charts**: High-resolution 8-level Unicode block charts (`▁▂▃▄▅▆▇█`) tracking CPU Utility %, CPU Clock Speed (MHz + Turbo Boost), Memory Usage %, and ACPI CPU Temperature (°C).
- **GPU Usage & VRAM Monitoring (NVIDIA / AMD / Intel)**: Live GPU utilization and dedicated VRAM (`used / total`) gauges plus trend charts, read from the same vendor-neutral Windows WDDM performance counters that Task Manager uses. Multiple GPUs are supported (cycle with **`G`**). The GPU rows are hidden automatically when no supported GPU is present.
- **Ultra-Fast Native Telemetry (<30ms/tick)**: Uses Win32 `CreateToolhelp32Snapshot`, `GetProcessTimes`, `GlobalMemoryStatusEx`, and `.NET PerformanceCounter` for near-zero overhead and instant hotkey response.
- **Live Top Processes Table**: Tracks per-process CPU%, CPU load bar, Working Set Memory (MB & %), and thread counts, sortable by CPU or Memory.
- **Bilingual UI (`en` / `zh-TW`)**: Automatically detects Traditional Chinese vs. English from your system UI culture, or toggle live at runtime with **`L`**.

---

## Installation

### Using `PSResourceGet` (PowerShell 7.4+ Recommended)

```powershell
Install-PSResource -Name WinTop -TrustRepository
```

### Using `PowerShellGet` (Windows PowerShell 5.1 / PowerShell 7)

```powershell
Install-Module -Name WinTop -Scope CurrentUser
```

---

## Usage

Run `top` (or `wintop` / `Start-WinTop`) in any PowerShell terminal:

```powershell
# Launch interactive full-screen TUI
top

# Custom refresh interval (2s), 10-minute chart window, English UI, without maximizing window
Start-WinTop -Interval 2 -Minutes 10 -Language en -NoMaximize

# Start directly in Processes-only view sorted by Memory
top -View Processes -SortBy MEM
```

### Interactive Hotkeys

| Key | Action |
| :--- | :--- |
| **`Q`** / **`Esc`** / **`Ctrl+C`** | Quit WinTop and restore terminal cursor |
| **`1`** / **`A`** | Switch to **Split View** (5-Min Charts + Top Processes) |
| **`2`** / **`C`** | Switch to **Charts-Only View** (Full-screen 5-minute charts) |
| **`3`** / **`P`** | Switch to **Processes-Only View** (Full-screen `top` process list) |
| **`S`** | Toggle process sort order between **CPU%** and **Memory (MEM)** |
| **`G`** | Switch the displayed GPU when more than one is installed (e.g. integrated + discrete) |
| **`L`** | Toggle UI language live between **English** and **繁體中文 (`zh-TW`)** |

---

## Requirements

- **OS**: Windows 10 / Windows 11 / Windows Server 2016+
- **PowerShell**: Windows PowerShell 5.1 or PowerShell 7+ (`pwsh`)
- **Terminal**: Windows Terminal (recommended), VS Code Integrated Terminal, or Console Host

### Running inside a virtual machine (Hyper-V, etc.)

Many hypervisors (notably Hyper-V guests) do not expose the CPU counters behind `% Processor Utility` / `% Processor Performance`, so they read a constant `0`. WinTop detects this automatically:

- **CPU usage** falls back to the OS idle-time based `% Processor Time` counter (which aggregates all processor groups) and, if that is unavailable too, to the kernel/user/idle times from `GetSystemTimes`.
- **CPU clock** falls back to the clock reported by the OS power manager, tagged **`[OS]`**; if even that is unavailable it shows the base clock tagged **`[Est]`**. VM guests usually cannot see Turbo or P-state changes, so this value is typically constant.

### GPU monitoring notes

- Needs the WDDM 2.0+ `GPU Engine` / `GPU Adapter Memory` performance counters (Windows 10 version 1709 or later with a WDDM 2.x driver). Without them the GPU rows are simply not shown.
- **GPU %** is the utilization of the adapter's busiest engine (3D, Copy, Video Decode, ...), which is what Task Manager reports as the GPU's percentage.
- **VRAM** is *dedicated* video memory (`used / total`). Like Task Manager, the *shared* memory (system RAM the GPU may borrow, `used / total`) is reported separately in the `GPU:` header line instead of guessing whether a GPU is integrated. Integrated GPUs keep most of their data in shared memory, so look there.
- The GPU rows (header line + two gauges) and the two GPU charts only appear when the terminal is tall enough to hold them on top of the normal layout, so they never push the dashboard past the bottom of the window. As a rough guide, on a machine with a thermal sensor the GPU gauges need about 28 rows in the Charts view, 36 in the Split view and 23 in the Processes view, and the GPU charts additionally need about 34 rows in the Charts view and 46 in the Split view (without a thermal sensor, 1-6 rows fewer). Maximize the window (the default) to see everything.
- Per-process GPU/VRAM statistics are not included (yet).

## License

Released under the [MIT License](LICENSE). Copyright (c) 2026 Will 保哥.
