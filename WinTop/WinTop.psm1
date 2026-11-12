#Requires -Version 5.1

# Compile Win32 native helpers once per session for ultra-fast (<20ms) process, memory, and window queries
if (-not ('WinTop.NativeHelper' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace WinTop {
    public struct ProcSample {
        public int Pid;
        public string Name;
        public long CpuTicks100ns;
        public long WorkingSetBytes;
        public uint Threads;
    }

    public struct MemInfo {
        public ulong TotalPhysBytes;
        public ulong AvailPhysBytes;
        public uint MemoryLoadPct;
    }

    // System-wide CPU times in 100ns units (as returned by GetSystemTimes). Kernel INCLUDES Idle.
    public struct CpuTimes {
        public long Idle;
        public long Kernel;
        public long User;
    }

    public static class NativeHelper {
        [StructLayout(LayoutKind.Sequential)]
        public struct RECT {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        private class MEMORYSTATUSEX {
            public uint dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
            public uint dwMemoryLoad;
            public ulong ullTotalPhys;
            public ulong ullAvailPhys;
            public ulong ullTotalPageFile;
            public ulong ullAvailPageFile;
            public ulong ullTotalVirtual;
            public ulong ullAvailVirtual;
            public ulong ullAvailExtendedVirtual;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct PROCESSENTRY32W {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID;
            public uint cntThreads;
            public uint th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string szExeFile;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_MEMORY_COUNTERS {
            public uint cb;
            public uint PageFaultCount;
            public UIntPtr PeakWorkingSetSize;
            public UIntPtr WorkingSetSize;
            public UIntPtr QuotaPeakPagedPoolUsage;
            public UIntPtr QuotaPagedPoolUsage;
            public UIntPtr QuotaPeakNonPagedPoolUsage;
            public UIntPtr QuotaNonPagedPoolUsage;
            public UIntPtr PagefileUsage;
            public UIntPtr PeakPagefileUsage;
        }

        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")]   public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")]   public static extern bool IsZoomed(IntPtr hWnd);
        [DllImport("user32.dll")]   public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX lpBuffer);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern bool Process32FirstW(IntPtr hSnapshot, ref PROCESSENTRY32W lppe);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern bool Process32NextW(IntPtr hSnapshot, ref PROCESSENTRY32W lppe);
        [DllImport("kernel32.dll")]
        private static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll")]
        private static extern bool GetProcessTimes(IntPtr hProcess, out long creation, out long exit, out long kernel, out long user);
        [DllImport("psapi.dll")]
        private static extern bool GetProcessMemoryInfo(IntPtr hProcess, out PROCESS_MEMORY_COUNTERS counters, uint size);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
        [DllImport("powrprof.dll")]
        private static extern uint CallNtPowerInformation(int informationLevel, IntPtr inputBuffer, uint inputBufferLength, IntPtr outputBuffer, uint outputBufferLength);

        // Whole-system CPU times. Works on every Windows guest/host, unlike the "% Processor Utility"
        // performance counter which needs APERF/MPERF MSRs that Hyper-V guests commonly do not expose.
        public static CpuTimes GetCpuTimes() {
            var t = new CpuTimes();
            long idle, kernel, user;
            if (GetSystemTimes(out idle, out kernel, out user)) {
                t.Idle = idle;
                t.Kernel = kernel;
                t.User = user;
            }
            return t;
        }

        // Average current clock (MHz) across logical processors as reported by the OS power manager
        // (ProcessorInformation, level 11). Returns 0 when unavailable.
        public static int GetProcessorCurrentMhz() {
            const int ProcessorInformation = 11;
            const int EntrySize = 24; // PROCESSOR_POWER_INFORMATION: 6 x ULONG
            int count = Environment.ProcessorCount;
            if (count < 1) return 0;
            IntPtr buf = Marshal.AllocHGlobal(count * EntrySize);
            try {
                if (CallNtPowerInformation(ProcessorInformation, IntPtr.Zero, 0, buf, (uint)(count * EntrySize)) != 0) return 0;
                long sum = 0;
                int n = 0;
                for (int i = 0; i < count; i++) {
                    int cur = Marshal.ReadInt32(buf, i * EntrySize + 8); // CurrentMhz
                    if (cur > 0) { sum += cur; n++; }
                }
                return n > 0 ? (int)(sum / n) : 0;
            } finally {
                Marshal.FreeHGlobal(buf);
            }
        }

        public static MemInfo GetMemoryStatus() {
            var m = new MEMORYSTATUSEX();
            if (GlobalMemoryStatusEx(m)) {
                return new MemInfo {
                    TotalPhysBytes = m.ullTotalPhys,
                    AvailPhysBytes = m.ullAvailPhys,
                    MemoryLoadPct  = m.dwMemoryLoad
                };
            }
            return new MemInfo();
        }

        public static List<ProcSample> GetProcessSnapshot() {
            var list = new List<ProcSample>(256);
            IntPtr snap = CreateToolhelp32Snapshot(0x00000002, 0);
            if (snap == IntPtr.Zero || snap == new IntPtr(-1)) return list;
            try {
                var pe = new PROCESSENTRY32W();
                pe.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
                if (!Process32FirstW(snap, ref pe)) return list;
                uint pmcSize = (uint)Marshal.SizeOf(typeof(PROCESS_MEMORY_COUNTERS));
                do {
                    if (pe.th32ProcessID == 0) continue; // Skip System Idle Process
                    string exeName = pe.szExeFile ?? "";
                    if (exeName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) {
                        exeName = exeName.Substring(0, exeName.Length - 4);
                    }
                    var s = new ProcSample {
                        Pid = (int)pe.th32ProcessID,
                        Name = exeName,
                        Threads = pe.cntThreads
                    };
                    IntPtr hp = OpenProcess(0x1000, false, pe.th32ProcessID); // PROCESS_QUERY_LIMITED_INFORMATION
                    if (hp != IntPtr.Zero) {
                        long c, e, k, u;
                        if (GetProcessTimes(hp, out c, out e, out k, out u)) {
                            s.CpuTicks100ns = k + u;
                        }
                        PROCESS_MEMORY_COUNTERS pmc;
                        pmc.cb = pmcSize;
                        if (GetProcessMemoryInfo(hp, out pmc, pmcSize)) {
                            s.WorkingSetBytes = (long)pmc.WorkingSetSize.ToUInt64();
                        }
                        CloseHandle(hp);
                    }
                    list.Add(s);
                } while (Process32NextW(snap, ref pe));
            } finally {
                CloseHandle(snap);
            }
            return list;
        }
    }
}
'@ -ErrorAction SilentlyContinue
}

function Get-WinTopStrings {
    param([string]$Lang)
    if ($Lang -eq 'zh-TW') {
        return @{
            Title        = 'WinTop 系統即時監控儀表板'
            Time         = '時間'
            Sample       = '取樣'
            Window       = '視窗'
            CPU          = '處理器'
            BaseClock    = '基本頻率'
            Cores        = '核'
            Threads      = '緒'
            UsageLbl     = 'CPU 使用率:'
            ClockLbl     = 'CPU 頻  率:'
            MemLbl       = '記憶體使用:'
            TempLbl      = 'CPU 溫  度:'
            LimitLbl     = '散熱降頻限:'
            NormalTag    = '[正常] '
            ThrottleTag  = '[降頻!]'
            ChartSection = '最近 {0} 分鐘趨勢圖 ({1}s 視窗, 寬度 {2} 格, 每格 = {3}s)'
            ChartUsage   = 'CPU 使用率 (%)'
            ChartClock   = 'CPU 運作頻率 (MHz)'
            ChartMem     = '記憶體使用率 (%)'
            ChartTemp    = 'CPU 溫度 ({0})'
            ChartLimit   = '散熱被動降頻限制 (%)'
            TurboHint    = '紫=Turbo > {0}MHz'
            ClockOsHint  = '系統回報頻率 (無 Turbo 計數器)'
            ClockEstHint = '推估值: 僅基本頻率'
            ProcSection  = '熱門處理程序 (共 {0} 個程序 | 排序: {1})'
            ProcHeader   = '    PID  程序名稱                      CPU%   CPU 負載條        記憶體 (MB)    MEM%   執行緒'
            Hotkeys      = '快捷鍵: [Q/Esc]離開  [1/A]綜合檢視  [2/C]全圖表  [3/P]全程序表  [S]切換排序(CPU/MEM)  [L]中/英切換'
            ViewSplit    = '綜合'
            ViewCharts   = '圖表'
            ViewProcs    = '程序'
        }
    } else {
        return @{
            Title        = 'WinTop System Monitor'
            Time         = 'Time'
            Sample       = 'Tick'
            Window       = 'Span'
            CPU          = 'CPU'
            BaseClock    = 'Base'
            Cores        = 'C'
            Threads      = 'T'
            UsageLbl     = 'CPU Usage :'
            ClockLbl     = 'CPU Clock :'
            MemLbl       = 'Memory    :'
            TempLbl      = 'CPU Temp  :'
            LimitLbl     = 'Therm Lim :'
            NormalTag    = '[OK]   '
            ThrottleTag  = '[THROT]'
            ChartSection = 'Recent {0}-Min Trend Charts ({1}s window, {2} cols, {3}s/col)'
            ChartUsage   = 'CPU Usage (%)'
            ChartClock   = 'CPU Clock Speed (MHz)'
            ChartMem     = 'Memory Usage (%)'
            ChartTemp    = 'CPU Temperature ({0})'
            ChartLimit   = 'Thermal Passive Limit (%)'
            TurboHint    = 'Magenta=Turbo > {0}MHz'
            ClockOsHint  = 'OS-reported clock, no Turbo counter'
            ClockEstHint = 'estimated: base clock only'
            ProcSection  = 'Top Processes ({0} total | Sort by: {1})'
            ProcHeader   = '    PID  Process Name                  CPU%   CPU Bar           Memory (MB)    MEM%   Threads'
            Hotkeys      = 'Keys: [Q/Esc]Quit  [1/A]Split View  [2/C]Charts Only  [3/P]Processes Only  [S]Sort(CPU/MEM)  [L]Lang'
            ViewSplit    = 'Split'
            ViewCharts   = 'Charts'
            ViewProcs    = 'Procs'
        }
    }
}

function Get-DisplayWidth {
    param([string]$Text)
    $clean = $Text -replace '\x1b\[[0-9;]*[a-zA-Z]', ''
    $w = 0
    foreach ($ch in $clean.ToCharArray()) {
        $code = [int]$ch
        if (($code -ge 0x2E80 -and $code -le 0x9FFF) -or
            ($code -ge 0xF900 -and $code -le 0xFAFF) -or
            ($code -ge 0xFF01 -and $code -le 0xFF60)) {
            $w += 2
        } else {
            $w += 1
        }
    }
    return $w
}

# Busy-time percentage between two NativeHelper.GetCpuTimes() samples (Kernel already includes Idle).
# Returns $null when no time elapsed between the samples.
function Get-WinTopCpuLoad {
    param($Prev, $Cur)
    $total = ($Cur.Kernel - $Prev.Kernel) + ($Cur.User - $Prev.User)
    if ($total -le 0) { return $null }
    $idle = $Cur.Idle - $Prev.Idle
    return [math]::Max(0.0, [math]::Min(100.0, (1.0 - ($idle / [double]$total)) * 100.0))
}

# Picks the CPU usage source. "% Processor Utility" is preferred (matches Task Manager), but Hyper-V guests and
# some other VMs expose the counter yet leave it at 0 forever. When the counter is missing, or keeps reading 0
# while the OS clearly reports activity for 3 consecutive samples, switch to the GetSystemTimes-based load.
# $State is a caller-owned hashtable: @{ Streak = 0; UseSystem = $false }.
function Resolve-WinTopCpuUsage {
    param(
        [AllowNull()][object]$CounterValue,
        [AllowNull()][object]$SystemValue,
        [Parameter(Mandatory)][hashtable]$State
    )
    if ($null -eq $CounterValue) { $State.UseSystem = $true }
    if (-not $State.UseSystem -and $null -ne $SystemValue -and [double]$CounterValue -le 0.0 -and [double]$SystemValue -ge 1.0) {
        $State.Streak++
        if ($State.Streak -ge 3) { $State.UseSystem = $true }
        return [math]::Max(0.0, [math]::Min(100.0, [double]$SystemValue))
    }
    if ($State.UseSystem) {
        $v = if ($null -ne $SystemValue) { $SystemValue } elseif ($null -ne $CounterValue) { $CounterValue } else { 0.0 }
        return [math]::Max(0.0, [math]::Min(100.0, [double]$v))
    }
    $State.Streak = 0
    return [math]::Max(0.0, [math]::Min(100.0, [double]$CounterValue))
}

# Picks the CPU clock source: the "% Processor Performance" counter (scaled from the base clock, can exceed 100
# for Turbo) -> the OS power manager's CurrentMhz (VMs without APERF/MPERF) -> the base clock as a last resort.
function Resolve-WinTopClock {
    param(
        [double]$Perf,
        [double]$BaseMHz,
        [double]$OsMHz
    )
    if ($Perf -gt 0) {
        return [PSCustomObject]@{ Source = 'Counter'; MHz = [math]::Round($BaseMHz * $Perf / 100.0); Perf = $Perf }
    }
    if ($OsMHz -gt 0) {
        return [PSCustomObject]@{ Source = 'OS'; MHz = [math]::Round($OsMHz); Perf = $OsMHz * 100.0 / $BaseMHz }
    }
    return [PSCustomObject]@{ Source = 'Est'; MHz = [math]::Round($BaseMHz); Perf = 100.0 }
}

<#
.SYNOPSIS
    Interactive full-screen TUI system & CPU monitor ("top" for Windows) with 5-minute trend charts, thermal telemetry, memory usage, and live top processes.

.DESCRIPTION
    Start-WinTop (aliased to `top` and `wintop`) displays a flicker-free, responsive Terminal User Interface (TUI) on Windows.
    It monitors real-time CPU utility, clock frequency (including Turbo Boost), system memory, ACPI thermal zone temperature, passive thermal throttling limits, 5-minute historical multi-row charts, and top resource-consuming processes.

.PARAMETER Interval
    Refresh interval in seconds (default: 1.0). Hotkeys remain responsive (<50ms) regardless of Interval.

.PARAMETER Count
    Number of samples to collect before exiting automatically. Default is 0 (run continuously until 'q', Esc, or Ctrl+C).

.PARAMETER Minutes
    Time window in minutes for historical trend charts (default: 5).

.PARAMETER View
    Initial layout view: 'Split' (Charts + Processes, default), 'Charts' (Charts only), or 'Processes' (Processes only).

.PARAMETER SortBy
    Initial sort column for Top Processes: 'CPU' (default) or 'MEM'.

.PARAMETER Language
    UI display language: 'Auto' (detects zh-TW vs English automatically), 'en', or 'zh-TW'.

.PARAMETER NoMaximize
    Do not maximize the terminal window automatically on startup.

.EXAMPLE
    top
    Launches WinTop in interactive full-screen mode.

.EXAMPLE
    Start-WinTop -Interval 2 -Minutes 10 -Language en -NoMaximize
    Launches WinTop with a 2-second refresh interval, 10-minute chart history, English UI, without maximizing the window.
#>
function Start-WinTop {
    [CmdletBinding()]
    [Alias('top', 'wintop')]
    param(
        [ValidateRange(0.25, 3600)]
        [double]$Interval = 1.0,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$Count = 0,

        [ValidateRange(1, 120)]
        [int]$Minutes = 5,

        [ValidateSet('Split', 'Charts', 'Processes')]
        [string]$View = 'Split',

        [ValidateSet('CPU', 'MEM')]
        [string]$SortBy = 'CPU',

        [ValidateSet('Auto', 'en', 'zh-TW')]
        [string]$Language = 'Auto',

        [switch]$NoMaximize
    )

    if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
        throw "WinTop requires Windows (uses Windows Performance Counters and Win32 Process APIs)."
    }

    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    $activeLang = if ($Language -eq 'Auto') {
        if ([System.Globalization.CultureInfo]::CurrentUICulture.Name -like 'zh*') { 'zh-TW' } else { 'en' }
    } else {
        $Language
    }

    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $baseMHz = if ($cpu -and $cpu.MaxClockSpeed -gt 0) { [double]$cpu.MaxClockSpeed } else { 2500.0 }
    $cpuName = if ($cpu -and $cpu.Name) { ($cpu.Name -replace '\s+', ' ').Trim() } else { 'Windows Processor' }
    $numCores   = if ($cpu -and $cpu.NumberOfCores) { [int]$cpu.NumberOfCores } else { [Environment]::ProcessorCount }
    $numThreads = if ($cpu -and $cpu.NumberOfLogicalProcessors) { [int]$cpu.NumberOfLogicalProcessors } else { [Environment]::ProcessorCount }

    # Initialize low-overhead .NET PerformanceCounters
    $cntUtil = $null; $cntPerf = $null; $cntTemp = $null; $cntLimit = $null
    try {
        if ([System.Diagnostics.PerformanceCounterCategory]::Exists('Processor Information')) {
            $cntUtil = New-Object System.Diagnostics.PerformanceCounter('Processor Information', '% Processor Utility', '_Total', $true)
            $cntPerf = New-Object System.Diagnostics.PerformanceCounter('Processor Information', '% Processor Performance', '_Total', $true)
        } else {
            $cntUtil = New-Object System.Diagnostics.PerformanceCounter('Processor', '% Processor Time', '_Total', $true)
        }
        $null = $cntUtil.NextValue()
        if ($cntPerf) { $null = $cntPerf.NextValue() }
    } catch {}

    # Fallback CPU usage source (GetSystemTimes) for guests where the Processor Utility counter is missing or stuck at 0
    $prevCpuTimes  = [WinTop.NativeHelper]::GetCpuTimes()
    $cpuUsageState = @{ Streak = 0; UseSystem = (-not $cntUtil) }

    $hasThermal = $false
    try {
        if ([System.Diagnostics.PerformanceCounterCategory]::Exists('Thermal Zone Information')) {
            $tzCat = New-Object System.Diagnostics.PerformanceCounterCategory('Thermal Zone Information')
            $tzInst = $tzCat.GetInstanceNames() | Select-Object -First 1
            if ($tzInst) {
                $cntTemp  = New-Object System.Diagnostics.PerformanceCounter('Thermal Zone Information', 'Temperature', $tzInst, $true)
                $cntLimit = New-Object System.Diagnostics.PerformanceCounter('Thermal Zone Information', '% Passive Limit', $tzInst, $true)
                $null = $cntTemp.NextValue()
                $null = $cntLimit.NextValue()
                $hasThermal = $true
            }
        }
    } catch {}

    # Seed initial process snapshot so first frame has valid CPU% delta
    $prevProcMap = @{}
    $prevProcTime = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($ps in [WinTop.NativeHelper]::GetProcessSnapshot()) {
        $prevProcMap[$ps.Pid] = $ps.CpuTicks100ns
    }
    Start-Sleep -Milliseconds 250

    $history = New-Object System.Collections.Generic.List[PSCustomObject]
    $windowSeconds = [math]::Max(60, $Minutes * 60)

    # Box & block drawing characters
    $sparkChars = @(
        [char]0x2581, [char]0x2582, [char]0x2583, [char]0x2584,
        [char]0x2585, [char]0x2586, [char]0x2587, [char]0x2588
    )
    $blockFull   = [char]0x2588
    $blockLight  = [char]0x2591
    $arrowUp     = [char]0x25B2
    $arrowDown   = [char]0x25BC
    $arrowFlat   = [char]0x25AC
    $dotGrid     = [char]0x00B7
    $boxVLine    = [char]0x2502
    $boxHLine    = [char]0x2500
    $boxBLCorner = [char]0x2514
    $boxBRCorner = [char]0x2518
    $boxBottomT  = [char]0x2534
    $boxTL       = [char]0x2554
    $boxTR       = [char]0x2557
    $boxBL       = [char]0x255A
    $boxBR       = [char]0x255D
    $boxV        = [char]0x2551
    $boxDblH     = [char]0x2550
    $degC        = "$([char]0x00B0)C"

    # ANSI colors
    $esc      = [char]27
    $cReset   = "$esc[0m"
    $cBold    = "$esc[1m"
    $cCyan    = "$esc[96m"
    $cGreen   = "$esc[92m"
    $cYellow  = "$esc[93m"
    $cRed     = "$esc[91m"
    $cMagenta = "$esc[95m"
    $cWhite   = "$esc[97m"
    $cGray    = "$esc[90m"
    $cBgBar   = "$esc[48;5;236m"

    $getMetricColor = {
        param([double]$Val, [double]$Warn, [double]$Crit, [bool]$Invert = $false)
        if ($Invert) {
            if ($Val -le $Crit) { return $cRed }
            if ($Val -le $Warn) { return $cYellow }
            return $cGreen
        } else {
            if ($Val -ge $Crit) { return $cRed }
            if ($Val -ge $Warn) { return $cYellow }
            return $cGreen
        }
    }

    $newGaugeBar = {
        param([double]$Val, [double]$Min, [double]$Max, [int]$Width = 20, [string]$Color = $cGreen)
        $Width = [math]::Max(6, $Width)
        $ratio = if ($Max -gt $Min) { ($Val - $Min) / ($Max - $Min) } else { 0.0 }
        $ratio = [math]::Max(0.0, [math]::Min(1.0, $ratio))
        $filled = [int][math]::Round($ratio * $Width)
        $empty  = $Width - $filled
        return "${Color}$([string]::new($blockFull, $filled))${cGray}$([string]::new($blockLight, $empty))${cReset}"
    }

    $formatDelta = {
        param([double]$Cur, [double]$Prev, [string]$Fmt = '0.0', [string]$Unit = '', [bool]$HasPrev = $false)
        if (-not $HasPrev) {
            $raw = "  --     "
            return [PSCustomObject]@{ Text = "${cGray}${raw}${cReset}"; Width = $raw.Length }
        }
        $diff = $Cur - $Prev
        if ([math]::Abs($diff) -lt 0.05) {
            $raw = "${arrowFlat} 0.0${Unit}"
            return [PSCustomObject]@{ Text = "${cGray}${raw}${cReset}"; Width = $raw.Length }
        } elseif ($diff -gt 0) {
            $raw = "${arrowUp} +$($diff.ToString($Fmt))${Unit}"
            return [PSCustomObject]@{ Text = "${cYellow}${raw}${cReset}"; Width = $raw.Length }
        } else {
            $raw = "${arrowDown} $($diff.ToString($Fmt))${Unit}"
            return [PSCustomObject]@{ Text = "${cCyan}${raw}${cReset}"; Width = $raw.Length }
        }
    }

    $getStatsText = {
        param([double[]]$Vals, [string]$Fmt = '0.0', [string]$Unit = '')
        if (-not $Vals -or $Vals.Count -eq 0) { return "Min: -- | Avg: -- | Max: --" }
        $m = $Vals | Measure-Object -Minimum -Maximum -Average
        return ("Min:{0}${Unit} Avg:{1}${Unit} Max:{2}${Unit}" -f $m.Minimum.ToString($Fmt), $m.Average.ToString($Fmt), $m.Maximum.ToString($Fmt))
    }

    $getTimeBuckets = {
        param($HistList, [datetime]$NowTs, [string]$Prop, [int]$W, [double]$BktSec)
        $sums   = New-Object double[] $W
        $counts = New-Object int[] $W
        foreach ($item in $HistList) {
            $age = ($NowTs - $item.Timestamp).TotalSeconds
            $idx = $W - 1 - [int][math]::Floor($age / $BktSec)
            if ($idx -ge 0 -and $idx -lt $W) {
                $sums[$idx] += [double]$item.$Prop
                $counts[$idx]++
            }
        }
        $res = New-Object object[] $W
        for ($k = 0; $k -lt $W; $k++) {
            $res[$k] = if ($counts[$k] -gt 0) { $sums[$k] / $counts[$k] } else { $null }
        }
        return $res
    }

    $newMultiRowChart = {
        param([object[]]$Buckets, [double]$MinVal, [double]$MaxVal, [int]$Rows, [string]$LblFmt, [string]$LblUnit, [scriptblock]$ColSel, [string]$ClrLine)
        $w = $Buckets.Count
        $totalLvls = $Rows * 8
        $span = if ($MaxVal -gt $MinVal) { $MaxVal - $MinVal } else { 1.0 }
        $lvls = New-Object int[] $w
        $cols = New-Object string[] $w
        for ($c = 0; $c -lt $w; $c++) {
            $v = $Buckets[$c]
            if ($null -eq $v) {
                $lvls[$c] = -1; $cols[$c] = $cGray
            } else {
                $norm = [math]::Max(0.0, [math]::Min(1.0, ([double]$v - $MinVal) / $span))
                $lvl  = [int][math]::Round($norm * $totalLvls)
                if ([double]$v -gt $MinVal -and $lvl -eq 0) { $lvl = 1 }
                $lvls[$c] = $lvl
                $cols[$c] = & $ColSel ([double]$v)
            }
        }
        $lines = New-Object System.Collections.Generic.List[string]
        for ($r = $Rows - 1; $r -ge 0; $r--) {
            $rBase = $r * 8
            $rVal  = $MinVal + (($r + 1) / [double]$Rows) * $span
            $lbl   = "$($rVal.ToString($LblFmt))${LblUnit}"
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.AppendFormat(" {0}{1,8} {2}{3}", $cGray, $lbl, $boxVLine, $cReset)
            for ($c = 0; $c -lt $w; $c++) {
                $lvl = $lvls[$c]
                if ($lvl -lt 0 -or $lvl -le $rBase) {
                    [void]$sb.Append($cGray).Append($dotGrid)
                } elseif ($lvl -ge ($rBase + 8)) {
                    [void]$sb.Append($cols[$c]).Append($sparkChars[7])
                } else {
                    [void]$sb.Append($cols[$c]).Append($sparkChars[$lvl - $rBase - 1])
                }
            }
            [void]$sb.Append($cReset).Append($ClrLine)
            $lines.Add($sb.ToString())
        }
        return $lines
    }

    $newTimeAxis = {
        param([int]$Mins, [int]$W, [string]$ClrLine)
        $ticks = New-Object int[] 6
        for ($k = 0; $k -le 5; $k++) {
            $ticks[$k] = 1 + [int][math]::Round($k * ($W - 1) / 5.0)
        }
        $totalAxisLen = $W + 1
        $barChars = New-Object char[] $totalAxisLen
        for ($c = 0; $c -lt $totalAxisLen; $c++) { $barChars[$c] = $boxHLine }
        $barChars[0] = $boxBLCorner
        for ($k = 1; $k -lt 5; $k++) { $barChars[$ticks[$k]] = $boxBottomT }
        $barChars[$totalAxisLen - 1] = $boxBRCorner
        $axisBar = "          ${cGray}" + (-join $barChars) + "${cReset}${ClrLine}"

        $lblCanvas = New-Object char[] ($totalAxisLen + 4)
        for ($c = 0; $c -lt $lblCanvas.Length; $c++) { $lblCanvas[$c] = ' ' }
        for ($k = 0; $k -le 5; $k++) {
            $txt = if ($k -eq 5) { 'Now' } else { '-{0:0.#}m' -f ($Mins * (5 - $k) / 5.0) }
            $pos = if ($k -eq 0) { 0 } elseif ($k -eq 5) { [math]::Max(0, $totalAxisLen - $txt.Length) } else { [math]::Max(0, $ticks[$k] - 1) }
            for ($j = 0; $j -lt $txt.Length; $j++) {
                if (($pos + $j) -lt $lblCanvas.Length) { $lblCanvas[$pos + $j] = $txt[$j] }
            }
        }
        $axisLbl = "          ${cGray}" + ((-join $lblCanvas).TrimEnd()) + "${cReset}${ClrLine}"
        return @($axisBar, $axisLbl)
    }

    # Terminal cursor & safe window maximization setup
    $canControlCursor = $true
    $fHwnd = [IntPtr]::Zero
    try {
        $null = [Console]::CursorTop
        [Console]::CursorVisible = $false
        try {
            $fHwnd = [WinTop.NativeHelper]::GetForegroundWindow()
            if ($fHwnd -eq [IntPtr]::Zero) { $fHwnd = [WinTop.NativeHelper]::GetConsoleWindow() }

            if ([Console]::WindowWidth -gt 350 -or [Console]::BufferWidth -gt 350) {
                try { [Console]::SetWindowSize(80, 24); [Console]::SetBufferSize(80, 24) } catch {}
                if ($fHwnd -ne [IntPtr]::Zero) {
                    [void][WinTop.NativeHelper]::ShowWindow($fHwnd, 9)
                    Start-Sleep -Milliseconds 80
                    [void][WinTop.NativeHelper]::ShowWindow($fHwnd, 3)
                    Start-Sleep -Milliseconds 100
                }
            } elseif (-not $NoMaximize -and $fHwnd -ne [IntPtr]::Zero -and -not [WinTop.NativeHelper]::IsZoomed($fHwnd)) {
                [void][WinTop.NativeHelper]::ShowWindow($fHwnd, 3)
                Start-Sleep -Milliseconds 80
            }
        } catch {}
        Clear-Host
    } catch {
        $canControlCursor = $false
    }

    $prevUsage = 0.0; $prevMHz = 0.0; $prevMemPct = 0.0; $prevTemp = 0.0
    $hasPrev   = $false
    $lastTermW = 0; $lastTermH = 0
    $i = 0
    $forceRedraw = $false
    $quitRequested = $false

    try {
        while (-not $quitRequested) {
            $ui = Get-WinTopStrings -Lang $activeLang

            # 1. Sample CPU, Memory, Thermal counters (<10ms)
            $curCpuTimes = [WinTop.NativeHelper]::GetCpuTimes()
            $sysLoad     = Get-WinTopCpuLoad -Prev $prevCpuTimes -Cur $curCpuTimes
            $prevCpuTimes = $curCpuTimes
            $ctrUsage = if ($cntUtil) { [double]$cntUtil.NextValue() } else { $null }
            $usage    = Resolve-WinTopCpuUsage -CounterValue $ctrUsage -SystemValue $sysLoad -State $cpuUsageState

            $ctrPerf = if ($cntPerf) { [double]$cntPerf.NextValue() } else { 0.0 }
            $osMHz   = if ($ctrPerf -gt 0) { 0 } else { [WinTop.NativeHelper]::GetProcessorCurrentMhz() }
            $clock   = Resolve-WinTopClock -Perf $ctrPerf -BaseMHz $baseMHz -OsMHz $osMHz
            $perf    = $clock.Perf
            $mhz     = $clock.MHz
            $tempC = if ($hasThermal -and $cntTemp) { [math]::Max(0.0, [double]$cntTemp.NextValue() - 273.15) } else { 0.0 }
            $limit = if ($hasThermal -and $cntLimit) { [double]$cntLimit.NextValue() } else { 100.0 }

            $memStat  = [WinTop.NativeHelper]::GetMemoryStatus()
            $totalGB  = if ($memStat.TotalPhysBytes -gt 0) { $memStat.TotalPhysBytes / 1GB } else { 16.0 }
            $usedBytes = if ($memStat.TotalPhysBytes -ge $memStat.AvailPhysBytes) { $memStat.TotalPhysBytes - $memStat.AvailPhysBytes } else { 0 }
            $usedGB   = $usedBytes / 1GB
            $memPct   = if ($memStat.TotalPhysBytes -gt 0) { ($usedBytes / [double]$memStat.TotalPhysBytes) * 100.0 } else { [double]$memStat.MemoryLoadPct }

            # 2. Sample Top Processes (<20ms)
            $dtSec = [math]::Max(0.05, $prevProcTime.Elapsed.TotalSeconds)
            $prevProcTime.Restart()
            $curSnap = [WinTop.NativeHelper]::GetProcessSnapshot()
            $newProcMap = @{}
            $procRows = New-Object System.Collections.Generic.List[PSCustomObject] ($curSnap.Count)
            $totalTickScale = $dtSec * 10000000.0 * $numThreads
            foreach ($ps in $curSnap) {
                $newProcMap[$ps.Pid] = $ps.CpuTicks100ns
                $pCpu = 0.0
                if ($prevProcMap.ContainsKey($ps.Pid) -and $ps.CpuTicks100ns -ge $prevProcMap[$ps.Pid]) {
                    $pCpu = (($ps.CpuTicks100ns - $prevProcMap[$ps.Pid]) / $totalTickScale) * 100.0
                    if ($pCpu -gt 100.0) { $pCpu = 100.0 }
                }
                $pMemMB  = $ps.WorkingSetBytes / 1MB
                $pMemPct = if ($memStat.TotalPhysBytes -gt 0) { ($ps.WorkingSetBytes / [double]$memStat.TotalPhysBytes) * 100.0 } else { 0.0 }
                $procRows.Add([PSCustomObject]@{
                    Pid     = $ps.Pid
                    Name    = $ps.Name
                    CpuPct  = $pCpu
                    MemMB   = $pMemMB
                    MemPct  = $pMemPct
                    Threads = $ps.Threads
                })
            }
            $prevProcMap = $newProcMap

            $now = Get-Date
            $nowStr = $now.ToString('HH:mm:ss')

            if (-not $forceRedraw) {
                $history.Add([PSCustomObject]@{
                    Timestamp = $now
                    Usage     = $usage
                    MHz       = $mhz
                    MemPct    = $memPct
                    Temp      = $tempC
                    Limit     = $limit
                })
                $cutoff = $now.AddSeconds(-$windowSeconds)
                while ($history.Count -gt 0 -and $history[0].Timestamp -lt $cutoff) {
                    $history.RemoveAt(0)
                }
                $i++
            }
            $forceRedraw = $false

            # 3. Detect terminal viewport dimensions safely
            $termWidth  = 120
            $termHeight = 36
            if ($canControlCursor) {
                try {
                    $w = [Console]::WindowWidth
                    $h = [Console]::WindowHeight
                    if ($w -gt 350 -and $fHwnd -ne [IntPtr]::Zero) {
                        $rect = New-Object WinTop.NativeHelper+RECT
                        if ([WinTop.NativeHelper]::GetClientRect($fHwnd, [ref]$rect) -and ($rect.Right - $rect.Left) -gt 400) {
                            $w = [int][math]::Floor(($rect.Right - $rect.Left - 24) / 9.0)
                            $h = [int][math]::Floor(($rect.Bottom - $rect.Top - 48) / 19.0)
                        } else {
                            $w = 180; $h = 46
                        }
                    }
                    if ($w -gt 0) { $termWidth  = [math]::Max(80, [math]::Min(320, $w - 1)) }
                    if ($h -gt 0) { $termHeight = [math]::Max(24, [math]::Min(120, $h - 1)) }
                } catch {}
                if ($termWidth -ne $lastTermW -or $termHeight -ne $lastTermH) {
                    Clear-Host
                    $lastTermW = $termWidth
                    $lastTermH = $termHeight
                }
                [Console]::SetCursorPosition(0, 0)
            }

            $innerWidth    = $termWidth - 2
            $chartWidth    = [math]::Max(40, $termWidth - 11)
            $bucketSeconds = [double]$windowSeconds / $chartWidth
            $elapsedSec    = [int][math]::Min($windowSeconds, [math]::Round(($now - $history[0].Timestamp).TotalSeconds) + $Interval)

            # Colors & Deltas
            $colUsage = & $getMetricColor $usage 60 85 $false
            $colMHz   = if ($perf -gt 100) { $cMagenta } else { $cCyan }
            $colMem   = & $getMetricColor $memPct 70 88 $false
            $colTemp  = & $getMetricColor $tempC 70 85 $false
            $colLimit = & $getMetricColor $limit 99 80 $true

            $dltUsage = & $formatDelta $usage $prevUsage '0.0' '%' $hasPrev
            $dltMHz   = & $formatDelta $mhz $prevMHz '0' 'M' $hasPrev
            $dltMem   = & $formatDelta $memPct $prevMemPct '0.0' '%' $hasPrev
            $dltTemp  = & $formatDelta $tempC $prevTemp '0.0' $degC $hasPrev

            $stsUsage = & $getStatsText ($history | ForEach-Object { $_.Usage }) '0.0' '%'
            $stsMHz   = & $getStatsText ($history | ForEach-Object { $_.MHz }) '0' 'M'
            $stsMem   = & $getStatsText ($history | ForEach-Object { $_.MemPct }) '0.0' '%'
            $stsTemp  = & $getStatsText ($history | ForEach-Object { $_.Temp }) '0.0' $degC
            $stsLimit = & $getStatsText ($history | ForEach-Object { $_.Limit }) '0' '%'

            $maxMHzHistory = ($history | ForEach-Object { $_.MHz } | Measure-Object -Maximum).Maximum
            $maxMHzScale = [math]::Ceiling([math]::Max($baseMHz * 1.30, $maxMHzHistory) / 100.0) * 100.0
            $minMHzScale = [math]::Floor(($baseMHz * 0.25) / 100.0) * 100.0

            $gaugeWidth = [math]::Max(12, $termWidth - 82)
            $barUsage = & $newGaugeBar $usage 0 100 $gaugeWidth $colUsage
            $barMHz   = & $newGaugeBar $mhz $minMHzScale $maxMHzScale $gaugeWidth $colMHz
            $barMem   = & $newGaugeBar $memPct 0 100 $gaugeWidth $colMem
            $barTemp  = & $newGaugeBar $tempC 30 100 $gaugeWidth $colTemp

            $prevUsage = $usage; $prevMHz = $mhz; $prevMemPct = $memPct; $prevTemp = $tempC
            $hasPrev = $true

            $hr    = [string]::new($boxHLine, $termWidth - 1)
            $dblHr = [string]::new($boxDblH, $innerWidth)
            $clr   = if ($canControlCursor) { "$esc[K" } else { "" }

            $viewLabel = switch ($View) {
                'Split'     { $ui.ViewSplit }
                'Charts'    { $ui.ViewCharts }
                'Processes' { $ui.ViewProcs }
            }

            $out = New-Object System.Text.StringBuilder
            [void]$out.AppendLine("${cCyan}${cBold}${boxTL}${dblHr}${boxTR}${cReset}${clr}")

            $hdr1 = " ${cWhite}${cBold}$($ui.Title)${cReset}  ${cGray}$($ui.Time):${cReset} ${cWhite}${nowStr}${cReset} ${cGray}| $($ui.Sample):${cReset} ${cWhite}#${i}${cReset} ${cGray}| $($ui.Window):${cReset} ${cWhite}${elapsedSec}s/${windowSeconds}s${cReset} ${cGray}| [${viewLabel}] ${termWidth}x${termHeight}${cReset}"
            $hdr2 = " ${cGray}$($ui.CPU):${cReset} ${cWhite}${cpuName} ($($ui.BaseClock) ${baseMHz} MHz, ${numCores}$($ui.Cores)/${numThreads}$($ui.Threads))${cReset}"
            foreach ($hLine in @($hdr1, $hdr2)) {
                $visW = Get-DisplayWidth -Text $hLine
                $pad  = [string]::new(' ', [math]::Max(0, $innerWidth - $visW))
                [void]$out.AppendLine("${cCyan}${cBold}${boxV}${cReset}${hLine}${pad}${cCyan}${cBold}${boxV}${cReset}${clr}")
            }
            [void]$out.AppendLine("${cCyan}${cBold}${boxBL}${dblHr}${boxBR}${cReset}${clr}")

            # Top Summary Gauges
            $turboTag = switch ($clock.Source) {
                'OS'    { "${cGray}[OS]   ${cReset}" }
                'Est'   { "${cGray}[Est]  ${cReset}" }
                default { if ($perf -gt 100) { "${cMagenta}[Turbo]${cReset}" } else { "${cGray}[Base] ${cReset}" } }
            }
            $memTag   = ("{0,4:N1}/{1:N0}G" -f $usedGB, $totalGB)
            $padU = [string]::new(' ', [math]::Max(1, 10 - $dltUsage.Width))
            $padM = [string]::new(' ', [math]::Max(1, 10 - $dltMHz.Width))
            $padR = [string]::new(' ', [math]::Max(1, 10 - $dltMem.Width))
            $padT = [string]::new(' ', [math]::Max(1, 10 - $dltTemp.Width))

            [void]$out.AppendLine((" ${cBold}$($ui.UsageLbl)${cReset} ${colUsage}${cBold}{0,6:N1}%${cReset}          [{1}] {2}{3}${cGray}({4})${cReset}${clr}" -f $usage, $barUsage, $dltUsage.Text, $padU, $stsUsage))
            [void]$out.AppendLine((" ${cBold}$($ui.ClockLbl)${cReset} ${colMHz}${cBold}{0,4} MHz${cReset} {1} [{2}] {3}{4}${cGray}({5})${cReset}${clr}" -f $mhz, $turboTag, $barMHz, $dltMHz.Text, $padM, $stsMHz))
            [void]$out.AppendLine((" ${cBold}$($ui.MemLbl)${cReset} ${colMem}${cBold}{0,6:N1}%${cReset} {1,8} [{2}] {3}{4}${cGray}({5})${cReset}${clr}" -f $memPct, $memTag, $barMem, $dltMem.Text, $padR, $stsMem))
            if ($hasThermal) {
                $throtBadge = if ($limit -lt 100) { "${cRed}$($ui.ThrottleTag)${cReset}" } else { "${cGreen}$($ui.NormalTag)${cReset}" }
                [void]$out.AppendLine((" ${cBold}$($ui.TempLbl)${cReset} ${colTemp}${cBold}{0,5:N1} {1}${cReset} {2} [{3}] {4}{5}${cGray}({6})${cReset}${clr}" -f $tempC, $degC, $throtBadge, $barTemp, $dltTemp.Text, $padT, $stsTemp))
            }
            [void]$out.AppendLine("${cGray} ${hr}${cReset}${clr}")

            # Calculate remaining vertical lines (reserve 1 bottom line for Hotkey bar)
            $usedLines = 4 + $(if ($hasThermal) { 4 } else { 3 }) + 1 + 1
            $bodyLines = [math]::Max(10, $termHeight - $usedLines)

            $showCharts = ($View -eq 'Split' -or $View -eq 'Charts')
            $showProcs  = ($View -eq 'Split' -or $View -eq 'Processes')

            $chartBudget = 0
            $procBudget  = 0
            if ($View -eq 'Charts') {
                $chartBudget = $bodyLines
            } elseif ($View -eq 'Processes') {
                $procBudget = $bodyLines
            } else {
                # Split view: ~58% charts, ~42% top processes (at least 6 lines for processes)
                $procBudget  = [math]::Max(6, [int][math]::Floor($bodyLines * 0.38))
                $chartBudget = [math]::Max(9, $bodyLines - $procBudget)
            }

            if ($showCharts) {
                $bktUsage = & $getTimeBuckets $history $now 'Usage'  $chartWidth $bucketSeconds
                $bktMHz   = & $getTimeBuckets $history $now 'MHz'    $chartWidth $bucketSeconds
                $bktMem   = & $getTimeBuckets $history $now 'MemPct' $chartWidth $bucketSeconds
                $bktTemp  = & $getTimeBuckets $history $now 'Temp'   $chartWidth $bucketSeconds

                $secPerColStr = "{0:0.#}" -f $bucketSeconds
                $chartTitle = $ui.ChartSection -f $Minutes, $windowSeconds, $chartWidth, $secPerColStr
                [void]$out.AppendLine(" ${cBold}${cCyan}[${chartTitle}]${cReset}${clr}")

                $numCharts = if ($hasThermal) { 4 } else { 3 }
                # Overhead inside chart block: 1 section header + $numCharts titles + 2 time axis lines
                $availPlotRows = [math]::Max($numCharts * 2, $chartBudget - (3 + $numCharts))
                $baseRows = [math]::Max(2, [int][math]::Floor($availPlotRows / [double]$numCharts))
                $extraRows = [math]::Max(0, $availPlotRows - ($baseRows * $numCharts))

                $rUsage = $baseRows + $(if ($extraRows -ge 1) { 1 } else { 0 })
                $rMHz   = $baseRows + $(if ($extraRows -ge 2) { 1 } else { 0 })
                $rMem   = $baseRows + $(if ($extraRows -ge 3) { 1 } else { 0 })
                $rTemp  = $baseRows

                [void]$out.AppendLine(" ${cBold}1. $($ui.ChartUsage)${cReset}  ${cGray}${stsUsage}${cReset}${clr}")
                foreach ($ln in (& $newMultiRowChart $bktUsage 0 100 $rUsage '0' '%' { param($v) & $getMetricColor $v 60 85 $false } $clr)) {
                    [void]$out.AppendLine($ln)
                }

                $turboHintStr = switch ($clock.Source) {
                    'OS'    { $ui.ClockOsHint }
                    'Est'   { $ui.ClockEstHint }
                    default { $ui.TurboHint -f $baseMHz }
                }
                [void]$out.AppendLine(" ${cBold}2. $($ui.ChartClock)${cReset}  ${cGray}${stsMHz} (${turboHintStr})${cReset}${clr}")
                foreach ($ln in (& $newMultiRowChart $bktMHz $minMHzScale $maxMHzScale $rMHz '0' 'M' { param($v) if ($v -gt $baseMHz) { $cMagenta } else { $cCyan } } $clr)) {
                    [void]$out.AppendLine($ln)
                }

                [void]$out.AppendLine(" ${cBold}3. $($ui.ChartMem)${cReset}  ${cGray}${stsMem}${cReset}${clr}")
                foreach ($ln in (& $newMultiRowChart $bktMem 0 100 $rMem '0' '%' { param($v) & $getMetricColor $v 70 88 $false } $clr)) {
                    [void]$out.AppendLine($ln)
                }

                if ($hasThermal) {
                    $tempChartLbl = $ui.ChartTemp -f $degC
                    [void]$out.AppendLine(" ${cBold}4. ${tempChartLbl}${cReset}  ${cGray}${stsTemp} | Limit: ${stsLimit}${cReset}${clr}")
                    foreach ($ln in (& $newMultiRowChart $bktTemp 30 95 $rTemp '0' $degC { param($v) & $getMetricColor $v 70 85 $false } $clr)) {
                        [void]$out.AppendLine($ln)
                    }
                }

                foreach ($ln in (& $newTimeAxis $Minutes $chartWidth $clr)) {
                    [void]$out.AppendLine($ln)
                }

                if ($showProcs) {
                    [void]$out.AppendLine("${cGray} ${hr}${cReset}${clr}")
                }
            }

            if ($showProcs) {
                $maxProcItems = [math]::Max(3, $procBudget - $(if ($showCharts) { 3 } else { 2 }))
                $sortedProcs = if ($SortBy -eq 'MEM') {
                    $procRows | Sort-Object MemMB, CpuPct -Descending | Select-Object -First $maxProcItems
                } else {
                    $procRows | Sort-Object CpuPct, MemMB -Descending | Select-Object -First $maxProcItems
                }

                $sortIndicator = if ($SortBy -eq 'MEM') { "MEM $arrowDown" } else { "CPU $arrowDown" }
                $procSecTitle = $ui.ProcSection -f $curSnap.Count, $sortIndicator
                [void]$out.AppendLine(" ${cBold}${cCyan}[${procSecTitle}]${cReset}${clr}")
                [void]$out.AppendLine("${cGray}$($ui.ProcHeader)${cReset}${clr}")

                foreach ($pr in $sortedProcs) {
                    $pCol = & $getMetricColor $pr.CpuPct 25 60 $false
                    $mCol = & $getMetricColor $pr.MemPct 10 25 $false
                    $pBar = & $newGaugeBar $pr.CpuPct 0 100 14 $pCol
                    $pName = if ($pr.Name.Length -gt 26) { $pr.Name.Substring(0, 25) + '~' } else { $pr.Name }
                    [void]$out.AppendLine((" {0,6}  {1,-26} {2}{3,6:N1}%{4}  [{5}]  {6}{7,9:N1} MB{8}  {9,5:N1}%  {10,6}${clr}" -f `
                        $pr.Pid, $pName, $pCol, $pr.CpuPct, $cReset, $pBar, $mCol, $pr.MemMB, $cReset, $pr.MemPct, $pr.Threads))
                }
            }

            # Bottom status / hotkey bar
            $hkVis = Get-DisplayWidth -Text " $($ui.Hotkeys)"
            $hkPad = [string]::new(' ', [math]::Max(0, $termWidth - $hkVis))
            [void]$out.Append("${cBgBar}${cWhite} $($ui.Hotkeys)${hkPad}${cReset}${clr}")
            if ($canControlCursor) { [void]$out.Append("$esc[J") } else { [void]$out.AppendLine() }

            Write-Host $out.ToString() -NoNewline

            if ($Count -gt 0 -and $i -ge $Count) { break }

            # Interactive non-blocking sleep loop (~40ms polling for instant hotkeys)
            $waitSw = [System.Diagnostics.Stopwatch]::StartNew()
            $targetMs = [int]($Interval * 1000)
            while ($waitSw.ElapsedMilliseconds -lt $targetMs) {
                if ($canControlCursor -and [Console]::KeyAvailable) {
                    $keyInfo = [Console]::ReadKey($true)
                    $kChar = [char]::ToLowerInvariant($keyInfo.KeyChar)
                    if ($keyInfo.Key -eq [ConsoleKey]::Escape -or $kChar -eq 'q') {
                        $quitRequested = $true
                        break
                    } elseif ($kChar -eq '1' -or $kChar -eq 'a') {
                        $View = 'Split'; $forceRedraw = $true; Clear-Host; break
                    } elseif ($kChar -eq '2' -or $kChar -eq 'c') {
                        $View = 'Charts'; $forceRedraw = $true; Clear-Host; break
                    } elseif ($kChar -eq '3' -or $kChar -eq 'p') {
                        $View = 'Processes'; $forceRedraw = $true; Clear-Host; break
                    } elseif ($kChar -eq 's') {
                        $SortBy = if ($SortBy -eq 'CPU') { 'MEM' } else { 'CPU' }
                        $forceRedraw = $true; break
                    } elseif ($kChar -eq 'l') {
                        $activeLang = if ($activeLang -eq 'zh-TW') { 'en' } else { 'zh-TW' }
                        $forceRedraw = $true; Clear-Host; break
                    }
                }
                Start-Sleep -Milliseconds 40
            }
        }
    } finally {
        if ($cntUtil)  { $cntUtil.Dispose() }
        if ($cntPerf)  { $cntPerf.Dispose() }
        if ($cntTemp)  { $cntTemp.Dispose() }
        if ($cntLimit) { $cntLimit.Dispose() }
        if ($canControlCursor) {
            [Console]::CursorVisible = $true
        }
        Write-Host "$cReset"
    }
}

Set-Alias -Name top -Value Start-WinTop
Set-Alias -Name wintop -Value Start-WinTop

Export-ModuleMember -Function 'Start-WinTop' -Alias @('top', 'wintop')
