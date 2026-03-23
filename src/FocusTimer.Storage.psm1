Set-StrictMode -Version Latest

function Get-FocusTimerDataDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory
    )

    Join-Path -Path $BaseDirectory -ChildPath 'data'
}

function Get-TasksFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory
    )

    Join-Path -Path (Get-FocusTimerDataDirectory -BaseDirectory $BaseDirectory) -ChildPath 'tasks.csv'
}

function Get-TaskLogFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory
    )

    Join-Path -Path (Get-FocusTimerDataDirectory -BaseDirectory $BaseDirectory) -ChildPath 'task_log.csv'
}

function Format-StorageTimestamp {
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$Value
    )

    $Value.ToString('yyyy-MM-dd HH:mm:ss')
}

function Parse-StorageTimestamp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    [datetime]::ParseExact($Value, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Ensure-FileWithHeader {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Header
    )

    if (-not (Test-Path -Path $Path)) {
        Set-Content -Path $Path -Value $Header -Encoding UTF8
        return
    }

    $fileInfo = Get-Item -Path $Path
    if ($fileInfo.Length -eq 0) {
        Set-Content -Path $Path -Value $Header -Encoding UTF8
    }
}

function Initialize-FocusTimerStorage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory
    )

    $dataDirectory = Get-FocusTimerDataDirectory -BaseDirectory $BaseDirectory
    if (-not (Test-Path -Path $dataDirectory)) {
        New-Item -Path $dataDirectory -ItemType Directory | Out-Null
    }

    Ensure-FileWithHeader -Path (Get-TasksFilePath -BaseDirectory $BaseDirectory) -Header 'id,order,title,status,created_at,updated_at'
    Ensure-FileWithHeader -Path (Get-TaskLogFilePath -BaseDirectory $BaseDirectory) -Header 'started_at,task_id,task_title,trigger'
}

function Read-FocusTimerTasks {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory
    )

    Initialize-FocusTimerStorage -BaseDirectory $BaseDirectory
    $path = Get-TasksFilePath -BaseDirectory $BaseDirectory

    $rows = Import-Csv -Path $path
    if (-not $rows) {
        return @()
    }

    $tasks = foreach ($row in $rows) {
        [pscustomobject]@{
            id         = $row.id
            order      = [int]$row.order
            title      = $row.title
            status     = $row.status
            created_at = Parse-StorageTimestamp -Value $row.created_at
            updated_at = Parse-StorageTimestamp -Value $row.updated_at
        }
    }

    @($tasks | Sort-Object -Property order, created_at, title)
}

function Save-FocusTimerTasks {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory,

        [AllowNull()]
        [object[]]$Tasks
    )

    Initialize-FocusTimerStorage -BaseDirectory $BaseDirectory
    $path = Get-TasksFilePath -BaseDirectory $BaseDirectory
    $orderedTasks = @($Tasks | Sort-Object -Property order, created_at, title)

    if ($orderedTasks.Count -eq 0) {
        Set-Content -Path $path -Value 'id,order,title,status,created_at,updated_at' -Encoding UTF8
        return
    }

    $records = foreach ($task in $orderedTasks) {
        [pscustomobject]@{
            id         = $task.id
            order      = [int]$task.order
            title      = $task.title
            status     = $task.status
            created_at = Format-StorageTimestamp -Value $task.created_at
            updated_at = Format-StorageTimestamp -Value $task.updated_at
        }
    }

    $records | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
}

function Append-TaskLogEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory,

        [Parameter(Mandatory = $true)]
        [psobject]$Task,

        [Parameter(Mandatory = $true)]
        [string]$Trigger,

        [datetime]$StartedAt = (Get-Date)
    )

    Initialize-FocusTimerStorage -BaseDirectory $BaseDirectory
    $path = Get-TaskLogFilePath -BaseDirectory $BaseDirectory

    $record = [pscustomobject]@{
        started_at = Format-StorageTimestamp -Value $StartedAt
        task_id    = $Task.id
        task_title = $Task.title
        trigger    = $Trigger
    }

    $record | Export-Csv -Path $path -Append -NoTypeInformation -Encoding UTF8
}

function Read-TaskLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory
    )

    Initialize-FocusTimerStorage -BaseDirectory $BaseDirectory
    $path = Get-TaskLogFilePath -BaseDirectory $BaseDirectory

    $rows = Import-Csv -Path $path
    if (-not $rows) {
        return @()
    }

    foreach ($row in $rows) {
        [pscustomobject]@{
            started_at = Parse-StorageTimestamp -Value $row.started_at
            task_id    = $row.task_id
            task_title = $row.task_title
            trigger    = $row.trigger
        }
    }
}

Export-ModuleMember -Function @(
    'Append-TaskLogEntry',
    'Get-FocusTimerDataDirectory',
    'Get-TaskLogFilePath',
    'Get-TasksFilePath',
    'Initialize-FocusTimerStorage',
    'Read-FocusTimerTasks',
    'Read-TaskLog',
    'Save-FocusTimerTasks'
)







