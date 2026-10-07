<#
.SYNOPSIS
  Compila VPN-Prioridad.ps1 a un .exe con ps2exe (opcional).
.DESCRIPTION
  Genera dist\VPN-Prioridad.exe, que pide permisos de administrador al abrirse.
  Requiere el modulo ps2exe (https://github.com/MScholtes/PS2EXE); se instala solo para tu usuario.
  Compilalo vos mismo desde el codigo fuente: un .exe sin firma digital puede ser
  bloqueado por SmartScreen o por el antivirus, por eso este repo no incluye binarios.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Exe.ps1
#>
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $raiz 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Instalando el modulo ps2exe (solo para tu usuario)...' -ForegroundColor Cyan
    Install-Module -Name ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

Invoke-ps2exe -inputFile (Join-Path $raiz 'VPN-Prioridad.ps1') `
              -outputFile (Join-Path $dist 'VPN-Prioridad.exe') `
              -requireAdmin `
              -title 'VPN Prioridad' `
              -description 'DNS, ruteo y monitoreo de VPN'
Write-Host ("Listo: {0}" -f (Join-Path $dist 'VPN-Prioridad.exe')) -ForegroundColor Green
