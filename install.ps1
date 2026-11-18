#Requires -Version 5.1
<#
  مظهر ماك لويندوز ١١ — سكربت التثبيت
  ---------------------------------------
  - يثبّت البرامج من مدير الحزم الرسمي (winget) فقط.
  - ينشئ نقطة استعادة ونسخة احتياطية من الإعدادات قبل أي تغيير.
  - يسجّل كل ما فعله في ملف حالة حتى يستطيع uninstall.ps1 التراجع عنه.
  - لا يلمس ملفات النظام ولا يرقّع ثيمات النظام.

  أمثلة:
    .\install.ps1 -DryRun                 # محاكاة: يعرض الخطوات ولا يغيّر شيئاً
    .\install.ps1                         # تثبيت كامل مع أسئلة تأكيد
    .\install.ps1 -Launcher Flow          # بديل رايكاست
    .\install.ps1 -Wallpaper D:\wall.jpg  # تعيين خلفية
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [ValidateSet('Raycast', 'Flow', 'None')][string]$Launcher = 'Raycast',
    [switch]$NoWidgets,
    [switch]$NoDarkMode,
    [switch]$SkipRestorePoint,
    [switch]$SkipModGuide,
    [string]$Wallpaper,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$ProjectDir = $PSScriptRoot
$StateDir   = Join-Path $env:LOCALAPPDATA 'MacLook'
$StateFile  = Join-Path $StateDir 'state.json'
$BackupDir  = Join-Path $StateDir ('backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))

# ---------------------------------------------------------------- أدوات مساعدة
function Say([string]$msg, [string]$color = 'Gray') { Write-Host $msg -ForegroundColor $color }
function Title([string]$msg) { Write-Host ''; Write-Host "== $msg ==" -ForegroundColor Cyan }
function Ok([string]$msg)    { Say "  [تم] $msg" 'Green' }
function Warn([string]$msg)  { Say "  [تنبيه] $msg" 'Yellow' }
function Sim([string]$msg)   { Say "  [محاكاة] $msg" 'Magenta' }

function Confirm-Step([string]$question) {
    if ($Yes -or $DryRun) { return $true }
    $a = Read-Host "  $question (y = نعم / n = لا)"
    return ($a -match '^(y|yes|ن|نعم)$')
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$State = [ordered]@{
    version        = 1
    installedAt    = (Get-Date).ToString('s')
    backupDir      = $BackupDir
    installedApps  = @()
    registryBackup = @()
    wallpaperOld   = $null
    restorePoint   = $false
}
function Save-State {
    if ($DryRun) { return }
    New-Item -ItemType Directory -Force $StateDir | Out-Null
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
}

# ---------------------------------------------------------------- ١. الفحص
Title 'الخطوة ١: فحص الجهاز'
if ($DryRun) { Say '  وضع المحاكاة مفعّل: لن يتغيّر أي شيء في الجهاز.' 'Magenta' }

$build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
if ($build -lt 22000) { throw "هذا السكربت لويندوز ١١ فقط (رقم النسخة الحالي $build)." }
Ok "ويندوز ١١، رقم النسخة $build"

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'مدير الحزم winget غير موجود. ثبّت «App Installer» من متجر مايكروسوفت ثم أعد المحاولة.'
}
Ok 'مدير الحزم winget موجود'

if (-not $DryRun -and -not (Test-Admin)) {
    Warn 'السكربت يحتاج صلاحية المدير. سيُعاد تشغيله بها الآن...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v) { $argList += "-$k" } } else { $argList += "-$k"; $argList += "`"$v`"" }
    }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    return
}

if (Test-Path $StateFile) {
    Warn "يوجد تثبيت سابق مسجّل في $StateFile"
    if (-not (Confirm-Step 'المتابعة على كل حال؟')) { return }
}

# ---------------------------------------------------------------- ٢. الأمان
Title 'الخطوة ٢: نقطة استعادة ونسخة احتياطية'

