Set-StrictMode -Version Latest

$script:FallbackNotifyIcon = $null

function Get-FallbackNotifyIcon {
    if ($script:FallbackNotifyIcon) {
        return $script:FallbackNotifyIcon
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
    $notifyIcon.Visible = $true
    $script:FallbackNotifyIcon = $notifyIcon
    $script:FallbackNotifyIcon
}

function Show-NotificationFallback {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $notifyIcon = Get-FallbackNotifyIcon
    $notifyIcon.BalloonTipTitle = $Title
    $notifyIcon.BalloonTipText = $Message
    $notifyIcon.ShowBalloonTip(5000)
    $false
}

function Show-IdleCompleteNotification {
    param(
        [string]$Title = 'focus-timer',

        [string]$Message = '1分経過しました。focus または break を選んでください。'
    )

    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction SilentlyContinue
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] > $null

        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $toastXml = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>$Title</text>
      <text>$Message</text>
    </binding>
  </visual>
</toast>
"@
        $xml.LoadXml($toastXml)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Windows PowerShell')
        $notifier.Show($toast)
        return $true
    }
    catch {
        Show-NotificationFallback -Title $Title -Message $Message | Out-Null
        return $false
    }
}

Export-ModuleMember -Function 'Show-IdleCompleteNotification'







