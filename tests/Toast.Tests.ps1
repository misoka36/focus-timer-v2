$modulePath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'src\FocusTimer.Toast.psm1'
Import-Module $modulePath -Force

Describe 'FocusTimer.Toast' {
    It 'registers the default toast shortcut as a start app' {
        $result = Ensure-ToastShortcut

        (Test-Path -Path $result.ShortcutPath) | Should Be $true
        $result.AppId | Should Be 'FocusTimer.Desktop'
        $result.RegisteredAppId | Should Be 'FocusTimer.Desktop'
        $result.RegisteredName | Should Be 'focus-timer'
    }
}
