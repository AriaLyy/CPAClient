$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = 'd:\WeokSpace\CpaClient'
$macDir = Join-Path $root 'macos\Runner\Assets.xcassets\AppIcon.appiconset'
$winIco = Join-Path $root 'windows\runner\resources\app_icon.ico'

New-Item -ItemType Directory -Force -Path $macDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $winIco) | Out-Null

function New-IconPng([int]$size, [string]$path) {
  $bmp = New-Object System.Drawing.Bitmap($size, $size)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

  $rect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
  $bg1 = [System.Drawing.Color]::FromArgb(255, 22, 46, 84)
  $bg2 = [System.Drawing.Color]::FromArgb(255, 45, 119, 255)
  $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $bg1, $bg2, 45)
  $g.FillRectangle($brush, $rect)

  $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 242, 247, 255), [Math]::Max(2, [int]($size * 0.12)))
  $margin = [int]($size * 0.22)
  $diameter = $size - (2 * $margin)
  $arcRect = New-Object System.Drawing.Rectangle($margin, $margin, $diameter, $diameter)
  $g.DrawArc($pen, $arcRect, 40, 280)

  $dotBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 133, 220, 255))
  $dot = [int]($size * 0.09)
  $dx = [int]($size * 0.57)
  $dy = [int]($size * 0.46)
  $g.FillEllipse($dotBrush, $dx, $dy, $dot, $dot)

  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)

  $g.Dispose()
  $brush.Dispose()
  $pen.Dispose()
  $dotBrush.Dispose()
  $bmp.Dispose()
}

$sizes = @(16, 32, 64, 128, 256, 512, 1024)
foreach ($s in $sizes) {
  New-IconPng -size $s -path (Join-Path $macDir ("app_icon_$s.png"))
}

$iconBmp = New-Object System.Drawing.Bitmap((Join-Path $macDir 'app_icon_256.png'))
$hIcon = $iconBmp.GetHicon()
$icon = [System.Drawing.Icon]::FromHandle($hIcon)
$fs = New-Object System.IO.FileStream($winIco, [System.IO.FileMode]::Create)
$icon.Save($fs)
$fs.Close()

$icon.Dispose()
$iconBmp.Dispose()

Write-Output 'icons generated'
