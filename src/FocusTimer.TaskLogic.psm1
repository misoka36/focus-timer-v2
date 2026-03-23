Set-StrictMode -Version Latest

function Get-TrimmedTaskTitle {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    $trimmed = $Title.Trim()

    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw 'Task title cannot be empty.'
    }

    $trimmed
}

function Get-OrderedTasks {
    param(
        [AllowNull()]
        [object[]]$Tasks
    )

    $taskList = @($Tasks)
    if ($taskList.Count -eq 0) {
        return @()
    }

    @($taskList | Sort-Object -Property order, created_at, title)
}

function Normalize-TaskOrder {
    param(
        [AllowNull()]
        [object[]]$Tasks
    )

    $orderedTasks = @(Get-OrderedTasks -Tasks $Tasks)
    $activeTasks = @($orderedTasks | Where-Object { $_.status -ne 'Done' })
    $completedTasks = @($orderedTasks | Where-Object { $_.status -eq 'Done' })
    $normalizedTasks = @($activeTasks + $completedTasks)

    for ($index = 0; $index -lt $normalizedTasks.Count; $index++) {
        $normalizedTasks[$index].order = $index + 1
    }

    @($normalizedTasks)
}

function New-TaskItem {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [int]$Order = 1,

        [ValidateSet('Normal', 'Stopped', 'Done')]
        [string]$Status = 'Normal',

        [datetime]$Now = (Get-Date),

        [string]$Id
    )

    if (-not $Id) {
        $Id = [guid]::NewGuid().ToString()
    }

    [pscustomobject]@{
        id         = $Id
        order      = [int]$Order
        title      = Get-TrimmedTaskTitle -Title $Title
        status     = $Status
        created_at = $Now
        updated_at = $Now
    }
}

function Add-TaskItem {
    param(
        [AllowNull()]
        [object[]]$Tasks,

        [Parameter(Mandatory = $true)]
        [string]$Title,

        [datetime]$Now = (Get-Date)
    )

    $currentTasks = @(Get-OrderedTasks -Tasks $Tasks)
    $activeTasks = @($currentTasks | Where-Object { $_.status -ne 'Done' })
    $completedTasks = @($currentTasks | Where-Object { $_.status -eq 'Done' })
    $newTask = New-TaskItem -Title $Title -Order ($activeTasks.Count + 1) -Now $Now
    @(Normalize-TaskOrder -Tasks (@($activeTasks) + $newTask + $completedTasks))
}

function Get-ActiveTasks {
    param(
        [AllowNull()]
        [object[]]$Tasks
    )

    @(Get-OrderedTasks -Tasks $Tasks | Where-Object { $_.status -ne 'Done' })
}

function Get-CompletedTasks {
    param(
        [AllowNull()]
        [object[]]$Tasks
    )

    @(Get-OrderedTasks -Tasks $Tasks | Where-Object { $_.status -eq 'Done' })
}

function Get-SelectedTask {
    param(
        [AllowNull()]
        [object[]]$Tasks
    )

    Get-OrderedTasks -Tasks $Tasks | Where-Object { $_.status -eq 'Normal' } | Select-Object -First 1
}

function Set-TaskStatus {
    param(
        [AllowNull()]
        [object[]]$Tasks,

        [Parameter(Mandatory = $true)]
        [string]$TaskId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Normal', 'Stopped', 'Done')]
        [string]$Status,

        [datetime]$Now = (Get-Date)
    )

    $updated = $false
    $previousStatus = $null

    foreach ($task in @($Tasks)) {
        if ($task.id -eq $TaskId) {
            $previousStatus = $task.status
            $task.status = $Status
            $task.updated_at = $Now
            $updated = $true
            break
        }
    }

    if (-not $updated) {
        throw "Task not found: $TaskId"
    }

    $orderedTasks = @(Get-OrderedTasks -Tasks $Tasks)
    $targetTask = @($orderedTasks | Where-Object { $_.id -eq $TaskId })[0]

    if ($Status -eq 'Done') {
        $targetTask.order = $orderedTasks.Count + 1
    }
    elseif ($previousStatus -eq 'Done' -and $Status -ne 'Done') {
        $activeTasks = @($orderedTasks | Where-Object { $_.status -ne 'Done' -and $_.id -ne $TaskId })
        $targetTask.order = $activeTasks.Count + 1
    }

    @(Normalize-TaskOrder -Tasks $Tasks)
}

