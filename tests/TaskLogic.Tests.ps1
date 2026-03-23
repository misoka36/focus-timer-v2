$modulePath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'src\FocusTimer.TaskLogic.psm1'
Import-Module $modulePath -Force

Describe 'FocusTimer.TaskLogic' {
    It 'adds tasks with sequential order' {
        $now = Get-Date '2026-03-23T10:00:00'
        $tasks = @()

        $tasks = Add-TaskItem -Tasks $tasks -Title 'Task A' -Now $now
        $tasks = Add-TaskItem -Tasks $tasks -Title 'Task B' -Now $now

        $tasks.Count | Should Be 2
        $tasks[0].order | Should Be 1
        $tasks[1].order | Should Be 2
    }

    It 'adds a new task before completed tasks' {
        $now = Get-Date '2026-03-23T10:00:00'
        $tasks = @(
            (New-TaskItem -Title 'Task A' -Order 1 -Status Normal -Now $now -Id '1'),
            (New-TaskItem -Title 'Task Done' -Order 2 -Status Done -Now $now -Id '2')
        )

        $updated = Add-TaskItem -Tasks $tasks -Title 'Task B' -Now $now

        $updated[0].title | Should Be 'Task A'
        $updated[1].title | Should Be 'Task B'
        $updated[2].title | Should Be 'Task Done'
    }

    It 'adds a new task right below the displayed task' {
        $now = Get-Date '2026-03-23T10:00:00'
        $tasks = @(
            (New-TaskItem -Title 'Stopped Task' -Order 1 -Status Stopped -Now $now -Id '1'),
            (New-TaskItem -Title 'Task A' -Order 2 -Status Normal -Now $now -Id '2'),
            (New-TaskItem -Title 'Task B' -Order 3 -Status Normal -Now $now -Id '3'),
            (New-TaskItem -Title 'Task Done' -Order 4 -Status Done -Now $now -Id '4')
        )

        $updated = Add-TaskItem -Tasks $tasks -Title 'Task C' -Now $now

        (@($updated) | ForEach-Object { $_.title }) -join '|' | Should Be 'Task A|Task C|Task B|Stopped Task|Task Done'
    }

    It 'selects the topmost normal task only' {
        $now = Get-Date '2026-03-23T10:00:00'
        $tasks = @(
            (New-TaskItem -Title 'Task A' -Order 1 -Status Stopped -Now $now -Id '1'),
            (New-TaskItem -Title 'Task B' -Order 2 -Status Normal -Now $now -Id '2'),
            (New-TaskItem -Title 'Task C' -Order 3 -Status Normal -Now $now -Id '3')
        )

        $selectedTask = Get-SelectedTask -Tasks $tasks

        $selectedTask.id | Should Be '2'
    }

    It 'keeps the displayed task at the top of active tasks' {
        $now = Get-Date '2026-03-23T10:00:00'
        $tasks = @(
            (New-TaskItem -Title 'Stopped Task' -Order 1 -Status Stopped -Now $now -Id '1'),
            (New-TaskItem -Title 'Task A' -Order 2 -Status Normal -Now $now -Id '2'),
            (New-TaskItem -Title 'Task B' -Order 3 -Status Normal -Now $now -Id '3')
        )

        $activeTasks = @(Get-ActiveTasks -Tasks $tasks)

        ($activeTasks | ForEach-Object { $_.title }) -join '|' | Should Be 'Task A|Task B|Stopped Task'
    }

    It 'moves a task to the top and normalizes the order' {
        $now = Get-Date '2026-03-23T10:00:00'
        $tasks = @(
            (New-TaskItem -Title 'Task A' -Order 1 -Now $now -Id '1'),
            (New-TaskItem -Title 'Task B' -Order 2 -Now $now -Id '2'),
            (New-TaskItem -Title 'Task C' -Order 3 -Now $now -Id '3')
        )

        $moved = Move-TaskToTop -Tasks $tasks -TaskId '3' -Now $now

        $moved[0].id | Should Be '3'
        $moved[0].order | Should Be 1
        $moved[1].order | Should Be 2
        $moved[2].order | Should Be 3
    }

    It 'moves a task up by one position' {
        $now = Get-Date '2026-03-23T10:00:00'
        $tasks = @(
            (New-TaskItem -Title 'Task A' -Order 1 -Now $now -Id '1'),
            (New-TaskItem -Title 'Task B' -Order 2 -Now $now -Id '2'),
            (New-TaskItem -Title 'Task C' -Order 3 -Now $now -Id '3')
        )

        $moved = Move-TaskUp -Tasks $tasks -TaskId '3' -Now $now

        $moved[0].id | Should Be '1'
        $moved[1].id | Should Be '3'
        $moved[2].id | Should Be '2'
    }

    It 'moves a task down by one position' {
        $now = Get-Date '2026-03-23T10:00:00'
        $tasks = @(
            (New-TaskItem -Title 'Task A' -Order 1 -Now $now -Id '1'),
            (New-TaskItem -Title 'Task B' -Order 2 -Now $now -Id '2'),
            (New-TaskItem -Title 'Task C' -Order 3 -Now $now -Id '3')
        )

        $moved = Move-TaskDown -Tasks $tasks -TaskId '1' -Now $now

        $moved[0].id | Should Be '2'
        $moved[1].id | Should Be '1'
        $moved[2].id | Should Be '3'
    }

    It 'moves a task to the bottom' {
        $now = Get-Date '2026-03-23T10:00:00'
        $tasks = @(
            (New-TaskItem -Title 'Task A' -Order 1 -Now $now -Id '1'),
            (New-TaskItem -Title 'Task B' -Order 2 -Now $now -Id '2'),
            (New-TaskItem -Title 'Task C' -Order 3 -Now $now -Id '3')
        )

        $moved = Move-TaskToBottom -Tasks $tasks -TaskId '1' -Now $now

        $moved[0].id | Should Be '2'
        $moved[1].id | Should Be '3'
        $moved[2].id | Should Be '1'
    }

    It 'changes task status and updates selection' {
        $now = Get-Date '2026-03-23T10:00:00'
        $tasks = @(
            (New-TaskItem -Title 'Task A' -Order 1 -Now $now -Id '1'),
            (New-TaskItem -Title 'Task B' -Order 2 -Now $now -Id '2')
        )

        $updated = Set-TaskStatus -Tasks $tasks -TaskId '1' -Status Done -Now $now
        $selectedTask = Get-SelectedTask -Tasks $updated
        $updatedTask = @($updated | Where-Object { $_.id -eq '1' })[0]

        $updatedTask.status | Should Be 'Done'
        $selectedTask.id | Should Be '2'
    }

    It 'toggles a task between normal and stopped' {
        $now = Get-Date '2026-03-23T10:00:00'
        $tasks = @(
            (New-TaskItem -Title 'Task A' -Order 1 -Status Normal -Now $now -Id '1')
        )

        $stopped = Toggle-TaskStopped -Tasks $tasks -TaskId '1' -Now $now

        $stopped[0].status | Should Be 'Stopped'

        $resumed = Toggle-TaskStopped -Tasks $stopped -TaskId '1' -Now $now
        $resumed[0].status | Should Be 'Normal'
    }

    It 'moves a completed task to the completed list' {
        $now = Get-Date '2026-03-23T10:00:00'
        $tasks = @(
            (New-TaskItem -Title 'Task A' -Order 1 -Status Normal -Now $now -Id '1'),
            (New-TaskItem -Title 'Task B' -Order 2 -Status Normal -Now $now -Id '2')
        )

        $completed = Complete-TaskItem -Tasks $tasks -TaskId '1' -Now $now
        $activeTasks = @(Get-ActiveTasks -Tasks $completed)
        $doneTasks = @(Get-CompletedTasks -Tasks $completed)

        $activeTasks.Count | Should Be 1
        $activeTasks[0].title | Should Be 'Task B'
        $doneTasks.Count | Should Be 1
        $doneTasks[0].title | Should Be 'Task A'
    }
}












