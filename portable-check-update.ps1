param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PackageDir = Split-Path -Parent $BaseDir
$LogsDir = Join-Path $PackageDir "logs"
$BuildInfoFile = Join-Path $BaseDir "build-info.json"
$UpdateStatusFile = Join-Path $LogsDir "update-status.json"
$ApiUrl = "https://api.github.com/repos/zwmopen/voice-input-sync/releases/latest"
$FallbackReleaseUrl = "https://github.com/zwmopen/voice-input-sync/releases/latest"
$CacheMinutes = 45

New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null

function Read-BuildInfo {
    if (-not (Test-Path $BuildInfoFile)) {
        return $null
    }

    try {
        return Get-Content -Raw -LiteralPath $BuildInfoFile -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Read-UpdateStatus {
    if (-not (Test-Path $UpdateStatusFile)) {
        return $null
    }

    try {
        return Get-Content -Raw -LiteralPath $UpdateStatusFile -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Normalize-Version {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    return $Value.Trim().TrimStart("v", "V")
}

function Compare-Version {
    param(
        [string]$Left,
        [string]$Right
    )

    $leftText = if ($null -eq $Left) { "" } else { [string]$Left }
    $rightText = if ($null -eq $Right) { "" } else { [string]$Right }
    $leftParts = @(([regex]::Split($leftText, '[^0-9]+')) | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
    $rightParts = @(([regex]::Split($rightText, '[^0-9]+')) | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })

    if ($leftParts.Count -eq 0 -or $rightParts.Count -eq 0) {
        if ($Left -eq $Right) {
            return 0
        }

        return -1
    }

    $maxCount = [Math]::Max($leftParts.Count, $rightParts.Count)
    for ($index = 0; $index -lt $maxCount; $index++) {
        $leftValue = if ($index -lt $leftParts.Count) { $leftParts[$index] } else { 0 }
        $rightValue = if ($index -lt $rightParts.Count) { $rightParts[$index] } else { 0 }

        if ($leftValue -gt $rightValue) {
            return 1
        }
        if ($leftValue -lt $rightValue) {
            return -1
        }
    }

    return 0
}

function Write-UpdateStatus {
    param(
        [string]$CurrentVersion,
        [string]$LatestVersion,
        [bool]$HasUpdate,
        [string]$ReleaseUrl,
        [string]$State,
        [string]$CheckedAt,
        [string]$ErrorMessage = ""
    )

    $payload = [ordered]@{
        currentVersion = $CurrentVersion
        latestVersion = $LatestVersion
        hasUpdate = $HasUpdate
        releaseUrl = $ReleaseUrl
        state = $State
        checkedAt = $CheckedAt
        error = $ErrorMessage
    }

    $payload | ConvertTo-Json -Compress | Set-Content -LiteralPath $UpdateStatusFile -Encoding UTF8
}

$buildInfo = Read-BuildInfo
$currentVersion = ""
if ($buildInfo) {
    $currentVersion = Normalize-Version ([string]$buildInfo.appVersion)
    if ([string]::IsNullOrWhiteSpace($currentVersion)) {
        $currentVersion = Normalize-Version ([string]$buildInfo.gitCommit)
    }
}

$existingStatus = Read-UpdateStatus
if (-not $Force -and $existingStatus -and $existingStatus.checkedAt) {
    try {
        $checkedAt = [datetime]::Parse([string]$existingStatus.checkedAt)
        if (((Get-Date) - $checkedAt).TotalMinutes -lt $CacheMinutes -and ([string]$existingStatus.currentVersion).Trim() -eq $currentVersion) {
            exit 0
        }
    } catch {
    }
}

$headers = @{
    "User-Agent" = "VoiceInputSync/$currentVersion"
    "Accept" = "application/vnd.github+json"
}

$checkedStamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $response = Invoke-RestMethod -Uri $ApiUrl -Headers $headers -TimeoutSec 8
    $latestVersion = Normalize-Version ([string]$response.tag_name)
    $releaseUrl = [string]$response.html_url
    if ([string]::IsNullOrWhiteSpace($releaseUrl)) {
        $releaseUrl = $FallbackReleaseUrl
    }

    $hasUpdate = $false
    if (-not [string]::IsNullOrWhiteSpace($latestVersion) -and -not [string]::IsNullOrWhiteSpace($currentVersion)) {
        $hasUpdate = ((Compare-Version -Left $latestVersion -Right $currentVersion) -gt 0)
    }

    Write-UpdateStatus -CurrentVersion $currentVersion -LatestVersion $latestVersion -HasUpdate $hasUpdate -ReleaseUrl $releaseUrl -State "success" -CheckedAt $checkedStamp
} catch {
    Write-UpdateStatus -CurrentVersion $currentVersion -LatestVersion "" -HasUpdate $false -ReleaseUrl $FallbackReleaseUrl -State "error" -CheckedAt $checkedStamp -ErrorMessage $_.Exception.Message
}
