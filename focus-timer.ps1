[CmdletBinding()]
param(
    [switch]$SmokeTest,
    [switch]$UiSmokeTest,
    [switch]$TaskAddSmokeTest,
    [switch]$TaskAddByEnterSmokeTest,
    [switch]$TaskMoveSmokeTest,
    [string]$DataRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$moduleRoot = Join-Path -Path $scriptRoot -ChildPath 'src'

Import-Module (Join-Path -Path $moduleRoot -ChildPath 'FocusTimer.TimerEngine.psm1') -Force
Import-Module (Join-Path -Path $moduleRoot -ChildPath 'FocusTimer.TaskLogic.psm1') -Force
Import-Module (Join-Path -Path $moduleRoot -ChildPath 'FocusTimer.Storage.psm1') -Force
Import-Module (Join-Path -Path $moduleRoot -ChildPath 'FocusTimer.Toast.psm1') -Force

$resolvedDataRoot = if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $scriptRoot
}
else {
    $DataRoot
}

if ($SmokeTest) {
    $state = New-TimerState
    Initialize-FocusTimerStorage -BaseDirectory $resolvedDataRoot
    $tasks = Read-FocusTimerTasks -BaseDirectory $resolvedDataRoot
    [pscustomobject]@{
        ok             = $true
        mode           = $state.Mode
        task_count     = @($tasks).Count
        data_directory = Get-FocusTimerDataDirectory -BaseDirectory $resolvedDataRoot
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

$script:baseDirectory = $resolvedDataRoot
$script:timerState = New-TimerState
$script:tasks = @(Read-FocusTimerTasks -BaseDirectory $script:baseDirectory)
$script:tasks = @(Normalize-TaskOrder -Tasks $script:tasks)
$script:lastFocusedTaskId = $null
$script:taskWindow = $null
$script:activeTasksItemsControl = $null
$script:completedTasksItemsControl = $null
$script:taskInputBox = $null
$script:mainWindowDragEnabled = $false

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

        [double]$CanvasSize = 60,

        [double]$Padding = 6
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

function Get-ActiveTaskViewItems {
    $selectedTask = Get-CurrentSelectedTask

    foreach ($task in @(Get-ActiveTasks -Tasks $script:tasks)) {
        [pscustomobject]@{
            id                = $task.id
            order             = $task.order
            title             = $task.title
            status            = $task.status
            is_display_target = [bool]($selectedTask -and $selectedTask.id -eq $task.id)
        }
    }
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
    $script:PlayButton.ToolTip = if ($script:timerState.Mode -eq 'Paused') { '再開' } else { '再生' }
    $script:PauseButton.ToolTip = '一時停止'
    $script:ResetButton.ToolTip = 'リセット'
    $script:OpenTasksButton.ToolTip = 'タスク管理'

    $script:FocusChoiceButton.Visibility = Convert-BoolToVisibility -Value $uiState.ShowFocusChoice
    $script:IdleBreakChoiceButton.Visibility = Convert-BoolToVisibility -Value $uiState.ShowIdleBreakChoice
    $script:FocusBreakButton.Visibility = Convert-BoolToVisibility -Value $uiState.ShowFocusBreak
    $script:FocusBreakButton.Content = $uiState.FocusBreakLabel
    $script:IdleBreakChoiceButton.Content = $uiState.IdleBreakLabel
    $script:FocusChoiceButton.ToolTip = 'focus'
    $script:IdleBreakChoiceButton.ToolTip = '1分休憩'
    $script:FocusBreakButton.ToolTip = '5分休憩'
}

function Refresh-TaskViews {
    if ($script:activeTasksItemsControl) {
        $script:activeTasksItemsControl.ItemsSource = $null
        $script:activeTasksItemsControl.ItemsSource = @(Get-ActiveTaskViewItems)
    }

    if ($script:completedTasksItemsControl) {
        $script:completedTasksItemsControl.ItemsSource = $null
        $script:completedTasksItemsControl.ItemsSource = @(Get-CompletedTasks -Tasks $script:tasks)
    }
}

function Handle-TaskCollectionChanged {
    Save-Tasks
    Refresh-TaskViews
    Update-MainWindow
    Sync-FocusTaskSelection -Reason 'task_change'
}

function Submit-TaskInput {
    if (-not $script:taskInputBox) {
        return
    }

    $title = $script:taskInputBox.Text
    if ([string]::IsNullOrWhiteSpace($title)) {
        return
    }

    $script:tasks = Add-TaskItem -Tasks $script:tasks -Title $title -Now (Get-Date)
    $script:taskInputBox.Text = ''
    Handle-TaskCollectionChanged
}

function Handle-TaskInputKeyDown {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Key
    )

    $keyName = [string]$Key
    if ($keyName -in @('Enter', 'Return')) {
        Submit-TaskInput
        return $true
    }

    $false
}

function Invoke-TaskRowAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('move_to_top', 'move_up', 'move_down', 'move_to_bottom', 'toggle_stopped', 'complete_task')]
        [string]$Action
    )

    $now = Get-Date

    switch ($Action) {
        'move_to_top' {
            $script:tasks = Move-TaskToTop -Tasks $script:tasks -TaskId $TaskId -Now $now
        }
        'move_up' {
            $script:tasks = Move-TaskUp -Tasks $script:tasks -TaskId $TaskId -Now $now
        }
        'move_down' {
            $script:tasks = Move-TaskDown -Tasks $script:tasks -TaskId $TaskId -Now $now
        }
        'move_to_bottom' {
            $script:tasks = Move-TaskToBottom -Tasks $script:tasks -TaskId $TaskId -Now $now
        }
        'toggle_stopped' {
            $script:tasks = Toggle-TaskStopped -Tasks $script:tasks -TaskId $TaskId -Now $now
        }
        'complete_task' {
            $script:tasks = Complete-TaskItem -Tasks $script:tasks -TaskId $TaskId -Now $now
        }
    }

    Handle-TaskCollectionChanged
}

