[CmdletBinding()]
param(
    [switch]$SmokeTest,
    [switch]$UiSmokeTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$moduleRoot = Join-Path -Path $scriptRoot -ChildPath 'src'

Import-Module (Join-Path -Path $moduleRoot -ChildPath 'FocusTimer.TimerEngine.psm1') -Force
Import-Module (Join-Path -Path $moduleRoot -ChildPath 'FocusTimer.TaskLogic.psm1') -Force
Import-Module (Join-Path -Path $moduleRoot -ChildPath 'FocusTimer.Storage.psm1') -Force
Import-Module (Join-Path -Path $moduleRoot -ChildPath 'FocusTimer.Toast.psm1') -Force

Initialize-FocusTimerStorage -BaseDirectory $scriptRoot

if ($SmokeTest) {
    $state = New-TimerState
    $tasks = Read-FocusTimerTasks -BaseDirectory $scriptRoot
    [pscustomobject]@{
        ok             = $true
        mode           = $state.Mode
        task_count     = @($tasks).Count
        data_directory = Get-FocusTimerDataDirectory -BaseDirectory $scriptRoot
    } | ConvertTo-Json -Compress
    return
}

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'focus-timer.ps1 must run in STA. Use focus-timer.bat or powershell.exe.'
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

$script:baseDirectory = $scriptRoot
$script:timerState = New-TimerState
$script:tasks = @(Read-FocusTimerTasks -BaseDirectory $script:baseDirectory)
$script:lastFocusedTaskId = $null
$script:taskWindow = $null
$script:taskListBox = $null
$script:taskDragStart = $null

function Convert-BoolToVisibility {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Value
    )

    if ($Value) {
        [System.Windows.Visibility]::Visible
    }
    else {
        [System.Windows.Visibility]::Collapsed
    }
}

function New-WpfWindowFromXaml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Xaml
    )

    $xml = [xml]$Xaml
    $reader = New-Object System.Xml.XmlNodeReader $xml
    [Windows.Markup.XamlReader]::Load($reader)
}

function Get-ArcGeometryData {
    param(
        [Parameter(Mandatory = $true)]
        [double]$Progress,

        [double]$CanvasSize = 72,

        [double]$Padding = 8
    )

    if ($Progress -le 0) {
        return $null
    }

    $radius = ($CanvasSize / 2.0) - $Padding
    $center = $CanvasSize / 2.0
    $startX = $center
    $startY = $center - $radius

    if ($Progress -ge 0.9999) {
        return 'FULL'
    }

    $angle = 360.0 * $Progress
    $endAngle = -90.0 + $angle
    $radians = $endAngle * [Math]::PI / 180.0
    $endX = $center + ($radius * [Math]::Cos($radians))
    $endY = $center + ($radius * [Math]::Sin($radians))
    $largeArc = if ($angle -gt 180.0) { 1 } else { 0 }

    'M {0},{1} A {2},{2} 0 {3} 1 {4},{5}' -f (
        [Math]::Round($startX, 2),
        [Math]::Round($startY, 2),
        [Math]::Round($radius, 2),
        $largeArc,
        [Math]::Round($endX, 2),
        [Math]::Round($endY, 2)
    )
}

function Get-MeterBrush {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$State
    )

    switch ($State.Mode) {
        'FocusRunning' {
            '#5BC0BE'
        }
        'BreakRunning' {
            '#F4A261'
        }
        'Paused' {
            '#9CA3AF'
        }
        'IdleChoice' {
            '#84CC16'
        }
        default {
            '#84CC16'
        }
    }
}

function Save-Tasks {
    Save-FocusTimerTasks -BaseDirectory $script:baseDirectory -Tasks $script:tasks
}

function Get-CurrentSelectedTask {
    Get-SelectedTask -Tasks $script:tasks
}

function Record-FocusTaskLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Trigger
    )

    $selectedTask = Get-CurrentSelectedTask
    if (-not $selectedTask) {
        $script:lastFocusedTaskId = $null
        return
    }

    Append-TaskLogEntry -BaseDirectory $script:baseDirectory -Task $selectedTask -Trigger $Trigger
    $script:lastFocusedTaskId = $selectedTask.id
}