function Move-TaskItem {
    param(
        [AllowNull()]
        [object[]]$Tasks,

        [Parameter(Mandatory = $true)]
        [string]$TaskId,

        [int]$TargetIndex,

        [datetime]$Now = (Get-Date)
    )

    $activeTaskList = @(Get-ActiveTasks -Tasks $Tasks)
    $completedTasks = @(Get-CompletedTasks -Tasks $Tasks)
    $orderedTasks = [System.Collections.ArrayList]::new()
    foreach ($task in $activeTaskList) {
        [void]$orderedTasks.Add($task)
    }

    if ($orderedTasks.Count -eq 0) {
        return @()
    }

    $sourceIndex = -1

    for ($index = 0; $index -lt $orderedTasks.Count; $index++) {
        if ($orderedTasks[$index].id -eq $TaskId) {
            $sourceIndex = $index
            break
        }
    }

    if ($sourceIndex -lt 0) {
        throw "Task not found: $TaskId"
    }

    if ($TargetIndex -lt 0) {
        $TargetIndex = 0
    }

    if ($TargetIndex -gt ($orderedTasks.Count - 1)) {
        $TargetIndex = $orderedTasks.Count - 1
    }

    $movedTask = $orderedTasks[$sourceIndex]
    $orderedTasks.RemoveAt($sourceIndex)
    $orderedTasks.Insert($TargetIndex, $movedTask)

    for ($index = 0; $index -lt $orderedTasks.Count; $index++) {
        $orderedTasks[$index].order = $index + 1
        $orderedTasks[$index].updated_at = $Now
    }

    @(Normalize-TaskOrder -Tasks (@($orderedTasks) + $completedTasks))
}

function Get-TaskIndex {
    param(
        [AllowNull()]
        [object[]]$Tasks,

        [Parameter(Mandatory = $true)]
        [string]$TaskId
    )

    $orderedTasks = @(Get-OrderedTasks -Tasks $Tasks)
    for ($index = 0; $index -lt $orderedTasks.Count; $index++) {
        if ($orderedTasks[$index].id -eq $TaskId) {
            return $index
        }
    }

    throw "Task not found: $TaskId"
}

function Move-TaskToTop {
    param(
        [AllowNull()]
        [object[]]$Tasks,

        [Parameter(Mandatory = $true)]
        [string]$TaskId,

        [datetime]$Now = (Get-Date)
    )

    Move-TaskItem -Tasks $Tasks -TaskId $TaskId -TargetIndex 0 -Now $Now
}

function Move-TaskUp {
    param(
        [AllowNull()]
        [object[]]$Tasks,

        [Parameter(Mandatory = $true)]
        [string]$TaskId,

        [datetime]$Now = (Get-Date)
    )

    $currentIndex = Get-TaskIndex -Tasks $Tasks -TaskId $TaskId
    $targetIndex = [Math]::Max($currentIndex - 1, 0)
    Move-TaskItem -Tasks $Tasks -TaskId $TaskId -TargetIndex $targetIndex -Now $Now
}

function Move-TaskDown {
    param(
        [AllowNull()]
        [object[]]$Tasks,

        [Parameter(Mandatory = $true)]
        [string]$TaskId,

        [datetime]$Now = (Get-Date)
    )

    $orderedTasks = @(Get-OrderedTasks -Tasks $Tasks)
    if ($orderedTasks.Count -eq 0) {
        return @()
    }

    $currentIndex = Get-TaskIndex -Tasks $orderedTasks -TaskId $TaskId
    $targetIndex = [Math]::Min($currentIndex + 1, $orderedTasks.Count - 1)
    Move-TaskItem -Tasks $orderedTasks -TaskId $TaskId -TargetIndex $targetIndex -Now $Now
}

function Move-TaskToBottom {
    param(
        [AllowNull()]
        [object[]]$Tasks,

        [Parameter(Mandatory = $true)]
        [string]$TaskId,

        [datetime]$Now = (Get-Date)
    )

    $orderedTasks = @(Get-OrderedTasks -Tasks $Tasks)
    if ($orderedTasks.Count -eq 0) {
        return @()
    }

    Move-TaskItem -Tasks $orderedTasks -TaskId $TaskId -TargetIndex ($orderedTasks.Count - 1) -Now $Now
}

function Toggle-TaskStopped {
    param(
        [AllowNull()]
        [object[]]$Tasks,

        [Parameter(Mandatory = $true)]
        [string]$TaskId,

        [datetime]$Now = (Get-Date)
    )

    $task = @(Get-OrderedTasks -Tasks $Tasks | Where-Object { $_.id -eq $TaskId })[0]
    if (-not $task) {
        throw "Task not found: $TaskId"
    }

    switch ($task.status) {
        'Normal' {
            Set-TaskStatus -Tasks $Tasks -TaskId $TaskId -Status 'Stopped' -Now $Now
        }
        'Stopped' {
            Set-TaskStatus -Tasks $Tasks -TaskId $TaskId -Status 'Normal' -Now $Now
        }
        default {
            throw "Task cannot be toggled from status: $($task.status)"
        }
    }
}

function Complete-TaskItem {
    param(
        [AllowNull()]
        [object[]]$Tasks,

        [Parameter(Mandatory = $true)]
        [string]$TaskId,

        [datetime]$Now = (Get-Date)
    )

    Set-TaskStatus -Tasks $Tasks -TaskId $TaskId -Status 'Done' -Now $Now
}

Export-ModuleMember -Function @(
    'Add-TaskItem',
    'Complete-TaskItem',
    'Get-ActiveTasks',
    'Get-CompletedTasks',
    'Get-OrderedTasks',
    'Get-SelectedTask',
    'Move-TaskDown',
    'Move-TaskItem',
    'Move-TaskToBottom',
    'Move-TaskToTop',
    'Move-TaskUp',
    'New-TaskItem',
    'Normalize-TaskOrder',
    'Set-TaskStatus',
    'Toggle-TaskStopped'
)












