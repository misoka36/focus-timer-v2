Set-StrictMode -Version Latest

function New-TimerEvent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Type,

        [hashtable]$Data = @{}
    )

    $eventData = [ordered]@{
        Type = $Type
    }

    foreach ($key in $Data.Keys) {
        $eventData[$key] = $Data[$key]
    }

    [pscustomobject]$eventData
}

function New-TimerResult {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$State,

        [object[]]$Events = @()
    )

    [pscustomobject]@{
        State  = $State
        Events = @($Events)
    }
}

function Convert-SecondsToDisplayText {
    param(
        [Parameter(Mandatory = $true)]
        [int]$TotalSeconds
    )

    if ($TotalSeconds -lt 0) {
        $TotalSeconds = 0
    }

    $minutes = [int][Math]::Floor($TotalSeconds / 60)
    $seconds = $TotalSeconds % 60
    '{0:D2}:{1:D2}' -f $minutes, $seconds
}

function New-TimerState {
    [pscustomobject]@{
        Mode                  = 'Initial'
        PreviousMode          = $null
        ElapsedSeconds        = 0
        BreakRemainingSeconds = 0
        BreakDurationSeconds  = 0
    }
}

function Start-Timer {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$State
    )

    $events = @()

    switch ($State.Mode) {
        'Initial' {
            $State.Mode = 'IdleRunning'
            $State.PreviousMode = $null
            $State.ElapsedSeconds = 0
            $State.BreakRemainingSeconds = 0
            $State.BreakDurationSeconds = 0
            $events += New-TimerEvent -Type 'idle_started'
        }
        'Paused' {
            if (-not $State.PreviousMode) {
                throw 'Paused state does not contain a previous mode.'
            }

            $resumeMode = $State.PreviousMode
            $State.Mode = $resumeMode
            $State.PreviousMode = $null

            switch ($resumeMode) {
                'IdleRunning' {
                    $events += New-TimerEvent -Type 'idle_resumed'
                }
                'FocusRunning' {
                    $events += New-TimerEvent -Type 'focus_resumed'
                }
                'BreakRunning' {
                    $events += New-TimerEvent -Type 'break_resumed'
                }
                default {
                    $events += New-TimerEvent -Type 'resumed' -Data @{ ResumedMode = $resumeMode }
                }
            }
        }
        default {
        }
    }

    New-TimerResult -State $State -Events $events
}

function Pause-Timer {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$State
    )

    $events = @()

    if ($State.Mode -in @('IdleRunning', 'FocusRunning', 'BreakRunning')) {
        $pausedMode = $State.Mode
        $State.Mode = 'Paused'
        $State.PreviousMode = $pausedMode
        $events += New-TimerEvent -Type 'paused' -Data @{ PausedMode = $pausedMode }
    }

    New-TimerResult -State $State -Events $events
}

function Reset-Timer {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$State
    )

    $State.Mode = 'Initial'
    $State.PreviousMode = $null
    $State.ElapsedSeconds = 0
    $State.BreakRemainingSeconds = 0
    $State.BreakDurationSeconds = 0

    New-TimerResult -State $State -Events @(New-TimerEvent -Type 'reset')
}

function Advance-Timer {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$State,

        [int]$Seconds = 1
    )

    if ($Seconds -le 0) {
        return (New-TimerResult -State $State)
    }

    $events = @()

    switch ($State.Mode) {
        'IdleRunning' {
            $State.ElapsedSeconds += $Seconds

            if ($State.ElapsedSeconds -ge 60) {
                $State.ElapsedSeconds = 60
                $State.Mode = 'IdleChoice'
                $events += New-TimerEvent -Type 'idle_complete'
            }
        }
        'FocusRunning' {
            $State.ElapsedSeconds += $Seconds
        }
        'BreakRunning' {
            $State.BreakRemainingSeconds -= $Seconds

            if ($State.BreakRemainingSeconds -le 0) {
                $State.Mode = 'IdleRunning'
                $State.PreviousMode = $null
                $State.ElapsedSeconds = 0
                $State.BreakRemainingSeconds = 0
                $State.BreakDurationSeconds = 0
                $events += New-TimerEvent -Type 'break_complete'
            }
        }
        default {
        }
    }

    New-TimerResult -State $State -Events $events
}

