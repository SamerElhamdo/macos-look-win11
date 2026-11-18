#Requires -Version 5.1
<#
  مظهر ماك لويندوز ١١ — سكربت التراجع
  ------------------------------------
  يقرأ سجلّ التثبيت ويتراجع عن كل ما فعله install.ps1 فقط:
  - يزيل البرامج التي ثبّتها هو (لا يلمس ما كان مثبّتاً قبله).
  - يعيد الإعدادات والخلفية من النسخة الاحتياطية.

    .\uninstall.ps1 -DryRun   # يعرض ما سيفعله فقط
    .\uninstall.ps1           # تراجع فعلي مع أسئلة تأكيد
#>
[CmdletBinding()]
param([switch]$DryRun, [switch]$KeepApps, [switch]$Yes)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$StateDir  = Join-Path $env:LOCALAPPDATA 'MacLook'
$StateFile = Join-Path $StateDir 'state.json'

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Ok([string]$m)   { Say "  [تم] $m" 'Green' }
function Warn([string]$m) { Say "  [تنبيه] $m" 'Yellow' }
function Sim([string]$m)  { Say "  [محاكاة] $m" 'Magenta' }
function Confirm-Step([string]$q) {
    if ($Yes -or $DryRun) { return $true }
    return ((Read-Host "  $q (y = نعم / n = لا)") -match '^(y|yes|ن|نعم)$')
}

if (-not (Test-Path $StateFile)) {
    Warn "لا يوجد سجلّ تثبيت في $StateFile — لا شيء للتراجع عنه."
    Say  '  إن كان النظام لا يعمل جيداً، استعمل «استعادة النظام» واختر نقطة «MacLook - before install».'
    return
}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $DryRun -and -not $isAdmin) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($KeepApps) { $argList += '-KeepApps' }
    if ($Yes)      { $argList += '-Yes' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    return
}

$state = Get-Content $StateFile -Raw | ConvertFrom-Json
Say "== التراجع عن تثبيت $($state.installedAt) ==" 'Cyan'

# ١. البرامج
if (-not $KeepApps) {
    foreach ($app in @($state.installedApps)) {
        if (-not $app) { continue }
        if ($DryRun) { Sim "winget uninstall --id $($app.Id)"; continue }
        if (-not (Confirm-Step "إزالة $($app.Name)؟")) { continue }
        & winget uninstall --id $app.Id -e --source $app.Source --silent --accept-source-agreements
        if ($LASTEXITCODE -eq 0) { Ok "أُزيل $($app.Name)" } else { Warn "تعذّرت إزالة $($app.Name)" }
    }
}

# ٢. الإعدادات
foreach ($file in @($state.registryBackup)) {
    if (-not $file -or -not (Test-Path $file)) { continue }
    if ($DryRun) { Sim "استرجاع $file"; continue }
    & reg.exe import $file 2>$null
    if ($LASTEXITCODE -eq 0) { Ok "استُرجع $(Split-Path $file -Leaf)" } else { Warn "تعذّر استرجاع $file" }
}

# ٣. الخلفية
if ($state.wallpaperOld -and (Test-Path $state.wallpaperOld)) {
    if ($DryRun) { Sim "إرجاع الخلفية: $($state.wallpaperOld)" }
    else {
        Add-Type -Namespace MacLook -Name Native -MemberDefinition '[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int SystemParametersInfo(int a, int b, string c, int d);'
        [void][MacLook.Native]::SystemParametersInfo(0x14, 0, $state.wallpaperOld, 3)
        Ok 'أُرجعت الخلفية'
    }
}

if ($DryRun) { Say '  كانت هذه محاكاة فقط.' 'Magenta'; return }

# ٤. إعادة تشغيل المستكشف لتطبيق الإعدادات
if (Confirm-Step 'إعادة تشغيل واجهة ويندوز الآن لتطبيق التغييرات؟') {
    Stop-Process -Name explorer -Force
    Ok 'أُعيد تشغيل الواجهة'
}

Rename-Item $StateFile ("state-undone-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
Ok 'انتهى التراجع. النسخ الاحتياطية باقية في المجلد نفسه للاحتياط.'
