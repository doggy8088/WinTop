@{
    RootModule           = 'WinTop.psm1'
    ModuleVersion        = '0.1.0'
    CompatiblePSEditions = @('Desktop', 'Core')
    GUID                 = '8a9e4d21-6c3b-4f19-9b72-5e84d1a0c3f7'
    Author               = 'Will 保哥'
    CompanyName          = 'Will 保哥'
    Copyright            = '(c) 2026 Will 保哥. All rights reserved.'
    Description          = 'Interactive full-screen TUI system & CPU monitor ("top" for Windows) featuring 5-minute multi-row trend charts, CPU clock/Turbo telemetry, memory usage, ACPI thermal monitoring, GPU usage and VRAM monitoring (NVIDIA / AMD / Intel), and live top processes.'
    PowerShellVersion    = '5.1'

    FunctionsToExport    = @('Start-WinTop')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @('top', 'wintop')

    PrivateData          = @{
        PSData = @{
            Tags         = @(
                'top', 'htop', 'btop', 'wintop', 'monitor', 'cpu', 'memory', 'gpu', 'vram',
                'thermal', 'temperature', 'tui', 'dashboard', 'performance',
                'process', 'PSEdition_Desktop', 'PSEdition_Core', 'Windows'
            )
            LicenseUri   = 'https://github.com/doggy8088/WinTop/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/doggy8088/WinTop'
            ReleaseNotes = 'v0.1.0 - Initial release: responsive full-screen TUI system monitor ("top" for Windows) with 5-minute trend charts, CPU/Turbo/Memory/Thermal gauges, live top processes, interactive hotkeys, and auto-detected English / Traditional Chinese UI.'
        }
    }
}
