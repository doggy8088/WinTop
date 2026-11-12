#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeDiscovery {
    # -Skip expressions are evaluated at discovery time, i.e. before BeforeAll runs
    Import-Module (Join-Path $PSScriptRoot '..\WinTop\WinTop.psd1') -Force -ErrorAction Stop
    $machineHasGpu = [System.Diagnostics.PerformanceCounterCategory]::Exists('GPU Engine') -and @([WinTop.GpuHelper]::GetAdapters()).Count -gt 0
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinTop\WinTop.psd1') -Force -ErrorAction Stop

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
        It 'computes VRAM% from dedicated memory on discrete GPUs and from dedicated+shared on integrated GPUs' {
            InModuleScope WinTop {
                $d = 'luid_0x00000000_0x0001097f'   # discrete, 8 GiB
                $i = 'luid_0x00000000_0x0000aaaa'   # integrated, 1 GiB total (dedicated + shared)
                $adapters = @(
                    [PSCustomObject]@{ Index = 0; Name = 'dGPU'; Key = $d; Uma = $false; TotalBytes = [double]8GB },
                    [PSCustomObject]@{ Index = 1; Name = 'iGPU'; Key = $i; Uma = $true;  TotalBytes = [double]1GB })
                $eng = New-TestCategory @{ 'Utilization Percentage' = @() }
                $mem = New-TestCategory @{
                    'Dedicated Usage' = @(
                        @{ Name = "${d}_phys_0"; Sample = (New-TestSample -Raw ([long]2GB) -Ts 1) },
                        @{ Name = "${i}_phys_0"; Sample = (New-TestSample -Raw ([long]128MB) -Ts 1) })
                    'Shared Usage' = @(
                        @{ Name = "${d}_phys_0"; Sample = (New-TestSample -Raw ([long]1GB) -Ts 1) },     # ignored for discrete GPUs
                        @{ Name = "${i}_phys_0"; Sample = (New-TestSample -Raw ([long]384MB) -Ts 1) })
                }
                $s = Get-WinTopGpuSnapshot -Adapters $adapters -EngineCategory $eng -MemoryCategory $mem -State @{ Prev = @{}; Meta = @{} }
                $s[$d].VramPct | Should -Be 25    # 2 GiB / 8 GiB
                $s[$d].Util    | Should -Be 0
                $s[$i].VramPct | Should -Be 50    # (128 MiB + 384 MiB) / 1 GiB
            }
        }
        It 'reports 0% (not a divide-by-zero) when the adapter capacity is unknown' {
            InModuleScope WinTop {
                $k = 'luid_0x00000000_0x0001097f'
                $adapters = @([PSCustomObject]@{ Index = 0; Name = 'GPU 0'; Key = $k; Uma = $false; TotalBytes = 0.0 })
                $eng = New-TestCategory @{ 'Utilization Percentage' = @() }
                $mem = New-TestCategory @{ 'Dedicated Usage' = @(@{ Name = "${k}_phys_0"; Sample = (New-TestSample -Raw 12345 -Ts 1) }) }
                $s = Get-WinTopGpuSnapshot -Adapters $adapters -EngineCategory $eng -MemoryCategory $mem -State @{ Prev = @{}; Meta = @{} }
                $s[$k].VramPct   | Should -Be 0
                $s[$k].UsedBytes | Should -Be 12345
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
    It 'shows GPU rows only when a GPU is available' -Skip:(-not $machineHasGpu) {
        $out = (Start-WinTop -Count 2 -Interval 0.5 -Language en -View Charts -NoMaximize 6>&1 | Out-String) -replace '\x1b\[[0-9;?]*[a-zA-Z]', ''
        $out | Should -Match 'GPU: '
        $out | Should -Match 'GPU Usage :'
        $out | Should -Match 'VRAM Usage:'
    }
}
