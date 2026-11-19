#requires -version 5.1
<#
====================================================================
 Restore-Workspace.ps1  —— 快速恢复工作区
--------------------------------------------------------------------
 按配置一次性打开若干终端窗口 / Windows Terminal 标签页 / 资源管理器窗口，
 每一个都直接进入各自的目录。

 配置：同目录下的 workspace.json（也可用 -ConfigPath 指定）

 用法：
   .\Restore-Workspace.ps1                 使用 workspace.json
   .\Restore-Workspace.ps1 -DryRun         只打印将要执行的动作
   .\Restore-Workspace.ps1 -ConfigPath x.json
====================================================================
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$DryRun,
    [switch]$Quiet
)

$script:Quiet = [bool]$Quiet

function Say {
    param([string]$Message, [string]$Color = 'Gray')
    if (-not $script:Quiet) { Write-Host $Message -ForegroundColor $Color }
}

# ---------------- 定位配置文件 ----------------
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $ConfigPath) { $ConfigPath = Join-Path $here 'workspace.json' }
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Say "找不到配置文件：$ConfigPath" 'Red'
    exit 1
}
$cfgFull = (Resolve-Path -LiteralPath $ConfigPath).Path
$baseDir = Split-Path -Parent $cfgFull

# ---------------- 读取配置 ----------------
try {
    $cfg = Get-Content -LiteralPath $cfgFull -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Say "配置文件不是合法 JSON：$($_.Exception.Message)" 'Red'
    exit 1
}

# ---------------- 工具函数 ----------------
# 支持 ~、%USERPROFILE% 这类环境变量、相对路径（相对于配置文件所在目录）
function Norm-Dir {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $p = $Raw.Trim()
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if ($p -eq '~') {
        $p = $HOME
    }
    elseif ($p.StartsWith('~')) {
        $rest = ($p.Substring(1)) -replace '^[\\/]+', ''
        $p = Join-Path $HOME $rest
    }
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $baseDir $p }
    try { return [IO.Path]::GetFullPath($p) } catch { return $p }
}

# 单个条目要用的程序：powershell / cmd / wt / explorer
function Norm-App {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $a = $Raw.Trim().ToLower()
    switch ($a) {
        'powershell' { return 'powershell' }
        'ps' { return 'powershell' }
        'pwsh' { return 'powershell' }
        'powershell.exe' { return 'powershell' }
        'cmd' { return 'cmd' }
        'cmd.exe' { return 'cmd' }
        'dos' { return 'cmd' }
        'wt' { return 'wt' }
        'terminal' { return 'wt' }
        'windows terminal' { return 'wt' }
        'explorer' { return 'explorer' }
        'exp' { return 'explorer' }
        '文件夹' { return 'explorer' }
        default { return 'unknown' }
    }
}

# ---------------- 解析选项 ----------------
$mode = 'window'
if ($cfg.mode) { $mode = ([string]$cfg.mode).Trim().ToLower() }
if ($mode -notin @('window', 'tab')) { $mode = 'window' }

# defaultApp 是推荐写法；terminal 是旧写法，两者都认
$defaultApp = 'auto'
if ($cfg.defaultApp) { $defaultApp = ([string]$cfg.defaultApp).Trim().ToLower() }
elseif ($cfg.terminal) { $defaultApp = ([string]$cfg.terminal).Trim().ToLower() }
$defaultApp = Norm-App $defaultApp
if (-not $defaultApp -or $defaultApp -eq 'unknown') {
    if ($defaultApp -eq 'unknown') { Say "defaultApp 无法识别，已按 powershell 处理" 'DarkYellow' }
    $defaultApp = 'powershell'
}
if ($defaultApp -eq 'auto') { $defaultApp = 'powershell' }

# 终端窗口是否最大化
$maximized = $false
if ($cfg.maximized) { $maximized = [bool]$cfg.maximized }

# 资源管理器：tab＝同一个窗口开多个标签页（默认）；window＝每个目录一个独立窗口
$explorerMode = 'tab'
if ($cfg.explorerMode) { $explorerMode = ([string]$cfg.explorerMode).Trim().ToLower() }
if ($explorerMode -like 'tab*') { $explorerMode = 'tab' }
elseif ($explorerMode -like 'win*') { $explorerMode = 'window' }
else { $explorerMode = 'tab' }

$hasWt = [bool](Get-Command 'wt.exe' -ErrorAction SilentlyContinue)

if ($mode -eq 'tab' -and -not $hasWt) {
    Say '提示：mode=tab 需要 Windows Terminal（未找到 wt.exe），已按 window 模式执行' 'DarkYellow'
    $mode = 'window'
}

$rawItems = @()
if ($cfg.PSObject.Properties.Name -contains 'launch') { $rawItems = @($cfg.launch) }
elseif ($cfg.PSObject.Properties.Name -contains 'items') { $rawItems = @($cfg.items) }