if (-not $SkipRestorePoint) {
    if ($DryRun) { Sim 'إنشاء نقطة استعادة للنظام باسم «قبل مظهر ماك»' }
    else {
        try {
            Checkpoint-Computer -Description 'MacLook - before install' -RestorePointType MODIFY_SETTINGS -WarningVariable rpWarn -WarningAction SilentlyContinue
            if ($rpWarn) { Warn "ويندوز لم ينشئ نقطة جديدة: $rpWarn" } else { $State.restorePoint = $true; Ok 'أُنشئت نقطة استعادة' }
        } catch {
            Warn "تعذّر إنشاء نقطة الاستعادة: $($_.Exception.Message)"
            Warn 'قد تكون «حماية النظام» معطّلة على القرص C.'
            if (-not (Confirm-Step 'المتابعة بدون نقطة استعادة؟ (النسخة الاحتياطية للإعدادات ستُنشأ على كل حال)')) { return }
        }
    }
}

$regKeys = [ordered]@{
    'personalize' = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    'explorer-adv' = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    'desktop'     = 'HKCU\Control Panel\Desktop'
}
if ($DryRun) { Sim "حفظ نسخة من الإعدادات في $BackupDir" }
else {
    New-Item -ItemType Directory -Force $BackupDir | Out-Null
    foreach ($name in $regKeys.Keys) {
        $file = Join-Path $BackupDir "$name.reg"
        & reg.exe export $regKeys[$name] $file /y | Out-Null
        if ($LASTEXITCODE -eq 0) { $State.registryBackup += $file }
    }
    $State.wallpaperOld = (Get-ItemProperty 'HKCU:\Control Panel\Desktop').WallPaper
    Save-State
    Ok "حُفظت نسخة الإعدادات في $BackupDir"
}

# ---------------------------------------------------------------- ٣. البرامج
Title 'الخطوة ٣: تثبيت البرامج من مدير الحزم الرسمي'

$apps = @(
    @{ Id = 'RamenSoftware.Windhawk'; Name = 'ويندهوك'; Source = 'winget' }
)
if (-not $NoWidgets)      { $apps += @{ Id = 'Rainmeter.Rainmeter';         Name = 'رينميتر';      Source = 'winget' } }
if ($Launcher -eq 'Raycast') { $apps += @{ Id = '9PFXXSHC64H3';              Name = 'رايكاست';      Source = 'msstore' } }
if ($Launcher -eq 'Flow')    { $apps += @{ Id = 'Flow-Launcher.Flow-Launcher'; Name = 'فلو لانشر';  Source = 'winget' } }

foreach ($app in $apps) {
    & winget list --id $app.Id -e --source $app.Source --accept-source-agreements *> $null
    if ($LASTEXITCODE -eq 0) { Ok "$($app.Name) مثبّت مسبقاً، لن يُلمس"; continue }

    if ($DryRun) { Sim "winget install --id $($app.Id) --source $($app.Source)"; continue }
    if (-not (Confirm-Step "تثبيت $($app.Name)؟")) { continue }

    & winget install --id $app.Id -e --source $app.Source --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -eq 0) {
        $State.installedApps += @{ Id = $app.Id; Source = $app.Source; Name = $app.Name }
        Save-State
        Ok "ثُبّت $($app.Name)"
    } else {
        Warn "فشل تثبيت $($app.Name) (رمز الخروج $LASTEXITCODE). سأكمل بقية الخطوات."
    }
}

# ---------------------------------------------------------------- ٤. الإعدادات
Title 'الخطوة ٤: إعدادات المظهر'

function Set-Reg([string]$path, [string]$name, [int]$value, [string]$label) {
    if ($DryRun) { Sim "$label  ($name = $value)"; return }
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    Set-ItemProperty -Path $path -Name $name -Value $value -Type DWord
    Ok $label
}

$pers = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
Set-Reg $pers 'EnableTransparency' 1 'تفعيل الشفافية'
if (-not $NoDarkMode) {
    Set-Reg $pers 'AppsUseLightTheme'    0 'الوضع الداكن للبرامج'
    Set-Reg $pers 'SystemUsesLightTheme' 0 'الوضع الداكن للنظام'
}
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAl' 1 'توسيط أيقونات شريط المهام'

