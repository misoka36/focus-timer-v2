[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module Pester -MinimumVersion 3.4.0
Invoke-Pester -Path (Join-Path -Path $scriptRoot -ChildPath 'tests') -EnableExit




