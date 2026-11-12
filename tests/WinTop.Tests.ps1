#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinTop\WinTop.psd1') -Force -ErrorAction Stop
}

Describe 'CPU usage fallback (issue #1: Hyper-V guests report 0% / 0 MHz)' {
    Context 'Get-WinTopCpuLoad' {
        It 'computes busy percentage from GetSystemTimes deltas (Kernel includes Idle)' {
            InModuleScope WinTop {
                $prev = [PSCustomObject]@{ Idle = 1000; Kernel = 2000; User = 1000 }
                # delta: kernel 1000 (idle 750) + user 1000 => total 2000, idle 750 => 62.5% busy
                $cur  = [PSCustomObject]@{ Idle = 1750; Kernel = 3000; User = 2000 }
                Get-WinTopCpuLoad -Prev $prev -Cur $cur | Should -Be 62.5
            }
        }
        It 'returns $null when no time elapsed' {
            InModuleScope WinTop {
                $t = [PSCustomObject]@{ Idle = 10; Kernel = 20; User = 5 }
                Get-WinTopCpuLoad -Prev $t -Cur $t | Should -BeNullOrEmpty
            }
        }
        It 'clamps to 0..100' {
            InModuleScope WinTop {
                $prev = [PSCustomObject]@{ Idle = 0; Kernel = 0; User = 0 }
                $cur  = [PSCustomObject]@{ Idle = 500; Kernel = 100; User = 0 }   # idle > kernel => would be negative
                Get-WinTopCpuLoad -Prev $prev -Cur $cur | Should -Be 0
            }
        }
    }

    Context 'Resolve-WinTopCpuUsage' {
        It 'uses the counter while it reports real values' {
            InModuleScope WinTop {
                $st = @{ Streak = 0; UseSystem = $false }
                Resolve-WinTopCpuUsage -CounterValue 37.5 -SystemValue 40.0 -State $st | Should -Be 37.5
                $st.UseSystem | Should -BeFalse
            }
        }
        It 'accepts a legitimately idle counter without switching source' {
            InModuleScope WinTop {
                $st = @{ Streak = 0; UseSystem = $false }
                1..5 | ForEach-Object {
                    Resolve-WinTopCpuUsage -CounterValue 0.0 -SystemValue 0.2 -State $st | Should -Be 0
                }
                $st.UseSystem | Should -BeFalse
            }
        }
        It 'latches onto the system load after 3 consecutive zero-counter samples that the OS says are busy' {
            InModuleScope WinTop {
                $st = @{ Streak = 0; UseSystem = $false }
                1..3 | ForEach-Object {
                    Resolve-WinTopCpuUsage -CounterValue 0.0 -SystemValue 12.5 -State $st | Should -Be 12.5
                }
                $st.UseSystem | Should -BeTrue
                # once latched, a (still stuck) counter is ignored
                Resolve-WinTopCpuUsage -CounterValue 0.0 -SystemValue 3.0 -State $st | Should -Be 3.0
            }
        }
        It 'resets the streak when the counter recovers' {
            InModuleScope WinTop {
                $st = @{ Streak = 0; UseSystem = $false }
                $null = Resolve-WinTopCpuUsage -CounterValue 0.0 -SystemValue 10.0 -State $st
                $null = Resolve-WinTopCpuUsage -CounterValue 0.0 -SystemValue 10.0 -State $st
                Resolve-WinTopCpuUsage -CounterValue 20.0 -SystemValue 10.0 -State $st | Should -Be 20
                $st.Streak | Should -Be 0
                $st.UseSystem | Should -BeFalse
            }
        }
        It 'uses the system load immediately when the counter is unavailable' {
            InModuleScope WinTop {
                $st = @{ Streak = 0; UseSystem = $false }
                Resolve-WinTopCpuUsage -CounterValue $null -SystemValue 55.0 -State $st | Should -Be 55
                $st.UseSystem | Should -BeTrue
            }
        }
        It 'returns 0 when neither source has data' {
            InModuleScope WinTop {
                $st = @{ Streak = 0; UseSystem = $true }
                Resolve-WinTopCpuUsage -CounterValue $null -SystemValue $null -State $st | Should -Be 0
            }
        }
        It 'clamps Turbo-inflated counter values to 100' {
            InModuleScope WinTop {
                $st = @{ Streak = 0; UseSystem = $false }
                Resolve-WinTopCpuUsage -CounterValue 130.0 -SystemValue 100.0 -State $st | Should -Be 100
            }
        }
    }

    Context 'Resolve-WinTopClock' {
        It 'scales the base clock by the Processor Performance counter (Turbo > 100%)' {
            InModuleScope WinTop {
                $c = Resolve-WinTopClock -Perf 150.0 -BaseMHz 2000 -OsMHz 0
                $c.Source | Should -Be 'Counter'
                $c.MHz    | Should -Be 3000
                $c.Perf   | Should -Be 150
            }
        }
        It 'falls back to the OS-reported clock when the counter reads 0' {
            InModuleScope WinTop {
                $c = Resolve-WinTopClock -Perf 0 -BaseMHz 2918 -OsMHz 2918
                $c.Source | Should -Be 'OS'
                $c.MHz    | Should -Be 2918
                $c.Perf   | Should -Be 100
            }
        }
        It 'falls back to the base clock when nothing else is available' {
            InModuleScope WinTop {
                $c = Resolve-WinTopClock -Perf 0 -BaseMHz 2500 -OsMHz 0
                $c.Source | Should -Be 'Est'
                $c.MHz    | Should -Be 2500
            }
        }
    }

    Context 'Native helpers' {
        It 'GetCpuTimes returns monotonic, non-zero system times' {
            $a = [WinTop.NativeHelper]::GetCpuTimes()
            Start-Sleep -Milliseconds 50
            $b = [WinTop.NativeHelper]::GetCpuTimes()
            $a.Kernel | Should -BeGreaterThan 0
            $b.Kernel | Should -BeGreaterOrEqual $a.Kernel
            $b.User   | Should -BeGreaterOrEqual $a.User
            $b.Idle   | Should -BeGreaterOrEqual $a.Idle
        }
        It 'GetProcessorCurrentMhz never throws and is non-negative' {
            [WinTop.NativeHelper]::GetProcessorCurrentMhz() | Should -BeGreaterOrEqual 0
        }
        It 'GetProcessorCurrentMhz is not affected by a restricted process affinity mask' -Skip:([Environment]::ProcessorCount -lt 2) {
            # Environment.ProcessorCount follows the affinity mask on modern .NET (read once at process start), so the
            # affinity must be applied when the child process is created: `start /affinity 1` pins it to CPU 0 from the start.
            $psd1   = (Resolve-Path (Join-Path $PSScriptRoot '..\WinTop\WinTop.psd1')).Path
            $hostExe = (Get-Process -Id $PID).Path
            $script = Join-Path $TestDrive 'probe.ps1'
            Set-Content -Path $script -Value "Import-Module '$psd1'; Write-Output ([WinTop.NativeHelper]::GetProcessorCurrentMhz())"

            $run = {
                param([string]$AffinityArg, [string]$OutFile)
                # The empty "" is start's window-title argument; without it a quoted exe path would be mistaken for the title
                cmd /c "start `"`" /wait /b $AffinityArg `"$hostExe`" -NoProfile -ExecutionPolicy Bypass -File `"$script`" > `"$OutFile`" 2>&1"
                [int](Get-Content -Path $OutFile -Raw).Trim()
            }
            $unrestricted = & $run '' (Join-Path $TestDrive 'out-free.txt')
            $restricted   = & $run '/affinity 1' (Join-Path $TestDrive 'out-pinned.txt')

            # Whatever the platform reports (possibly 0 inside a VM), pinning the process must not turn a success into a failure
            ($restricted -gt 0) | Should -Be ($unrestricted -gt 0)
        }
    }
}

Describe 'Start-WinTop smoke test' {
    It 'renders a frame in English and zh-TW with sane CPU numbers' {
        $en = Start-WinTop -Count 1 -Language en -NoMaximize 6>&1 | Out-String
        $en | Should -Match 'CPU Usage'
        $en | Should -Match 'CPU Clock'
        $zh = Start-WinTop -Count 1 -Language zh-TW -View Processes -SortBy MEM -NoMaximize 6>&1 | Out-String
        $zh | Should -Match 'WinTop'
    }
}