function Get-ButtonFromRoutedSource {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Source
    )

    $current = $Source

    while ($current) {
        if ($current -is [System.Windows.Controls.Button]) {
            return $current
        }

        if (-not ($current -is [System.Windows.DependencyObject])) {
            return $null
        }

        $current = [System.Windows.Media.VisualTreeHelper]::GetParent($current)
    }

    $null
}

function Start-MainWindowDrag {
    param(
        [Parameter(Mandatory = $true)]
        [object]$EventArgs
    )

    if (Get-ButtonFromRoutedSource -Source $EventArgs.OriginalSource) {
        return
    }

    try {
        $script:mainWindow.DragMove()
        $EventArgs.Handled = $true
    }
    catch {
    }
}

function Get-TaskWindowXaml {
@"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Task Manager"
        Width="520"
        Height="620"
        ResizeMode="CanResize"
        Background="#FFF9F6EE"
        WindowStartupLocation="CenterScreen">
  <Window.Resources>
    <Style x:Key="TaskInputStyle" TargetType="TextBox">
      <Setter Property="Height" Value="36" />
      <Setter Property="Padding" Value="12,6,12,6" />
      <Setter Property="FontSize" Value="14" />
      <Setter Property="Foreground" Value="#FF2E2520" />
      <Setter Property="Background" Value="#FFFFFBF5" />
      <Setter Property="BorderBrush" Value="#FFE6D4BA" />
      <Setter Property="BorderThickness" Value="1" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border CornerRadius="14"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}">
              <ScrollViewer x:Name="PART_ContentHost"
                            Margin="0"
                            VerticalAlignment="Center" />
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="TaskSectionTitleStyle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12" />
      <Setter Property="FontWeight" Value="Bold" />
      <Setter Property="Foreground" Value="#FF8B5E34" />
      <Setter Property="Margin" Value="2,0,0,0" />
    </Style>

    <Style x:Key="TaskModernIconButtonStyle" TargetType="Button">
      <Setter Property="Cursor" Value="Hand" />
      <Setter Property="Foreground" Value="#FF2D241F" />
      <Setter Property="Background" Value="#FFF7ECDD" />
      <Setter Property="BorderBrush" Value="#00FFFFFF" />
      <Setter Property="BorderThickness" Value="1" />
      <Setter Property="FontSize" Value="15" />
      <Setter Property="FontWeight" Value="SemiBold" />
      <Setter Property="Padding" Value="0" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Chrome"
                    CornerRadius="13"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center"
                                VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}" />
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#FFF1E1CB" />
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#FFE6D4BA" />
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Chrome" Property="Opacity" Value="0.42" />
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="TaskAddButtonStyle"
           TargetType="Button"
           BasedOn="{StaticResource TaskModernIconButtonStyle}">
      <Setter Property="Width" Value="58" />
      <Setter Property="Height" Value="36" />
      <Setter Property="FontSize" Value="17" />
      <Setter Property="Foreground" Value="White" />
      <Setter Property="Background" Value="#FF42B99A" />
      <Setter Property="BorderBrush" Value="#0042B99A" />
    </Style>

    <Style x:Key="TaskMoveButtonStyle"
           TargetType="Button"
           BasedOn="{StaticResource TaskModernIconButtonStyle}">
      <Setter Property="Width" Value="30" />
      <Setter Property="Height" Value="28" />
      <Setter Property="Margin" Value="0,0,0,4" />
      <Setter Property="FontSize" Value="13" />
      <Setter Property="Foreground" Value="#FF6C4B1F" />
      <Setter Property="Background" Value="#FFF7ECDD" />
      <Setter Property="BorderBrush" Value="#00FFFFFF" />
    </Style>

    <Style x:Key="TaskToggleButtonStyle"
           TargetType="Button"
           BasedOn="{StaticResource TaskModernIconButtonStyle}">
      <Setter Property="Width" Value="34" />
      <Setter Property="Height" Value="30" />
      <Setter Property="Margin" Value="0,0,4,4" />
      <Setter Property="FontSize" Value="15" />
      <Setter Property="Content" Value="⏸" />
      <Setter Property="ToolTip" Value="停止" />
      <Setter Property="Foreground" Value="#FF8A5A12" />
      <Setter Property="Background" Value="#FFFFF1DE" />
      <Setter Property="BorderBrush" Value="#00FFFFFF" />
      <Style.Triggers>
        <DataTrigger Binding="{Binding status}" Value="Stopped">
          <Setter Property="Content" Value="▶" />
          <Setter Property="ToolTip" Value="再開" />
          <Setter Property="Foreground" Value="#FF1C655C" />
          <Setter Property="Background" Value="#FFE3F5EF" />
        </DataTrigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="TaskCompleteButtonStyle"
           TargetType="Button"
           BasedOn="{StaticResource TaskModernIconButtonStyle}">
      <Setter Property="Width" Value="34" />
      <Setter Property="Height" Value="30" />
      <Setter Property="Margin" Value="0,0,0,4" />
      <Setter Property="FontSize" Value="15" />
      <Setter Property="Content" Value="✔" />
      <Setter Property="ToolTip" Value="完了" />
      <Setter Property="Foreground" Value="#FF1F6F43" />
      <Setter Property="Background" Value="#FFE6F5E8" />
      <Setter Property="BorderBrush" Value="#00FFFFFF" />
    </Style>

    <Style x:Key="ActiveTaskCardStyle" TargetType="Border">
      <Setter Property="Background" Value="#FFFFFBF4" />
      <Setter Property="BorderBrush" Value="#FFF0E1CE" />
      <Setter Property="BorderThickness" Value="1" />
      <Setter Property="CornerRadius" Value="16" />
      <Setter Property="Padding" Value="12" />
      <Style.Triggers>
        <DataTrigger Binding="{Binding is_display_target}" Value="True">
          <Setter Property="Background" Value="#FFFDF1D8" />
          <Setter Property="BorderBrush" Value="#FFE0B46D" />
          <Setter Property="BorderThickness" Value="1.5" />
        </DataTrigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="ActiveTaskTitleStyle" TargetType="TextBlock">
      <Setter Property="TextWrapping" Value="Wrap" />
      <Setter Property="Foreground" Value="#FF2E2520" />
      <Setter Property="FontSize" Value="14" />
      <Setter Property="FontWeight" Value="SemiBold" />
      <Style.Triggers>
        <DataTrigger Binding="{Binding is_display_target}" Value="True">
          <Setter Property="Foreground" Value="#FF3A2407" />
          <Setter Property="FontSize" Value="15" />
          <Setter Property="FontWeight" Value="Bold" />
        </DataTrigger>
        <DataTrigger Binding="{Binding status}" Value="Stopped">
          <Setter Property="Foreground" Value="#FF8F877B" />
          <Setter Property="Opacity" Value="0.74" />
        </DataTrigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="CompletedTaskTitleStyle" TargetType="TextBlock">
      <Setter Property="TextWrapping" Value="Wrap" />
      <Setter Property="Foreground" Value="#FF766E64" />
      <Setter Property="FontSize" Value="13" />
    </Style>

    <Style x:Key="TaskListHostStyle" TargetType="Border">
      <Setter Property="Background" Value="#66FFF7EB" />
      <Setter Property="BorderBrush" Value="#00FFFFFF" />
      <Setter Property="BorderThickness" Value="1" />
      <Setter Property="CornerRadius" Value="18" />
      <Setter Property="Padding" Value="10" />
    </Style>

  </Window.Resources>
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto" />
      <RowDefinition Height="12" />
      <RowDefinition Height="Auto" />
      <RowDefinition Height="8" />
      <RowDefinition Height="*" />
      <RowDefinition Height="12" />
      <RowDefinition Height="Auto" />
      <RowDefinition Height="8" />
      <RowDefinition Height="150" />
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Orientation="Horizontal">
      <TextBox x:Name="TaskInput"
               Width="250"
               Margin="0,0,10,0"
               Style="{StaticResource TaskInputStyle}" />
      <Button x:Name="AddTaskButton"
              Content="➕"
              ToolTip="タスク追加"
              Style="{StaticResource TaskAddButtonStyle}" />
    </StackPanel>

    <TextBlock Grid.Row="2"
               Text="Active"
               Style="{StaticResource TaskSectionTitleStyle}" />

    <Border Grid.Row="4" Style="{StaticResource TaskListHostStyle}">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <ItemsControl x:Name="ActiveTasksItemsControl">
          <ItemsControl.ItemTemplate>
            <DataTemplate>
              <Grid Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*" />
                  <ColumnDefinition Width="8" />
                  <ColumnDefinition Width="Auto" />
                </Grid.ColumnDefinitions>

                <Border Grid.Column="0"
                        Style="{StaticResource ActiveTaskCardStyle}">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="Auto" />
                      <ColumnDefinition Width="*" />
                      <ColumnDefinition Width="Auto" />
                    </Grid.ColumnDefinitions>

                    <TextBlock Grid.Column="0"
                               Text="●"
                               Foreground="#FFD09238"
                               FontSize="11"
                               FontWeight="Bold"
                               Margin="0,0,10,0"
                               VerticalAlignment="Center">
                      <TextBlock.Style>
                        <Style TargetType="TextBlock">
                          <Setter Property="Visibility" Value="Collapsed" />
                          <Style.Triggers>
                            <DataTrigger Binding="{Binding is_display_target}" Value="True">
                              <Setter Property="Visibility" Value="Visible" />
                            </DataTrigger>
                          </Style.Triggers>
                        </Style>
                      </TextBlock.Style>
                    </TextBlock>

                    <TextBlock Grid.Column="1"
                               Margin="0,0,12,0"
                               Text="{Binding title}"
                               Style="{StaticResource ActiveTaskTitleStyle}" />

                    <WrapPanel x:Name="TaskActionButtonsHost"
                               Grid.Column="2"
                               VerticalAlignment="Center">
                      <Button Tag="toggle_stopped"
                              CommandParameter="{Binding id}"
                              Style="{StaticResource TaskToggleButtonStyle}" />
                      <Button Tag="complete_task"
                              CommandParameter="{Binding id}"
                              Style="{StaticResource TaskCompleteButtonStyle}" />
                    </WrapPanel>
                  </Grid>
                </Border>

                <StackPanel x:Name="PriorityButtonsHost"
                            Grid.Column="2"
                            VerticalAlignment="Center">
                  <Button Tag="move_to_top"
                          CommandParameter="{Binding id}"
                          Content="⏫"
                          ToolTip="一番上へ"
                          Style="{StaticResource TaskMoveButtonStyle}" />
                  <Button Tag="move_up"
                          CommandParameter="{Binding id}"
                          Content="▲"
                          ToolTip="上へ"
                          Style="{StaticResource TaskMoveButtonStyle}" />
                  <Button Tag="move_down"
                          CommandParameter="{Binding id}"
                          Content="▼"
                          ToolTip="下へ"
                          Style="{StaticResource TaskMoveButtonStyle}" />
                  <Button Tag="move_to_bottom"
                          CommandParameter="{Binding id}"
                          Content="⏬"
                          ToolTip="一番下へ"
                          Style="{StaticResource TaskMoveButtonStyle}" />
                </StackPanel>
              </Grid>
            </DataTemplate>
          </ItemsControl.ItemTemplate>
        </ItemsControl>
      </ScrollViewer>
    </Border>

    <TextBlock Grid.Row="6"
               Text="Completed"
               Style="{StaticResource TaskSectionTitleStyle}" />

    <Border Grid.Row="8" Style="{StaticResource TaskListHostStyle}">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <ItemsControl x:Name="CompletedTasksItemsControl">
          <ItemsControl.ItemTemplate>
            <DataTemplate>
              <Border Background="#FFF6F2EA"
                      BorderBrush="#00FFFFFF"
                      BorderThickness="1"
                      CornerRadius="16"
                      Margin="0,0,0,8"
                      Padding="12">
                <DockPanel>
                  <TextBlock Text="✔"
                             Foreground="#FF1F6F43"
                             FontSize="13"
                             FontWeight="Bold"
                             Margin="0,0,8,0"
                             DockPanel.Dock="Left" />
                  <TextBlock Text="{Binding title}"
                             Style="{StaticResource CompletedTaskTitleStyle}" />
                </DockPanel>
              </Border>
            </DataTemplate>
          </ItemsControl.ItemTemplate>
        </ItemsControl>
      </ScrollViewer>
    </Border>
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
    $script:activeTasksItemsControl = $script:taskWindow.FindName('ActiveTasksItemsControl')
    $script:completedTasksItemsControl = $script:taskWindow.FindName('CompletedTasksItemsControl')
    $script:taskInputBox = $script:taskWindow.FindName('TaskInput')
    $addTaskButton = $script:taskWindow.FindName('AddTaskButton')

    Refresh-TaskViews

    $addTaskButton.Add_Click({
        Submit-TaskInput
    })

    $script:taskInputBox.Add_KeyDown({
        if (Handle-TaskInputKeyDown -Key $_.Key) {
            $_.Handled = $true
        }
    })

    $script:activeTasksItemsControl.AddHandler(
        [System.Windows.Controls.Button]::ClickEvent,
        [System.Windows.RoutedEventHandler]{
            param($sender, $eventArgs)

            $button = Get-ButtonFromRoutedSource -Source $eventArgs.OriginalSource
            if (-not $button) {
                return
            }

            $action = [string]$button.Tag
            if ([string]::IsNullOrWhiteSpace($action)) {
                return
            }

            $taskId = [string]$button.CommandParameter
            if ([string]::IsNullOrWhiteSpace($taskId)) {
                return
            }

            Invoke-TaskRowAction -TaskId $taskId -Action $action
            $eventArgs.Handled = $true
        }
    )

    $script:taskWindow.Add_Closed({
        $script:taskWindow = $null
        $script:activeTasksItemsControl = $null
        $script:completedTasksItemsControl = $null
        $script:taskInputBox = $null
    })

    $script:taskWindow.Show()
    $script:taskWindow.Activate() | Out-Null
}

