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
| **`L`** | Toggle UI language live between **English** and **繁體中文 (`zh-TW`)** |

---

## Requirements

- **OS**: Windows 10 / Windows 11 / Windows Server 2016+
- **PowerShell**: Windows PowerShell 5.1 or PowerShell 7+ (`pwsh`)
- **Terminal**: Windows Terminal (recommended), VS Code Integrated Terminal, or Console Host

## License

Released under the [MIT License](LICENSE). Copyright (c) 2026 Will 保哥.