function Sync-FocusTaskSelection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    if ($script:timerState.Mode -ne 'FocusRunning') {
        $script:lastFocusedTaskId = $null
        return
    }

    switch ($Reason) {
        'focus_start' {
            Record-FocusTaskLog -Trigger 'focus_start'
            return
        }
        'focus_resumed' {
            Record-FocusTaskLog -Trigger 'focus_resumed'
            return
        }
    }

    $selectedTask = Get-CurrentSelectedTask

    if (-not $selectedTask) {
        $script:lastFocusedTaskId = $null
        return
    }

    if ($selectedTask.id -ne $script:lastFocusedTaskId) {
        Record-FocusTaskLog -Trigger 'task_switched'
    }
}

function Stop-OrStartDispatcherTimer {
    if ($script:timerState.Mode -in @('IdleRunning', 'FocusRunning', 'BreakRunning')) {
        $script:dispatcherTimer.Start()
    }
    else {
        $script:dispatcherTimer.Stop()
    }
}

function Handle-TimerEvents {
    param(
        [object[]]$Events
    )

    foreach ($eventItem in @($Events)) {
        switch ($eventItem.Type) {
            'idle_complete' {
                Show-IdleCompleteNotification | Out-Null
            }
            'focus_started' {
                Sync-FocusTaskSelection -Reason 'focus_start'
            }
            'focus_resumed' {
                Sync-FocusTaskSelection -Reason 'focus_resumed'
            }
            'break_started' {
                $script:lastFocusedTaskId = $null
            }
            'paused' {
                if ($eventItem.PausedMode -eq 'FocusRunning') {
                    $script:lastFocusedTaskId = $null
                }
            }
            'reset' {
                $script:lastFocusedTaskId = $null
            }
            'break_complete' {
                $script:lastFocusedTaskId = $null
            }
        }
    }
}

function Invoke-TimerOperation {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Result
    )

    $script:timerState = $Result.State
    Handle-TimerEvents -Events $Result.Events
    Stop-OrStartDispatcherTimer
    Update-MainWindow
}

function Get-TaskDisplayText {
    $selectedTask = Get-CurrentSelectedTask
    if ($selectedTask) {
        return $selectedTask.title
    }

    '表示対象のタスクはありません'
}

function Update-MainWindow {
    $progress = Get-TimerProgress -State $script:timerState
    $arcData = Get-ArcGeometryData -Progress $progress
    $meterColor = Get-MeterBrush -State $script:timerState
    $uiState = Get-TimerUiState -State $script:timerState

    $script:TimeText.Text = Get-TimerDisplayText -State $script:timerState
    $script:StatusText.Text = Get-TimerStatusText -State $script:timerState
    $script:TaskText.Text = Get-TaskDisplayText

    $script:MeterArc.Stroke = $meterColor
    $script:MeterFullCircle.Stroke = $meterColor

    if ($arcData -eq 'FULL') {
        $script:MeterArc.Visibility = 'Collapsed'
        $script:MeterFullCircle.Visibility = 'Visible'
        $script:MeterArc.Data = $null
    }
    elseif ($arcData) {
        $script:MeterArc.Visibility = 'Visible'
        $script:MeterFullCircle.Visibility = 'Collapsed'
        $script:MeterArc.Data = [System.Windows.Media.Geometry]::Parse($arcData)
    }
    else {
        $script:MeterArc.Visibility = 'Collapsed'
        $script:MeterFullCircle.Visibility = 'Collapsed'
        $script:MeterArc.Data = $null
    }

    $script:PlayButton.Content = $uiState.PlayLabel
    $script:PlayButton.IsEnabled = $uiState.CanPlay
    $script:PauseButton.IsEnabled = $uiState.CanPause
    $script:ResetButton.IsEnabled = $uiState.CanReset

    $script:FocusChoiceButton.Visibility = Convert-BoolToVisibility -Value $uiState.ShowFocusChoice
    $script:IdleBreakChoiceButton.Visibility = Convert-BoolToVisibility -Value $uiState.ShowIdleBreakChoice
    $script:FocusBreakButton.Visibility = Convert-BoolToVisibility -Value $uiState.ShowFocusBreak
    $script:FocusBreakButton.Content = $uiState.FocusBreakLabel
    $script:IdleBreakChoiceButton.Content = $uiState.IdleBreakLabel
}