function Get-TaskTitleSequence {
    param(
        [AllowNull()]
        [object[]]$Tasks
    )

    if (-not $Tasks) {
        return ''
    }

    (@(Get-OrderedTasks -Tasks $Tasks) | ForEach-Object { $_.title }) -join '|'
}

$mainWindowXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="368"
        Height="154"
        ShowInTaskbar="False"
        Topmost="True"
        AllowsTransparency="True"
        Background="Transparent"
        WindowStyle="None"
        ResizeMode="NoResize"
        WindowStartupLocation="Manual">
  <Window.Resources>
    <Style x:Key="FloatingFlatButtonStyle" TargetType="Button">
      <Setter Property="Width" Value="40" />
      <Setter Property="Height" Value="28" />
      <Setter Property="Margin" Value="0,0,6,6" />
      <Setter Property="Cursor" Value="Hand" />
      <Setter Property="Foreground" Value="White" />
      <Setter Property="Background" Value="#332A3442" />
      <Setter Property="BorderBrush" Value="#002A3442" />
      <Setter Property="BorderThickness" Value="1" />
      <Setter Property="Padding" Value="0" />
      <Setter Property="FontSize" Value="14" />
      <Setter Property="FontWeight" Value="SemiBold" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Chrome"
                    CornerRadius="14"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center"
                                VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}" />
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#442F3E52" />
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#5525313F" />
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Chrome" Property="Opacity" Value="0.38" />
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid Margin="9">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="Auto" />
      <ColumnDefinition Width="8" />
      <ColumnDefinition Width="*" />
    </Grid.ColumnDefinitions>

    <StackPanel Grid.Column="0" VerticalAlignment="Center">
      <Grid Width="60" Height="60">
        <Ellipse Stroke="#33FFFFFF" StrokeThickness="6" />
        <Ellipse x:Name="MeterFullCircle" StrokeThickness="6" Visibility="Collapsed" />
        <Path x:Name="MeterArc"
              StrokeThickness="6"
              StrokeStartLineCap="Round"
              StrokeEndLineCap="Round"
              Visibility="Collapsed" />
        <TextBlock x:Name="TimeText"
                   HorizontalAlignment="Center"
                   VerticalAlignment="Center"
                   Foreground="White"
                   FontSize="12"
                   FontWeight="Bold"
                   Text="00:00" />
      </Grid>

      <WrapPanel Margin="0,8,0,0" HorizontalAlignment="Center">
        <Button x:Name="PlayButton"
                Content="▶"
                ToolTip="再生"
                Background="#2F2DBA81"
                BorderBrush="#002DBA81"
                Style="{StaticResource FloatingFlatButtonStyle}" />
        <Button x:Name="PauseButton"
                Content="⏸"
                ToolTip="一時停止"
                Background="#2F617083"
                BorderBrush="#00617083"
                Style="{StaticResource FloatingFlatButtonStyle}" />
        <Button x:Name="ResetButton"
                Content="↺"
                ToolTip="リセット"
                Background="#2FC8666A"
                BorderBrush="#00C8666A"
                Style="{StaticResource FloatingFlatButtonStyle}" />
        <Button x:Name="FocusChoiceButton"
                Content="🎯"
                ToolTip="focus"
                Background="#2FC7993D"
                BorderBrush="#00C7993D"
                Visibility="Collapsed"
                Style="{StaticResource FloatingFlatButtonStyle}" />
        <Button x:Name="IdleBreakChoiceButton"
                Content="☕"
                ToolTip="1分休憩"
                Background="#2FD88952"
                BorderBrush="#00D88952"
                Visibility="Collapsed"
                Style="{StaticResource FloatingFlatButtonStyle}" />
        <Button x:Name="FocusBreakButton"
                Content="☕"
                ToolTip="5分休憩"
                Background="#2FC47654"
                BorderBrush="#00C47654"
                Visibility="Collapsed"
                Style="{StaticResource FloatingFlatButtonStyle}" />
      </WrapPanel>
    </StackPanel>

    <StackPanel Grid.Column="2" VerticalAlignment="Center">
      <Border Background="#D91E293B" CornerRadius="16" Padding="10">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*" />
            <ColumnDefinition Width="Auto" />
          </Grid.ColumnDefinitions>

          <TextBlock x:Name="TaskText"
                     Grid.Column="0"
                     Text="表示対象のタスクはありません"
                     Foreground="White"
                     FontSize="12"
                     Width="196"
                     VerticalAlignment="Center"
                     Margin="0,0,8,0"
                     TextWrapping="Wrap" />

          <Button x:Name="OpenTasksButton"
                  Grid.Column="1"
                  Content="☰"
                  ToolTip="タスク管理"
                  Background="#2F4B7ED1"
                  BorderBrush="#004B7ED1"
                  Style="{StaticResource FloatingFlatButtonStyle}" />
        </Grid>
      </Border>
    </StackPanel>
  </Grid>
