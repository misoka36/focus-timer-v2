$taskLogicModulePath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'src\FocusTimer.TaskLogic.psm1'
$storageModulePath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'src\FocusTimer.Storage.psm1'

Import-Module $taskLogicModulePath -Force
Import-Module $storageModulePath -Force

Describe 'FocusTimer.Storage' {
    It 'creates the data directory and csv files' {
        $baseDirectory = Join-Path -Path $TestDrive -ChildPath 'app'
        New-Item -Path $baseDirectory -ItemType Directory -Force | Out-Null

        Initialize-FocusTimerStorage -BaseDirectory $baseDirectory

        (Test-Path -Path (Get-FocusTimerDataDirectory -BaseDirectory $baseDirectory)) | Should Be $true
        (Test-Path -Path (Get-TasksFilePath -BaseDirectory $baseDirectory)) | Should Be $true
        (Test-Path -Path (Get-TaskLogFilePath -BaseDirectory $baseDirectory)) | Should Be $true
    }

    It 'saves and reloads tasks from csv' {
        $baseDirectory = Join-Path -Path $TestDrive -ChildPath 'app'
        $now = Get-Date '2026-03-23T10:00:00'
        New-Item -Path $baseDirectory -ItemType Directory -Force | Out-Null

        $tasks = @(
            (New-TaskItem -Title 'Task A' -Order 1 -Now $now -Id '1'),
            (New-TaskItem -Title 'Task B' -Order 2 -Status Stopped -Now $now -Id '2')
        )

        Save-FocusTimerTasks -BaseDirectory $baseDirectory -Tasks $tasks
        $reloaded = @(Read-FocusTimerTasks -BaseDirectory $baseDirectory)

        $reloaded.Count | Should Be 2
        $reloaded[0].title | Should Be 'Task A'
        $reloaded[1].status | Should Be 'Stopped'
    }

    It 'appends task logs to csv' {
        $baseDirectory = Join-Path -Path $TestDrive -ChildPath 'app'
        $now = Get-Date '2026-03-23T10:00:00'
        New-Item -Path $baseDirectory -ItemType Directory -Force | Out-Null

        $task = New-TaskItem -Title 'Task A' -Order 1 -Now $now -Id '1'
        Append-TaskLogEntry -BaseDirectory $baseDirectory -Task $task -Trigger focus_start -StartedAt $now
        $logs = @(Read-TaskLog -BaseDirectory $baseDirectory)

        $logs.Count | Should Be 1
        $logs[0].task_id | Should Be '1'
        $logs[0].trigger | Should Be 'focus_start'
    }
}




