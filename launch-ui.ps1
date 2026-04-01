param(
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AutostartScript = Join-Path $BaseDir "autostart.ps1"
$LatestUrlFile = Join-Path $BaseDir "latest-url.txt"
$StartupLog = Join-Path $BaseDir "logs\startup.log"

function Decode-Zh {
    param([string]$Base64Text)
    [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Base64Text))
}

$MsgStarting = Decode-Zh "6K+t6Z+z6L6T5YWl5ZCM5q2l5q2j5Zyo5ZCv5YqoLi4u"
$MsgDone = Decode-Zh "5ZCv5Yqo5a6M5oiQ44CC"
$MsgPhoneUrl = Decode-Zh "5omL5py66K6/6Zeu5Zyw5Z2A77yaezB9"
$MsgBrowserOpened = Decode-Zh "5rWP6KeI5Zmo5bey6Ieq5Yqo5omT5byA77yM5Zyw5Z2A5Lmf5bey5aSN5Yi25Yiw5Ymq6LS05p2/44CC"
$MsgNoUrl = Decode-Zh "5pyN5Yqh5bey5ZCv5Yqo77yM5L2G5pqC5pe25rKh5pyJ6K+75Y+W5Yiw5omL5py66K6/6Zeu5Zyw5Z2A44CC"
$MsgFailed = Decode-Zh "5ZCv5Yqo5aSx6LSl77yM6K+35p+l55yL5pel5b+X77ya"
$MsgClose = Decode-Zh "5oyJ5Zue6L2m6ZSu5YWz6Zet56qX5Y+j"

try {
    Write-Host ""
    Write-Host $MsgStarting -ForegroundColor Cyan
    Write-Host ""

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $AutostartScript -ForceOpenBrowser -Silent
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw "Start failed with exit code: $exitCode"
    }

    $url = ""
    if (Test-Path $LatestUrlFile) {
        $url = (Get-Content -Raw -LiteralPath $LatestUrlFile -Encoding UTF8).Trim()
    }

    Write-Host ""
    Write-Host $MsgDone -ForegroundColor Green
    if ($url) {
        Write-Host ($MsgPhoneUrl -f $url) -ForegroundColor Yellow
        Write-Host $MsgBrowserOpened -ForegroundColor DarkYellow
    } else {
        Write-Host $MsgNoUrl -ForegroundColor Yellow
    }
    Write-Host ""

    if (-not $NoPause) {
        Start-Sleep -Seconds 3
    }
    exit 0
} catch {
    Write-Host ""
    Write-Host $MsgFailed -ForegroundColor Red
    Write-Host $StartupLog -ForegroundColor Yellow
    Write-Host ""

    if (-not $NoPause) {
        Read-Host $MsgClose
    }
    exit 1
}
