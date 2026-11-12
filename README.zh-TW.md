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
- **GPU 使用率與 VRAM 監控 (NVIDIA / AMD / Intel)**：即時顯示 GPU 使用率與專用顯示記憶體 (VRAM，已用 / 總量) 的儀表與趨勢圖，資料來自 Windows 工作管理員同樣使用、不分廠牌的 WDDM 效能計數器。支援多張顯示卡 (按 **`G`** 切換)；若系統沒有支援的 GPU，相關欄位會自動隱藏。
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
| **`G`** | 安裝多張顯示卡時（例如內顯 + 獨顯）切換要顯示的 GPU |
| **`L`** | 即時切換 **繁體中文** / **英文** 介面 |

---

## GPU 監控說明

- 需要 WDDM 2.0 以上的 `GPU Engine` / `GPU Adapter Memory` 效能計數器（Windows 10 1709 以上並搭配 WDDM 2.x 驅動程式）；若不支援，GPU 欄位會直接不顯示。
- **GPU %** 為該顯示卡「最忙碌的引擎」(3D、Copy、Video Decode 等) 的使用率，與工作管理員顯示的 GPU 百分比一致。
- **VRAM** 為*專用*顯示記憶體 (已用 / 總量)。與工作管理員相同，*共用*記憶體（GPU 可借用的系統記憶體，已用 / 總量）會另外顯示在 `GPU:` 標題列，而不是自行猜測是否為內建顯示晶片。內建顯示晶片的資料多半放在共用記憶體，請看該欄位。
- GPU 欄位（標題列 + 兩條儀表）與兩張 GPU 圖表，只有在終端機高度足以在原有版面之上容納時才會顯示，因此不會把畫面擠出視窗底部。大致來說，有溫度感測器時，GPU 儀表列在全圖表模式約需 28 列、綜合檢視約需 36 列、全程序表約需 23 列；GPU 圖表則在全圖表模式約需 34 列、綜合檢視約需 46 列（沒有溫度感測器時各少 1～6 列）。將視窗最大化（預設行為）即可看到全部內容。
- 目前尚未提供「每個程序」的 GPU / VRAM 統計。

---

## 授權條款

本專案採用 [MIT License](LICENSE) 授權。Copyright (c) 2026 Will 保哥.
