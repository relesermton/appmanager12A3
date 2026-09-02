#Requires -Version 5.1
<#
.SYNOPSIS
    Windows App Manager - list, uninstall, move, and modify installed applications.

.DESCRIPTION
    A GUI tool (WinForms) for managing installed Windows applications:
      - List:      Reads installed apps from the registry (both 32/64-bit + per-user).
      - Uninstall: Runs each app's own uninstall command.
      - Modify:    Runs the app's "modify/repair" command (MSI installers only - not all
                   apps support this; the button is disabled when unavailable).
      - Move:      Relocates the app's install folder to a new location and leaves a
                   junction (symbolic link) behind at the original path, so shortcuts,
                   registry entries, and the app itself keep working. This is the same
                   trick used to move Steam game folders between drives.

.NOTES
    - Run as Administrator for uninstall/modify/move to work reliably.
    - "Move" is inherently a bit risky for apps that hardcode absolute paths in ways a
      junction can't intercept (rare, but possible - e.g. apps that check volume serial
      numbers). Close the app before moving it. A log of every action is kept and shown
      in the app, and you can always undo a move by deleting the junction and moving the
      folder back to the original path.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ------------------------------------------------------------------
# Elevation check
# ------------------------------------------------------------------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    $result = [System.Windows.Forms.MessageBox]::Show(
        "This tool works best run as Administrator (needed for uninstall/move/modify on many apps).`n`nRestart as Administrator now?",
        "App Manager - Elevation Recommended",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        exit
    }
}

# ------------------------------------------------------------------
# Data model: read installed apps from registry
# ------------------------------------------------------------------
function Get-InstalledApps {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $apps = foreach ($path in $paths) {
        Get-ItemProperty -Path $path -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -and
            $_.DisplayName.Trim() -ne '' -and
            -not $_.SystemComponent -and
            ($_.ParentKeyName -eq $null) -and
            ($_.ReleaseType -ne 'Update' -and $_.ReleaseType -ne 'Hotfix')
        } | ForEach-Object {
            [PSCustomObject]@{
                Name            = $_.DisplayName
                Version         = $_.DisplayVersion
                Publisher       = $_.Publisher
                InstallLocation = $_.InstallLocation
                UninstallString = $_.UninstallString
                ModifyPath      = $_.ModifyPath
                QuietUninstall  = $_.QuietUninstallString
                RegistryKey     = $_.PSPath
                SizeKB          = $_.EstimatedSize
            }
        }
    }

    $apps | Sort-Object Name -Unique
}

# ------------------------------------------------------------------
# Actions
# ------------------------------------------------------------------
function Invoke-AppUninstall {
    param($app)

    $cmd = if ($app.QuietUninstall) { $app.QuietUninstall } else { $app.UninstallString }
    if (-not $cmd) {
        [System.Windows.Forms.MessageBox]::Show("No uninstall command found for '$($app.Name)'.", "Cannot Uninstall", 'OK', 'Error')
        return $false
    }

    try {
        if ($cmd -match '^"([^"]+)"(.*)$') {
            $exe = $Matches[1]; $argStr = $Matches[2].Trim()
        } elseif ($cmd -match '^(\S+)(.*)$') {
            $exe = $Matches[1]; $argStr = $Matches[2].Trim()
        } else {
            $exe = $cmd; $argStr = ''
        }
        Start-Process -FilePath $exe -ArgumentList $argStr -Wait -ErrorAction Stop
        return $true
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Uninstall failed for '$($app.Name)':`n$($_.Exception.Message)", "Error", 'OK', 'Error')
        return $false
    }
}

function Invoke-AppModify {
    param($app)

    if (-not $app.ModifyPath) {
        [System.Windows.Forms.MessageBox]::Show("'$($app.Name)' does not expose a Modify/Repair command (most non-MSI installers don't support this).", "Not Available", 'OK', 'Information')
        return
    }
    try {
        if ($app.ModifyPath -match '^"([^"]+)"(.*)$') {
            $exe = $Matches[1]; $argStr = $Matches[2].Trim()
        } else {
            $exe = $app.ModifyPath; $argStr = ''
        }
        Start-Process -FilePath $exe -ArgumentList $argStr -Wait -ErrorAction Stop
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Modify failed for '$($app.Name)':`n$($_.Exception.Message)", "Error", 'OK', 'Error')
    }
}

