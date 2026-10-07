<#
.SYNOPSIS
  Genera VPN-Prioridad-TodoEnUno.bat a partir de VPN-Prioridad.ps1.
.DESCRIPTION
  El .bat es: cabecera (tools\bat-header.txt, con la auto-elevacion) + el script de PowerShell.
  La fuente unica es VPN-Prioridad.ps1: editalo y volve a correr esto.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Bat.ps1
#>
$ErrorActionPreference = 'Stop'
$raiz   = Split-Path -Parent $PSScriptRoot
$ps1    = Join-Path $raiz 'VPN-Prioridad.ps1'
$cab    = Join-Path $PSScriptRoot 'bat-header.txt'
$salida = Join-Path $raiz 'VPN-Prioridad-TodoEnUno.bat'

$texto = (Get-Content -Path $cab -Raw) + (Get-Content -Path $ps1 -Raw)
$texto = $texto -replace "`r?`n", "`r`n"          # el .bat necesita CRLF
if ($texto -match '[^\x00-\x7F]') { throw 'El script tiene caracteres no ASCII: el .bat los rompe. Usa solo ASCII.' }
[System.IO.File]::WriteAllText($salida, $texto, [System.Text.Encoding]::ASCII)
Write-Host ("Generado: {0} ({1:N0} KB)" -f $salida, ((Get-Item $salida).Length / 1KB))