# ---------------- 整理任务列表 ----------------
$jobs = @()
$idx = 0
foreach ($it in $rawItems) {
    $path = $null
    $title = $null
    $app = $null
    if ($it -is [string]) {
        $path = $it
    }
    elseif ($it) {
        if ($it.PSObject.Properties.Name -contains 'path') { $path = $it.path }
        if ($it.PSObject.Properties.Name -contains 'title') { $title = $it.title }
        if ($it.PSObject.Properties.Name -contains 'app') { $app = $it.app }
    }
    if (-not $path) { continue }

    $full = Norm-Dir ([string]$path)
    if (-not $full) { continue }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        Say ("  跳过（目录不存在）：{0}" -f $full) 'DarkYellow'
        continue
    }

    # 条目级 app 优先，其次全局 defaultApp
    $itemApp = Norm-App ([string]$app)
    if (-not $itemApp) { $itemApp = $defaultApp }
    if ($itemApp -eq 'unknown') {
        Say ("  条目 app 无法识别，已按 {0} 处理：{1}" -f $defaultApp, $full) 'DarkYellow'
        $itemApp = $defaultApp
    }
    if ($itemApp -eq 'wt' -and -not $hasWt) {
        Say ("  未找到 Windows Terminal，{0} 改用 powershell" -f $full) 'DarkYellow'
        $itemApp = 'powershell'
    }

    if ($title) { $title = ([string]$title).Trim() } else { $title = $null }
    $idx++

    $jobs += [pscustomobject]@{
        Index = $idx
        Path  = $full
        Title = $title
        App   = $itemApp
    }
}

if ($jobs.Count -eq 0) {
    Say '没有可打开的目标，请检查 workspace.json 里的 launch 列表。' 'Red'
    exit 1
}

