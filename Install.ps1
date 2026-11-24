[CmdletBinding()]
param([switch]$Check, [string]$GamePath)

$ErrorActionPreference = 'Stop'

function Get-R3DeviceId {
    $pnp = Join-Path $env:SystemRoot 'System32\pnputil.exe'
    $devices = & $pnp /enum-devices /connected /class HIDClass | Out-String
    if ($LASTEXITCODE -ne 0) { throw 'Windows 无法列出已连接的 HID 设备。' }
    $ids = @([regex]::Matches($devices, '(?i)\bVID_346E&PID_(0005|0015)\b') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    if ($ids.Count -eq 0) { throw '找不到 R3。请开启基座，确认 Pit House 已识别，再运行。' }
    if ($ids.Count -gt 1) { throw '检测到两种 R3 设备 ID。请连接要配置的基座后重试。' }
    return $ids[0]
}

function Test-GameDirectory([string]$Path) {
    foreach ($name in @('forzahorizon6.exe', 'media\inputmappingprofiles.zip', 'media\wheeltunablesettingspc.zip')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $name) -PathType Leaf)) { return $false }
    }
    return $true
}

function Find-GameDirectory([string]$Override) {
    if ($Override) {
        if (-not (Test-GameDirectory $Override)) { throw '-GamePath 应指向 Steam 游戏的安装目录。' }
        return (Resolve-Path -LiteralPath $Override).ProviderPath
    }

    $roots = @(
        foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
            $properties = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
            $properties.SteamPath
            $properties.InstallPath
        }
        Get-Process -Name steam -ErrorAction SilentlyContinue |
            Where-Object Path | ForEach-Object { Split-Path -LiteralPath $_.Path }
    ) | Where-Object { $_ } | Sort-Object -Unique

    $libraries = @(
        foreach ($root in $roots) {
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
            $root
            $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
            if (Test-Path -LiteralPath $vdf -PathType Leaf) {
                foreach ($match in [regex]::Matches([IO.File]::ReadAllText($vdf), '(?m)^\s*"path"\s+"([^"]+)"')) {
                    $match.Groups[1].Value.Replace('\\', '\')
                }
            }
        }
    ) | Sort-Object -Unique

    $found = @(
        foreach ($library in $libraries) {
            if (-not (Test-Path -LiteralPath $library -PathType Container)) { continue }
            $steamApps = Join-Path $library 'steamapps'
            $manifest = Join-Path $steamApps 'appmanifest_2483190.acf'
            if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { continue }
            $text = [IO.File]::ReadAllText($manifest)
            if ($text -notmatch '(?m)^\s*"appid"\s+"2483190"') { continue }
            $dir = [regex]::Match($text, '(?m)^\s*"installdir"\s+"([^"\\/]+)"').Groups[1].Value
            if (-not $dir -or $dir -in @('.', '..') -or $dir.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { continue }
            $candidate = Join-Path (Join-Path $steamApps 'common') $dir
            if (Test-GameDirectory $candidate) { (Resolve-Path -LiteralPath $candidate).ProviderPath }
        }
    ) | Sort-Object -Unique
    if (@($found).Count -ne 1) {
        throw '未定位到唯一的 Steam 版游戏。可使用 Install.cmd -GamePath "游戏安装目录"。'
    }
    return $found
}

function Find-SelectionFile {
    $storage = Join-Path $env:LOCALAPPDATA 'ForzaHorizon6\LocalStorage_Shared'
    try {
        if (-not (Test-Path -LiteralPath $storage -PathType Container)) { return }
        $choices = @(Get-ChildItem -LiteralPath $storage -Directory -Filter 'InputTranslationManager_*' |
            ForEach-Object { Join-Path $_.FullName 'LastUsedProfile' } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    } catch {
        Write-Warning '当前 Windows 用户无法读取游戏的方向盘设定。安装后可在游戏内选择 R3 预设。'
        return
    }
    if ($choices.Count -eq 1) { return $choices[0] }
    if ($choices.Count -gt 1) {
        Write-Host '检测到多个游戏设置目录。安装后请在游戏内选择 R3 默认预设。'
    }
}

function Assert-GameClosed {
    if (Get-Process -Name forzahorizon6 -ErrorAction SilentlyContinue) {
        throw '请完全退出《地平线 6》再安装。'
    }
}

function Get-ContentHash([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)) }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}

function Test-ArchiveContents([string]$Path, [hashtable]$Expected) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($name in $Expected.Keys) {
            $entries = @($zip.Entries | Where-Object FullName -eq $name)
            if ($entries.Count -ne 1 -or $entries[0].FullName -cne $name) { return $false }
            $reader = [IO.StreamReader]::new($entries[0].Open())
            try { $actual = $reader.ReadToEnd() } finally { $reader.Dispose() }
            if ($actual -cne $Expected[$name]) { return $false }
        }
        return $true
    } finally { $zip.Dispose() }
}

