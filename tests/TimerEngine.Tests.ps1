$modulePath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'src\FocusTimer.TimerEngine.psm1'
Import-Module $modulePath -Force

Describe 'FocusTimer.TimerEngine' {
    It 'starts idle from the initial state' {
        $state = New-TimerState

        $result = Start-Timer -State $state

        $result.State.Mode | Should Be 'IdleRunning'
        $result.Events[0].Type | Should Be 'idle_started'
    }

    It 'transitions to IdleChoice at 60 seconds and emits a completion event' {
        $state = New-TimerState
        Start-Timer -State $state | Out-Null

        $result = Advance-Timer -State $state -Seconds 60

        $result.State.Mode | Should Be 'IdleChoice'
        $result.State.ElapsedSeconds | Should Be 60
        $result.Events[0].Type | Should Be 'idle_complete'
    }

    It 'starts focus from IdleChoice and keeps the meter full' {
        $state = New-TimerState
        Start-Timer -State $state | Out-Null
        Advance-Timer -State $state -Seconds 60 | Out-Null

        $result = Choose-IdleAction -State $state -Choice Focus

        $result.State.Mode | Should Be 'FocusRunning'
        $result.Events[0].Type | Should Be 'focus_started'
        (Get-TimerProgress -State $state) | Should Be 1
    }

    It 'starts a 1 minute break from IdleChoice' {
        $state = New-TimerState
        Start-Timer -State $state | Out-Null
        Advance-Timer -State $state -Seconds 60 | Out-Null

        $result = Choose-IdleAction -State $state -Choice Break

        $result.State.Mode | Should Be 'BreakRunning'
        $result.State.BreakRemainingSeconds | Should Be 60
        $result.Events[0].DurationSeconds | Should Be 60
    }

    It 'starts a 5 minute break from focus' {
        $state = New-TimerState
        Start-Timer -State $state | Out-Null
        Advance-Timer -State $state -Seconds 60 | Out-Null
        Choose-IdleAction -State $state -Choice Focus | Out-Null

        $result = Start-FocusBreak -State $state

        $result.State.Mode | Should Be 'BreakRunning'
        $result.State.BreakRemainingSeconds | Should Be 300
        $result.Events[0].Source | Should Be 'FocusRunning'
    }

    It 'returns to idle when a break completes' {
        $state = New-TimerState
        Start-Timer -State $state | Out-Null
        Advance-Timer -State $state -Seconds 60 | Out-Null
        Choose-IdleAction -State $state -Choice Break | Out-Null

        $result = Advance-Timer -State $state -Seconds 60

        $result.State.Mode | Should Be 'IdleRunning'
        $result.State.ElapsedSeconds | Should Be 0
        $result.Events[0].Type | Should Be 'break_complete'
    }

    It 'pauses and resumes focus with a focus_resumed event' {
        $state = New-TimerState
        Start-Timer -State $state | Out-Null
        Advance-Timer -State $state -Seconds 60 | Out-Null
        Choose-IdleAction -State $state -Choice Focus | Out-Null

        $pauseResult = Pause-Timer -State $state
        $pauseMode = $pauseResult.State.Mode
        $pausedMode = $pauseResult.Events[0].PausedMode
        $resumeResult = Start-Timer -State $state

        $pauseMode | Should Be 'Paused'
        $pausedMode | Should Be 'FocusRunning'
        $resumeResult.State.Mode | Should Be 'FocusRunning'
        $resumeResult.Events[0].Type | Should Be 'focus_resumed'
    }

    It 'resets to the initial state from anywhere' {
        $state = New-TimerState
        Start-Timer -State $state | Out-Null
        Advance-Timer -State $state -Seconds 60 | Out-Null
        Choose-IdleAction -State $state -Choice Focus | Out-Null

        $result = Reset-Timer -State $state

        $result.State.Mode | Should Be 'Initial'
        $result.State.ElapsedSeconds | Should Be 0
        $result.Events[0].Type | Should Be 'reset'
    }

    It 'formats the break countdown for display' {
        $state = New-TimerState
        Start-Timer -State $state | Out-Null
        Advance-Timer -State $state -Seconds 60 | Out-Null
        Choose-IdleAction -State $state -Choice Break | Out-Null
        Advance-Timer -State $state -Seconds 5 | Out-Null

        Get-TimerDisplayText -State $state | Should Be '00:55'
    }
}







