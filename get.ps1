# MacLook - one-command bootstrap
#
#   Install:    irm https://raw.githubusercontent.com/SamerElhamdo/macos-look-win11/main/get.ps1 | iex
#   Preview:    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/SamerElhamdo/macos-look-win11/main/get.ps1))) -DryRun
#   Uninstall:  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/SamerElhamdo/macos-look-win11/main/get.ps1))) -Uninstall
#
# Downloads this repository into a temporary folder and runs install.ps1
# (or uninstall.ps1) from there. Any other arguments are passed through.
param(
    [switch]$Uninstall,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$repo   = 'SamerElhamdo/macos-look-win11'
$branch = 'main'
$dir    = Join-Path $env:TEMP ('maclook-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$zip    = Join-Path $dir 'src.zip'

New-Item -ItemType Directory -Path $dir | Out-Null
Write-Host "Downloading $repo ..." -ForegroundColor Cyan
Invoke-WebRequest -Uri "https://codeload.github.com/$repo/zip/refs/heads/$branch" -OutFile $zip -UseBasicParsing
Expand-Archive -Path $zip -DestinationPath $dir -Force

$src    = Join-Path $dir ("macos-look-win11-$branch")
$script = if ($Uninstall) { 'uninstall.ps1' } else { 'install.ps1' }
$target = Join-Path $src $script
if (-not (Test-Path $target)) { throw "Missing $script in the downloaded archive." }

$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $target)
if ($Rest) { $argList += $Rest }
& powershell.exe @argList
