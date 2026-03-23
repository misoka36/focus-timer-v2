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

    for ($index = 0; $index -lt $orderedTasks.Count; $index++) {
        $orderedTasks[$index].order = $index + 1
    }

    @($orderedTasks)
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
    $newTask = New-TaskItem -Title $Title -Order ($currentTasks.Count + 1) -Now $Now
    @(Normalize-TaskOrder -Tasks (@($currentTasks) + $newTask))
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

    foreach ($task in @($Tasks)) {
        if ($task.id -eq $TaskId) {
            $task.status = $Status
            $task.updated_at = $Now
            $updated = $true
            break
        }
    }

    if (-not $updated) {
        throw "Task not found: $TaskId"
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

    $orderedTasks = [System.Collections.ArrayList]::new()
    foreach ($task in (Get-OrderedTasks -Tasks $Tasks)) {
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

    @($orderedTasks)
}

Export-ModuleMember -Function @(
    'Add-TaskItem',
    'Get-OrderedTasks',
    'Get-SelectedTask',
    'Move-TaskItem',
    'New-TaskItem',
    'Normalize-TaskOrder',
    'Set-TaskStatus'
)