if ($Wallpaper) {
    if (-not (Test-Path $Wallpaper)) { Warn "ملف الخلفية غير موجود: $Wallpaper" }
    elseif ($DryRun) { Sim "تعيين الخلفية: $Wallpaper" }
    else {
        $dest = Join-Path $StateDir ('wallpaper' + [IO.Path]::GetExtension($Wallpaper))
        Copy-Item $Wallpaper $dest -Force
        Add-Type -Namespace MacLook -Name Native -MemberDefinition '[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int SystemParametersInfo(int a, int b, string c, int d);'
        [void][MacLook.Native]::SystemParametersInfo(0x14, 0, $dest, 3)
        Ok 'عُيّنت الخلفية'
    }
}

# ---------------------------------------------------------------- ٥. إضافات ويندهوك
Title 'الخطوة ٥: إضافات ويندهوك (خطوات موجّهة)'
Say '  ويندهوك لا يوفّر طريقة رسمية لتثبيت الإضافات من سطر الأوامر،'
Say '  لذلك سيفتح السكربت صفحة كل إضافة وأنت تضغط «تثبيت» داخل ويندهوك.'

$mods = @(
    @{ Id = 'windows-11-taskbar-styler';              Name = 'تنسيق شريط المهام';
       Hint = 'من تبويب الإعدادات اختر الثيم: OS26 Liquid Glass (Dark MacDock) ثم احفظ.' }
    @{ Id = 'taskbar-dock-animation';                 Name = 'حركة التكبير مثل الدوك';
       Hint = 'من تبويب الإعدادات اختر الوضع النصي، والصق الإعدادات المنسوخة، ثم احفظ.';
       Clip = 'themes\taskbar\dock-animation-settings.yaml' }
    @{ Id = 'taskbar-thumbnail-size';                 Name = 'حجم المعاينات المصغّرة';
       Hint = 'الصق الإعدادات المنسوخة في الوضع النصي ثم احفظ.';
       Clip = 'themes\taskbar\thumbnail-size-settings.yaml' }
    @{ Id = 'windows-11-start-menu-styler';           Name = 'تنسيق قائمة ابدأ';
       Hint = 'اختر ثيماً زجاجياً أو شفافاً من القائمة ثم احفظ.' }
    @{ Id = 'windows-11-notification-center-styler';  Name = 'تنسيق مركز الإشعارات';
       Hint = 'اختر ثيماً زجاجياً أو شفافاً من القائمة ثم احفظ.' }
    @{ Id = 'windows-11-file-explorer-styler';        Name = 'تنسيق مستكشف الملفات (اختياري)';
       Hint = 'اختر ثيماً يناسب الزجاج ثم احفظ.' }
)

if ($SkipModGuide) { Say '  تخطّي الدليل الموجّه بناءً على طلبك.' }
else {
    $wh = Join-Path $env:ProgramFiles 'Windhawk\windhawk.exe'
    if ($DryRun) { Sim 'تشغيل ويندهوك' }
    elseif (Test-Path $wh) { Start-Process $wh }
    else { Warn 'لم أجد ويندهوك في مكانه المعتاد. افتحه يدوياً.' }

    $i = 0
    foreach ($m in $mods) {
        $i++
        Say ''
        Say "  ($i/$($mods.Count)) $($m.Name)" 'White'
        Say "      $($m.Hint)"
        $url = "https://windhawk.net/mods/$($m.Id)"
        if ($DryRun) { Sim "فتح $url"; if ($m.Clip) { Sim "نسخ $($m.Clip) إلى الحافظة" }; continue }
        if ($m.Clip) { Get-Content (Join-Path $ProjectDir $m.Clip) -Raw | Set-Clipboard; Ok 'نُسخت الإعدادات إلى الحافظة' }
        Start-Process $url
        Read-Host '      اضغط Enter بعد أن تنتهي من هذه الإضافة (أو Enter للتخطّي)' | Out-Null
    }
}

# ---------------------------------------------------------------- النهاية
Save-State
Title 'انتهى'
if ($DryRun) {
    Say '  كانت هذه محاكاة فقط ولم يتغيّر شيء.' 'Magenta'
    Say '  للتثبيت الفعلي: انقر install.cmd نقراً مزدوجاً، أو شغّل .\install.ps1 بدون -DryRun'
} else {
    Ok "سجلّ التثبيت محفوظ في $StateFile"
    Say '  الخطوات اليدوية الاختيارية (الشريط العلوي، الأدوات، الأيقونات) موجودة في README.md'
    Say '  للتراجع: انقر uninstall.cmd نقراً مزدوجاً.'
}