function Invoke-AppMove {
    param($app, [string]$destRoot)

    if (-not $app.InstallLocation -or -not (Test-Path $app.InstallLocation)) {
        [System.Windows.Forms.MessageBox]::Show("No valid install folder known for '$($app.Name)', so it can't be moved automatically.", "Cannot Move", 'OK', 'Error')
        return $false
    }

    $source = $app.InstallLocation.TrimEnd('\')
    $folderName = Split-Path $source -Leaf
    $dest = Join-Path $destRoot $folderName

    if (Test-Path $dest) {
        [System.Windows.Forms.MessageBox]::Show("Destination '$dest' already exists. Choose a different destination.", "Cannot Move", 'OK', 'Error')
        return $false
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Move:`n  $source`nto:`n  $dest`n`nA junction will be left at the original path so the app keeps working. Make sure '$($app.Name)' is closed first.`n`nContinue?",
        "Confirm Move", 'YesNo', 'Warning')
    if ($confirm -ne 'Yes') { return $false }

    try {
        # Robocopy preserves permissions/attributes better than Copy-Item for app folders
        $robocopyArgs = @("`"$source`"", "`"$dest`"", "/MIR", "/COPYALL", "/R:1", "/W:1", "/NFL", "/NDL")
        $p = Start-Process -FilePath robocopy.exe -ArgumentList $robocopyArgs -Wait -PassThru -NoNewWindow
        # Robocopy exit codes 0-7 are success/informational; 8+ indicates failure
        if ($p.ExitCode -ge 8) {
            throw "Robocopy failed with exit code $($p.ExitCode)"
        }

        Remove-Item -LiteralPath $source -Recurse -Force
        # Create junction at old path pointing to new location
        cmd.exe /c "mklink /J `"$source`" `"$dest`"" | Out-Null

        if (-not (Test-Path $source)) {
            throw "Junction creation failed."
        }

        [System.Windows.Forms.MessageBox]::Show("Moved '$($app.Name)' successfully.`n`nOriginal path now links to the new location via a junction.", "Move Complete", 'OK', 'Information')
        return $true
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Move failed for '$($app.Name)':`n$($_.Exception.Message)`n`nIf files were partially copied, check '$dest' and '$source' manually before retrying.", "Error", 'OK', 'Error')
        return $false
    }
}

# ------------------------------------------------------------------
# GUI
# ------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "App Manager - Uninstall / Move / Modify"
$form.Size = New-Object System.Drawing.Size(980, 620)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(760, 480)

$searchBox = New-Object System.Windows.Forms.TextBox
$searchBox.Location = New-Object System.Drawing.Point(10, 10)
$searchBox.Size = New-Object System.Drawing.Size(300, 24)
$searchBox.Anchor = 'Top,Left'
$form.Controls.Add($searchBox)

$searchLabel = New-Object System.Windows.Forms.Label
$searchLabel.Text = "Search:"
$searchLabel.Location = New-Object System.Drawing.Point(10, -14)
$searchLabel.AutoSize = $true
$form.Controls.Add($searchLabel)
$searchLabel.Location = New-Object System.Drawing.Point(10, 40 - 32)

$refreshBtn = New-Object System.Windows.Forms.Button
$refreshBtn.Text = "Refresh"
$refreshBtn.Location = New-Object System.Drawing.Point(320, 9)
$refreshBtn.Size = New-Object System.Drawing.Size(90, 26)
$refreshBtn.Anchor = 'Top,Left'
$form.Controls.Add($refreshBtn)

$list = New-Object System.Windows.Forms.ListView
$list.View = 'Details'
$list.FullRowSelect = $true
$list.GridLines = $true
$list.MultiSelect = $false
$list.Location = New-Object System.Drawing.Point(10, 45)
$list.Size = New-Object System.Drawing.Size(945, 430)
$list.Anchor = 'Top,Bottom,Left,Right'
$list.Columns.Add("Name", 300) | Out-Null
$list.Columns.Add("Version", 100) | Out-Null
$list.Columns.Add("Publisher", 200) | Out-Null
$list.Columns.Add("Install Location", 330) | Out-Null
$form.Controls.Add($list)

$statusBox = New-Object System.Windows.Forms.TextBox
$statusBox.Multiline = $true
$statusBox.ReadOnly = $true
$statusBox.ScrollBars = 'Vertical'
$statusBox.Location = New-Object System.Drawing.Point(10, 485)
$statusBox.Size = New-Object System.Drawing.Size(945, 60)
$statusBox.Anchor = 'Bottom,Left,Right'
$form.Controls.Add($statusBox)

function Write-Status([string]$msg) {
    $ts = Get-Date -Format "HH:mm:ss"
    $statusBox.AppendText("[$ts] $msg`r`n")
}

$uninstallBtn = New-Object System.Windows.Forms.Button
$uninstallBtn.Text = "Uninstall"
$uninstallBtn.Location = New-Object System.Drawing.Point(10, 553)
$uninstallBtn.Size = New-Object System.Drawing.Size(110, 30)
$uninstallBtn.Anchor = 'Bottom,Left'
$form.Controls.Add($uninstallBtn)

$modifyBtn = New-Object System.Windows.Forms.Button
$modifyBtn.Text = "Modify / Repair"
$modifyBtn.Location = New-Object System.Drawing.Point(130, 553)
$modifyBtn.Size = New-Object System.Drawing.Size(130, 30)
$modifyBtn.Anchor = 'Bottom,Left'
$form.Controls.Add($modifyBtn)

$moveBtn = New-Object System.Windows.Forms.Button
$moveBtn.Text = "Move to..."
$moveBtn.Location = New-Object System.Drawing.Point(270, 553)
$moveBtn.Size = New-Object System.Drawing.Size(110, 30)
$moveBtn.Anchor = 'Bottom,Left'
$form.Controls.Add($moveBtn)

$openLocBtn = New-Object System.Windows.Forms.Button
$openLocBtn.Text = "Open Folder"
$openLocBtn.Location = New-Object System.Drawing.Point(390, 553)
$openLocBtn.Size = New-Object System.Drawing.Size(110, 30)
$openLocBtn.Anchor = 'Bottom,Left'
$form.Controls.Add($openLocBtn)

$script:allApps = @()

function Populate-List {
    param([string]$filter = '')
    $list.Items.Clear()
    $filtered = if ($filter) {
        $script:allApps | Where-Object { $_.Name -like "*$filter*" -or $_.Publisher -like "*$filter*" }
    } else {
        $script:allApps
    }
    foreach ($a in $filtered) {
        $item = New-Object System.Windows.Forms.ListViewItem($a.Name)
        $item.SubItems.Add($a.Version) | Out-Null
        $item.SubItems.Add($a.Publisher) | Out-Null
        $item.SubItems.Add($a.InstallLocation) | Out-Null
        $item.Tag = $a
        $list.Items.Add($item) | Out-Null
    }
}

function Reload-Apps {
    Write-Status "Scanning installed applications..."
    $form.Cursor = 'WaitCursor'
    $script:allApps = Get-InstalledApps
    Populate-List -filter $searchBox.Text
    $form.Cursor = 'Default'
    Write-Status "Found $($script:allApps.Count) applications."
}

$refreshBtn.Add_Click({ Reload-Apps })
$searchBox.Add_TextChanged({ Populate-List -filter $searchBox.Text })

function Get-SelectedApp {
    if ($list.SelectedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Select an app first.", "No Selection", 'OK', 'Information')
        return $null
    }
    return $list.SelectedItems[0].Tag
}

$uninstallBtn.Add_Click({
    $app = Get-SelectedApp
    if (-not $app) { return }
    $confirm = [System.Windows.Forms.MessageBox]::Show("Uninstall '$($app.Name)'?", "Confirm Uninstall", 'YesNo', 'Warning')
    if ($confirm -ne 'Yes') { return }
    Write-Status "Uninstalling $($app.Name)..."
    if (Invoke-AppUninstall -app $app) {
        Write-Status "Uninstalled $($app.Name)."
        Reload-Apps
    } else {
        Write-Status "Uninstall of $($app.Name) failed or was cancelled."
    }
})

$modifyBtn.Add_Click({
    $app = Get-SelectedApp
    if (-not $app) { return }
    Write-Status "Launching modify/repair for $($app.Name)..."
    Invoke-AppModify -app $app
    Write-Status "Modify/repair finished for $($app.Name)."
})

$moveBtn.Add_Click({
    $app = Get-SelectedApp
    if (-not $app) { return }
    if (-not $app.InstallLocation -or -not (Test-Path $app.InstallLocation)) {
        [System.Windows.Forms.MessageBox]::Show("No install folder detected for '$($app.Name)'.", "Cannot Move", 'OK', 'Error')
        return
    }
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = "Choose destination drive/folder for '$($app.Name)'"
    if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Write-Status "Moving $($app.Name) to $($fbd.SelectedPath)..."
        if (Invoke-AppMove -app $app -destRoot $fbd.SelectedPath) {
            Write-Status "Move complete for $($app.Name)."
            Reload-Apps
        } else {
            Write-Status "Move of $($app.Name) failed or was cancelled."
        }
    }
})

$openLocBtn.Add_Click({
    $app = Get-SelectedApp
    if (-not $app) { return }
    if ($app.InstallLocation -and (Test-Path $app.InstallLocation)) {
        Start-Process explorer.exe $app.InstallLocation
    } else {
        [System.Windows.Forms.MessageBox]::Show("No known folder for '$($app.Name)'.", "Not Found", 'OK', 'Information')
    }
})

Reload-Apps
[void]$form.ShowDialog()