</Window>
"@

$script:mainWindow = New-WpfWindowFromXaml -Xaml $mainWindowXaml
$script:MeterArc = $script:mainWindow.FindName('MeterArc')
$script:MeterFullCircle = $script:mainWindow.FindName('MeterFullCircle')
$script:TimeText = $script:mainWindow.FindName('TimeText')
$script:TaskText = $script:mainWindow.FindName('TaskText')
$script:PlayButton = $script:mainWindow.FindName('PlayButton')
$script:PauseButton = $script:mainWindow.FindName('PauseButton')
$script:ResetButton = $script:mainWindow.FindName('ResetButton')
$script:OpenTasksButton = $script:mainWindow.FindName('OpenTasksButton')
$script:FocusChoiceButton = $script:mainWindow.FindName('FocusChoiceButton')
$script:IdleBreakChoiceButton = $script:mainWindow.FindName('IdleBreakChoiceButton')
$script:FocusBreakButton = $script:mainWindow.FindName('FocusBreakButton')

$script:mainWindow.Add_PreviewMouseLeftButtonDown({
    Start-MainWindowDrag -EventArgs $_
})
$script:mainWindowDragEnabled = $true

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
    $taskWindowXaml = Get-TaskWindowXaml
    [pscustomobject]@{
        ok                  = $true
        ui_loaded           = $true
        main_title          = $script:mainWindow.Title
        task_title          = $taskWindowProbe.Title
        control_probe       = @(
            [bool]$script:mainWindow.FindName('PlayButton'),
            [bool]$taskWindowProbe.FindName('ActiveTasksItemsControl'),
            [bool]$taskWindowProbe.FindName('CompletedTasksItemsControl')
        ) -notcontains $false
        clickable_symbols   = @(
            ([string]$script:PlayButton.Content -eq '▶'),
            ([string]$script:PauseButton.Content -eq '⏸'),
            ([string]$script:ResetButton.Content -eq '↺'),
            ([string]$script:OpenTasksButton.Content -eq '☰'),
            ([string]$script:FocusChoiceButton.Content -eq '🎯'),
            ([string]$script:IdleBreakChoiceButton.Content -eq '☕'),
            ([string]$script:FocusBreakButton.Content -eq '☕'),
            $taskWindowXaml.Contains('Content="➕"'),
            $taskWindowXaml.Contains('Tag="toggle_stopped"'),
            $taskWindowXaml.Contains('Tag="complete_task"'),
            $taskWindowXaml.Contains('⏫'),
            $taskWindowXaml.Contains('▲'),
            $taskWindowXaml.Contains('▼'),
            $taskWindowXaml.Contains('⏬')
        ) -notcontains $false
        flat_button_styles   = @(
            $mainWindowXaml.Contains('FloatingFlatButtonStyle'),
            $taskWindowXaml.Contains('TaskModernIconButtonStyle'),
            $taskWindowXaml.Contains('TaskMoveButtonStyle'),
            -not $mainWindowXaml.Contains('DropShadowEffect'),
            -not $taskWindowXaml.Contains('DropShadowEffect'),
            -not $mainWindowXaml.Contains('TopSheen'),
            -not $taskWindowXaml.Contains('TopSheen')
        ) -notcontains $false
        task_manager_layout = @(
            -not $mainWindowXaml.Contains('StatusText'),
            -not $taskWindowXaml.Contains('NormalStatusButton'),
            -not $taskWindowXaml.Contains('StoppedStatusButton'),
            -not $taskWindowXaml.Contains('DoneStatusButton'),
            $taskWindowXaml.Contains('CompletedTasksItemsControl'),
            $taskWindowXaml.Contains('PriorityButtonsHost'),
            $taskWindowXaml.Contains('TaskActionButtonsHost'),
            $taskWindowXaml.Contains('is_display_target')
        ) -notcontains $false
        compact_main_layout = @(
            $mainWindowXaml.Contains('Width="368"'),
            $mainWindowXaml.Contains('Height="154"'),
            $mainWindowXaml.Contains('FontSize="12"'),
            $mainWindowXaml.Contains('Width="196"')
        ) -notcontains $false
        main_window_behavior = @(
            $script:mainWindowDragEnabled,
            $mainWindowXaml.Contains('WindowStyle="None"'),
            $mainWindowXaml.Contains('AllowsTransparency="True"')
        ) -notcontains $false
    } | ConvertTo-Json -Compress

    $taskWindowProbe.Close()
    $script:mainWindow.Close()
    return
}

