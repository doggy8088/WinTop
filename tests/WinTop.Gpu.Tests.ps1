#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeDiscovery {
    # -Skip expressions are evaluated at discovery time, i.e. before BeforeAll runs
    Import-Module (Join-Path $PSScriptRoot '..\WinTop\WinTop.psd1') -Force -ErrorAction Stop
    $machineHasGpu = [System.Diagnostics.PerformanceCounterCategory]::Exists('GPU Engine') -and @([WinTop.GpuHelper]::GetAdapters()).Count -gt 0
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinTop\WinTop.psd1') -Force -ErrorAction Stop

    # Renders two ticks and returns the last frame: its text (ANSI stripped), its height, and the viewport size the frame
    # prints in its own header, e.g. "[Charts] 120x36" (the 36-row fallback when output is redirected, the real window otherwise).
    function script:Get-WinTopFrame {
        param([string]$View = 'Split', [string]$Language = 'en')
        # Join the raw Write-Host messages: Out-String would re-wrap them at the host width on Windows PowerShell 5.1
        $raw   = @(Start-WinTop -Count 2 -Interval 0.5 -Language $Language -View $View -NoMaximize 6>&1 | ForEach-Object { [string]$_ }) -join ''
        $lines = ($raw -replace '\x1b\[[0-9;?]*[a-zA-Z]', '') -split "`r?`n"
        $topLeft = [string][char]0x2554   # box-drawing corner of the header frame (kept out of the file: 5.1 reads BOM-less files as ANSI)
        $start = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -match ('^' + $topLeft) })[-1]
        $end   = @($start..($lines.Count - 1) | Where-Object { $lines[$_] -match 'Keys:|\[Q/Esc\]' })[0]
        # Should -Match does not populate $Matches in this scope, so extract the viewport explicitly
        $vp = [regex]::Match($lines[$start + 1], '\] (\d+)x(\d+)')
        [PSCustomObject]@{
            Text            = ($lines[$start..$end] -join "`n")
            LineCount       = $end - $start + 1
            ViewportMatched = $vp.Success
            ViewportRows    = $(if ($vp.Success) { [int]$vp.Groups[2].Value } else { 0 })
        }
    }

    # Test doubles live in the module's script scope so InModuleScope blocks can use them.
    InModuleScope WinTop {
        # Minimal stand-in for PerformanceCounterCategory: ReadCategory()['<counter>'].Values -> InstanceName / Sample
        function script:New-TestCategory {
            param([hashtable]$Counters)   # counter name -> @( @{ Name = '<instance>'; Sample = <CounterSample> }, ... )
            $data = @{}
            foreach ($counter in $Counters.Keys) {
                $values = foreach ($i in $Counters[$counter]) { [PSCustomObject]@{ InstanceName = $i.Name; Sample = $i.Sample } }
                $data[$counter] = [PSCustomObject]@{ Values = @($values) }
            }
            $cat = [PSCustomObject]@{}
            $cat | Add-Member -MemberType ScriptMethod -Name ReadCategory -Value { $data }.GetNewClosure()
            return $cat
        }

        # Timer100Ns sample, shaped like the real "GPU Engine" samples: busy time is `Raw` (100ns units) at wall-clock `Ts`
        # (100ns units, so both frequencies are 10,000,000). Filling in both timestamp fields keeps the maths identical on
        # Windows PowerShell (.NET Framework) and PowerShell 7 (.NET), which read different ones.
        function script:New-TestSample {
            param([long]$Raw, [long]$Ts)
            [System.Diagnostics.CounterSample]::new($Raw, 0, 10000000, 10000000, $Ts, $Ts, [System.Diagnostics.PerformanceCounterType]::Timer100Ns)
        }
    }
}

