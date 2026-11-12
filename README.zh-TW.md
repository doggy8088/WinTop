# WinTop — Windows 專屬的 PowerShell 互動式 `top` 系統監控儀表板

[![PowerShell Gallery Version](https://img.shields.io/powershellgallery/v/WinTop?logo=powershell)](https://www.powershellgallery.com/packages/WinTop)
[![PowerShell Gallery Downloads](https://img.shields.io/powershellgallery/dt/WinTop?logo=powershell)](https://www.powershellgallery.com/packages/WinTop)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

[English](README.md) | 繁體中文

**WinTop** 為 Windows（支援 Windows PowerShell 5.1 與 PowerShell 7+）提供無閃爍、全螢幕自適應的終端機圖形化 (TUI) 即時監控體驗。

安裝完成後，只要在任何 PowerShell 視窗輸入 **`top`** 即可立即啟動！

---

## 功能特色

- **內建 `top` 與 `wintop` 指令別名**：透過 PowerShell 模組自動載入機制，安裝後無須手動設定 `PATH` 即可直接輸入 `top` 執行。
- **全螢幕響應式版面 (Responsive TUI)**：自動偵測並填滿終端機 100% 寬度與高度，完美相容 Windows Terminal (ConPTY) 並支援執行中即時縮放視窗。
- **最近 5 分鐘多列高解析度趨勢圖**：結合多列高度與 8 階方塊字元 (`▁▂▃▄▅▆▇█`)，即時繪製 CPU 使用率 (%)、運作頻率 (MHz 與 Turbo 狀態)、記憶體使用率 (%) 與 CPU 溫度 (°C) 歷史曲線。
- **極速原生取樣 (<30ms)**：底層採用 Win32 `CreateToolhelp32Snapshot`、`GetProcessTimes`、`GlobalMemoryStatusEx` 與 `.NET PerformanceCounter`，低資源耗用且鍵盤快捷鍵即時反應。
- **即時熱門處理程序表 (Top Processes)**：顯示各程序 PID、CPU%、迷你負載條、記憶體耗用 (MB / %) 與執行緒數，支援依 CPU 或記憶體排序。
- **中/英文雙語介面自動偵測**：依系統語系自動切換繁體中文 (`zh-TW`) 或英文 (`en`)，亦可在執行中按 **`L`** 鍵即時切換。

---

## 安裝方式

### 使用 `PSResourceGet`（PowerShell 7.4+ 推薦）

```powershell
Install-PSResource -Name WinTop -TrustRepository
```

### 使用 `PowerShellGet`（Windows PowerShell 5.1 / PowerShell 7）

```powershell
Install-Module -Name WinTop -Scope CurrentUser
```

---

## 使用方式

在任意 PowerShell 視窗輸入 `top`（或 `wintop` / `Start-WinTop`）：

```powershell
# 啟動互動式全螢幕監控儀表板
top

# 自訂每 2 秒更新、顯示最近 10 分鐘趨勢圖、不自動最大化視窗
Start-WinTop -Interval 2 -Minutes 10 -NoMaximize

# 直接以「全程序表」模式啟動，並依記憶體排序
top -View Processes -SortBy MEM
```

### 互動快捷鍵

| 按鍵 | 功能說明 |
| :--- | :--- |
| **`Q`** / **`Esc`** / **`Ctrl+C`** | 離開 WinTop 並還原終端機游標 |
| **`1`** / **`A`** | 切換至 **綜合檢視 (Split View)**（5 分鐘趨勢圖 + 熱門處理程序） |
| **`2`** / **`C`** | 切換至 **全圖表模式 (Charts Only)** |
| **`3`** / **`P`** | 切換至 **全程序表模式 (Processes Only)** |
| **`S`** | 切換處理程序排序依據（**CPU%** / **MEM 記憶體**） |
| **`L`** | 即時切換 **繁體中文** / **英文** 介面 |

---

## 在虛擬機器中執行 (Hyper-V 等)

許多虛擬化平台（尤其是 Hyper-V 客體）不會提供 `% Processor Utility` / `% Processor Performance` 背後所需的 CPU 計數器，導致數值永遠為 `0`。WinTop 會自動偵測並改用替代來源：

- **CPU 使用率**：改用作業系統的 kernel / user / idle 時間 (`GetSystemTimes`) 計算。
- **CPU 頻率**：改用作業系統電源管理員回報的頻率並標示 **`[OS]`**；若仍無法取得，則顯示基本頻率並標示 **`[Est]`**。虛擬機器客體通常看不到 Turbo 或 P-state 變化，因此該數值多半固定不變。

---

## 授權條款

本專案採用 [MIT License](LICENSE) 授權。Copyright (c) 2026 Will 保哥.