function Refresh-TaskListBox {
    if (-not $script:taskListBox) {
        return
    }

    $selectedId = $null
    if ($script:taskListBox.SelectedItem) {
        $selectedId = $script:taskListBox.SelectedItem.id
    }

    $ordered = @(Get-OrderedTasks -Tasks $script:tasks)
    $script:taskListBox.ItemsSource = $null
    $script:taskListBox.ItemsSource = $ordered

    if ($selectedId) {
        foreach ($item in $ordered) {
            if ($item.id -eq $selectedId) {
                $script:taskListBox.SelectedItem = $item
                break
            }
        }
    }
}

function Handle-TaskCollectionChanged {
    Save-Tasks
    Refresh-TaskListBox
    Update-MainWindow
    Sync-FocusTaskSelection -Reason 'task_change'
}

function Set-TaskWindowStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status
    )

    if (-not $script:taskListBox) {
        return
    }

    $selectedTask = $script:taskListBox.SelectedItem
    if (-not $selectedTask) {
        return
    }

    $script:tasks = Set-TaskStatus -Tasks $script:tasks -TaskId $selectedTask.id -Status $Status -Now (Get-Date)
    Handle-TaskCollectionChanged
}

function Get-TaskWindowXaml {
@"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Task Manager"
        Width="420"
        Height="520"
        ResizeMode="CanResize"
        Background="#FFF9F6EE"
        WindowStartupLocation="CenterScreen">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto" />
      <RowDefinition Height="12" />
      <RowDefinition Height="*" />
      <RowDefinition Height="12" />
      <RowDefinition Height="Auto" />
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Orientation="Horizontal">
      <TextBox x:Name="TaskInput" Width="250" Height="32" Margin="0,0,8,0" Padding="8,5,8,5" />
      <Button x:Name="AddTaskButton" Width="100" Height="32" Content="追加" />
    </StackPanel>

    <ListBox x:Name="TaskListBox"
             Grid.Row="2"
             BorderThickness="0"
             Background="#00FFFFFF"
             AllowDrop="True">
      <ListBox.ItemTemplate>
        <DataTemplate>
          <Border Background="#FFF1E9D8"
                  BorderBrush="#FFD4B483"
                  BorderThickness="1"
                  CornerRadius="10"
                  Margin="0,0,0,8"
                  Padding="10">
            <DockPanel>
              <TextBlock Text="{Binding status}"
                         Foreground="#FF8B5E34"
                         FontWeight="Bold"
                         DockPanel.Dock="Right" />
              <TextBlock Text="{Binding title}"
                         TextWrapping="Wrap"
                         Foreground="#FF2E2520"
                         FontSize="14"
                         Margin="0,0,10,0" />
            </DockPanel>
          </Border>
        </DataTemplate>
      </ListBox.ItemTemplate>
    </ListBox>

    <WrapPanel Grid.Row="4">
      <Button x:Name="NormalStatusButton" Width="110" Height="32" Margin="0,0,8,8" Content="通常にする" />
      <Button x:Name="StoppedStatusButton" Width="110" Height="32" Margin="0,0,8,8" Content="停止にする" />
      <Button x:Name="DoneStatusButton" Width="110" Height="32" Margin="0,0,8,8" Content="完了にする" />
    </WrapPanel>
  </Grid>
</Window>
"@
}

