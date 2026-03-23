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
        ($output -match '"clickable_symbols":true') | Should Be $true
        ($output -match '"flat_button_styles":true') | Should Be $true
    }

    It 'adds a task through the task window event handler' {
        $projectRoot = Split-Path -Parent $PSScriptRoot
        $scriptPath = Join-Path -Path $projectRoot -ChildPath 'focus-timer.ps1'
        $dataRoot = Join-Path -Path $TestDrive -ChildPath 'task-add-smoke'
        New-Item -Path $dataRoot -ItemType Directory -Force | Out-Null

        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -TaskAddSmokeTest -DataRoot $dataRoot

        $LASTEXITCODE | Should Be 0
        ($output -match '"ok":true') | Should Be $true
        ($output -match '"task_count":1') | Should Be $true
        ($output -match '"saved_count":1') | Should Be $true
        ($output -match '"first_task":"Smoke Task"') | Should Be $true
        ($output -match '"input_cleared":true') | Should Be $true
    }

    It 'reorders tasks through the task move action path' {
        $projectRoot = Split-Path -Parent $PSScriptRoot
        $scriptPath = Join-Path -Path $projectRoot -ChildPath 'focus-timer.ps1'
        $dataRoot = Join-Path -Path $TestDrive -ChildPath 'task-move-smoke'
        New-Item -Path $dataRoot -ItemType Directory -Force | Out-Null

        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -TaskMoveSmokeTest -DataRoot $dataRoot

        $LASTEXITCODE | Should Be 0
        ($output -match '"ok":true') | Should Be $true
        ($output -match '"order_after":"Task C\|Task A\|Task B"') | Should Be $true
    }
}