function Choose-IdleAction {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$State,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Focus', 'Break')]
        [string]$Choice
    )

    if ($State.Mode -ne 'IdleChoice') {
        throw 'Idle action can only be selected from IdleChoice state.'
    }

    $events = @()

    switch ($Choice) {
        'Focus' {
            $State.Mode = 'FocusRunning'
            $events += New-TimerEvent -Type 'focus_started'
        }
        'Break' {
            $State.Mode = 'BreakRunning'
            $State.BreakDurationSeconds = 60
            $State.BreakRemainingSeconds = 60
            $events += New-TimerEvent -Type 'break_started' -Data @{
                Source          = 'IdleChoice'
                DurationSeconds = 60
            }
        }
    }

    New-TimerResult -State $State -Events $events
}

function Start-FocusBreak {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$State
    )

    if ($State.Mode -ne 'FocusRunning') {
        throw 'Focus break can only be started from FocusRunning state.'
    }

    $State.Mode = 'BreakRunning'
    $State.BreakDurationSeconds = 300
    $State.BreakRemainingSeconds = 300

    New-TimerResult -State $State -Events @(
        New-TimerEvent -Type 'break_started' -Data @{
            Source          = 'FocusRunning'
            DurationSeconds = 300
        }
    )
}

function Get-TimerDisplayText {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$State
    )

    if ($State.Mode -eq 'Paused' -and $State.PreviousMode -eq 'BreakRunning') {
        return Convert-SecondsToDisplayText -TotalSeconds $State.BreakRemainingSeconds
    }

    if ($State.Mode -eq 'BreakRunning') {
        return Convert-SecondsToDisplayText -TotalSeconds $State.BreakRemainingSeconds
    }

    Convert-SecondsToDisplayText -TotalSeconds $State.ElapsedSeconds
}

function Get-TimerProgress {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$State
    )

    switch ($State.Mode) {
        'Initial' {
            return 0.0
        }
        'IdleRunning' {
            return [Math]::Min(($State.ElapsedSeconds / 60.0), 1.0)
        }
        'IdleChoice' {
            return 1.0
        }
        'FocusRunning' {
            return 1.0
        }
        'BreakRunning' {
            if ($State.BreakDurationSeconds -le 0) {
                return 0.0
            }

            return [Math]::Max([Math]::Min(($State.BreakRemainingSeconds / [double]$State.BreakDurationSeconds), 1.0), 0.0)
        }
        'Paused' {
            if ($State.PreviousMode -eq 'BreakRunning') {
                if ($State.BreakDurationSeconds -le 0) {
                    return 0.0
                }

                return [Math]::Max([Math]::Min(($State.BreakRemainingSeconds / [double]$State.BreakDurationSeconds), 1.0), 0.0)
            }

            return [Math]::Min(($State.ElapsedSeconds / 60.0), 1.0)
        }
        default {
            return 0.0
        }
    }
}

function Get-TimerUiState {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$State
    )

    [pscustomobject]@{
        CanPlay             = $State.Mode -in @('Initial', 'Paused')
        PlayLabel           = '▶'
        CanPause            = $State.Mode -in @('IdleRunning', 'FocusRunning', 'BreakRunning')
        CanReset            = $true
        ShowFocusChoice     = $State.Mode -eq 'IdleChoice'
        ShowIdleBreakChoice = $State.Mode -eq 'IdleChoice'
        ShowFocusBreak      = $State.Mode -eq 'FocusRunning'
        FocusBreakLabel     = '☕'
        IdleBreakLabel      = '☕'
    }
}

function Get-TimerStatusText {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$State
    )

    switch ($State.Mode) {
        'Initial' {
            '待機中'
        }
        'IdleRunning' {
            'Idle'
        }
        'IdleChoice' {
            '1分経過: focus か break を選択'
        }
        'FocusRunning' {
            'Focus'
        }
        'BreakRunning' {
            'Break'
        }
        'Paused' {
            if ($State.PreviousMode) {
                '一時停止 ({0})' -f $State.PreviousMode
            }
            else {
                '一時停止'
            }
        }
        default {
            $State.Mode
        }
    }
}

Export-ModuleMember -Function @(
    'Advance-Timer',
    'Choose-IdleAction',
    'Get-TimerDisplayText',
    'Get-TimerProgress',
    'Get-TimerStatusText',
    'Get-TimerUiState',
    'New-TimerState',
    'Pause-Timer',
    'Reset-Timer',
    'Start-FocusBreak',
    'Start-Timer'
)












