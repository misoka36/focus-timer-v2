Set-StrictMode -Version Latest

$script:FallbackNotifyIcon = $null
$script:ToastAppId = 'FocusTimer.Desktop'
$script:ToastShortcutName = 'focus-timer.lnk'

function Initialize-ToastShortcutInterop {
    if ('ToastShortcutNative' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct WIN32_FIND_DATAW
{
    public uint dwFileAttributes;
    public System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime;
    public System.Runtime.InteropServices.ComTypes.FILETIME ftLastAccessTime;
    public System.Runtime.InteropServices.ComTypes.FILETIME ftLastWriteTime;
    public uint nFileSizeHigh;
    public uint nFileSizeLow;
    public uint dwReserved0;
    public uint dwReserved1;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
    public string cFileName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)]
    public string cAlternateFileName;
}

[StructLayout(LayoutKind.Sequential, Pack = 4)]
public struct PROPERTYKEY
{
    public Guid fmtid;
    public uint pid;

    public PROPERTYKEY(Guid formatId, uint propertyId)
    {
        fmtid = formatId;
        pid = propertyId;
    }
}

[StructLayout(LayoutKind.Explicit)]
public struct PROPVARIANT
{
    [FieldOffset(0)]
    public ushort valueType;

    [FieldOffset(8)]
    public IntPtr pointerValue;
}

public static class PropVariantNative
{
    [DllImport("ole32.dll")]
    public static extern int PropVariantClear(ref PROPVARIANT propVariant);
}

[ComImport]
[Guid("000214F9-0000-0000-C000-000000000046")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IShellLinkW
{
    void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cch, out WIN32_FIND_DATAW pfd, uint fFlags);
    void GetIDList(out IntPtr ppidl);
    void SetIDList(IntPtr pidl);
    void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName, int cch);
    void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
    void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cch);
    void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
    void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cch);
    void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
    void GetHotkey(out short pwHotkey);
    void SetHotkey(short wHotkey);
    void GetShowCmd(out int piShowCmd);
    void SetShowCmd(int iShowCmd);
    void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cch, out int piIcon);
    void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
    void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
    void Resolve(IntPtr hwnd, uint fFlags);
    void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
}

[ComImport]
[Guid("0000010b-0000-0000-C000-000000000046")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPersistFile
{
    void GetClassID(out Guid pClassID);
    void IsDirty();
    void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
    void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, bool fRemember);
    void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
    void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
}

[ComImport]
[Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPropertyStore
{
    uint GetCount(out uint cProps);
    void GetAt(uint iProp, out PROPERTYKEY pkey);
    void GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
    void SetValue(ref PROPERTYKEY key, ref PROPVARIANT pv);
    void Commit();
}

[ComImport]
[Guid("00021401-0000-0000-C000-000000000046")]
public class CShellLink
{
}

public static class ToastShortcutNative
{
    private static readonly PROPERTYKEY AppUserModelIdKey =
        new PROPERTYKEY(new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5);

    public static void CreateShortcut(
        string shortcutPath,
        string targetPath,
        string arguments,
        string workingDirectory,
        string iconPath,
        string appUserModelId)
    {
        if (string.IsNullOrWhiteSpace(shortcutPath))
        {
            throw new ArgumentException("shortcutPath");
        }

        if (string.IsNullOrWhiteSpace(targetPath))
        {
            throw new ArgumentException("targetPath");
        }

        if (string.IsNullOrWhiteSpace(appUserModelId))
        {
            throw new ArgumentException("appUserModelId");
        }

        Directory.CreateDirectory(Path.GetDirectoryName(shortcutPath));

        IShellLinkW shellLink = null;
        IPropertyStore propertyStore = null;
        IPersistFile persistFile = null;

        try
        {
            shellLink = (IShellLinkW)new CShellLink();
            shellLink.SetPath(targetPath);

            if (!string.IsNullOrWhiteSpace(arguments))
            {
                shellLink.SetArguments(arguments);
            }

            if (!string.IsNullOrWhiteSpace(workingDirectory))
            {
                shellLink.SetWorkingDirectory(workingDirectory);
            }

            if (!string.IsNullOrWhiteSpace(iconPath))
            {
                shellLink.SetIconLocation(iconPath, 0);
            }

            propertyStore = (IPropertyStore)shellLink;
            PROPERTYKEY key = AppUserModelIdKey;
            PROPVARIANT appId = new PROPVARIANT();
            appId.valueType = 31;
            appId.pointerValue = Marshal.StringToCoTaskMemUni(appUserModelId);

            try
            {
                propertyStore.SetValue(ref key, ref appId);
                propertyStore.Commit();
            }
            finally
            {
                PropVariantNative.PropVariantClear(ref appId);
            }

            persistFile = (IPersistFile)shellLink;
            persistFile.Save(shortcutPath, true);
        }
        finally
        {
            if (persistFile != null)
            {
                Marshal.ReleaseComObject(persistFile);
            }

            if (propertyStore != null)
            {
                Marshal.ReleaseComObject(propertyStore);
            }

            if (shellLink != null)
            {
                Marshal.ReleaseComObject(shellLink);
            }
        }
    }
}
"@
}