function Open-TaskWindow {
    if ($script:taskWindow -and $script:taskWindow.IsVisible) {
        $script:taskWindow.Activate() | Out-Null
        return
    }

    $script:taskWindow = New-WpfWindowFromXaml -Xaml (Get-TaskWindowXaml)
    $script:taskListBox = $script:taskWindow.FindName('TaskListBox')
    $taskInput = $script:taskWindow.FindName('TaskInput')
    $addTaskButton = $script:taskWindow.FindName('AddTaskButton')
    $normalStatusButton = $script:taskWindow.FindName('NormalStatusButton')
    $stoppedStatusButton = $script:taskWindow.FindName('StoppedStatusButton')
    $doneStatusButton = $script:taskWindow.FindName('DoneStatusButton')

    Refresh-TaskListBox

    $addTaskButton.Add_Click({
        if ([string]::IsNullOrWhiteSpace($taskInput.Text)) {
            return
        }

        $script:tasks = Add-TaskItem -Tasks $script:tasks -Title $taskInput.Text -Now (Get-Date)
        $taskInput.Text = ''
        Handle-TaskCollectionChanged
    })

    $normalStatusButton.Add_Click({
        Set-TaskWindowStatus -Status 'Normal'
    })

    $stoppedStatusButton.Add_Click({
        Set-TaskWindowStatus -Status 'Stopped'
    })

    $doneStatusButton.Add_Click({
        Set-TaskWindowStatus -Status 'Done'
    })

    $script:taskListBox.Add_PreviewMouseLeftButtonDown({
        $script:taskDragStart = $_.GetPosition($script:taskListBox)
    })

    $script:taskListBox.Add_MouseMove({
        if ($_.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) {
            return
        }

        if (-not $script:taskListBox.SelectedItem) {
            return
        }

        if (-not $script:taskDragStart) {
            return
        }

        $position = $_.GetPosition($script:taskListBox)
        $deltaX = [Math]::Abs($position.X - $script:taskDragStart.X)
        $deltaY = [Math]::Abs($position.Y - $script:taskDragStart.Y)

        if ($deltaX -lt 4 -and $deltaY -lt 4) {
            return
        }

        [System.Windows.DragDrop]::DoDragDrop(
            $script:taskListBox,
            $script:taskListBox.SelectedItem,
            [System.Windows.DragDropEffects]::Move
        ) | Out-Null
    })

    $script:taskListBox.Add_Drop({
        $sourceTask = $_.Data.GetData([object])
        if (-not $sourceTask) {
            return
        }

        $position = $_.GetPosition($script:taskListBox)
        $targetElement = $script:taskListBox.InputHitTest($position)

        while ($targetElement -and -not ($targetElement -is [System.Windows.Controls.ListBoxItem])) {
            $targetElement = [System.Windows.Media.VisualTreeHelper]::GetParent($targetElement)
        }

        $orderedTasks = @(Get-OrderedTasks -Tasks $script:tasks)
        if ($orderedTasks.Count -eq 0) {
            return
        }

        $targetIndex = $orderedTasks.Count - 1
        if ($targetElement) {
            $targetTask = $targetElement.DataContext
            for ($index = 0; $index -lt $orderedTasks.Count; $index++) {
                if ($orderedTasks[$index].id -eq $targetTask.id) {
                    $targetIndex = $index
                    break
                }
            }
        }

        $script:tasks = Move-TaskItem -Tasks $script:tasks -TaskId $sourceTask.id -TargetIndex $targetIndex -Now (Get-Date)
        Handle-TaskCollectionChanged
    })

    $script:taskWindow.Add_Closed({
        $script:taskWindow = $null
        $script:taskListBox = $null
        $script:taskDragStart = $null
    })

    $script:taskWindow.Show()
    $script:taskWindow.Activate() | Out-Null
}

$mainWindowXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="420"
        Height="180"
        ShowInTaskbar="False"
        Topmost="True"
        AllowsTransparency="True"
        Background="Transparent"
        WindowStyle="None"
        ResizeMode="NoResize"
        WindowStartupLocation="Manual">
  <Grid Margin="12">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="Auto" />
      <ColumnDefinition Width="12" />
      <ColumnDefinition Width="*" />
    </Grid.ColumnDefinitions>

    <Border Grid.Column="0"
            Background="#D91E293B"
            Padding="10"
            CornerRadius="40">
      <Grid Width="72" Height="72">
        <Ellipse Stroke="#33FFFFFF" StrokeThickness="8" />
        <Ellipse x:Name="MeterFullCircle" StrokeThickness="8" Visibility="Collapsed" />
        <Path x:Name="MeterArc"
              StrokeThickness="8"
              StrokeStartLineCap="Round"
              StrokeEndLineCap="Round"
              Visibility="Collapsed" />
        <TextBlock x:Name="TimeText"
                   HorizontalAlignment="Center"
                   VerticalAlignment="Center"
                   Foreground="White"
                   FontSize="14"
                   FontWeight="Bold"
                   Text="00:00" />
      </Grid>
    </Border>

    <StackPanel Grid.Column="2" VerticalAlignment="Center">
      <Border Background="#D91E293B" CornerRadius="16" Padding="12" Margin="0,0,0,10">
        <StackPanel>
          <TextBlock x:Name="StatusText"
                     Text="待機中"
                     Foreground="#FFB8F2E6"
                     FontSize="11"
                     FontWeight="Bold" />
          <TextBlock x:Name="TaskText"
                     Text="表示対象のタスクはありません"
                     Foreground="White"
                     FontSize="14"
                     Margin="0,4,0,0"
                     Width="280"
                     TextWrapping="Wrap" />
        </StackPanel>
      </Border>

      <WrapPanel>
        <Button x:Name="PlayButton" Width="68" Height="30" Margin="0,0,8,8" Content="再生" />
        <Button x:Name="PauseButton" Width="68" Height="30" Margin="0,0,8,8" Content="一時停止" />
        <Button x:Name="ResetButton" Width="68" Height="30" Margin="0,0,8,8" Content="リセット" />
        <Button x:Name="OpenTasksButton" Width="92" Height="30" Margin="0,0,8,8" Content="タスク管理" />
        <Button x:Name="FocusChoiceButton" Width="88" Height="30" Margin="0,0,8,8" Content="focus" Visibility="Collapsed" />
        <Button x:Name="IdleBreakChoiceButton" Width="88" Height="30" Margin="0,0,8,8" Content="休憩 1分" Visibility="Collapsed" />
        <Button x:Name="FocusBreakButton" Width="88" Height="30" Margin="0,0,8,8" Content="休憩 5分" Visibility="Collapsed" />
      </WrapPanel>
    </StackPanel>
  </Grid>