function New-ArchiveStage($Change) {
    [IO.File]::Copy($Change.Path, $Change.Stage, $false)
    $zip = [IO.Compression.ZipFile]::Open($Change.Stage, [IO.Compression.ZipArchiveMode]::Update)
    try {
        foreach ($name in $Change.Entries.Keys) {
            foreach ($entry in @($zip.Entries | Where-Object FullName -eq $name)) { $entry.Delete() }
            $entry = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
            $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
            try { $writer.Write($Change.Entries[$name]) } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose() }
    if (-not (Test-ArchiveContents $Change.Stage $Change.Entries)) { throw ('归档校验失败 ' + $Change.Name) }
}

function Install-R3Configuration {
    param(
        [string]$Directory,
        [ValidateSet('0005', '0015')][string]$DeviceId,
        [string]$PresetDirectory,
        [string]$SelectionFile,
        [switch]$DryRun
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $canonical = 'DefaultRawGameControllerMappingProfileMozaR3.xml'
    $secondary = 'DefaultRawGameControllerMappingProfileMozaR3ForzaMode.xml'
    $canonicalId = 'eb08a7a1-2e26-4699-9572-f474540a7733'
    $secondaryId = '169ebda8-342f-400f-9f25-7d71e85100ac'
    $profileNames = @{ '0005' = $canonical; '0015' = $secondary }
    $profileIds = @{ '0005' = $canonicalId; '0015' = $secondaryId }
    $mappings = @{}
    foreach ($id in @('0005', '0015')) {
        $profilePath = Join-Path $PresetDirectory ('inputmappingprofiles\' + $profileNames[$id])
        $mappings[$id] = [IO.File]::ReadAllText($profilePath)
        [xml]$definition = $mappings[$id]
        $profile = $definition.SelectSingleNode('/Profiles/RawGameControllerInputMappingProfile')
        $device = '0x346e' + $id
        if (-not $profile -or $profile.Id -ne $profileIds[$id] -or $profile.PrimaryDeviceVidPid -ne $device -or $profile.FFBDeviceVidPid -ne $device -or
            $profile.SelectNodes('Context/Value').Count -ne 133) {
            throw "R3 $id 的预设校验失败。请完整解压配置包。"
        }
    }

    # Install the detected mode in the game's stock filename and GUID.
    $otherId = if ($DeviceId -eq '0005') { '0015' } else { '0005' }
    $mappingsToInstall = @{
        $canonical = $mappings[$DeviceId].Replace($profileIds[$DeviceId], $canonicalId)
        $secondary = $mappings[$otherId].Replace($profileIds[$otherId], $secondaryId)
    }
    $media = Join-Path $Directory 'media'
    $changes = @()
    $inputArchive = Join-Path $media 'inputmappingprofiles.zip'
    $inputHash = Get-ContentHash $inputArchive
    if (-not (Test-ArchiveContents $inputArchive $mappingsToInstall)) {
        $changes += @{ Path = $inputArchive; Name = 'inputmappingprofiles.zip'; Entries = $mappingsToInstall; OriginalHash = $inputHash }
    }

    # Keep existing game-side FFB tuning. Add a device entry only when it's missing.
    $ffbArchive = Join-Path $media 'wheeltunablesettingspc.zip'
    $ffbHash = Get-ContentHash $ffbArchive
    $ffbName = "ControllerFFB-0X346E$DeviceId.ini"
    $zip = [IO.Compression.ZipFile]::OpenRead($ffbArchive)
    try { $ffbExists = $zip.Entries.FullName -contains $ffbName }
    finally { $zip.Dispose() }
    if (-not $ffbExists) {
        $ffb = [IO.File]::ReadAllText((Join-Path $PresetDirectory ('wheeltunablesettingspc\' + $ffbName)))
        if ($ffb -notmatch "(?m)^VendorProduct\s+0x346e$DeviceId\s*$") { throw "R3 $DeviceId 的备用力反馈文件校验失败。" }
        $changes += @{ Path = $ffbArchive; Name = 'wheeltunablesettingspc.zip'; Entries = @{ $ffbName = $ffb }; OriginalHash = $ffbHash }
    }

    if ($SelectionFile) {
        try {
            $selectionHash = Get-ContentHash $SelectionFile
            $choice = [xml]::new()
            $choice.PreserveWhitespace = $true
            $choice.XmlResolver = $null
            $choice.Load($SelectionFile)
            $attribute = 'RawGameControllerInputMappingProfile'
            if ($choice.DocumentElement.Name -ne 'ProfileChoices' -or -not $choice.DocumentElement.HasAttribute($attribute)) {
                throw '方向盘选择文件格式不同。'
            }
            if ($choice.DocumentElement.GetAttribute($attribute) -ne $canonicalId) {
                $choice.DocumentElement.SetAttribute($attribute, $canonicalId)
                $changes += @{ Path = $SelectionFile; Name = 'LastUsedProfile'; Xml = $choice; OriginalHash = $selectionHash }
            }
        } catch {
            Write-Warning '无法读取已有的方向盘选择。安装后可在游戏内选择 R3 预设。'
            $SelectionFile = $null
        }
    }

    Write-Host "已识别 VID_346E&PID_$DeviceId"
    Write-Host "游戏目录 $Directory"
    if ($DryRun) {
        if ($changes.Count) { Write-Host ('将更新 ' + (($changes | ForEach-Object Name) -join '、')) }
        else { Write-Host '现有配置已匹配。' }
        if (-not $SelectionFile) { Write-Host '游戏尚无可唯一定位的已选方案。预设仍可安装。' }
        return
    }

    if ($changes.Count) {
        $operation = [Guid]::NewGuid().ToString('N')
        $backupDir = Join-Path (Join-Path $media 'FH6-MOZA-R3-backups') ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $operation.Substring(0, 8))
        $committed = @()
        try {
            foreach ($change in $changes) {
                $change.Stage = $change.Path + '.moza-r3-' + $operation + '.tmp'
                if ($change.Entries) { New-ArchiveStage $change }
                else { $change.Xml.Save($change.Stage) }
                $change.NewHash = Get-ContentHash $change.Stage
            }
            Assert-GameClosed
            if ((Get-R3DeviceId) -ne $DeviceId) { throw '配置准备期间设备连接状态发生变化，请重试。' }

            [void][IO.Directory]::CreateDirectory($backupDir)
            foreach ($change in $changes) {
                $change.Backup = Join-Path $backupDir $change.Name
                [IO.File]::Copy($change.Path, $change.Backup, $false)
                if ((Get-ContentHash $change.Backup) -ne $change.OriginalHash) {
                    throw ('准备期间原文件发生变化 ' + $change.Name)
                }
            }
            foreach ($change in $changes) {
                Assert-GameClosed
                if ((Get-ContentHash $change.Path) -ne $change.OriginalHash) {
                    throw ('准备期间原文件发生变化 ' + $change.Name)
                }
                $committed += $change
                [IO.File]::Replace($change.Stage, $change.Path, [NullString]::Value)
                if ((Get-ContentHash $change.Path) -ne $change.NewHash) {
                    throw ('写入校验失败 ' + $change.Name)
                }
            }
        } catch {
            $failure = $_
            for ($index = $committed.Count - 1; $index -ge 0; $index--) {
                $change = $committed[$index]
                try {
                    if ([IO.File]::Exists($change.Path)) {
                        $currentHash = Get-ContentHash $change.Path
                        if ($currentHash -eq $change.OriginalHash) { continue }
                        if ($currentHash -ne $change.NewHash) { throw '文件已有其他修改。' }
                        [IO.File]::Copy($change.Backup, $change.Stage, $true)
                        [IO.File]::Replace($change.Stage, $change.Path, [NullString]::Value)
                    } else {
                        [IO.File]::Copy($change.Backup, $change.Stage, $true)
                        [IO.File]::Move($change.Stage, $change.Path)
                    }
                    if ((Get-ContentHash $change.Path) -ne $change.OriginalHash) { throw '恢复校验失败。' }
                } catch {
                    Write-Warning "请退出游戏并从备份恢复 $($change.Name)。备份文件 $($change.Backup)"
                }
            }
            if ([IO.Directory]::Exists($backupDir)) { Write-Host "备份目录 $backupDir" }
            throw $failure
        } finally {
            foreach ($change in $changes) {
                if ($change.Stage -and [IO.File]::Exists($change.Stage)) { [IO.File]::Delete($change.Stage) }
            }
        }
        Write-Host "备份目录 $backupDir"
        if ($changes | Where-Object Name -eq 'LastUsedProfile') { Write-Host "原方案选择文件位置 $SelectionFile" }
    }

    if ($SelectionFile) { Write-Host '安装完成，已切换到新键位。现在可以启动游戏。' }
    else { Write-Host '新键位已安装。如果进游戏后仍在用旧键位，可在方向盘设置的「配置」栏切到最左侧的方案。' }
}

if ($MyInvocation.InvocationName -ne '.') {
    $mutex = [Threading.Mutex]::new($false, 'Local\FH6-MOZA-R3-OneClick')
    $ownsMutex = $false
    try {
        try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { throw '已经有一个安装器在运行。' }
        if (-not $Check) { Assert-GameClosed }
        $connectedId = Get-R3DeviceId
        $directory = Find-GameDirectory $GamePath
        $choiceFile = Find-SelectionFile
        Install-R3Configuration -Directory $directory -DeviceId $connectedId -SelectionFile $choiceFile -PresetDirectory (Join-Path $PSScriptRoot 'presets') -DryRun:$Check
    } catch {
        Write-Host ('安装器结束：' + $_.Exception.Message) -ForegroundColor Red
        exit 1
    } finally {
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
