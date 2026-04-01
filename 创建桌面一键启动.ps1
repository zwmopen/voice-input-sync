function Decode-Zh {
    param([string]$Base64Text)
    [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Base64Text))
}

$baseDir = 'D:\AICode\voice-input-sync'
$desktopDir = [Environment]::GetFolderPath('Desktop')
$desktopFileName = Decode-Zh '6K+t6Z+z6L6T5YWl5ZCM5q2lLeWQr+WKqOW5tuaJk+W8gOWcsOWdgC5iYXQ='
$desktopScriptPath = Join-Path $desktopDir $desktopFileName
$targetBatPath = Join-Path $baseDir 'start.bat'

if (-not (Test-Path $targetBatPath)) {
    throw "Launch script not found: $targetBatPath"
}

$content = "@echo off`r`ncall ""$targetBatPath""`r`n"
[System.IO.File]::WriteAllText($desktopScriptPath, $content, [System.Text.Encoding]::ASCII)

Write-Output ("Desktop launcher created: {0}" -f $desktopScriptPath)
