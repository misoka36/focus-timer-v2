Describe 'focus-timer smoke test' {
    It 'loads the application script in smoke test mode' {
        $projectRoot = Split-Path -Parent $PSScriptRoot
        $scriptPath = Join-Path -Path $projectRoot -ChildPath 'focus-timer.ps1'

        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -SmokeTest

        $LASTEXITCODE | Should Be 0
        ($output -match '"ok":true') | Should Be $true
    }

    It 'loads the GUI definitions in ui smoke test mode' {
        $projectRoot = Split-Path -Parent $PSScriptRoot
        $scriptPath = Join-Path -Path $projectRoot -ChildPath 'focus-timer.ps1'

        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -UiSmokeTest

        $LASTEXITCODE | Should Be 0
        ($output -match '"ui_loaded":true') | Should Be $true
        ($output -match '"control_probe":true') | Should Be $true
    }
}