Describe 'GPU monitoring (issue #2)' {
    Context 'ConvertFrom-WinTopGpuEngineName' {
        It 'extracts the adapter and engine from a GPU Engine instance name' {
            InModuleScope WinTop {
                $m = ConvertFrom-WinTopGpuEngineName -Name 'pid_14680_luid_0x00000000_0x0001097f_phys_0_eng_3_engtype_3d'
                $m.Adapter | Should -Be 'luid_0x00000000_0x0001097f'
                $m.Engine  | Should -Be 'luid_0x00000000_0x0001097f_phys0_eng3'
            }
        }
        It 'is case-insensitive and normalizes the adapter key to lower case' {
            InModuleScope WinTop {
                $m = ConvertFrom-WinTopGpuEngineName -Name 'pid_1_luid_0x00000000_0x0000E5A3_phys_1_eng_12_engtype_Copy'
                $m.Adapter | Should -Be 'luid_0x00000000_0x0000e5a3'
                $m.Engine  | Should -Be 'luid_0x00000000_0x0000e5a3_phys1_eng12'
            }
        }
        It 'returns $null for unrelated names' {
            InModuleScope WinTop {
                ConvertFrom-WinTopGpuEngineName -Name '_Total' | Should -BeNullOrEmpty
                ConvertFrom-WinTopGpuEngineName -Name '' | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Measure-WinTopGpuUtil' {
        It 'sums processes sharing an engine, then takes the busiest engine per adapter' {
            InModuleScope WinTop {
                $a = 'luid_0x00000000_0x0001097f'
                $util = @{
                    "pid_1_${a}_phys_0_eng_0_engtype_3d"          = 20.0   # engine 0: 20 + 15 = 35
                    "pid_2_${a}_phys_0_eng_0_engtype_3d"          = 15.0
                    "pid_3_${a}_phys_0_eng_1_engtype_videodecode" = 50.0   # engine 1: 50  <- busiest
                }
                $r = Measure-WinTopGpuUtil -Utilization $util -MetaCache @{}
                $r[$a] | Should -Be 50
            }
        }
        It 'keeps adapters separate' {
            InModuleScope WinTop {
                $a = 'luid_0x00000000_0x0001097f'; $b = 'luid_0x00000000_0x0001213a'
                $util = @{
                    "pid_1_${a}_phys_0_eng_0_engtype_3d" = 10.0
                    "pid_1_${b}_phys_0_eng_0_engtype_3d" = 70.0
                }
                $r = Measure-WinTopGpuUtil -Utilization $util -MetaCache @{}
                $r[$a] | Should -Be 10
                $r[$b] | Should -Be 70
            }
        }
        It 'clamps the per-engine sum to 100 and ignores non-engine instances' {
            InModuleScope WinTop {
                $a = 'luid_0x00000000_0x0001097f'
                $util = @{
                    "pid_1_${a}_phys_0_eng_0_engtype_3d" = 80.0
                    "pid_2_${a}_phys_0_eng_0_engtype_3d" = 80.0
                    'garbage' = 99.0
                }
                $cache = @{}
                $r = Measure-WinTopGpuUtil -Utilization $util -MetaCache $cache
                $r[$a] | Should -Be 100
                $r.Count | Should -Be 1
                $cache['garbage'] | Should -BeFalse   # negative result memoized
            }
        }
        It 'returns an empty map when nothing is active' {
            InModuleScope WinTop {
                (Measure-WinTopGpuUtil -Utilization @{} -MetaCache @{}).Count | Should -Be 0
            }
        }
        It 'keeps the instance-name cache bounded' {
            InModuleScope WinTop {
                $cache = @{}
                1..5001 | ForEach-Object { $cache["x$_"] = $false }
                $null = Measure-WinTopGpuUtil -Utilization @{} -MetaCache $cache
                $cache.Count | Should -Be 0
            }
        }
    }

    Context 'Get-WinTopGpuUtilization' {
        It 'turns cumulative busy-time samples into percentages and ignores idle instances' {
            InModuleScope WinTop {
                $a = 'luid_0x00000000_0x0001097f'
                $busy = "pid_1_${a}_phys_0_eng_0_engtype_3d"
                $idle = "pid_2_${a}_phys_0_eng_1_engtype_copy"
                $state = @{ Prev = @{}; Meta = @{} }

                $cat1 = New-TestCategory @{ 'Utilization Percentage' = @(
                    @{ Name = $busy; Sample = (New-TestSample -Raw 1000000 -Ts 10000000) },
                    @{ Name = $idle; Sample = (New-TestSample -Raw 500 -Ts 10000000) }) }
                (Get-WinTopGpuUtilization -Category $cat1 -State $state).Count | Should -Be 0   # priming read: no baseline yet

                # 1s later the busy instance accumulated 0.25s of busy time => 25 %
                $cat2 = New-TestCategory @{ 'Utilization Percentage' = @(
                    @{ Name = $busy; Sample = (New-TestSample -Raw 3500000 -Ts 20000000) },
                    @{ Name = $idle; Sample = (New-TestSample -Raw 500 -Ts 20000000) }) }
                $r = Get-WinTopGpuUtilization -Category $cat2 -State $state
                $r[$a] | Should -Be 25
                $state.Prev.Count | Should -Be 2
            }
        }
        It 'forgets instances that disappeared (process exit) and tolerates a missing counter' {
            InModuleScope WinTop {
                $a = 'luid_0x00000000_0x0001097f'
                $state = @{ Prev = @{}; Meta = @{} }
                $cat = New-TestCategory @{ 'Utilization Percentage' = @(
                    @{ Name = "pid_1_${a}_phys_0_eng_0_engtype_3d"; Sample = (New-TestSample -Raw 1 -Ts 1) }) }
                $null = Get-WinTopGpuUtilization -Category $cat -State $state
                $state.Prev.Count | Should -Be 1
                $empty = New-TestCategory @{}
                (Get-WinTopGpuUtilization -Category $empty -State $state).Count | Should -Be 0
                $state.Prev.Count | Should -Be 0
            }
        }
    }

    Context 'Get-WinTopGpuMemory' {
        It 'sums physical nodes per adapter and keeps dedicated / shared apart' {
            InModuleScope WinTop {
                $a = 'luid_0x00000000_0x0001097F'
                $cat = New-TestCategory @{
                    'Dedicated Usage' = @(
                        @{ Name = "${a}_phys_0"; Sample = (New-TestSample -Raw 1000 -Ts 1) },
                        @{ Name = "${a}_phys_1"; Sample = (New-TestSample -Raw 500 -Ts 1) })
                    'Shared Usage' = @(
                        @{ Name = "${a}_phys_0"; Sample = (New-TestSample -Raw 70 -Ts 1) })
                }
                $m = Get-WinTopGpuMemory -Category $cat
                $m.Dedicated['luid_0x00000000_0x0001097f'] | Should -Be 1500
                $m.Shared['luid_0x00000000_0x0001097f']    | Should -Be 70
            }
        }
    }

    Context 'Get-WinTopGpuSnapshot' {
        It 'reports dedicated memory as VRAM and shared memory separately, without guessing the memory architecture' {
            InModuleScope WinTop {
                $d = 'luid_0x00000000_0x0001097f'   # discrete: 8 GiB dedicated
                $i = 'luid_0x00000000_0x0000aaaa'   # integrated with a 2 GiB firmware carve-out (looks "big" but shares system RAM)
                $adapters = @(
                    [PSCustomObject]@{ Index = 0; Name = 'dGPU'; Key = $d; TotalBytes = [double]8GB; SharedTotalBytes = [double]32GB },
                    [PSCustomObject]@{ Index = 1; Name = 'iGPU'; Key = $i; TotalBytes = [double]2GB; SharedTotalBytes = [double]16GB })
                $eng = New-TestCategory @{ 'Utilization Percentage' = @() }
                $mem = New-TestCategory @{
                    'Dedicated Usage' = @(
                        @{ Name = "${d}_phys_0"; Sample = (New-TestSample -Raw ([long]2GB) -Ts 1) },
                        @{ Name = "${i}_phys_0"; Sample = (New-TestSample -Raw ([long]512MB) -Ts 1) })
                    'Shared Usage' = @(
                        @{ Name = "${d}_phys_0"; Sample = (New-TestSample -Raw ([long]1GB) -Ts 1) },
                        @{ Name = "${i}_phys_0"; Sample = (New-TestSample -Raw ([long]3GB) -Ts 1) })
                }
                $s = Get-WinTopGpuSnapshot -Adapters $adapters -EngineCategory $eng -MemoryCategory $mem -State @{ Prev = @{}; Meta = @{} }
                $s[$d].VramPct          | Should -Be 25            # 2 GiB / 8 GiB dedicated
                $s[$d].UsedBytes        | Should -Be ([double]2GB)
                $s[$d].SharedUsedBytes  | Should -Be ([double]1GB)
                $s[$d].SharedTotalBytes | Should -Be ([double]32GB)
                $s[$d].Util             | Should -Be 0
                $s[$i].VramPct          | Should -Be 25            # 512 MiB / 2 GiB dedicated; the 3 GiB of shared use is NOT folded in
                $s[$i].SharedUsedBytes  | Should -Be ([double]3GB)
            }
        }
        It 'reports 0% (not a divide-by-zero) when the adapter capacity is unknown' {
            InModuleScope WinTop {
                $k = 'luid_0x00000000_0x0001097f'
                $adapters = @([PSCustomObject]@{ Index = 0; Name = 'GPU 0'; Key = $k; TotalBytes = 0.0; SharedTotalBytes = 0.0 })
                $eng = New-TestCategory @{ 'Utilization Percentage' = @() }
                $mem = New-TestCategory @{ 'Dedicated Usage' = @(@{ Name = "${k}_phys_0"; Sample = (New-TestSample -Raw 12345 -Ts 1) }) }
                $s = Get-WinTopGpuSnapshot -Adapters $adapters -EngineCategory $eng -MemoryCategory $mem -State @{ Prev = @{}; Meta = @{} }
                $s[$k].VramPct   | Should -Be 0
                $s[$k].UsedBytes | Should -Be 12345
            }
        }
    }

    Context 'Limit-WinTopText' {
        It 'returns text that already fits unchanged' {
            InModuleScope WinTop {
                Limit-WinTopText -Text 'NVIDIA GeForce RTX 2070' -MaxWidth 40 | Should -Be 'NVIDIA GeForce RTX 2070'
                Limit-WinTopText -Text 'abc' -MaxWidth 3 | Should -Be 'abc'
            }
        }
        It 'truncates by display width and ends with ~' {
            InModuleScope WinTop {
                $t = Limit-WinTopText -Text 'NVIDIA GeForce RTX 4070 Ti SUPER' -MaxWidth 20
                $t | Should -Be 'NVIDIA GeForce RTX ~'
                (Get-DisplayWidth -Text $t) | Should -BeLessOrEqual 20
            }
        }
        It 'counts wide CJK characters as two columns' {
            InModuleScope WinTop {
                $cjk = (-join ([char[]](0x986F, 0x793A, 0x5361, 0x986F, 0x793A, 0x5361)))   # 6 wide chars = 12 columns
                $t = Limit-WinTopText -Text $cjk -MaxWidth 7
                (Get-DisplayWidth -Text $t) | Should -BeLessOrEqual 7
                $t | Should -Match '~$'
            }
        }
        It 'degrades to just ~ when there is no room' {
            InModuleScope WinTop {
                Limit-WinTopText -Text 'GPU' -MaxWidth 0 | Should -Be '~'
            }
        }
    }

    Context 'Format-WinTopMemory' {
        It 'uses GiB for GiB-sized capacities' {
            InModuleScope WinTop {
                Format-WinTopMemory -UsedBytes ([double]2.1GB) -TotalBytes ([double]8GB) | Should -Match '^2[.,]1/8G$'
                Format-WinTopMemory -UsedBytes 0 -TotalBytes ([double]1GB) | Should -Match '^0[.,]0/1G$'
            }
        }
        It 'uses MiB for sub-GiB capacities instead of rounding them to 0G' {
            InModuleScope WinTop {
                Format-WinTopMemory -UsedBytes ([double]64MB) -TotalBytes ([double]128MB) | Should -Be '64/128M'
                Format-WinTopMemory -UsedBytes 0 -TotalBytes ([double]512MB) | Should -Be '0/512M'
            }
        }
        It 'returns N/A when the capacity is unknown' {
            InModuleScope WinTop {
                Format-WinTopMemory -UsedBytes 12345 -TotalBytes 0 | Should -Be 'N/A'
            }
        }
    }

    Context 'Native DXGI helper (runs on machines with or without a GPU)' {
        It 'GetAdapters never throws and returns well-formed adapters' {
            $adapters = @([WinTop.GpuHelper]::GetAdapters())
            foreach ($a in $adapters) {
                $a.Key  | Should -Match '^luid_0x[0-9a-f]{8}_0x[0-9a-f]{8}$'
                $a.Name | Should -Not -BeNullOrEmpty
            }
        }
    }
}

Describe 'Start-WinTop with GPU support' {
    It 'renders English and zh-TW frames in every view without errors' {
        foreach ($view in 'Split', 'Charts', 'Processes') {
            $en = Start-WinTop -Count 2 -Interval 0.5 -Language en -View $view -NoMaximize 6>&1 | Out-String
            $en | Should -Match 'CPU Usage'
        }
        $zh = Start-WinTop -Count 2 -Interval 0.5 -Language zh-TW -View Charts -NoMaximize 6>&1 | Out-String
        $zh | Should -Match 'WinTop'
    }
    It 'never renders a frame taller than the viewport it reports in its own header, in any view' {
        # The viewport (e.g. "120x36") is whatever Start-WinTop detected: the 36-row fallback when output is redirected (CI),
        # the real window size in an interactive console. Below 36 rows the original layout already overflows, so only assert above that.
        foreach ($view in 'Split', 'Charts', 'Processes') {
            $frame = Get-WinTopFrame -View $view
            $frame.ViewportMatched | Should -BeTrue -Because "the header of the $view frame prints the viewport size"
            if ($frame.ViewportRows -ge 36) {
                $frame.LineCount | Should -BeLessOrEqual $frame.ViewportRows -Because "the $view frame must fit the $($frame.ViewportRows)-row viewport"
            }
        }
    }
    It 'shows the GPU header and gauge rows when a GPU is available and the viewport can hold them' -Skip:(-not $machineHasGpu) {
        # The layout deliberately hides the GPU rows in a viewport that is too small (Charts view needs up to 28 rows with
        # a thermal sensor), so only assert presence when the frame reports a viewport that is comfortably tall enough.
        $frame = Get-WinTopFrame -View Charts
        $frame.ViewportMatched | Should -BeTrue
        if ($frame.ViewportRows -ge 36) {
            $frame.Text | Should -Match 'GPU: '
            $frame.Text | Should -Match 'GPU Usage :'
            $frame.Text | Should -Match 'VRAM Usage:'
        }
    }
    It 'keeps the header box rectangular (all box lines the same width)' {
        # The long-adapter-name case is covered by the Limit-WinTopText unit tests; this checks the real rendered box
        $frame = Get-WinTopFrame -View Charts
        $box = @($frame.Text -split "`n" | Select-Object -First 5)   # top border, 2-3 header lines, bottom border
        $widths = @($box | ForEach-Object { $_.Length } | Select-Object -Unique)
        $widths.Count | Should -Be 1 -Because 'all header box lines should have the same width'
    }
}