if ($TaskAddSmokeTest) {
    Open-TaskWindow
    $addTaskButtonProbe = $script:taskWindow.FindName('AddTaskButton')
    $script:taskInputBox.Text = 'Smoke Task'
    $addTaskButtonProbe.RaiseEvent(
        (New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent))
    )

    $reloadedTasks = @(Read-FocusTimerTasks -BaseDirectory $script:baseDirectory)

    [pscustomobject]@{
        ok             = $true
        task_count     = @($script:tasks).Count
        saved_count    = $reloadedTasks.Count
        first_task     = if (@($script:tasks).Count -gt 0) { $script:tasks[0].title } else { $null }
        input_cleared  = [string]::IsNullOrEmpty($script:taskInputBox.Text)
    } | ConvertTo-Json -Compress

    $script:taskWindow.Close()
    $script:mainWindow.Close()
    return
}

if ($TaskAddByEnterSmokeTest) {
    Open-TaskWindow
    $script:taskInputBox.Text = 'Enter Task'
    $handled = Handle-TaskInputKeyDown -Key 'Enter'

    $reloadedTasks = @(Read-FocusTimerTasks -BaseDirectory $script:baseDirectory)

    [pscustomobject]@{
        ok             = $true
        handled        = $handled
        task_count     = @($script:tasks).Count
        saved_count    = $reloadedTasks.Count
        first_task     = if (@($script:tasks).Count -gt 0) { $script:tasks[0].title } else { $null }
        input_cleared  = [string]::IsNullOrEmpty($script:taskInputBox.Text)
    } | ConvertTo-Json -Compress

    $script:taskWindow.Close()
    $script:mainWindow.Close()
    return
}

if ($TaskMoveSmokeTest) {
    $seedTime = Get-Date '2026-03-23T10:00:00'
    $script:tasks = @(
        (New-TaskItem -Title 'Task A' -Order 1 -Now $seedTime -Id '1'),
        (New-TaskItem -Title 'Task B' -Order 2 -Now $seedTime -Id '2'),
        (New-TaskItem -Title 'Task C' -Order 3 -Now $seedTime -Id '3')
    )

    Open-TaskWindow
    Invoke-TaskRowAction -TaskId '3' -Action 'move_to_top'

    [pscustomobject]@{
        ok          = $true
        order_after = Get-TaskTitleSequence -Tasks $script:tasks
    } | ConvertTo-Json -Compress

    $script:taskWindow.Close()
    $script:mainWindow.Close()
    return
}

[void]$script:mainWindow.ShowDialog()