</Window>
"@

$script:mainWindow = New-WpfWindowFromXaml -Xaml $mainWindowXaml
$script:MeterArc = $script:mainWindow.FindName('MeterArc')
$script:MeterFullCircle = $script:mainWindow.FindName('MeterFullCircle')
$script:TimeText = $script:mainWindow.FindName('TimeText')
$script:StatusText = $script:mainWindow.FindName('StatusText')
$script:TaskText = $script:mainWindow.FindName('TaskText')
$script:PlayButton = $script:mainWindow.FindName('PlayButton')
$script:PauseButton = $script:mainWindow.FindName('PauseButton')
$script:ResetButton = $script:mainWindow.FindName('ResetButton')
$script:OpenTasksButton = $script:mainWindow.FindName('OpenTasksButton')
$script:FocusChoiceButton = $script:mainWindow.FindName('FocusChoiceButton')
$script:IdleBreakChoiceButton = $script:mainWindow.FindName('IdleBreakChoiceButton')
$script:FocusBreakButton = $script:mainWindow.FindName('FocusBreakButton')

$script:dispatcherTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:dispatcherTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:dispatcherTimer.Add_Tick({
    $result = Advance-Timer -State $script:timerState -Seconds 1
    Invoke-TimerOperation -Result $result
})

$script:PlayButton.Add_Click({
    $result = Start-Timer -State $script:timerState
    Invoke-TimerOperation -Result $result
})

$script:PauseButton.Add_Click({
    $result = Pause-Timer -State $script:timerState
    Invoke-TimerOperation -Result $result
})

$script:ResetButton.Add_Click({
    $result = Reset-Timer -State $script:timerState
    Invoke-TimerOperation -Result $result
})

$script:OpenTasksButton.Add_Click({
    Open-TaskWindow
})

$script:FocusChoiceButton.Add_Click({
    $result = Choose-IdleAction -State $script:timerState -Choice 'Focus'
    Invoke-TimerOperation -Result $result
})

$script:IdleBreakChoiceButton.Add_Click({
    $result = Choose-IdleAction -State $script:timerState -Choice 'Break'
    Invoke-TimerOperation -Result $result
})

$script:FocusBreakButton.Add_Click({
    $result = Start-FocusBreak -State $script:timerState
    Invoke-TimerOperation -Result $result
})

$script:mainWindow.Add_Loaded({
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $script:mainWindow.Left = $workArea.Left + 18
    $script:mainWindow.Top = $workArea.Bottom - $script:mainWindow.Height - 24
    Update-MainWindow
})

$script:mainWindow.Add_Closed({
    if ($script:dispatcherTimer) {
        $script:dispatcherTimer.Stop()
    }

    if ($script:taskWindow) {
        $script:taskWindow.Close()
    }
})

Update-MainWindow

if ($UiSmokeTest) {
    $taskWindowProbe = New-WpfWindowFromXaml -Xaml (Get-TaskWindowXaml)
    [pscustomobject]@{
        ok            = $true
        ui_loaded     = $true
        main_title    = $script:mainWindow.Title
        task_title    = $taskWindowProbe.Title
        control_probe = @(
            [bool]$script:mainWindow.FindName('PlayButton'),
            [bool]$taskWindowProbe.FindName('TaskListBox')
        ) -notcontains $false
    } | ConvertTo-Json -Compress

    $taskWindowProbe.Close()
    $script:mainWindow.Close()
    return
}

[void]$script:mainWindow.ShowDialog()




