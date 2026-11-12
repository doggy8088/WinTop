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

    public struct GpuAdapterInfo {
        public string Name;
        public string Key;            // lower-case "luid_0x00000000_0x0001097f": matches the GPU performance counter instance names
        public ulong DedicatedBytes;  // DXGI DedicatedVideoMemory (real VRAM on discrete GPUs, a small carve-out on integrated GPUs)
        public ulong SharedBytes;     // DXGI SharedSystemMemory
        public uint VendorId;
    }

    // Enumerates hardware GPUs through DXGI. Win32_VideoController.AdapterRAM is a uint32 and wraps at 4 GB,
    // and the performance counters expose usage but not capacity, so DXGI is the only dependable source of total VRAM.
    public static class GpuHelper {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct DXGI_ADAPTER_DESC1 {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
            public string Description;
            public uint VendorId;
            public uint DeviceId;
            public uint SubSysId;
            public uint Revision;
            public UIntPtr DedicatedVideoMemory;
            public UIntPtr DedicatedSystemMemory;
            public UIntPtr SharedSystemMemory;
            public uint LuidLow;
            public int LuidHigh;
            public uint Flags;
        }

        // COM interop does not flatten base interfaces, so IDXGIObject / IDXGIFactory / IDXGIAdapter slots are repeated in vtable order.
        [ComImport, Guid("770aae78-f26f-4dba-a829-253c83d1b387"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IDXGIFactory1 {
            [PreserveSig] int SetPrivateData(ref Guid name, uint dataSize, IntPtr data);
            [PreserveSig] int SetPrivateDataInterface(ref Guid name, [MarshalAs(UnmanagedType.IUnknown)] object unknown);
            [PreserveSig] int GetPrivateData(ref Guid name, ref uint dataSize, IntPtr data);
            [PreserveSig] int GetParent(ref Guid riid, out IntPtr parent);
            [PreserveSig] int EnumAdapters(uint index, out IntPtr adapter);
            [PreserveSig] int MakeWindowAssociation(IntPtr hwnd, uint flags);
            [PreserveSig] int GetWindowAssociation(out IntPtr hwnd);
            [PreserveSig] int CreateSwapChain(IntPtr device, IntPtr desc, out IntPtr swapChain);
            [PreserveSig] int CreateSoftwareAdapter(IntPtr module, out IntPtr adapter);
            [PreserveSig] int EnumAdapters1(uint index, [MarshalAs(UnmanagedType.Interface)] out IDXGIAdapter1 adapter);
            [PreserveSig] int IsCurrent();
        }

        [ComImport, Guid("29038f61-3839-4626-91fd-086879011a05"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IDXGIAdapter1 {
            [PreserveSig] int SetPrivateData(ref Guid name, uint dataSize, IntPtr data);
            [PreserveSig] int SetPrivateDataInterface(ref Guid name, [MarshalAs(UnmanagedType.IUnknown)] object unknown);
            [PreserveSig] int GetPrivateData(ref Guid name, ref uint dataSize, IntPtr data);
            [PreserveSig] int GetParent(ref Guid riid, out IntPtr parent);
            [PreserveSig] int EnumOutputs(uint index, out IntPtr output);
            [PreserveSig] int GetDesc(IntPtr desc);
            [PreserveSig] int CheckInterfaceSupport(ref Guid guid, out long umdVersion);
            [PreserveSig] int GetDesc1(out DXGI_ADAPTER_DESC1 desc);
        }

        [DllImport("dxgi.dll")]
        private static extern int CreateDXGIFactory1(ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IDXGIFactory1 factory);

        // Returns hardware adapters only (software adapters such as the Basic Render Driver are skipped).
        // Returns an empty list when DXGI is unavailable (e.g. Server Core).
        public static List<GpuAdapterInfo> GetAdapters() {
            var list = new List<GpuAdapterInfo>();
            IDXGIFactory1 factory = null;
            try {
                Guid iid = typeof(IDXGIFactory1).GUID;
                if (CreateDXGIFactory1(ref iid, out factory) < 0 || factory == null) return list;
                for (uint i = 0; i < 32; i++) {
                    IDXGIAdapter1 adapter;
                    if (factory.EnumAdapters1(i, out adapter) != 0 || adapter == null) break;
                    try {
                        DXGI_ADAPTER_DESC1 d;
                        if (adapter.GetDesc1(out d) < 0) continue;
                        if ((d.Flags & 2) != 0) continue; // DXGI_ADAPTER_FLAG_SOFTWARE
                        list.Add(new GpuAdapterInfo {
                            Name = d.Description,
                            Key = string.Format("luid_0x{0:x8}_0x{1:x8}", (uint)d.LuidHigh, d.LuidLow),
                            DedicatedBytes = d.DedicatedVideoMemory.ToUInt64(),
                            SharedBytes = d.SharedSystemMemory.ToUInt64(),
                            VendorId = d.VendorId
                        });
                    } finally {
                        Marshal.ReleaseComObject(adapter);
                    }
                }
            } catch (Exception) {
                // DXGI missing or misbehaving: report whatever was found so far
            } finally {
                if (factory != null) Marshal.ReleaseComObject(factory);
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
            ProcSection  = '熱門處理程序 (共 {0} 個程序 | 排序: {1})'
            ProcHeader   = '    PID  程序名稱                      CPU%   CPU 負載條        記憶體 (MB)    MEM%   執行緒'
            Hotkeys      = '快捷鍵: [Q/Esc]離開  [1/A]綜合檢視  [2/C]全圖表  [3/P]全程序表  [S]切換排序(CPU/MEM)  [L]中/英切換'
            ViewSplit    = '綜合'
            ViewCharts   = '圖表'
            ViewProcs    = '程序'
            GpuLbl       = 'GPU 使用率:'
            VramLbl      = '顯示記憶體:'
            ChartGpu     = 'GPU 使用率 (%)'
            ChartVram    = '顯示記憶體使用率 (%)'
            VramKind     = '專用'
            VramKindUma  = '共用'
            HotkeyGpu    = '  [G]切換GPU'
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
            ProcSection  = 'Top Processes ({0} total | Sort by: {1})'
            ProcHeader   = '    PID  Process Name                  CPU%   CPU Bar           Memory (MB)    MEM%   Threads'
            Hotkeys      = 'Keys: [Q/Esc]Quit  [1/A]Split View  [2/C]Charts Only  [3/P]Processes Only  [S]Sort(CPU/MEM)  [L]Lang'
            ViewSplit    = 'Split'
            ViewCharts   = 'Charts'
            ViewProcs    = 'Procs'
            GpuLbl       = 'GPU Usage :'
            VramLbl      = 'VRAM Usage:'
            ChartGpu     = 'GPU Usage (%)'
            ChartVram    = 'VRAM Usage (%)'
            VramKind     = 'VRAM'
            VramKindUma  = 'shared'
            HotkeyGpu    = '  [G]GPU'
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

# GPU telemetry uses the vendor-neutral WDDM performance counters (NVIDIA / AMD / Intel, Windows 10 1709+), the same
# source Task Manager reads: "GPU Engine" (per process+engine utilization) and "GPU Adapter Memory" (VRAM usage).

# "pid_1234_luid_0x00000000_0x0001097f_phys_0_eng_3_engtype_3d" -> Adapter 'luid_0x00000000_0x0001097f' + a per-engine key.
# Returns $null for names that do not look like GPU engine instances.
function ConvertFrom-WinTopGpuEngineName {
    param([string]$Name)
    if ($Name -match 'luid_(0x[0-9a-f]+_0x[0-9a-f]+)_phys_(\d+)_eng_(\d+)_engtype_') {
        $adapter = "luid_$($Matches[1].ToLowerInvariant())"
        return [PSCustomObject]@{ Adapter = $adapter; Engine = "${adapter}_phys$($Matches[2])_eng$($Matches[3])" }
    }
    return $null
}

# $Utilization maps GPU Engine instance name -> % of one engine used by one process. Like Task Manager, sum the
# processes sharing an engine, then report each adapter's busiest engine. Returns adapter key -> percent (0..100).
# $MetaCache memoizes parsed instance names (a $false entry means "not a GPU engine name").
function Measure-WinTopGpuUtil {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Utilization,
        [Parameter(Mandatory)][hashtable]$MetaCache
    )
    if ($MetaCache.Count -gt 5000) { $MetaCache.Clear() }   # PIDs churn; keep the cache bounded
    $engineSum = @{}
    $engineAdapter = @{}
    foreach ($name in $Utilization.Keys) {
        $meta = $MetaCache[$name]
        if ($null -eq $meta) {
            $meta = ConvertFrom-WinTopGpuEngineName -Name $name
            if ($null -eq $meta) { $meta = $false }
            $MetaCache[$name] = $meta
        }
        if ($meta -is [bool]) { continue }
        $engineSum[$meta.Engine] = [double]$engineSum[$meta.Engine] + [double]$Utilization[$name]
        $engineAdapter[$meta.Engine] = $meta.Adapter
    }
    $result = @{}
    foreach ($engine in $engineSum.Keys) {
        $adapter = $engineAdapter[$engine]
        $v = [math]::Min(100.0, $engineSum[$engine])
        if (-not $result.ContainsKey($adapter) -or $result[$adapter] -lt $v) { $result[$adapter] = $v }
    }
    return $result
}

# Reads the "GPU Engine" category once and converts the cumulative 100ns busy-time samples to percentages against the
# samples kept in $State.Prev (updated here). Instances whose raw value did not move are idle and skipped cheaply.
function Get-WinTopGpuUtilization {
    param(
        [Parameter(Mandatory)]$Category,
        [Parameter(Mandatory)][hashtable]$State
    )
    $instances = $Category.ReadCategory()['Utilization Percentage']
    $next = @{}
    $active = @{}
    if ($instances) {
        foreach ($d in $instances.Values) {
            $name = $d.InstanceName
            $cur  = $d.Sample
            $next[$name] = $cur
            $prev = $State.Prev[$name]
            if ($null -eq $prev -or $cur.RawValue -eq $prev.RawValue) { continue }
            $v = [System.Diagnostics.CounterSample]::Calculate($prev, $cur)
            if ($v -gt 0) { $active[$name] = $v }
        }
    }
    $State.Prev = $next
    return (Measure-WinTopGpuUtil -Utilization $active -MetaCache $State.Meta)
}

# "GPU Adapter Memory" usage in bytes, summed over the physical nodes of each adapter: @{ Dedicated = @{key=bytes}; Shared = @{key=bytes} }
function Get-WinTopGpuMemory {
    param([Parameter(Mandatory)]$Category)
    $data = $Category.ReadCategory()
    $dedicated = @{}
    $shared = @{}
    foreach ($pair in @(@('Dedicated Usage', $dedicated), @('Shared Usage', $shared))) {
        $col = $data[$pair[0]]
        if (-not $col) { continue }
        foreach ($d in $col.Values) {
            $key = $d.InstanceName.ToLowerInvariant() -replace '_phys_\d+$', ''
            $pair[1][$key] = [double]$pair[1][$key] + [double]$d.Sample.RawValue
        }
    }
    return @{ Dedicated = $dedicated; Shared = $shared }
}

# Hardware GPUs sorted discrete-first (largest dedicated memory first). Integrated GPUs (little dedicated memory) use
# system RAM, so for those the "VRAM" figure is dedicated + shared. Names/capacity come from DXGI; if DXGI is
# unavailable the adapters seen in the counters are listed as "GPU n" with unknown (0) capacity.
function Get-WinTopGpuAdapterList {
    param([Parameter(Mandatory)]$MemoryCategory)
    $counterKeys = @{}
    foreach ($n in $MemoryCategory.GetInstanceNames()) {
        $counterKeys[($n.ToLowerInvariant() -replace '_phys_\d+$', '')] = $true
    }
    $list = New-Object System.Collections.Generic.List[PSCustomObject]
    $idx = 0
    foreach ($a in [WinTop.GpuHelper]::GetAdapters()) {
        if ($counterKeys.Count -gt 0 -and -not $counterKeys.ContainsKey($a.Key)) { continue }
        $name = ([string]$a.Name -replace '[\x00-\x1F\x7F]', '' -replace '\s+', ' ').Trim()
        if (-not $name) { $name = "GPU $idx" }
        $uma = $a.DedicatedBytes -lt 1GB
        $list.Add([PSCustomObject]@{
            Index      = $idx++
            Name       = $name
            Key        = $a.Key
            Uma        = $uma
            TotalBytes = [double]$(if ($uma) { $a.DedicatedBytes + $a.SharedBytes } else { $a.DedicatedBytes })
        })
    }
    if ($list.Count -eq 0) {
        foreach ($key in ($counterKeys.Keys | Sort-Object)) {
            $list.Add([PSCustomObject]@{ Index = $idx; Name = "GPU $idx"; Key = $key; Uma = $false; TotalBytes = 0.0 })
            $idx++
        }
    }
    return @($list | Sort-Object @{ Expression = { $_.Uma } }, @{ Expression = { $_.TotalBytes }; Descending = $true }, Index)
}

# One sample for every adapter: adapter key -> @{ Util (%), UsedBytes, TotalBytes, VramPct (%) }
function Get-WinTopGpuSnapshot {
    param(
        [Parameter(Mandatory)]$Adapters,
        [Parameter(Mandatory)]$EngineCategory,
        [Parameter(Mandatory)]$MemoryCategory,
        [Parameter(Mandatory)][hashtable]$State
    )
    $util = Get-WinTopGpuUtilization -Category $EngineCategory -State $State
    $mem  = Get-WinTopGpuMemory -Category $MemoryCategory
    $snapshot = @{}
    foreach ($a in $Adapters) {
        $u  = if ($util.ContainsKey($a.Key)) { [double]$util[$a.Key] } else { 0.0 }
        $ded = [double]$mem.Dedicated[$a.Key]
        $shr = [double]$mem.Shared[$a.Key]
        $used = if ($a.Uma) { $ded + $shr } else { $ded }
        $pct  = if ($a.TotalBytes -gt 0) { [math]::Max(0.0, [math]::Min(100.0, $used / $a.TotalBytes * 100.0)) } else { 0.0 }
        $snapshot[$a.Key] = [PSCustomObject]@{ Util = $u; UsedBytes = $used; TotalBytes = $a.TotalBytes; VramPct = $pct }
    }
    return $snapshot
}

<#
.SYNOPSIS
    Interactive full-screen TUI system & CPU monitor ("top" for Windows) with 5-minute trend charts, thermal telemetry, memory usage, and live top processes.

.DESCRIPTION
    Start-WinTop (aliased to `top` and `wintop`) displays a flicker-free, responsive Terminal User Interface (TUI) on Windows.
    It monitors real-time CPU utility, clock frequency (including Turbo Boost), system memory, ACPI thermal zone temperature, passive thermal throttling limits, GPU utilization and dedicated VRAM (any vendor, via the WDDM performance counters; press G to switch between multiple GPUs), 5-minute historical multi-row charts, and top resource-consuming processes.

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

    # GPU telemetry: hidden entirely when the WDDM counters or DXGI adapters are unavailable (VMs, old Windows, Server Core)
    $hasGpu      = $false
    $gpuEngCat   = $null
    $gpuMemCat   = $null
    $gpuAdapters = @()
    $gpuState    = @{ Prev = @{}; Meta = @{} }
    $gpuHist     = @{}
    $gpuNow      = @{}
    $gpuPrevVals = @{}
    $gpuDeltas   = @{}
    $gpuSel      = 0
    try {
        if ([System.Diagnostics.PerformanceCounterCategory]::Exists('GPU Engine') -and
            [System.Diagnostics.PerformanceCounterCategory]::Exists('GPU Adapter Memory')) {
            $gpuEngCat   = New-Object System.Diagnostics.PerformanceCounterCategory('GPU Engine')
            $gpuMemCat   = New-Object System.Diagnostics.PerformanceCounterCategory('GPU Adapter Memory')
            $gpuAdapters = @(Get-WinTopGpuAdapterList -MemoryCategory $gpuMemCat)
            if ($gpuAdapters.Count -gt 0) {
                $null = Get-WinTopGpuUtilization -Category $gpuEngCat -State $gpuState   # prime the "previous" samples
                foreach ($ga in $gpuAdapters) { $gpuHist[$ga.Key] = New-Object System.Collections.Generic.List[PSCustomObject] }
                $hasGpu = $true
            }
        }
    } catch { $hasGpu = $false }

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
            $usage = if ($cntUtil) { [math]::Max(0.0, [math]::Min(100.0, [double]$cntUtil.NextValue())) } else { 0.0 }
            $perf  = if ($cntPerf) { [double]$cntPerf.NextValue() } else { $usage }
            $mhz   = [math]::Round($baseMHz * $perf / 100.0)
            $tempC = if ($hasThermal -and $cntTemp) { [math]::Max(0.0, [double]$cntTemp.NextValue() - 273.15) } else { 0.0 }
            $limit = if ($hasThermal -and $cntLimit) { [double]$cntLimit.NextValue() } else { 100.0 }

            $memStat  = [WinTop.NativeHelper]::GetMemoryStatus()
            $totalGB  = if ($memStat.TotalPhysBytes -gt 0) { $memStat.TotalPhysBytes / 1GB } else { 16.0 }
            $usedBytes = if ($memStat.TotalPhysBytes -ge $memStat.AvailPhysBytes) { $memStat.TotalPhysBytes - $memStat.AvailPhysBytes } else { 0 }
            $usedGB   = $usedBytes / 1GB
            $memPct   = if ($memStat.TotalPhysBytes -gt 0) { ($usedBytes / [double]$memStat.TotalPhysBytes) * 100.0 } else { [double]$memStat.MemoryLoadPct }

            # GPU: sampled once per real tick (a hotkey-triggered redraw reuses the previous values)
            if ($hasGpu -and -not $forceRedraw) {
                try {
                    $gpuNow = Get-WinTopGpuSnapshot -Adapters $gpuAdapters -EngineCategory $gpuEngCat -MemoryCategory $gpuMemCat -State $gpuState
                } catch {
                    # A transient counter read failure keeps the last known values instead of killing the monitor
                    Write-Verbose "GPU sampling failed: $($_.Exception.Message)"
                }
            }

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
                if ($hasGpu) {
                    foreach ($ga in $gpuAdapters) {
                        $gs = $gpuNow[$ga.Key]
                        if ($null -eq $gs) { continue }
                        $gh = $gpuHist[$ga.Key]
                        $gh.Add([PSCustomObject]@{ Timestamp = $now; Util = $gs.Util; VramPct = $gs.VramPct })
                        while ($gh.Count -gt 0 -and $gh[0].Timestamp -lt $cutoff) { $gh.RemoveAt(0) }
                        $gpv = $gpuPrevVals[$ga.Key]
                        $gpvUtil = if ($gpv) { $gpv.Util } else { 0.0 }
                        $gpvVram = if ($gpv) { $gpv.VramPct } else { 0.0 }
                        $gpuDeltas[$ga.Key] = @{
                            Util = (& $formatDelta $gs.Util $gpvUtil '0.0' '%' ($null -ne $gpv))
                            Vram = (& $formatDelta $gs.VramPct $gpvVram '0.0' '%' ($null -ne $gpv))
                        }
                        $gpuPrevVals[$ga.Key] = @{ Util = $gs.Util; VramPct = $gs.VramPct }
                    }
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

            # Selected GPU (G cycles through adapters when there is more than one)
            $showGpu = $false
            if ($hasGpu -and $gpuNow.ContainsKey($gpuAdapters[$gpuSel].Key) -and $gpuDeltas.ContainsKey($gpuAdapters[$gpuSel].Key)) {
                $showGpu  = $true
                $gAd      = $gpuAdapters[$gpuSel]
                $gNow     = $gpuNow[$gAd.Key]
                $gHist    = $gpuHist[$gAd.Key]
                $colGpu   = & $getMetricColor $gNow.Util 60 85 $false
                $colVram  = & $getMetricColor $gNow.VramPct 70 88 $false
                $dltGpu   = $gpuDeltas[$gAd.Key].Util
                $dltVram  = $gpuDeltas[$gAd.Key].Vram
                $stsGpu   = & $getStatsText ($gHist | ForEach-Object { $_.Util }) '0.0' '%'
                $stsVram  = & $getStatsText ($gHist | ForEach-Object { $_.VramPct }) '0.0' '%'
                $barGpu   = & $newGaugeBar $gNow.Util 0 100 $gaugeWidth $colGpu
                $barVram  = & $newGaugeBar $gNow.VramPct 0 100 $gaugeWidth $colVram
                $padGU    = [string]::new(' ', [math]::Max(1, 10 - $dltGpu.Width))
                $padGV    = [string]::new(' ', [math]::Max(1, 10 - $dltVram.Width))
                $vramTag  = if ($gNow.TotalBytes -gt 0) { "{0,4:N1}/{1:N0}G" -f ($gNow.UsedBytes / 1GB), ($gNow.TotalBytes / 1GB) } else { 'N/A' }
                $vramCap  = if ($gNow.TotalBytes -ge 1GB) { "{0:N0}G" -f ($gNow.TotalBytes / 1GB) } elseif ($gNow.TotalBytes -gt 0) { "{0:N0}M" -f ($gNow.TotalBytes / 1MB) } else { 'N/A' }
                $vramKind = if ($gAd.Uma) { $ui.VramKindUma } else { $ui.VramKind }
            }

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
            $hdrLines = @($hdr1, $hdr2)
            if ($showGpu) {
                $gpuMulti = if ($gpuAdapters.Count -gt 1) { "  ${cGray}[$($gpuSel + 1)/$($gpuAdapters.Count)]${cReset}" } else { '' }
                $hdrLines += " ${cGray}GPU:${cReset} ${cWhite}$($gAd.Name) (${vramCap} ${vramKind})${cReset}${gpuMulti}"
            }
            foreach ($hLine in $hdrLines) {
                $visW = Get-DisplayWidth -Text $hLine
                $pad  = [string]::new(' ', [math]::Max(0, $innerWidth - $visW))
                [void]$out.AppendLine("${cCyan}${cBold}${boxV}${cReset}${hLine}${pad}${cCyan}${cBold}${boxV}${cReset}${clr}")
            }
            [void]$out.AppendLine("${cCyan}${cBold}${boxBL}${dblHr}${boxBR}${cReset}${clr}")

            # Top Summary Gauges
            $turboTag = if ($perf -gt 100) { "${cMagenta}[Turbo]${cReset}" } else { "${cGray}[Base] ${cReset}" }
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
            if ($showGpu) {
                [void]$out.AppendLine((" ${cBold}$($ui.GpuLbl)${cReset} ${colGpu}${cBold}{0,6:N1}%${cReset}          [{1}] {2}{3}${cGray}({4})${cReset}${clr}" -f $gNow.Util, $barGpu, $dltGpu.Text, $padGU, $stsGpu))
                [void]$out.AppendLine((" ${cBold}$($ui.VramLbl)${cReset} ${colVram}${cBold}{0,6:N1}%${cReset} {1,8} [{2}] {3}{4}${cGray}({5})${cReset}${clr}" -f $gNow.VramPct, $vramTag, $barVram, $dltVram.Text, $padGV, $stsVram))
            }
            [void]$out.AppendLine("${cGray} ${hr}${cReset}${clr}")

            # Calculate remaining vertical lines (reserve 1 bottom line for Hotkey bar)
            $usedLines = 4 + $(if ($hasThermal) { 4 } else { 3 }) + 1 + 1 + $(if ($showGpu) { 3 } else { 0 })
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

                $numCoreCharts = if ($hasThermal) { 4 } else { 3 }
                # The two GPU charts always show in the Charts view; in the split view only when every chart still gets >= 2 plot rows
                $showGpuCharts = $showGpu -and ($View -eq 'Charts' -or $chartBudget -ge (3 + 3 * ($numCoreCharts + 2)))
                $numCharts = $numCoreCharts + $(if ($showGpuCharts) { 2 } else { 0 })
                # Overhead inside chart block: 1 section header + $numCharts titles + 2 time axis lines
                $availPlotRows = [math]::Max($numCharts * 2, $chartBudget - (3 + $numCharts))
                $baseRows = [math]::Max(2, [int][math]::Floor($availPlotRows / [double]$numCharts))
                $extraRows = [math]::Max(0, $availPlotRows - ($baseRows * $numCharts))

                # Leftover rows go to the first charts, in display order
                $rowList = @(for ($ci = 0; $ci -lt $numCharts; $ci++) { $baseRows + $(if ($ci -lt $extraRows) { 1 } else { 0 }) })
                $ri = 0
                $rUsage = $rowList[$ri++]
                $rMHz   = $rowList[$ri++]
                $rMem   = $rowList[$ri++]
                $rTemp  = if ($hasThermal) { $rowList[$ri++] } else { $baseRows }
                $rGpu   = if ($showGpuCharts) { $rowList[$ri++] } else { 0 }
                $rVram  = if ($showGpuCharts) { $rowList[$ri++] } else { 0 }

                [void]$out.AppendLine(" ${cBold}1. $($ui.ChartUsage)${cReset}  ${cGray}${stsUsage}${cReset}${clr}")
                foreach ($ln in (& $newMultiRowChart $bktUsage 0 100 $rUsage '0' '%' { param($v) & $getMetricColor $v 60 85 $false } $clr)) {
                    [void]$out.AppendLine($ln)
                }

                $turboHintStr = $ui.TurboHint -f $baseMHz
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

                if ($showGpuCharts) {
                    $gpuChartNo = $numCoreCharts + 1
                    $bktGpu  = & $getTimeBuckets $gHist $now 'Util'    $chartWidth $bucketSeconds
                    $bktVram = & $getTimeBuckets $gHist $now 'VramPct' $chartWidth $bucketSeconds

                    [void]$out.AppendLine(" ${cBold}${gpuChartNo}. $($ui.ChartGpu)${cReset}  ${cGray}${stsGpu}${cReset}${clr}")
                    foreach ($ln in (& $newMultiRowChart $bktGpu 0 100 $rGpu '0' '%' { param($v) & $getMetricColor $v 60 85 $false } $clr)) {
                        [void]$out.AppendLine($ln)
                    }

                    [void]$out.AppendLine(" ${cBold}$($gpuChartNo + 1). $($ui.ChartVram)${cReset}  ${cGray}${stsVram}${cReset}${clr}")
                    foreach ($ln in (& $newMultiRowChart $bktVram 0 100 $rVram '0' '%' { param($v) & $getMetricColor $v 70 88 $false } $clr)) {
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
            $hkText = $ui.Hotkeys + $(if ($showGpu -and $gpuAdapters.Count -gt 1) { $ui.HotkeyGpu } else { '' })
            $hkVis = Get-DisplayWidth -Text " $hkText"
            $hkPad = [string]::new(' ', [math]::Max(0, $termWidth - $hkVis))
            [void]$out.Append("${cBgBar}${cWhite} ${hkText}${hkPad}${cReset}${clr}")
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
                    } elseif ($kChar -eq 'g' -and $hasGpu -and $gpuAdapters.Count -gt 1) {
                        $gpuSel = ($gpuSel + 1) % $gpuAdapters.Count
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