function Test-ToastShortcutRegistration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShortcutPath,

        [Parameter(Mandatory = $true)]
        [string]$AppId
    )

    $getStartAppsCommand = Get-Command -Name Get-StartApps -ErrorAction SilentlyContinue
    if (-not $getStartAppsCommand) {
        return $null
    }

    $startMenuProgramsPath = Join-Path -Path $env:APPDATA -ChildPath 'Microsoft\Windows\Start Menu\Programs'
    if (-not $ShortcutPath.StartsWith($startMenuProgramsPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    $shortcutName = [System.IO.Path]::GetFileNameWithoutExtension($ShortcutPath)

    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $registeredApp = @(Get-StartApps | Where-Object {
            $_.AppID -eq $AppId -and $_.Name -eq $shortcutName
        })[0]

        if ($registeredApp) {
            return $registeredApp
        }

        Start-Sleep -Milliseconds 200
    }

    $null
}

function Get-DefaultToastRegistration {
    $applicationRoot = Split-Path -Parent $PSScriptRoot
    $scriptPath = Join-Path -Path $applicationRoot -ChildPath 'focus-timer.ps1'

    if (-not (Test-Path -Path $scriptPath)) {
        throw "Unable to locate toast notification script target: $scriptPath"
    }

    $powershellPath = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
    if (-not (Test-Path -Path $powershellPath)) {
        $powershellPath = (Get-Command powershell.exe -ErrorAction Stop).Source
    }

    [pscustomobject]@{
        ShortcutPath     = Join-Path -Path (Join-Path -Path $env:APPDATA -ChildPath 'Microsoft\Windows\Start Menu\Programs') -ChildPath $script:ToastShortcutName
        TargetPath       = $powershellPath
        Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
        WorkingDirectory = $applicationRoot
        IconPath         = $powershellPath
        AppId            = $script:ToastAppId
    }
}

function Ensure-ToastShortcut {
    param(
        [string]$ShortcutPath,
        [string]$TargetPath,
        [string]$Arguments,
        [string]$WorkingDirectory,
        [string]$IconPath,
        [string]$AppId = $script:ToastAppId
    )

    $registration = Get-DefaultToastRegistration

    if ($PSBoundParameters.ContainsKey('ShortcutPath')) {
        $registration.ShortcutPath = $ShortcutPath
    }

    if ($PSBoundParameters.ContainsKey('TargetPath')) {
        $registration.TargetPath = $TargetPath
    }

    if ($PSBoundParameters.ContainsKey('Arguments')) {
        $registration.Arguments = $Arguments
    }

    if ($PSBoundParameters.ContainsKey('WorkingDirectory')) {
        $registration.WorkingDirectory = $WorkingDirectory
    }

    if ($PSBoundParameters.ContainsKey('IconPath')) {
        $registration.IconPath = $IconPath
    }

    if ($PSBoundParameters.ContainsKey('AppId')) {
        $registration.AppId = $AppId
    }

    Initialize-ToastShortcutInterop
    [ToastShortcutNative]::CreateShortcut(
        $registration.ShortcutPath,
        $registration.TargetPath,
        $registration.Arguments,
        $registration.WorkingDirectory,
        $registration.IconPath,
        $registration.AppId
    )

    $registeredStartApp = Test-ToastShortcutRegistration -ShortcutPath $registration.ShortcutPath -AppId $registration.AppId
    $registeredAppId = if ($registeredStartApp) { $registeredStartApp.AppID } else { $null }
    $registeredName = if ($registeredStartApp) { $registeredStartApp.Name } else { $null }

    if ($registration.ShortcutPath.StartsWith((Join-Path -Path $env:APPDATA -ChildPath 'Microsoft\Windows\Start Menu\Programs'), [System.StringComparison]::OrdinalIgnoreCase) -and
        (Get-Command -Name Get-StartApps -ErrorAction SilentlyContinue) -and
        $registeredAppId -ne $registration.AppId) {
        throw "Toast shortcut registration failed for AppUserModelID '$($registration.AppId)'."
    }

    [pscustomobject]@{
        ShortcutPath     = $registration.ShortcutPath
        TargetPath       = $registration.TargetPath
        Arguments        = $registration.Arguments
        WorkingDirectory = $registration.WorkingDirectory
        IconPath         = $registration.IconPath
        AppId            = $registration.AppId
        RegisteredAppId  = $registeredAppId
        RegisteredName   = $registeredName
    }
}

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
        $toastRegistration = Ensure-ToastShortcut

        Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction SilentlyContinue
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] > $null

        $safeTitle = [System.Security.SecurityElement]::Escape($Title)
        $safeMessage = [System.Security.SecurityElement]::Escape($Message)

        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $toastXml = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>$safeTitle</text>
      <text>$safeMessage</text>
    </binding>
  </visual>
</toast>
"@
        $xml.LoadXml($toastXml)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($toastRegistration.AppId)
        $notifier.Show($toast)
        return $true
    }
    catch {
        Show-NotificationFallback -Title $Title -Message $Message | Out-Null
        return $false
    }
}

Export-ModuleMember -Function @(
    'Ensure-ToastShortcut',
    'Show-IdleCompleteNotification'
)