# ---------------- 各种打开方式 ----------------
function Open-Explorer {
    param($Job)
    if ($DryRun) {
        Say ("[{0}] explorer.exe `"{1}`"" -f $Job.Index, $Job.Path) 'Green'
        return
    }
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $Job.Path)
}

function Open-Cmd {
    param($Job)
    $a = @()
    if ($Job.Title) {
        $t = ($Job.Title -replace '[&|<>^"]', '')
        $a += ('/k title {0}' -f $t)
    }
    if ($DryRun) {
        Say ("[{0}] cmd.exe {1}  工作目录={2}" -f $Job.Index, ($a -join ' '), $Job.Path) 'Green'
        return
    }
    $sp = @{ FilePath = 'cmd.exe'; WorkingDirectory = $Job.Path }
    if ($a.Count -gt 0) { $sp['ArgumentList'] = ($a -join ' ') }
    if ($maximized) { $sp['WindowStyle'] = 'Maximized' }
    Start-Process @sp
}

function Open-PowerShell {
    param($Job)
    $a = $null
    if ($Job.Title) {
        $q = ($Job.Title -replace '"', '').Replace("'", "''")
        $a = '-NoExit -Command "$Host.UI.RawUI.WindowTitle = ''' + $q + '''"'
    }
    if ($DryRun) {
        Say ("[{0}] powershell.exe {1}  工作目录={2}" -f $Job.Index, $a, $Job.Path) 'Green'
        return
    }
    $sp = @{ FilePath = 'powershell.exe'; WorkingDirectory = $Job.Path }
    if ($a) { $sp['ArgumentList'] = $a }
    if ($maximized) { $sp['WindowStyle'] = 'Maximized' }
    Start-Process @sp
}

function Open-WtWindow {
    param($Job)
    $t = $Job.Title
    if (-not $t) { $t = Split-Path -Leaf $Job.Path }
    $a = 'new-window --startingDirectory "{0}" --title "{1}"' -f $Job.Path, ($t -replace '"', '')
    if ($DryRun) {
        Say ("[{0}] wt.exe {1}" -f $Job.Index, $a) 'Green'
        return
    }
    Start-Process -FilePath 'wt.exe' -ArgumentList $a
}

# ---- 资源管理器多标签（Windows 11）----------------------------------
# explorer.exe 没有多标签的命令行参数，这里用 UI 自动化点窗口上的“添加新标签页”，
# 再用 Shell COM 让新标签页导航到目标目录。全程不抢焦点、不动剪贴板。

function Get-ExplorerWindows {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, 'CabinetWClass')
    $res = @()
    foreach ($w in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) { $res += $w }
    return $res
}

function Open-ExplorerWindow {
    param([string]$Path)
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $Path) | Out-Null
}

function Add-ExplorerTab {
    # 在指定窗口上新开一个标签页并导航到 Path；成功返回 $true
    param([int64]$Handle, [string]$Path)

    $win = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Handle)
    if ($null -eq $win) { return $false }

    $btnCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $btns = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond)
    $btn = $null
    foreach ($b in $btns) {
        if ($b.Current.Name -match '添加新标签页|新建选项卡|New tab') { $btn = $b; break }
    }
    if ($null -eq $btn) { return $false }

    try { $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
    catch { return $false }
    Start-Sleep -Milliseconds 700

    # 刚建好的标签页就是当前激活的标签页，让 Shell COM 把它导航到目标目录。
    # 注意：Shell.Windows() 是按“标签页”逐项枚举的，同一句柄会有多条记录，
    # 新建的标签页停在“主文件夹”，LocationURL 为空，取最后一个空 URL 的即为它。
    $sh = New-Object -ComObject Shell.Application
    $hit = $null
    foreach ($sw in $sh.Windows()) {
        if ($sw.HWND -eq $Handle -and [string]::IsNullOrEmpty($sw.LocationURL)) { $hit = $sw }
    }
    if ($null -eq $hit) { return $false }

    $url = ([uri]$Path).AbsoluteUri
    try { $hit.Navigate2($url) }
    catch { return $false }

    for ($k = 0; $k -lt 15; $k++) {
        Start-Sleep -Milliseconds 200
        $cur = $hit.LocationURL
        if ($cur -and $cur.TrimEnd('/') -eq $url.TrimEnd('/')) { return $true }
    }
    Say ("  标签页已建好但没确认导航完成：{0}" -f $Path) 'DarkYellow'
    return $true
}

function Open-ExplorerTabs {
    param($Jobs)

    if ($DryRun) {
        Say ("[{0}] explorer.exe `"{1}`"  （先用它开一个窗口）" -f $Jobs[0].Index, $Jobs[0].Path) 'Green'
        for ($i = 1; $i -lt $Jobs.Count; $i++) {
            Say ("[{0}] 在上面的窗口里新建标签页 -> `"{1}`"" -f $Jobs[$i].Index, $Jobs[$i].Path) 'Green'
        }
        return
    }

    try {
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
    }
    catch {
        Say '  无法加载 UI 自动化组件，资源管理器改为各自独立窗口' 'DarkYellow'
        foreach ($j in $Jobs) { Open-ExplorerWindow $j.Path }
        return
    }

    # 先记下已经存在的资源管理器窗口，方便认出新开的那个
    $before = @{}
    foreach ($w in Get-ExplorerWindows) { $before[[int64]$w.Current.NativeWindowHandle] = $true }

    $first = $Jobs[0]
    Open-ExplorerWindow $first.Path

    $anchor = [int64]0
    for ($k = 0; $k -lt 40; $k++) {
        Start-Sleep -Milliseconds 200
        foreach ($w in Get-ExplorerWindows) {
            $hd = [int64]$w.Current.NativeWindowHandle
            if (-not $before.ContainsKey($hd)) { $anchor = $hd; break }
        }
        if ($anchor -ne 0) { break }
    }

    if ($anchor -eq 0) {
        Say '  没认出新开的资源管理器窗口，其余目录改为各自独立窗口' 'DarkYellow'
        for ($i = 1; $i -lt $Jobs.Count; $i++) { Open-ExplorerWindow $Jobs[$i].Path }
        return
    }

    for ($i = 1; $i -lt $Jobs.Count; $i++) {
        $j = $Jobs[$i]
        if (-not (Add-ExplorerTab -Handle $anchor -Path $j.Path)) {
            Say ("  标签页方式失败，改为独立窗口：{0}" -f $j.Path) 'DarkYellow'
            Open-ExplorerWindow $j.Path
        }
    }
}

# ---------------- 执行 ----------------
Say ("准备打开 {0} 个目标（终端模式：{1}，资源管理器：{2}，默认程序：{3}）" -f $jobs.Count, $mode, $explorerMode, $defaultApp) 'Cyan'

$termJobs = @($jobs | Where-Object { $_.App -ne 'explorer' })
$expJobs = @($jobs | Where-Object { $_.App -eq 'explorer' })

# 1) 资源管理器
if ($expJobs.Count -gt 0) {
    if ($explorerMode -eq 'tab' -and $expJobs.Count -gt 1) { Open-ExplorerTabs $expJobs }
    else { foreach ($j in $expJobs) { Open-Explorer $j } }
}

# 2) 终端
if ($mode -eq 'tab') {
    # 合并到一个 Windows Terminal 窗口里开 N 个标签页
    if ($termJobs.Count -gt 0) {
        $parts = @()
        foreach ($j in $termJobs) {
            $t = $j.Title
            if (-not $t) { $t = Split-Path -Leaf $j.Path }
            $t = $t -replace '"', ''
            $p = 'new-tab --startingDirectory "{0}" --title "{1}"' -f $j.Path, $t
            if ($j.App -eq 'cmd') { $p += ' -- cmd.exe' }
            elseif ($j.App -eq 'powershell') { $p += ' -- powershell.exe' }
            $parts += $p
        }
        $all = $parts -join ' ; '
        if ($DryRun) { Say ("wt.exe {0}" -f $all) 'Green' }
        else { Start-Process -FilePath 'wt.exe' -ArgumentList $all }
    }
}
else {
    foreach ($j in $termJobs) {
        switch ($j.App) {
            'cmd' { Open-Cmd $j }
            'wt' { Open-WtWindow $j }
            default { Open-PowerShell $j }
        }
        if (-not $DryRun) { Start-Sleep -Milliseconds 200 }
    }
}

Say '完成。' 'Cyan'
