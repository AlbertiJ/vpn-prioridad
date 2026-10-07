# SPDX-License-Identifier: MIT
# https://github.com/AlbertiJ/vpn-prioridad
<#
.SYNOPSIS
  [v2] DNS del proveedor = automatico (DHCP) + verificacion; ya no usa la puerta de enlace como DNS.
  Gestion y monitoreo de la VPN: fuerza el DNS interno, verifica que
  el trafico salga por la VPN y no por el proveedor de internet, monitorea
  caidas en vivo y deja historial en disco.

.DESCRIPCION
  Caso tipico: te conectas a la VPN (de tu trabajo, de un cliente, etc.) pero Windows sigue saliendo por
  tu conexion de casa, porque combina los DNS de TODAS las interfaces activas y
  elige segun la metrica de cada una.

  Menu:
    1) Ver estado actual de la red            (no modifica nada)
    2) Forzar los DNS de la VPN
    3) Priorizar la VPN (bajar su metrica a 1)
    4) RESTABLECER TODO (DNS del proveedor, metricas, IPv6, cache DNS y ARP)
    5) Cambiar los DNS que se van a aplicar
    I) Cambiar la interfaz VPN elegida
    6) Monitorear la VPN en vivo
    7) Historial de caidas
    8) Ver log de OpenVPN
    9) Borrar registros
    A) Informe para el administrador
    0) Salir

  Los registros se guardan en la subcarpeta 'logs' junto al script.

.USO
  Modo menu (recomendado):
    .\VPN-Prioridad.ps1        (o doble clic en VPN-Prioridad-TodoEnUno.bat)

  Restablecer directo sin pasar por el menu:
    .\VPN-Prioridad.ps1 -Restore

  Los DNS se cargan desde el menu (opcion 5) y quedan guardados en logs\vpn_config.json.
  (Si corres el script de PowerShell por separado tambien acepta -DnsPrimario y -DnsSecundario.)

.NOTAS
  - Conectate PRIMERO a la VPN: el script necesita que la interfaz exista.
  - Hay que correrlo como Administrador para aplicar cambios. Sin permisos
    igual podes usar las opciones de diagnostico y monitoreo.
  - Si PowerShell bloquea el script (politica de ejecucion):
      powershell -NoProfile -ExecutionPolicy Bypass -File .\VPN-Prioridad.ps1
#>

param(
    [switch]$Restore,
    [string]$DnsPrimario   = '',   # DNS de la VPN: se cargan desde el menu (opcion 5)
    [string]$DnsSecundario = '',
    [string]$NombreDePrueba = '',  # un nombre interno que solo resuelva por la VPN (opcional)
    [string[]]$DnsVpnExtra = @(),
    [int]$IntervaloSegundos = 5
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------
# Rutas: todo cuelga de donde este el script
# ------------------------------------------------------------
$script:BaseDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:BaseDir)) {
    # Compilado a .exe (ps2exe) $PSScriptRoot viene vacio: usar la carpeta del .exe
    try {
        $exeRuta = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exeRuta -and ([System.IO.Path]::GetFileName($exeRuta) -notmatch '^(powershell|pwsh)')) {
            $script:BaseDir = Split-Path -Path $exeRuta -Parent
        }
    } catch { }
}
if ([string]::IsNullOrWhiteSpace($script:BaseDir)) { $script:BaseDir = (Get-Location).Path }

$script:LogDir     = Join-Path $script:BaseDir 'logs'
$script:EventosCsv = Join-Path $script:LogDir 'vpn_eventos.csv'
$script:MonitorLog = Join-Path $script:LogDir 'vpn_monitor.log'
$stateFile         = Join-Path $script:LogDir 'vpn_dns_state.json'
$configFile        = Join-Path $script:LogDir 'vpn_config.json'

$script:DnsPrim    = $DnsPrimario
$script:DnsSec     = $DnsSecundario
$script:VpnElegida = $null
$script:EsAdmin    = $false
$script:OpenVpn    = $null
$script:EstadoOtras = @()
$script:IPv6Apagado = @()
$script:NombrePrueba = $NombreDePrueba

# ============================================================
# Utilitarios
# ============================================================

function Test-EsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Save-Config {
    try {
        Initialize-Carpetas
        @{ DnsPrimario = $script:DnsPrim; DnsSecundario = $script:DnsSec; NombreDePrueba = $script:NombrePrueba } |
            ConvertTo-Json | Set-Content -Path $configFile -Encoding UTF8
    } catch {
        Write-Host ("No se pudo guardar la configuracion: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
    }
}

function Import-Config {
    # Solo completa lo que no vino por parametro.
    if (-not (Test-Path $configFile)) { return }
    try {
        $c = Get-Content -Path $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $script:DnsPrim      -and $c.DnsPrimario)    { $script:DnsPrim      = [string]$c.DnsPrimario }
        if (-not $script:DnsSec       -and $c.DnsSecundario)  { $script:DnsSec       = [string]$c.DnsSecundario }
        if (-not $script:NombrePrueba -and $c.NombreDePrueba) { $script:NombrePrueba = [string]$c.NombreDePrueba }
    } catch { }
}

function Test-EsIPv4 {
    param([string]$Texto)
    $ip = $null
    return ([System.Net.IPAddress]::TryParse($Texto, [ref]$ip) -and $ip.AddressFamily -eq 'InterNetwork')
}

function Confirm-DnsConfigurados {
    # Las acciones que escriben DNS necesitan al menos uno cargado.
    if ($script:DnsPrim) { return $true }
    Write-Host ''
    Write-Host 'Todavia no cargaste los DNS de la VPN (te los da el administrador).' -ForegroundColor Yellow
    Set-DnsPersonalizados
    if ($script:DnsPrim) { return $true }
    Write-Host 'Sin DNS no se puede continuar. No se toco nada.' -ForegroundColor Yellow
    return $false
}

function Wait-Enter {
    Write-Host ''
    Read-Host 'Presiona ENTER para volver al menu' | Out-Null
}

function Write-Titulo {
    param([string]$Texto)
    Write-Host ''
    Write-Host ('=' * 66) -ForegroundColor DarkCyan
    Write-Host "  $Texto" -ForegroundColor Cyan
    Write-Host ('=' * 66) -ForegroundColor DarkCyan
    Write-Host ''
}

function Initialize-Carpetas {
    if (-not (Test-Path $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        Write-Host ("Carpeta de logs creada: {0}" -f $script:LogDir) -ForegroundColor DarkGray
    }
    if (-not (Test-Path $script:EventosCsv)) {
        'Fecha,Tipo,Severidad,Detalle' | Set-Content -Path $script:EventosCsv -Encoding UTF8
    }
}

function Write-Evento {
    param(
        [string]$Tipo,
        [string]$Detalle,
        [ValidateSet('INFO','AVISO','CAIDA','OK','ACCION')]
        [string]$Severidad = 'INFO'
    )
    try {
        Initialize-Carpetas
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $d  = $Detalle -replace '"', "'"
        ('"{0}","{1}","{2}","{3}"' -f $ts, $Tipo, $Severidad, $d) |
            Add-Content -Path $script:EventosCsv -Encoding UTF8
        ('[{0}] [{1}] {2} - {3}' -f $ts, $Severidad, $Tipo, $d) |
            Add-Content -Path $script:MonitorLog -Encoding UTF8
    } catch {
        Write-Host ("No se pudo escribir el log: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
    }
}

function Get-AdaptadoresActivos {
    Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
}

function Test-RequiereAdmin {
    if (-not $script:EsAdmin) {
        Write-Host ''
        Write-Host 'Esta accion necesita permisos de Administrador.' -ForegroundColor Red
        Write-Host 'Cerra esta ventana y abri PowerShell con "Ejecutar como administrador".' -ForegroundColor Yellow
        return $false
    }
    return $true
}

function Show-ErrorAccion {
    param($ErrorRegistro)
    Write-Host ''
    Write-Host '  Se produjo un error en esta accion:' -ForegroundColor Red
    Write-Host ("  {0}" -f $ErrorRegistro.Exception.Message) -ForegroundColor Yellow
    if ($ErrorRegistro.InvocationInfo -and $ErrorRegistro.InvocationInfo.ScriptLineNumber) {
        Write-Host ("  (linea {0})" -f $ErrorRegistro.InvocationInfo.ScriptLineNumber) -ForegroundColor DarkGray
    }
    Write-Host '  El script sigue funcionando, volves al menu.' -ForegroundColor DarkGray
    try {
        Write-Evento -Tipo 'ERROR' -Severidad 'AVISO' -Detalle $ErrorRegistro.Exception.Message
    } catch { }
}

function Format-Duracion {
    param([datetime]$Desde)
    $t = (Get-Date) - $Desde
    if ($t.TotalMinutes -lt 1)  { return ('{0}s' -f [int]$t.TotalSeconds) }
    if ($t.TotalHours   -lt 1)  { return ('{0}m {1}s' -f $t.Minutes, $t.Seconds) }
    if ($t.TotalDays    -lt 1)  { return ('{0}h {1}m' -f [int]$t.TotalHours, $t.Minutes) }
    return ('{0}d {1}h' -f [int]$t.TotalDays, $t.Hours)
}

# ============================================================
# OpenVPN: deteccion automatica de servicio, proceso y log
# ============================================================

function Get-OpenVpnInfo {
    param([switch]$Refrescar)

    if ($script:OpenVpn -and -not $Refrescar) {
        # refrescamos solo el estado, no la deteccion completa
        if ($script:OpenVpn.ServicioNombre) {
            $sv = Get-Service -Name $script:OpenVpn.ServicioNombre -ErrorAction SilentlyContinue
            $script:OpenVpn.ServicioEstado = if ($sv) { $sv.Status.ToString() } else { 'NO ENCONTRADO' }
        }
        $script:OpenVpn.ProcesoActivo = [bool](Get-Process -Name 'openvpn*' -ErrorAction SilentlyContinue)
        return $script:OpenVpn
    }

    $info = [PSCustomObject]@{
        ServicioNombre  = $null
        ServicioDisplay = $null
        ServicioEstado  = 'NO ENCONTRADO'
        ProcesoActivo   = $false
        LogPath         = $null
        Detectado       = $false
    }

    $svc = Get-Service -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match 'openvpn' -or $_.DisplayName -match 'OpenVPN' } |
           Select-Object -First 1
    if ($svc) {
        $info.ServicioNombre  = $svc.Name
        $info.ServicioDisplay = $svc.DisplayName
        $info.ServicioEstado  = $svc.Status.ToString()
        $info.Detectado       = $true
    }

    $info.ProcesoActivo = [bool](Get-Process -Name 'openvpn*' -ErrorAction SilentlyContinue)
    if ($info.ProcesoActivo) { $info.Detectado = $true }

    $candidatos = @(
        (Join-Path $env:ProgramFiles 'OpenVPN\log'),
        (Join-Path ${env:ProgramFiles(x86)} 'OpenVPN\log'),
        (Join-Path $env:USERPROFILE 'OpenVPN\log'),
        (Join-Path $env:ProgramData 'OpenVPN\log'),
        (Join-Path $env:ProgramData 'OpenVPN Connect\log'),
        (Join-Path $env:APPDATA 'OpenVPN Connect\log')
    )
    foreach ($c in $candidatos) {
        if ($c -and (Test-Path $c)) {
            $ultimo = Get-ChildItem -Path $c -Filter '*.log' -ErrorAction SilentlyContinue |
                      Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($ultimo) { $info.LogPath = $ultimo.FullName; $info.Detectado = $true; break }
        }
    }

    $script:OpenVpn = $info
    return $info
}

# ============================================================
# Seleccion de la interfaz VPN
# ============================================================

function Select-InterfazVpn {
    param([switch]$Forzar, [switch]$Silencioso, [switch]$Confirmar)

    if ($script:VpnElegida -and -not $Forzar) {
        $viva = Get-NetAdapter -ifIndex $script:VpnElegida.ifIndex -ErrorAction SilentlyContinue

        if ($viva) {
            if ($Confirmar -and -not $Silencioso) {
                Write-Host ''
                Write-Host ("Interfaz VPN actual: {0}" -f $viva.Name) -ForegroundColor Cyan
                Write-Host ("  {0}  |  estado: {1}" -f $viva.InterfaceDescription, $viva.Status) -ForegroundColor DarkGray
                $r = Read-Host 'ENTER para usar esta, o C para elegir otra'
                if ($r -notmatch '^[cC]') { return $viva }
                Write-Host 'Elegi la interfaz correcta:' -ForegroundColor Yellow
                $script:VpnElegida = $null
            } else {
                return $viva
            }
        } else {
            if (-not $Silencioso) {
                Write-Host 'La interfaz elegida antes ya no existe. Elegi de nuevo.' -ForegroundColor Yellow
            }
            $script:VpnElegida = $null
        }
    }
    if ($Silencioso) { return $null }

    $adaptadores = Get-AdaptadoresActivos
    if (-not $adaptadores) {
        Write-Host 'No hay interfaces de red activas. Estas conectado a la VPN?' -ForegroundColor Yellow
        return $null
    }

    $tabla = @()
    $i = 0
    foreach ($a in $adaptadores) {
        $i++
        $tabla += [PSCustomObject]@{
            Num = $i; Nombre = $a.Name; Descripcion = $a.InterfaceDescription; IfIndex = $a.ifIndex
        }
    }

    Write-Host 'Interfaces de red activas:' -ForegroundColor Cyan
    $tabla | Format-Table Num, Nombre, Descripcion -AutoSize | Out-Host

    $posible = $adaptadores | Where-Object {
        $_.InterfaceDescription -match 'VPN|WAN Miniport|TAP|PPP|AnyConnect|FortiClient|GlobalProtect|Pulse|Cisco|SSTP|IKEv2|OpenVPN|WireGuard|Wintun'
    } | Select-Object -First 1
    if ($posible) {
        Write-Host ("Pinta a ser la VPN: '{0}' ({1})" -f $posible.Name, $posible.InterfaceDescription) -ForegroundColor Green
    }

    $sel = Read-Host 'Numero de la interfaz VPN (ENTER para cancelar)'
    if ([string]::IsNullOrWhiteSpace($sel)) { return $null }

    $num = 0
    if (-not [int]::TryParse($sel, [ref]$num)) { Write-Host 'Eso no es un numero.' -ForegroundColor Red; return $null }

    $elegido = $tabla | Where-Object { $_.Num -eq $num }
    if (-not $elegido) { Write-Host 'Numero fuera de la lista.' -ForegroundColor Red; return $null }

    $script:VpnElegida = Get-NetAdapter -ifIndex $elegido.IfIndex
    Write-Host ("Interfaz seleccionada: {0}" -f $script:VpnElegida.Name) -ForegroundColor Green
    Write-Evento -Tipo 'SELECCION' -Severidad 'INFO' -Detalle ("Interfaz VPN elegida: {0}" -f $script:VpnElegida.Name)
    return $script:VpnElegida
}

function Invoke-CambiarInterfaz {
    Write-Titulo 'CAMBIAR LA INTERFAZ VPN'

    if ($script:VpnElegida) {
        $act = Get-NetAdapter -ifIndex $script:VpnElegida.ifIndex -ErrorAction SilentlyContinue
        if ($act) {
            Write-Host ("Interfaz elegida ahora: {0}" -f $act.Name) -ForegroundColor Cyan
            Write-Host ("  {0}  |  estado: {1}" -f $act.InterfaceDescription, $act.Status) -ForegroundColor DarkGray
            Write-Host ''
        }
    } else {
        Write-Host 'Todavia no elegiste ninguna interfaz.' -ForegroundColor DarkGray
        Write-Host ''
    }

    $nueva = Select-InterfazVpn -Forzar
    if (-not $nueva) {
        Write-Host 'Cancelado: se mantiene la interfaz anterior.' -ForegroundColor Yellow
    }
}

# ============================================================
# Limpieza de caches: DNS y tabla ARP (Windows y Linux)
# ============================================================

function Show-ArpWindows {
    param([string]$Momento)
    try {
        $arp = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                 Where-Object { $_.State -ne 'Permanent' })
        Write-Host ("  Tabla ARP {0}: {1} entradas" -f $Momento, $arp.Count) -ForegroundColor DarkGray
        return $arp.Count
    } catch {
        Write-Host ("  No se pudo leer la tabla ARP: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
        return -1
    }
}

function Invoke-LimpiarWindows {
    Write-Host ''
    Write-Host '--- Limpiando en WINDOWS (este equipo) ---' -ForegroundColor Cyan
    if (-not (Test-RequiereAdmin)) { return }

    $antes = Show-ArpWindows -Momento 'ANTES'

    Write-Host ''
    Write-Host '  [1/3] Vaciando cache DNS...' -ForegroundColor Cyan
    try {
        Clear-DnsClientCache
        Write-Host '        OK (Clear-DnsClientCache)' -ForegroundColor Green
    } catch {
        Write-Host '        Fallo el cmdlet, probando con ipconfig...' -ForegroundColor DarkYellow
        $null = ipconfig /flushdns
        Write-Host '        OK (ipconfig /flushdns)' -ForegroundColor Green
    }

    Write-Host '  [2/3] Vaciando tabla ARP...' -ForegroundColor Cyan
    $arpOk = $false
    try {
        Remove-NetNeighbor -AddressFamily IPv4 -Confirm:$false -ErrorAction Stop
        $arpOk = $true
        Write-Host '        OK (Remove-NetNeighbor)' -ForegroundColor Green
    } catch {
        $salida = netsh interface ip delete arpcache 2>&1
        if ($LASTEXITCODE -eq 0) {
            $arpOk = $true
            Write-Host '        OK (netsh interface ip delete arpcache)' -ForegroundColor Green
        } else {
            Write-Host ("        No se pudo: {0}" -f ($salida -join ' ')) -ForegroundColor Red
        }
    }

    Write-Host '  [3/3] Vaciando cache NetBIOS...' -ForegroundColor Cyan
    try {
        $null = nbtstat -R 2>&1
        Write-Host '        OK (nbtstat -R)' -ForegroundColor Green
    } catch {
        Write-Host '        Omitido (nbtstat no disponible)' -ForegroundColor DarkGray
    }

    Write-Host ''
    Start-Sleep -Milliseconds 700
    $despues = Show-ArpWindows -Momento 'DESPUES'

    if ($antes -ge 0 -and $despues -ge 0) {
        Write-Host ''
        if ($despues -lt $antes) {
            Write-Host ("  Se liberaron {0} entradas ARP." -f ($antes - $despues)) -ForegroundColor Green
        } else {
            Write-Host '  La tabla ARP ya se esta repoblando sola: es normal.' -ForegroundColor DarkGray
        }
    }

    Write-Evento -Tipo 'LIMPIEZA' -Severidad 'ACCION' -Detalle ("Windows: DNS y ARP vaciados. ARP antes={0} despues={1}" -f $antes, $despues)

    Write-Host ''
    Write-Host '  Nota: la tabla ARP se repuebla sola en segundos. Es esperado.' -ForegroundColor DarkGray
    Write-Host '  Si ademas queres resetear el stack de red (requiere REINICIO):' -ForegroundColor DarkGray
    Write-Host '     netsh winsock reset' -ForegroundColor DarkGray
    Write-Host '     netsh int ip reset' -ForegroundColor DarkGray
}

function Invoke-LimpiarLinuxLocal {
    Write-Host ''
    Write-Host '--- Limpiando en LINUX (este equipo) ---' -ForegroundColor Cyan

    # detectar que resolvedor esta en uso
    $resolvedor = 'desconocido'
    if (Test-Path '/run/systemd/resolve') { $resolvedor = 'systemd-resolved' }
    elseif (Test-Path '/var/run/nscd')    { $resolvedor = 'nscd' }
    elseif (Test-Path '/etc/dnsmasq.conf'){ $resolvedor = 'dnsmasq' }
    Write-Host ("  Resolvedor detectado: {0}" -f $resolvedor) -ForegroundColor DarkGray

    Write-Host ''
    Write-Host '  [1/2] Vaciando cache DNS...' -ForegroundColor Cyan
    switch ($resolvedor) {
        'systemd-resolved' {
            $r = & sudo resolvectl flush-caches 2>&1
            if ($LASTEXITCODE -eq 0) { Write-Host '        OK (resolvectl flush-caches)' -ForegroundColor Green }
            else { Write-Host ("        Fallo: {0}" -f ($r -join ' ')) -ForegroundColor Red }
        }
        'nscd' {
            $r = & sudo nscd -i hosts 2>&1
            if ($LASTEXITCODE -eq 0) { Write-Host '        OK (nscd -i hosts)' -ForegroundColor Green }
            else { Write-Host ("        Fallo: {0}" -f ($r -join ' ')) -ForegroundColor Red }
        }
        'dnsmasq' {
            $r = & sudo systemctl restart dnsmasq 2>&1
            if ($LASTEXITCODE -eq 0) { Write-Host '        OK (restart dnsmasq)' -ForegroundColor Green }
            else { Write-Host ("        Fallo: {0}" -f ($r -join ' ')) -ForegroundColor Red }
        }
        default {
            Write-Host '        No se detecto un cache DNS local corriendo.' -ForegroundColor DarkYellow
            Write-Host '        En muchos Linux no hay cache: cada consulta va directo al DNS.' -ForegroundColor DarkGray
        }
    }

    Write-Host '  [2/2] Vaciando tabla ARP (vecinos)...' -ForegroundColor Cyan
    $antes = (& ip -4 neigh show 2>&1 | Measure-Object).Count
    Write-Host ("        Entradas antes: {0}" -f $antes) -ForegroundColor DarkGray
    $r = & sudo ip -s -s neigh flush all 2>&1
    if ($LASTEXITCODE -eq 0) {
        Start-Sleep -Milliseconds 500
        $despues = (& ip -4 neigh show 2>&1 | Measure-Object).Count
        Write-Host ("        OK (ip neigh flush all) - entradas despues: {0}" -f $despues) -ForegroundColor Green
    } else {
        Write-Host ("        Fallo: {0}" -f ($r -join ' ')) -ForegroundColor Red
    }

    Write-Evento -Tipo 'LIMPIEZA' -Severidad 'ACCION' -Detalle ("Linux local: DNS ({0}) y ARP vaciados" -f $resolvedor)
}

function Show-ComandosLinux {
    Write-Host ''
    Write-Host '--- COMANDOS PARA LINUX ---' -ForegroundColor Cyan
    Write-Host '  Copialos y pegalos en la terminal de la maquina Linux.' -ForegroundColor DarkGray
    Write-Host ''

    $bloque = @'
# ============================================================
#  VACIAR CACHE DNS  --  usa el que corresponda a tu sistema
# ============================================================

# 1) systemd-resolved (Ubuntu 18.04+, Debian 10+, la mayoria hoy)
sudo resolvectl flush-caches
resolvectl statistics            # verificar: Current Cache Size vuelve a 0

# 2) systemd-resolved en versiones viejas
sudo systemd-resolve --flush-caches

# 3) nscd (Name Service Cache Daemon)
sudo nscd -i hosts
# o directamente:  sudo systemctl restart nscd

# 4) dnsmasq (routers, equipos con cache local)
sudo systemctl restart dnsmasq

# 5) BIND / named (si el equipo es servidor DNS)
sudo rndc flush

# Como saber cual tenes corriendo:
systemctl is-active systemd-resolved nscd dnsmasq named 2>/dev/null


# ============================================================
#  VACIAR TABLA ARP  (en Linux se llama tabla de vecinos)
# ============================================================

ip -4 neigh show                 # ver la tabla actual
sudo ip -s -s neigh flush all    # vaciarla completa
ip -4 neigh show                 # confirmar que quedo vacia

# Borrar una sola entrada:
sudo ip neigh del <IP_DEL_HOST> dev eth0

# Forma vieja, todavia funciona:
sudo arp -d <IP_DEL_HOST>


# ============================================================
#  VERIFICAR DESPUES
# ============================================================

ip route get <IP_DEL_DNS>           # por que interfaz sale
dig <IP_DEL_DNS> -x +short          # resolucion inversa
ping -c 3 <IP_DEL_DNS>
'@

    Write-Host $bloque -ForegroundColor Gray
    Write-Host ''

    $r = Read-Host 'Copiar estos comandos al portapapeles? (S/N)'
    if ($r -match '^[sS]') {
        try {
            Set-Clipboard -Value $bloque
            Write-Host '  Copiado. Pegalo en la terminal Linux.' -ForegroundColor Green
        } catch {
            Write-Host '  No se pudo copiar al portapapeles en este host.' -ForegroundColor DarkYellow
        }
    }

    $r2 = Read-Host 'Guardar tambien como archivo .sh en la carpeta de logs? (S/N)'
    if ($r2 -match '^[sS]') {
        try {
            Initialize-Carpetas
            $ruta = Join-Path $script:LogDir 'limpiar_dns_arp_linux.sh'
            "#!/bin/bash`n$bloque" | Set-Content -Path $ruta -Encoding UTF8
            Write-Host ("  Guardado en: {0}" -f $ruta) -ForegroundColor Green
        } catch {
            Write-Host ("  No se pudo guardar: {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
    }
}

# ============================================================
# Nucleo del monitoreo: una foto del estado
# ============================================================

function Get-RutaGanadora {
    $rutas = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Select-Object ifIndex, NextHop, RouteMetric, InterfaceMetric,
            @{N='Efectiva'; E={ $_.RouteMetric + $_.InterfaceMetric }}
    if (-not $rutas) { return $null }
    return ($rutas | Sort-Object Efectiva | Select-Object -First 1)
}

function Get-EstadoVpn {
    param($Vpn, [switch]$ProbarDns)

    $e = [PSCustomObject]@{
        Hora            = Get-Date
        VpnNombre       = $null
        VpnArriba       = $false
        SalePorVpn      = $false
        RutaGanadoraIf  = $null
        RutaGanadoraNom = $null
        MetricaVpn      = $null
        DnsResponde     = $null
        DnsConfigurado  = $null
        SvcOpenVpn      = 'NO ENCONTRADO'
        ProcOpenVpn     = $false
    }

    if ($Vpn) {
        $ad = Get-NetAdapter -ifIndex $Vpn.ifIndex -ErrorAction SilentlyContinue
        $e.VpnNombre  = if ($ad) { $ad.Name } else { $Vpn.Name }
        $e.VpnArriba  = ($ad -and $ad.Status -eq 'Up')
        $e.MetricaVpn = (Get-NetIPInterface -InterfaceIndex $Vpn.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
        $dnsCfg = (Get-DnsClientServerAddress -InterfaceIndex $Vpn.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        $e.DnsConfigurado = if ($dnsCfg) { ($dnsCfg -join ', ') } else { '(automatico)' }
    }

    $ganadora = Get-RutaGanadora
    if ($ganadora) {
        $e.RutaGanadoraIf  = $ganadora.ifIndex
        $nom = (Get-NetAdapter -ifIndex $ganadora.ifIndex -ErrorAction SilentlyContinue).Name
        $e.RutaGanadoraNom = if ($nom) { $nom } else { ('ifIndex ' + $ganadora.ifIndex) }
        if ($Vpn -and $ganadora.ifIndex -eq $Vpn.ifIndex) { $e.SalePorVpn = $true }
    }

    if ($ProbarDns -and $script:DnsPrim) {
        try {
            $e.DnsResponde = Test-Connection -ComputerName $script:DnsPrim -Count 1 -Quiet -ErrorAction SilentlyContinue
        } catch { $e.DnsResponde = $false }
    }

    $ov = Get-OpenVpnInfo
    $e.SvcOpenVpn  = $ov.ServicioEstado
    $e.ProcOpenVpn = $ov.ProcesoActivo

    return $e
}

# ============================================================
# 1) Ver estado de la red
# ============================================================

function Show-EstadoRed {
    Write-Titulo 'ESTADO ACTUAL DE LA RED'

    Write-Host '--- Ruta por defecto (0.0.0.0/0), ordenada por metrica efectiva ---' -ForegroundColor Cyan
    Write-Host 'La de ARRIBA es por donde sale el trafico.' -ForegroundColor DarkGray
    $rutas = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Select-Object ifIndex,
            @{N='Interfaz';E={ (Get-NetAdapter -ifIndex $_.ifIndex -ErrorAction SilentlyContinue).Name }},
            NextHop, RouteMetric, InterfaceMetric,
            @{N='Efectiva';E={ $_.RouteMetric + $_.InterfaceMetric }}
    if ($rutas) { $rutas | Sort-Object Efectiva | Format-Table -AutoSize | Out-Host }
    else { Write-Host 'No se encontraron rutas por defecto.' -ForegroundColor Yellow }

    Write-Host '--- DNS configurados por interfaz ---' -ForegroundColor Cyan
    Get-DnsClientServerAddress |
        Where-Object { $_.ServerAddresses } |
        Format-Table InterfaceAlias, AddressFamily, ServerAddresses -AutoSize | Out-Host
    Write-Host '(si una placa que NO es la VPN tiene DNS internos o DNS IPv6, por ahi se fuga)' -ForegroundColor DarkGray

    Write-Host '--- Metrica de cada interfaz IPv4 ---' -ForegroundColor Cyan
    Write-Host '(menor metrica efectiva = gana. Se listan TODAS, no solo las fisicas)' -ForegroundColor DarkGray
    foreach ($ii in (Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue | Sort-Object InterfaceMetric)) {
        $ad = Get-NetAdapter -ifIndex $ii.InterfaceIndex -ErrorAction SilentlyContinue
        $nom = if ($ad) { $ad.Name } else { $ii.InterfaceAlias }
        $mark = ''
        if ($script:VpnElegida -and $ii.InterfaceIndex -eq $script:VpnElegida.ifIndex) { $mark = '  <== VPN elegida' }
        Write-Host ("  ifIndex {0,-4} {1,-34} metrica: {2,-4} auto: {3}{4}" -f `
            $ii.InterfaceIndex, $nom, $ii.InterfaceMetric, $ii.AutomaticMetric, $mark)
    }

    Write-Host ''
    Write-Host '--- OpenVPN ---' -ForegroundColor Cyan
    $ov = Get-OpenVpnInfo -Refrescar
    if ($ov.Detectado) {
        if ($ov.ServicioNombre) { Write-Host ("  Servicio : {0} ({1}) -> {2}" -f $ov.ServicioDisplay, $ov.ServicioNombre, $ov.ServicioEstado) }
        Write-Host ("  Proceso  : {0}" -f $(if ($ov.ProcesoActivo) { 'corriendo' } else { 'no esta corriendo' }))
        Write-Host ("  Log      : {0}" -f $(if ($ov.LogPath) { $ov.LogPath } else { 'no encontrado' }))
    } else {
        Write-Host '  No se detecto OpenVPN en este equipo.' -ForegroundColor DarkYellow
    }

    if (Test-Path $stateFile) {
        Write-Host ''
        Write-Host 'Hay DNS forzados sin restablecer (opcion 4).' -ForegroundColor Yellow
    }
}

# ============================================================
# 2) Forzar DNS de la VPN
# ============================================================

function Invoke-ForzarDns {
    param([switch]$SinTitulo)
    if (-not $SinTitulo) { Write-Titulo 'FORZAR LOS DNS DE LA VPN' }
    if (-not (Test-RequiereAdmin)) { return }
    if (-not (Confirm-DnsConfigurados)) { return }

    $vpn = Select-InterfazVpn -Confirmar
    if (-not $vpn) { Write-Host 'Cancelado, no se toco nada.' -ForegroundColor Yellow; return }

    $metricaOriginal = (Get-NetIPInterface -InterfaceIndex $vpn.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
    $dnsOriginal = (Get-DnsClientServerAddress -InterfaceIndex $vpn.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses

    Initialize-Carpetas
    @{
        IfIndex         = $vpn.ifIndex
        InterfaceAlias  = $vpn.Name
        MetricaOriginal = $metricaOriginal
        DnsOriginal     = $dnsOriginal
        Desde           = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    } | ConvertTo-Json | Set-Content $stateFile

    $dnsList = @($script:DnsPrim)
    if ($script:DnsSec) { $dnsList += $script:DnsSec }

    Write-Host ("Aplicando DNS ({0}) en '{1}'..." -f ($dnsList -join ', '), $vpn.Name) -ForegroundColor Cyan
    Set-DnsClientServerAddress -InterfaceIndex $vpn.ifIndex -ServerAddresses $dnsList
    Clear-DnsClientCache
    Write-Host 'DNS aplicados y cache limpiada.' -ForegroundColor Green
    Write-Evento -Tipo 'FORZAR-DNS' -Severidad 'ACCION' -Detalle ("DNS {0} aplicados en {1}" -f ($dnsList -join ' '), $vpn.Name)

    Show-EstadoRed

    $metricaVpn = (Get-NetIPInterface -InterfaceIndex $vpn.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
    $otraGana = $false
    foreach ($otra in (Get-AdaptadoresActivos | Where-Object { $_.ifIndex -ne $vpn.ifIndex })) {
        $m = (Get-NetIPInterface -InterfaceIndex $otra.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
        if ($m -and $metricaVpn -and $m -le $metricaVpn) { $otraGana = $true }
    }

    if ($otraGana) {
        Write-Host ''
        Write-Host 'OJO: otra interfaz activa tiene metrica igual o menor que la VPN.' -ForegroundColor Yellow
        Write-Host 'El trafico puede salir por ahi en vez de por la VPN.' -ForegroundColor Yellow
        $r = Read-Host 'Bajar la metrica de la VPN a 1 para priorizarla? (S/N)'
        if ($r -match '^[sS]') { Invoke-PriorizarVpn -VpnYaElegida $vpn }
    } else {
        Write-Host ''
        Write-Host 'La VPN ya tiene prioridad sobre las demas interfaces activas.' -ForegroundColor Green
    }
}

# ============================================================
# 3) Priorizar la VPN
# ============================================================

function Invoke-PriorizarVpn {
    param($VpnYaElegida)

    if (-not $VpnYaElegida) {
        Write-Titulo 'PRIORIZAR LA VPN'
        if (-not (Test-RequiereAdmin)) { return }
        $VpnYaElegida = Select-InterfazVpn -Confirmar
        if (-not $VpnYaElegida) { Write-Host 'Cancelado.' -ForegroundColor Yellow; return }
    }

    Initialize-Carpetas
    if (-not (Test-Path $stateFile)) {
        $mo = (Get-NetIPInterface -InterfaceIndex $VpnYaElegida.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
        @{
            IfIndex = $VpnYaElegida.ifIndex; InterfaceAlias = $VpnYaElegida.Name
            MetricaOriginal = $mo; DnsOriginal = $null
            Desde = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        } | ConvertTo-Json | Set-Content $stateFile
    }

    Set-NetIPInterface -InterfaceIndex $VpnYaElegida.ifIndex -InterfaceMetric 1
    Clear-DnsClientCache
    Write-Host ("Metrica de '{0}' puesta en 1 (maxima prioridad)." -f $VpnYaElegida.Name) -ForegroundColor Green
    Write-Evento -Tipo 'PRIORIZAR' -Severidad 'ACCION' -Detalle ("Metrica de {0} forzada a 1" -f $VpnYaElegida.Name)
}

# ============================================================
# 4) Restablecer
# ============================================================

function Invoke-Restaurar {
    Write-Titulo 'RESTABLECER DNS Y METRICA A AUTOMATICO'
    if (-not (Test-RequiereAdmin)) { return }

    if (-not (Test-Path $stateFile)) {
        Write-Host 'No hay estado guardado de una sesion anterior.' -ForegroundColor Yellow
        return
    }

    $estado = Get-Content $stateFile -Raw | ConvertFrom-Json

    Write-Host ("Restableciendo DNS automaticos en '{0}'..." -f $estado.InterfaceAlias) -ForegroundColor Cyan
    Set-DnsClientServerAddress -InterfaceIndex $estado.IfIndex -ResetServerAddresses

    if ($estado.MetricaOriginal) {
        Set-NetIPInterface -InterfaceIndex $estado.IfIndex -InterfaceMetric $estado.MetricaOriginal -ErrorAction SilentlyContinue
        Write-Host ("Metrica devuelta a {0}." -f $estado.MetricaOriginal) -ForegroundColor Cyan
    } else {
        Set-NetIPInterface -InterfaceIndex $estado.IfIndex -AutomaticMetric Enabled -ErrorAction SilentlyContinue
        Write-Host 'Metrica devuelta a automatica.' -ForegroundColor Cyan
    }

    if ($estado.Otras) {
        foreach ($o in @($estado.Otras)) {
            if (-not $o.IfIndex) { continue }
            $origDns = @($o.DnsOriginal | Where-Object { $_ })
            $eranDeVpn = $false
            foreach ($d in $origDns) { if ((Get-DnsVpn) -contains $d) { $eranDeVpn = $true } }
            if ($origDns.Count -gt 0 -and -not $eranDeVpn) {
                Set-DnsClientServerAddress -InterfaceIndex $o.IfIndex -ServerAddresses $origDns -ErrorAction SilentlyContinue
            } else {
                # estaba vacia o contaminada con DNS de la VPN: automatico + verificacion
                $null = Set-DnsProveedor -IfIndex $o.IfIndex -Alias $o.Alias
            }
            if ($o.AutoMetrica -eq 'Enabled') {
                Set-NetIPInterface -InterfaceIndex $o.IfIndex -AddressFamily IPv4 -AutomaticMetric Enabled -ErrorAction SilentlyContinue
            } elseif ($o.MetricaOriginal) {
                Set-NetIPInterface -InterfaceIndex $o.IfIndex -AddressFamily IPv4 -InterfaceMetric $o.MetricaOriginal -ErrorAction SilentlyContinue
            }
            Write-Host ("  '{0}' devuelta a como estaba." -f $o.Alias) -ForegroundColor DarkGray
        }
    }

    if ($estado.IPv6Apagado) {
        foreach ($nom in @($estado.IPv6Apagado)) {
            if (-not $nom) { continue }
            try {
                Enable-NetAdapterBinding -Name $nom -ComponentID 'ms_tcpip6' -Confirm:$false -ErrorAction Stop
                Write-Host ("  IPv6 vuelto a prender en '{0}'." -f $nom) -ForegroundColor DarkGray
            } catch {
                Write-Host ("  No se pudo re-activar IPv6 en '{0}'. Hacelo a mano en Propiedades de la placa." -f $nom) -ForegroundColor Red
            }
        }
    }

    Clear-DnsClientCache
    Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
    $script:EstadoOtras = @()
    $script:IPv6Apagado = @()
    Write-Host 'Listo: DNS y metricas restablecidos en todas las interfaces tocadas.' -ForegroundColor Green
    Write-Evento -Tipo 'RESTAURAR' -Severidad 'ACCION' -Detalle ("DNS y metrica restablecidos en {0}" -f $estado.InterfaceAlias)
}

# ============================================================
# 5) Cambiar DNS
# ============================================================

function Set-DnsPersonalizados {
    Write-Titulo 'CAMBIAR LOS DNS A APLICAR'
    $act1 = if ($script:DnsPrim) { $script:DnsPrim } else { '(sin configurar)' }
    $act2 = if ($script:DnsSec)  { $script:DnsSec }  else { '(sin secundario)' }
    Write-Host ("Actuales: {0} / {1}" -f $act1, $act2) -ForegroundColor Cyan
    Write-Host ''

    while ($true) {
        $p = Read-Host ("DNS primario (ENTER deja {0})" -f $act1)
        if ([string]::IsNullOrWhiteSpace($p)) { break }
        if (Test-EsIPv4 $p.Trim()) { $script:DnsPrim = $p.Trim(); break }
        Write-Host '  Eso no es una IPv4 valida. Proba de nuevo (o ENTER para dejar el anterior).' -ForegroundColor Red
    }

    while ($true) {
        $s = Read-Host ("DNS secundario (ENTER deja {0}, escribi NINGUNO para quitarlo)" -f $act2)
        if ([string]::IsNullOrWhiteSpace($s)) { break }
        if ($s -match '^(?i)ninguno$') { $script:DnsSec = ''; break }
        if (Test-EsIPv4 $s.Trim()) { $script:DnsSec = $s.Trim(); break }
        Write-Host '  Eso no es una IPv4 valida. Proba de nuevo (o ENTER para dejar el anterior).' -ForegroundColor Red
    }

    $nomAct = if ($script:NombrePrueba) { $script:NombrePrueba } else { 'ninguno' }
    $n = Read-Host ("Nombre interno de prueba (resuelve solo por la VPN; ENTER deja {0}, NINGUNO para quitarlo)" -f $nomAct)
    if ($n -match '^(?i)ninguno$') { $script:NombrePrueba = '' }
    elseif (-not [string]::IsNullOrWhiteSpace($n)) { $script:NombrePrueba = $n.Trim() }

    $txt = if ($script:DnsSec) { $script:DnsSec } else { '(sin secundario)' }
    $pr  = if ($script:DnsPrim) { $script:DnsPrim } else { '(sin configurar)' }
    Write-Host ''
    Write-Host ("Quedaron: {0} / {1}" -f $pr, $txt) -ForegroundColor Green
    Save-Config
    Write-Host 'Guardados en logs\vpn_config.json. Aplicalos con la opcion 2 o con F.' -ForegroundColor DarkGray
}

# ============================================================
# 6) Monitor en vivo
# ============================================================

function Test-SoportaTeclado {
    # Algunos hosts (ISE, consolas con stdin redirigido) no soportan
    # deteccion de teclas. Lo probamos de verdad antes de depender de eso.
    try {
        $null = [console]::KeyAvailable
        return $true
    } catch {
        try {
            $null = $Host.UI.RawUI.KeyAvailable
            return $true
        } catch {
            return $false
        }
    }
}

function Test-TeclaPresionada {
    # Devuelve $true si el usuario apreto CUALQUIER tecla.
    # Vacia el buffer para no arrastrar teclas viejas.
    try {
        if ([console]::KeyAvailable) {
            while ([console]::KeyAvailable) { [void][console]::ReadKey($true) }
            return $true
        }
        return $false
    } catch { }

    try {
        if ($Host.UI.RawUI.KeyAvailable) {
            while ($Host.UI.RawUI.KeyAvailable) {
                [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            }
            return $true
        }
    } catch { }

    return $false
}

function Start-MonitorVpn {
    Write-Titulo 'MONITOR DE VPN EN VIVO'

    $vpn = Select-InterfazVpn -Confirmar
    if (-not $vpn) { Write-Host 'Sin interfaz elegida, no se puede monitorear.' -ForegroundColor Yellow; return }

    Initialize-Carpetas

    # ---- preparar el teclado ----
    $soportaTeclado = Test-SoportaTeclado
    $ctrlCOriginal  = $null
    if ($soportaTeclado) {
        # Con esto el Ctrl+C llega como tecla comun y no mata el script:
        # asi volves al menu en vez de perder la sesion.
        try {
            $ctrlCOriginal = [console]::TreatControlCAsInput
            [console]::TreatControlCAsInput = $true
        } catch {
            $ctrlCOriginal = $null
        }
    }

    # ---- limite de tiempo: nunca queda colgado para siempre ----
    Write-Host ''
    if ($soportaTeclado) {
        Write-Host 'Salida: apreta CUALQUIER TECLA para volver al menu.' -ForegroundColor Green
    } else {
        Write-Host 'ATENCION: este host no permite detectar teclas.' -ForegroundColor Yellow
        Write-Host 'El monitor va a volver solo al menu cuando se cumpla el tiempo.' -ForegroundColor Yellow
    }

    $m = Read-Host 'Cuantos minutos monitoreo? (ENTER = 30)'
    $minutos = 30
    if (-not [string]::IsNullOrWhiteSpace($m)) {
        $tmp = 0
        if ([int]::TryParse($m, [ref]$tmp) -and $tmp -gt 0) { $minutos = $tmp }
    }
    $limite = (Get-Date).AddMinutes($minutos)

    Write-Host ''
    Write-Host ("Monitoreando cada {0} segundos, por {1} minutos." -f $IntervaloSegundos, $minutos) -ForegroundColor DarkGray
    Start-Sleep -Seconds 2

    Write-Evento -Tipo 'MONITOR' -Severidad 'INFO' -Detalle ("Monitoreo iniciado sobre {0} por {1} min" -f $vpn.Name, $minutos)

    $prev = $null
    $desdeVpn  = Get-Date
    $desdeRuta = Get-Date
    $tick = 0
    $salir = $false
    $motivoSalida = 'tiempo cumplido'
    $caidasSesion = 0

    try {
        while (-not $salir) {
            $tick++
            $probarDns = ($tick % 3 -eq 1)   # el ping cada 3 ticks, para no cargar
            $e = Get-EstadoVpn -Vpn $vpn -ProbarDns:$probarDns

            # ---- deteccion de transiciones ----
            if ($prev) {
                if ($e.VpnArriba -ne $prev.VpnArriba) {
                    $desdeVpn = Get-Date
                    if ($e.VpnArriba) {
                        Write-Evento -Tipo 'VPN-INTERFAZ' -Severidad 'OK' -Detalle ("La interfaz {0} volvio a estar UP" -f $e.VpnNombre)
                    } else {
                        $caidasSesion++
                        Write-Evento -Tipo 'VPN-INTERFAZ' -Severidad 'CAIDA' -Detalle ("La interfaz {0} se cayo (DOWN)" -f $e.VpnNombre)
                    }
                }
                if ($e.SalePorVpn -ne $prev.SalePorVpn) {
                    $desdeRuta = Get-Date
                    if ($e.SalePorVpn) {
                        Write-Evento -Tipo 'RUTEO' -Severidad 'OK' -Detalle 'El trafico volvio a salir por la VPN'
                    } else {
                        $caidasSesion++
                        Write-Evento -Tipo 'RUTEO' -Severidad 'CAIDA' -Detalle ("El trafico se fue por {0} (proveedor de internet)" -f $e.RutaGanadoraNom)
                    }
                }
                if ($null -ne $e.DnsResponde -and $e.DnsResponde -ne $prev.DnsResponde) {
                    if ($e.DnsResponde) {
                        Write-Evento -Tipo 'DNS' -Severidad 'OK' -Detalle ("El DNS interno {0} volvio a responder" -f $script:DnsPrim)
                    } else {
                        $caidasSesion++
                        Write-Evento -Tipo 'DNS' -Severidad 'CAIDA' -Detalle ("El DNS interno {0} dejo de responder" -f $script:DnsPrim)
                    }
                }
                if ($e.SvcOpenVpn -ne $prev.SvcOpenVpn) {
                    $sev = if ($e.SvcOpenVpn -eq 'Running') { 'OK' } else { 'CAIDA' }
                    if ($sev -eq 'CAIDA') { $caidasSesion++ }
                    Write-Evento -Tipo 'OPENVPN' -Severidad $sev -Detalle ("Servicio OpenVPN: {0} -> {1}" -f $prev.SvcOpenVpn, $e.SvcOpenVpn)
                }
            } else {
                Write-Evento -Tipo 'MONITOR' -Severidad 'INFO' -Detalle ("Estado inicial: VPN {0}, ruta por {1}, servicio {2}" -f `
                    $(if ($e.VpnArriba) {'UP'} else {'DOWN'}), $e.RutaGanadoraNom, $e.SvcOpenVpn)
            }

            # ---- pantalla ----
            Clear-Host
            Write-Host ''
            Write-Host '  ############################################################' -ForegroundColor DarkCyan
            Write-Host '  #                MONITOR DE VPN EN VIVO                    #' -ForegroundColor Cyan
            Write-Host '  ############################################################' -ForegroundColor DarkCyan
            Write-Host ''
            Write-Host ("  {0}" -f (Get-Date -Format 'dddd dd/MM/yyyy HH:mm:ss')) -ForegroundColor DarkGray
            if ($soportaTeclado) {
                Write-Host '  >>> Apreta CUALQUIER TECLA para volver al menu <<<' -ForegroundColor Yellow
            } else {
                Write-Host ("  >>> Vuelve solo al menu a las {0} <<<" -f $limite.ToString('HH:mm:ss')) -ForegroundColor Yellow
            }
            Write-Host ''

            $cVpn = if ($e.VpnArriba) { 'Green' } else { 'Red' }
            $tVpn = if ($e.VpnArriba) { 'ARRIBA' } else { 'CAIDA' }
            Write-Host ('  Interfaz VPN    : ') -NoNewline
            Write-Host ("{0,-10}" -f $tVpn) -ForegroundColor $cVpn -NoNewline
            Write-Host ("{0}  (hace {1})" -f $e.VpnNombre, (Format-Duracion $desdeVpn))

            $cRuta = if ($e.SalePorVpn) { 'Green' } else { 'Red' }
            $tRuta = if ($e.SalePorVpn) { 'POR VPN' } else { 'POR ISP' }
            Write-Host ('  Salida trafico  : ') -NoNewline
            Write-Host ("{0,-10}" -f $tRuta) -ForegroundColor $cRuta -NoNewline
            Write-Host ("{0}  (hace {1})" -f $e.RutaGanadoraNom, (Format-Duracion $desdeRuta))

            Write-Host ('  Metrica VPN     : ') -NoNewline
            Write-Host ("{0}" -f $e.MetricaVpn) -ForegroundColor Gray

            Write-Host ('  DNS en la VPN   : ') -NoNewline
            Write-Host ("{0}" -f $e.DnsConfigurado) -ForegroundColor Gray

            if ($null -ne $e.DnsResponde) {
                $cDns = if ($e.DnsResponde) { 'Green' } else { 'Red' }
                $tDns = if ($e.DnsResponde) { 'RESPONDE' } else { 'SIN RESPUESTA' }
                Write-Host ('  DNS interno     : ') -NoNewline
                Write-Host ("{0,-14}" -f $tDns) -ForegroundColor $cDns -NoNewline
                Write-Host ("({0})" -f $script:DnsPrim)
            }

            $cSvc = if ($e.SvcOpenVpn -eq 'Running') { 'Green' } elseif ($e.SvcOpenVpn -eq 'NO ENCONTRADO') { 'DarkGray' } else { 'Red' }
            Write-Host ('  Servicio OpenVPN: ') -NoNewline
            Write-Host ("{0,-14}" -f $e.SvcOpenVpn) -ForegroundColor $cSvc -NoNewline
            Write-Host ("proceso: {0}" -f $(if ($e.ProcOpenVpn) { 'si' } else { 'no' }))

            Write-Host ''
            Write-Host ('  ' + ('-' * 58)) -ForegroundColor DarkGray
            if ($e.SalePorVpn -and $e.VpnArriba) {
                Write-Host '  RECOMENDACION: todo OK, no hace falta forzar nada.' -ForegroundColor Green
            } elseif (-not $e.VpnArriba) {
                Write-Host '  RECOMENDACION: la VPN esta caida. Reconectala primero.' -ForegroundColor Red
            } else {
                Write-Host '  RECOMENDACION: HAY QUE FORZAR. El trafico sale por el ISP.' -ForegroundColor Red
            }
            Write-Host ('  Caidas detectadas en esta sesion: {0}' -f $caidasSesion) -ForegroundColor DarkGray
            Write-Host ('  Registro: {0}' -f $script:EventosCsv) -ForegroundColor DarkGray
            $restante = $limite - (Get-Date)
            if ($restante.TotalSeconds -gt 0) {
                Write-Host ('  Termina en: {0:hh\:mm\:ss}   (ciclo {1})' -f $restante, $tick) -ForegroundColor DarkGray
            }

            # ---- preguntar si se fue por el ISP ----
            if ($prev -and $e.VpnArriba -and -not $e.SalePorVpn -and $prev.SalePorVpn) {
                Write-Host ''
                [console]::Beep(800, 250)
                Write-Host '  !! El trafico dejo de salir por la VPN !!' -ForegroundColor Red
                $r = Read-Host '  Queres re-forzar ahora? (S = si / ENTER = seguir monitoreando)'
                if ($r -match '^[sS]') {
                    if ($script:EsAdmin) {
                        Write-Evento -Tipo 'RUTEO' -Severidad 'ACCION' -Detalle 'Re-forzado manual desde el monitor'
                        Invoke-PriorizarVpn -VpnYaElegida $vpn
                        $dnsList = @(Get-DnsVpn | Select-Object -First 2)
                        if ($dnsList.Count -gt 0) { Set-DnsClientServerAddress -InterfaceIndex $vpn.ifIndex -ServerAddresses $dnsList }
                        Clear-DnsClientCache
                        Write-Host '  Re-forzado aplicado.' -ForegroundColor Green
                        Start-Sleep -Seconds 2
                    } else {
                        Write-Host '  Sin permisos de administrador para aplicar cambios.' -ForegroundColor Red
                        Start-Sleep -Seconds 2
                    }
                }
            }

            $prev = $e

            # ---- espera: sale por tecla o por tiempo cumplido ----
            $fin = (Get-Date).AddSeconds($IntervaloSegundos)
            while ((Get-Date) -lt $fin) {

                if ($soportaTeclado -and (Test-TeclaPresionada)) {
                    $salir = $true
                    $motivoSalida = 'tecla'
                    break
                }

                if ((Get-Date) -ge $limite) {
                    $salir = $true
                    $motivoSalida = 'tiempo cumplido'
                    break
                }

                Start-Sleep -Milliseconds 150
            }

            if (-not $salir -and (Get-Date) -ge $limite) {
                $salir = $true
                $motivoSalida = 'tiempo cumplido'
            }
        }
    } finally {
        # devolver el Ctrl+C a su comportamiento normal
        if ($null -ne $ctrlCOriginal) {
            try { [console]::TreatControlCAsInput = $ctrlCOriginal } catch { }
        }
        Write-Evento -Tipo 'MONITOR' -Severidad 'INFO' -Detalle ("Monitoreo detenido ({0}). Caidas en la sesion: {1}" -f $motivoSalida, $caidasSesion)
        Write-Host ''
        Write-Host ("Monitoreo detenido ({0})." -f $motivoSalida) -ForegroundColor Cyan
        Write-Host ("Caidas registradas en esta sesion: {0}" -f $caidasSesion) -ForegroundColor DarkGray
    }
}

# ============================================================
# 7) Historial de caidas
# ============================================================

function Show-HistorialCaidas {
    Write-Titulo 'HISTORIAL DE CAIDAS Y EVENTOS'

    if (-not (Test-Path $script:EventosCsv)) {
        Write-Host 'Todavia no hay registros. Corre el monitor (opcion 6) primero.' -ForegroundColor Yellow
        return
    }

    $datos = @(Import-Csv -Path $script:EventosCsv -Encoding UTF8)
    if ($datos.Count -eq 0) { Write-Host 'El registro esta vacio.' -ForegroundColor Yellow; return }

    Write-Host ("Archivo : {0}" -f $script:EventosCsv) -ForegroundColor DarkGray
    Write-Host ("Eventos : {0}" -f $datos.Count) -ForegroundColor DarkGray
    Write-Host ''

    Write-Host '--- Resumen por tipo ---' -ForegroundColor Cyan
    $datos | Group-Object Tipo | Sort-Object Count -Descending |
        Select-Object @{N='Tipo';E={$_.Name}}, @{N='Cantidad';E={$_.Count}} |
        Format-Table -AutoSize | Out-Host

    $caidas = @($datos | Where-Object { $_.Severidad -eq 'CAIDA' })
    Write-Host ("--- Caidas registradas: {0} ---" -f $caidas.Count) -ForegroundColor Cyan
    if ($caidas.Count -gt 0) {
        $caidas | Select-Object -Last 20 | Format-Table Fecha, Tipo, Detalle -AutoSize -Wrap | Out-Host
        if ($caidas.Count -gt 20) { Write-Host ("(mostrando las ultimas 20 de {0})" -f $caidas.Count) -ForegroundColor DarkGray }

        Write-Host ''
        Write-Host '--- Caidas por dia ---' -ForegroundColor Cyan
        $caidas | Group-Object { ($_.Fecha -split ' ')[0] } | Sort-Object Name |
            Select-Object @{N='Dia';E={$_.Name}}, @{N='Caidas';E={$_.Count}} |
            Format-Table -AutoSize | Out-Host
    } else {
        Write-Host 'Ninguna caida registrada hasta ahora.' -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '--- Ultimos 15 eventos ---' -ForegroundColor Cyan
    $datos | Select-Object -Last 15 | Format-Table Fecha, Severidad, Tipo, Detalle -AutoSize -Wrap | Out-Host
}

# ============================================================
# 8) Log de OpenVPN
# ============================================================

function Show-LogOpenVpn {
    Write-Titulo 'LOG DE OPENVPN'

    $ov = Get-OpenVpnInfo -Refrescar
    if (-not $ov.LogPath) {
        Write-Host 'No se encontro un log de OpenVPN en las rutas habituales:' -ForegroundColor Yellow
        Write-Host '  Program Files\OpenVPN\log' -ForegroundColor DarkGray
        Write-Host '  Perfil de usuario\OpenVPN\log' -ForegroundColor DarkGray
        Write-Host '  ProgramData\OpenVPN Connect\log' -ForegroundColor DarkGray
        Write-Host ''
        $ruta = Read-Host 'Ruta completa al archivo de log (ENTER para cancelar)'
        if ([string]::IsNullOrWhiteSpace($ruta) -or -not (Test-Path $ruta)) {
            Write-Host 'Cancelado o ruta inexistente.' -ForegroundColor Yellow
            return
        }
        $ov.LogPath = $ruta
        $script:OpenVpn = $ov
    }

    Write-Host ("Archivo: {0}" -f $ov.LogPath) -ForegroundColor DarkGray
    $fi = Get-Item $ov.LogPath -ErrorAction SilentlyContinue
    if ($fi) { Write-Host ("Modificado: {0}  ({1:N0} KB)" -f $fi.LastWriteTime, ($fi.Length / 1KB)) -ForegroundColor DarkGray }
    Write-Host ''

    $contenido = Get-Content -Path $ov.LogPath -ErrorAction SilentlyContinue
    if (-not $contenido) { Write-Host 'El log esta vacio o no se pudo leer.' -ForegroundColor Yellow; return }

    Write-Host '--- Eventos de conexion, reconexion y error ---' -ForegroundColor Cyan
    $patron = 'Initialization Sequence Completed|Restart|RECONNECTING|Connection reset|TLS Error|AUTH_FAILED|SIGTERM|SIGUSR1|Inactivity timeout|read UDP|link remote|Peer Connection Initiated|EXITING'
    $relevantes = @($contenido | Select-String -Pattern $patron)
    if ($relevantes.Count -gt 0) {
        $relevantes | Select-Object -Last 25 | ForEach-Object {
            $linea = $_.Line
            $color = 'Gray'
            if ($linea -match 'Initialization Sequence Completed|Peer Connection Initiated') { $color = 'Green' }
            elseif ($linea -match 'TLS Error|AUTH_FAILED|Connection reset|EXITING') { $color = 'Red' }
            elseif ($linea -match 'RECONNECTING|Restart|Inactivity timeout') { $color = 'Yellow' }
            Write-Host ("  " + $linea) -ForegroundColor $color
        }
        Write-Host ''
        Write-Host ("Total de eventos relevantes en el log: {0}" -f $relevantes.Count) -ForegroundColor DarkGray
    } else {
        Write-Host 'No se encontraron eventos de conexion o error conocidos.' -ForegroundColor DarkGray
    }

    Write-Host ''
    $r = Read-Host 'Ver las ultimas 30 lineas crudas del log? (S/N)'
    if ($r -match '^[sS]') {
        Write-Host ''
        $contenido | Select-Object -Last 30 | ForEach-Object { Write-Host ("  " + $_) -ForegroundColor DarkGray }
    }
}

# ============================================================
# 9) Borrar registros
# ============================================================

function Clear-Registros {
    Write-Titulo 'BORRAR REGISTROS'

    $hayCsv = Test-Path $script:EventosCsv
    $hayLog = Test-Path $script:MonitorLog

    Write-Host ("Carpeta de logs: {0}" -f $script:LogDir) -ForegroundColor DarkGray
    if ($hayCsv) {
        $n = @(Import-Csv -Path $script:EventosCsv -Encoding UTF8).Count
        $t = (Get-Item $script:EventosCsv).Length
        Write-Host ("  vpn_eventos.csv : {0} eventos ({1:N0} KB)" -f $n, ($t / 1KB))
    } else { Write-Host '  vpn_eventos.csv : no existe' -ForegroundColor DarkGray }
    if ($hayLog) {
        $t = (Get-Item $script:MonitorLog).Length
        Write-Host ("  vpn_monitor.log : {0:N0} KB" -f ($t / 1KB))
    } else { Write-Host '  vpn_monitor.log : no existe' -ForegroundColor DarkGray }

    if (-not $hayCsv -and -not $hayLog) {
        Write-Host ''
        Write-Host 'No hay nada para borrar.' -ForegroundColor Yellow
        return
    }

    Write-Host ''
    Write-Host '  1) Borrar eventos anteriores a X dias  (conserva lo reciente)'
    Write-Host '  2) Borrar TODO el historial'
    Write-Host '  3) Hacer una copia de respaldo y despues vaciar'
    Write-Host '  0) Cancelar'
    Write-Host ''
    $op = Read-Host '  Que hacemos'

    switch ($op.Trim()) {

        '1' {
            $d = Read-Host '  Conservar los ultimos cuantos dias'
            $dias = 0
            if (-not [int]::TryParse($d, [ref]$dias) -or $dias -lt 0) {
                Write-Host '  Numero invalido.' -ForegroundColor Red; return
            }
            if (-not $hayCsv) { Write-Host '  No hay CSV para depurar.' -ForegroundColor Yellow; return }

            $corte = (Get-Date).AddDays(-$dias)
            $datos = @(Import-Csv -Path $script:EventosCsv -Encoding UTF8)
            $quedan = @($datos | Where-Object {
                $f = $null
                if ([datetime]::TryParse($_.Fecha, [ref]$f)) { $f -ge $corte } else { $true }
            })
            $borrados = $datos.Count - $quedan.Count

            Write-Host ("  Se van a borrar {0} eventos y conservar {1}." -f $borrados, $quedan.Count) -ForegroundColor Yellow
            $ok = Read-Host '  Confirmas? (S/N)'
            if ($ok -notmatch '^[sS]') { Write-Host '  Cancelado.' -ForegroundColor Yellow; return }

            'Fecha,Tipo,Severidad,Detalle' | Set-Content -Path $script:EventosCsv -Encoding UTF8
            foreach ($r in $quedan) {
                ('"{0}","{1}","{2}","{3}"' -f $r.Fecha, $r.Tipo, $r.Severidad, ($r.Detalle -replace '"', "'")) |
                    Add-Content -Path $script:EventosCsv -Encoding UTF8
            }
            Write-Host ("  Listo: {0} eventos borrados." -f $borrados) -ForegroundColor Green
            Write-Evento -Tipo 'MANTENIMIENTO' -Severidad 'ACCION' -Detalle ("Purga de historial: {0} eventos borrados, conservados {1} dias" -f $borrados, $dias)
        }

        '2' {
            Write-Host '  Esto borra TODO el historial de caidas y eventos.' -ForegroundColor Red
            $ok = Read-Host '  Escribi BORRAR para confirmar'
            if ($ok -ne 'BORRAR') { Write-Host '  Cancelado.' -ForegroundColor Yellow; return }

            if ($hayCsv) { 'Fecha,Tipo,Severidad,Detalle' | Set-Content -Path $script:EventosCsv -Encoding UTF8 }
            if ($hayLog) { Remove-Item $script:MonitorLog -Force -ErrorAction SilentlyContinue }
            Write-Host '  Historial borrado.' -ForegroundColor Green
        }

        '3' {
            $sello  = Get-Date -Format 'yyyyMMdd_HHmmss'
            $backup = Join-Path $script:LogDir ("respaldo_" + $sello)
            New-Item -ItemType Directory -Path $backup -Force | Out-Null
            if ($hayCsv) { Copy-Item $script:EventosCsv -Destination $backup -Force }
            if ($hayLog) { Copy-Item $script:MonitorLog -Destination $backup -Force }
            Write-Host ("  Respaldo guardado en: {0}" -f $backup) -ForegroundColor Green

            if ($hayCsv) { 'Fecha,Tipo,Severidad,Detalle' | Set-Content -Path $script:EventosCsv -Encoding UTF8 }
            if ($hayLog) { Remove-Item $script:MonitorLog -Force -ErrorAction SilentlyContinue }
            Write-Host '  Registros vaciados.' -ForegroundColor Green
            Write-Evento -Tipo 'MANTENIMIENTO' -Severidad 'ACCION' -Detalle ("Respaldo en {0} y vaciado de registros" -f $backup)
        }

        '0' { Write-Host '  Cancelado.' -ForegroundColor Yellow }
        default { Write-Host '  Opcion invalida.' -ForegroundColor Red }
    }
}

# ============================================================
# A) Informe para el administrador
# ============================================================

function Export-InformeAdmin {
    Write-Titulo 'INFORME PARA EL ADMINISTRADOR'
    Initialize-Carpetas
    $ruta = Join-Path $script:LogDir ('informe_admin_{0}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $o = New-Object System.Collections.Generic.List[string]

    function Add-Seccion { param([string]$Titulo, [scriptblock]$Bloque)
        $o.Add(''); $o.Add(('=== {0} ===' -f $Titulo))
        try { $txt = & $Bloque; foreach ($l in @($txt)) { $o.Add([string]$l) } }
        catch { $o.Add(('(no se pudo obtener: {0})' -f $_.Exception.Message)) }
    }

    $o.Add('INFORME DE CONEXION VPN')
    $o.Add(('Generado: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
    $o.Add(('Equipo  : {0}' -f $env:COMPUTERNAME))

    Add-Seccion 'Sistema' {
        $os = Get-CimInstance Win32_OperatingSystem
        ('{0} (version {1})' -f $os.Caption, $os.Version)
    }
    Add-Seccion 'Interfaz VPN elegida' {
        if ($script:VpnElegida) {
            $a = Get-NetAdapter -ifIndex $script:VpnElegida.ifIndex -ErrorAction SilentlyContinue
            if ($a) { '{0} | {1} | estado: {2}' -f $a.Name, $a.InterfaceDescription, $a.Status } else { 'La interfaz elegida ya no existe.' }
        } else { 'Ninguna elegida en esta sesion.' }
    }
    Add-Seccion 'Ruta por defecto (menor metrica efectiva gana)' {
        Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Select-Object ifIndex, @{N='Interfaz';E={ (Get-NetAdapter -ifIndex $_.ifIndex -ErrorAction SilentlyContinue).Name }},
                NextHop, RouteMetric, InterfaceMetric, @{N='Efectiva';E={ $_.RouteMetric + $_.InterfaceMetric }} |
            Sort-Object Efectiva | Format-Table -AutoSize | Out-String -Width 200
    }
    Add-Seccion 'DNS por interfaz' {
        Get-DnsClientServerAddress | Where-Object { $_.ServerAddresses } |
            Format-Table InterfaceAlias, AddressFamily, ServerAddresses -AutoSize | Out-String -Width 200
    }
    Add-Seccion 'OpenVPN' {
        $ov = Get-OpenVpnInfo -Refrescar
        if ($ov.Detectado) {
            ('Servicio: {0} -> {1}' -f $ov.ServicioNombre, $ov.ServicioEstado)
            ('Proceso : {0}' -f $(if ($ov.ProcesoActivo) { 'corriendo' } else { 'no esta corriendo' }))
            ('Log     : {0}' -f $(if ($ov.LogPath) { $ov.LogPath } else { 'no encontrado' }))
        } else { 'No se detecto OpenVPN en este equipo.' }
    }
    Add-Seccion 'Resumen de eventos del monitor' {
        if (Test-Path $script:EventosCsv) {
            $d = @(Import-Csv -Path $script:EventosCsv -Encoding UTF8)
            ('Eventos registrados: {0}' -f $d.Count)
            ('Caidas registradas : {0}' -f @($d | Where-Object { $_.Severidad -eq 'CAIDA' }).Count)
            $d | Group-Object Tipo | Sort-Object Count -Descending |
                Select-Object @{N='Tipo';E={$_.Name}}, @{N='Cantidad';E={$_.Count}} | Format-Table -AutoSize | Out-String
        } else { 'Todavia no hay registros (corre el monitor, opcion 6).' }
    }
    Add-Seccion 'Ultimas 30 caidas' {
        if (Test-Path $script:EventosCsv) {
            $c = @(Import-Csv -Path $script:EventosCsv -Encoding UTF8 | Where-Object { $_.Severidad -eq 'CAIDA' })
            if ($c.Count -gt 0) { $c | Select-Object -Last 30 | Format-Table Fecha, Tipo, Detalle -AutoSize -Wrap | Out-String -Width 200 }
            else { 'Ninguna caida registrada.' }
        } else { '(sin registros)' }
    }
    Add-Seccion 'Ultimos eventos de conexion en el log de OpenVPN' {
        $ov = Get-OpenVpnInfo
        if ($ov.LogPath -and (Test-Path -LiteralPath $ov.LogPath)) {
            $patron = 'Initialization Sequence Completed|Restart|RECONNECTING|Connection reset|TLS Error|AUTH_FAILED|SIGTERM|SIGUSR1|Inactivity timeout|EXITING'
            $r = @(Get-Content -LiteralPath $ov.LogPath -Tail 2000 -ErrorAction SilentlyContinue | Select-String -Pattern $patron)
            if ($r.Count -gt 0) { $r | Select-Object -Last 40 | ForEach-Object { $_.Line } } else { 'Sin eventos relevantes.' }
        } else { 'No se encontro el log de OpenVPN.' }
    }

    $o | Set-Content -Path $ruta -Encoding UTF8
    Write-Host ("Informe guardado en: {0}" -f $ruta) -ForegroundColor Green
    Write-Host 'Revisalo antes de enviarlo: incluye nombre del equipo, nombres de adaptadores, DNS y rutas.' -ForegroundColor Yellow
    Write-Evento -Tipo 'INFORME' -Severidad 'ACCION' -Detalle ("Informe para el administrador: {0}" -f (Split-Path $ruta -Leaf))
}

# ============================================================
# Menu
# ============================================================

# ============================================================
# MODO FORZADO  (todo junto y verificado)
# ============================================================

function Get-IfIndexRutaDefecto {
    Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty ifIndex -Unique
}

# ============================================================
# DNS LOCAL: devolverle a la interfaz de navegacion los DNS de casa
# ============================================================

function Get-DnsVpn {
    $l = @()
    if ($script:DnsPrim) { $l += $script:DnsPrim }
    if ($script:DnsSec)  { $l += $script:DnsSec }
    foreach ($x in @($DnsVpnExtra)) { if ($x -and ($l -notcontains $x)) { $l += $x } }
    return $l
}

function Get-DnsLocalInterfaz {
    # Devuelve los DNS que le corresponden a la placa SIN los de la VPN:
    # 1) los que entrego el DHCP (es lo que ipconfig /all muestra como propios)
    # 2) si no hay, la puerta de enlace (el router de casa hace de DNS)
    param([int]$IfIndex)

    $dnsVpn = @(Get-DnsVpn)
    $res = [PSCustomObject]@{ Dns = @(); Origen = $null }

    $ad = Get-NetAdapter -ifIndex $IfIndex -ErrorAction SilentlyContinue
    if ($ad -and $ad.InterfaceGuid) {
        $clave = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + $ad.InterfaceGuid
        try {
            $prop = Get-ItemProperty -Path $clave -ErrorAction Stop
            $crudo = [string]$prop.DhcpNameServer
            if ($crudo) {
                $lista = @(($crudo -split '[\s,]+') | Where-Object {
                    $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and ($dnsVpn -notcontains $_)
                })
                if ($lista.Count -gt 0) {
                    $res.Dns = $lista
                    $res.Origen = 'DHCP: lo que entrego el router'
                    return $res
                }
            }
        } catch { }
    }

    # v2: ya NO se usa la puerta de enlace como DNS. El cablemodem contesta ping
    # pero muchas veces no resuelve nombres: se pingaba y no se navegaba.
    return $res
}

function Test-ResuelveNombres {
    # Resuelve un nombre de internet (opcionalmente contra un servidor concreto).
    param([string]$Servidor, [string]$Nombre = 'www.google.com')
    try {
        if ($Servidor) {
            $r = Resolve-DnsName -Name $Nombre -Server $Servidor -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
        } else {
            Clear-DnsClientCache
            $r = Resolve-DnsName -Name $Nombre -Type A -DnsOnly -ErrorAction Stop
        }
        return [bool]$r
    } catch { return $false }
}

function Set-DnsProveedor {
    # Devuelve la placa al DNS del proveedor, en este orden, y VERIFICA cada paso:
    #   1) AUTOMATICO (DHCP)         -> lo correcto: toma lo que entrega el proveedor
    #   2) renovar DHCP si quedaron DNS de la VPN
    #   3) lista del DHCP fija       -> solo si el automatico no resuelve
    #   4) DNS publicos de respaldo  -> ultimo recurso, se avisa
    # Nunca usa la puerta de enlace como DNS. Devuelve $true si quedo resolviendo.
    param([int]$IfIndex, [string]$Alias = '')

    $dnsVpn = @(Get-DnsVpn)

    Set-DnsClientServerAddress -InterfaceIndex $IfIndex -ResetServerAddresses -ErrorAction SilentlyContinue
    Clear-DnsClientCache
    Start-Sleep -Milliseconds 800
    $act = @((Get-DnsClientServerAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)

    if (@($act | Where-Object { $dnsVpn -contains $_ }).Count -gt 0) {
        Write-Host '        El automatico sigue trayendo DNS de la VPN; renuevo el DHCP...' -ForegroundColor DarkYellow
        try { $null = ipconfig /renew "$Alias" 2>&1 } catch { }
        Start-Sleep -Seconds 3
        Clear-DnsClientCache
        $act = @((Get-DnsClientServerAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
    }

    $limpio = (@($act | Where-Object { $dnsVpn -contains $_ }).Count -eq 0)
    if ($limpio -and $act.Count -gt 0 -and (Test-ResuelveNombres -Servidor $act[0])) {
        Write-Host ("        [OK] Automatico (DHCP): {0} resuelve nombres" -f ($act -join ', ')) -ForegroundColor Green
        return $true
    }

    $loc = Get-DnsLocalInterfaz -IfIndex $IfIndex
    if ($loc.Dns.Count -gt 0 -and (Test-ResuelveNombres -Servidor $loc.Dns[0])) {
        Set-DnsClientServerAddress -InterfaceIndex $IfIndex -ServerAddresses $loc.Dns -ErrorAction SilentlyContinue
        Clear-DnsClientCache
        Write-Host ("        [OK] DNS del proveedor fijados: {0}" -f ($loc.Dns -join ', ')) -ForegroundColor Green
        return $true
    }

    $pub = @('1.1.1.1', '8.8.8.8')
    if (Test-ResuelveNombres -Servidor $pub[0]) {
        Set-DnsClientServerAddress -InterfaceIndex $IfIndex -ServerAddresses $pub -ErrorAction SilentlyContinue
        Clear-DnsClientCache
        Write-Host ("        [AVISO] El proveedor no resuelve nombres. Quedaron DNS publicos: {0}" -f ($pub -join ', ')) -ForegroundColor Yellow
        return $true
    }

    Set-DnsClientServerAddress -InterfaceIndex $IfIndex -ResetServerAddresses -ErrorAction SilentlyContinue
    Write-Host '        [FALLA] Ningun DNS resuelve nombres. Se deja en automatico. Revisa la conexion.' -ForegroundColor Red
    return $false
}

function Invoke-RestablecerTodo {
    # Opcion 4 unificada: deja la PC como si no hubieras usado las opciones 2, 3 y F.
    #   1) Deshace lo que guardo el script (VPN, metricas, IPv6) si hay estado guardado
    #   2) Placas de navegacion: borra los DNS fijos, metrica automatica, IPv6 prendido
    #   3) Vacia cache DNS, tabla ARP y cache NetBIOS
    #   4) Pone el DNS que entrega el proveedor por DHCP y verifica que resuelva
    #   5) Verifica que no quede ningun DNS de la VPN y borra el estado guardado
    Write-Titulo 'RESTABLECER TODO: DNS DEL PROVEEDOR, METRICAS, IPv6, CACHE DNS Y ARP'
    if (-not (Test-RequiereAdmin)) { return }

    $dnsVpn = @(Get-DnsVpn)
    Write-Host ("DNS de la VPN que no deben quedar en las placas locales: {0}" -f ($dnsVpn -join ', ')) -ForegroundColor Cyan

    $vpn = $null
    if ($script:VpnElegida) { $vpn = Get-NetAdapter -ifIndex $script:VpnElegida.ifIndex -ErrorAction SilentlyContinue }
    if (-not $vpn) { $vpn = Get-InterfazVpnAuto }
    if ($vpn) { Write-Host ("La VPN es '{0}': solo se toca lo que el script guardo de ella." -f $vpn.Name) -ForegroundColor DarkGray }
    Write-Host ''

    # ---- 1) deshacer lo guardado por 2 / 3 / F ----
    Write-Host '[1/5] Deshaciendo lo que aplicaron las opciones 2, 3 y F...' -ForegroundColor Cyan
    if (Test-Path $stateFile) {
        Invoke-Restaurar
    } else {
        Write-Host '      No hay estado guardado: se revisan igual las placas locales.' -ForegroundColor DarkGray
    }

    # ---- 2) placas de navegacion: DNS fijos fuera, metrica automatica, IPv6 prendido ----
    Write-Host ''
    Write-Host '[2/5] Placas de navegacion: borrando DNS fijos y metricas manuales...' -ForegroundColor Cyan
    $idx = @()
    foreach ($ix in @(Get-IfIndexRutaDefecto)) { if ($ix) { $idx += [int]$ix } }
    foreach ($s in @(Get-DnsInternosEnOtras -Vpn $vpn)) { $idx += [int]$s.IfIndex }
    $idx = @($idx | Sort-Object -Unique | Where-Object { -not ($vpn -and $_ -eq $vpn.ifIndex) })

    if ($idx.Count -eq 0) {
        Write-Host '      No encontre placas de navegacion activas (sin ruta por defecto).' -ForegroundColor Yellow
    }
    $placas = @()
    foreach ($ix in $idx) {
        $ad = Get-NetAdapter -ifIndex $ix -ErrorAction SilentlyContinue
        if (-not $ad) { continue }
        $placas += $ad
        $dnsAntes = @((Get-DnsClientServerAddress -InterfaceIndex $ix -ErrorAction SilentlyContinue).ServerAddresses)
        $miAntes  = Get-NetIPInterface -InterfaceIndex $ix -AddressFamily IPv4 -ErrorAction SilentlyContinue
        Write-Host ("      {0} (ifIndex {1})" -f $ad.Name, $ix) -ForegroundColor White
        Write-Host ("         DNS antes    : {0}" -f $(if ($dnsAntes.Count) { $dnsAntes -join ', ' } else { '(automatico)' })) -ForegroundColor DarkGray
        if ($miAntes) {
            Write-Host ("         Metrica antes: {0} (automatica: {1})" -f $miAntes.InterfaceMetric, $miAntes.AutomaticMetric) -ForegroundColor DarkGray
        }

        Set-DnsClientServerAddress -InterfaceIndex $ix -ResetServerAddresses -ErrorAction SilentlyContinue
        foreach ($fam in @('IPv4', 'IPv6')) {
            Set-NetIPInterface -InterfaceIndex $ix -AddressFamily $fam -AutomaticMetric Enabled -ErrorAction SilentlyContinue
        }

        # IPv6 apagado a mano o por la opcion F: se vuelve a prender
        try {
            $b = Get-NetAdapterBinding -Name $ad.Name -ComponentID 'ms_tcpip6' -ErrorAction Stop
            if (-not $b.Enabled) {
                Enable-NetAdapterBinding -Name $ad.Name -ComponentID 'ms_tcpip6' -Confirm:$false -ErrorAction Stop
                Write-Host '         IPv6 estaba apagado: vuelto a prender.' -ForegroundColor Green
            }
        } catch { }
        Write-Host '         DNS fijos borrados, metrica automatica.' -ForegroundColor Green
    }

    # ---- 3) cache DNS + tabla ARP + NetBIOS ----
    Write-Host ''
    Write-Host '[3/5] Vaciando cache DNS y tabla ARP...' -ForegroundColor Cyan
    $enLinux = $false
    try { if ($IsLinux) { $enLinux = $true } } catch { }
    if ($enLinux) { Invoke-LimpiarLinuxLocal } else { Invoke-LimpiarWindows }

    # ---- 4) DNS del proveedor por DHCP, con verificacion ----
    Write-Host ''
    Write-Host '[4/5] Poniendo el DNS que entrega el proveedor por DHCP...' -ForegroundColor Cyan
    $fallas = 0
    foreach ($ad in $placas) {
        Write-Host ("      {0}" -f $ad.Name) -ForegroundColor White
        $ok = Set-DnsProveedor -IfIndex $ad.ifIndex -Alias $ad.Name
        if (-not $ok) { $fallas++ }
    }
    if ($placas.Count -gt 0) { Clear-DnsClientCache }

    # ---- 5) verificacion final y limpieza del estado ----
    Write-Host ''
    Write-Host '[5/5] Verificacion final...' -ForegroundColor Cyan
    $quedan = @()
    foreach ($d in @(Get-DnsClientServerAddress -ErrorAction SilentlyContinue)) {
        if (-not $d.ServerAddresses) { continue }
        if ($vpn -and $d.InterfaceIndex -eq $vpn.ifIndex) { continue }
        foreach ($sv in $d.ServerAddresses) {
            if ($dnsVpn -contains $sv) { $quedan += ("{0}: {1}" -f $d.InterfaceAlias, $sv) }
        }
    }
    foreach ($ad in $placas) {
        $dnsAhora = @((Get-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
        $mi = Get-NetIPInterface -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        Write-Host ("      {0,-22} DNS: {1,-32} metrica auto: {2}" -f $ad.Name,
            $(if ($dnsAhora.Count) { $dnsAhora -join ', ' } else { '(automatico)' }),
            $(if ($mi) { $mi.AutomaticMetric } else { '?' })) -ForegroundColor Gray
    }

    if (Test-Path $stateFile) { Remove-Item $stateFile -Force -ErrorAction SilentlyContinue }
    $script:EstadoOtras = @()
    $script:IPv6Apagado = @()

    Write-Host ''
    if ($quedan.Count -eq 0 -and $fallas -eq 0) {
        Write-Host '  [OK] Todo restablecido: DNS del proveedor, metricas automaticas, IPv6 prendido, cache DNS y ARP vacios.' -ForegroundColor Green
    } else {
        if ($quedan.Count -gt 0) {
            Write-Host ("  [FALLA] Siguen DNS de la VPN en: {0}" -f ($quedan -join ' | ')) -ForegroundColor Red
            Write-Host '          Revisalo con ipconfig /all (o proba desconectar y volver a conectar la placa).' -ForegroundColor Yellow
        }
        if ($fallas -gt 0) {
            Write-Host ("  [AVISO] {0} placa(s) no resolvieron nombres con el DNS del proveedor. Revisa la conexion." -f $fallas) -ForegroundColor Yellow
        }
    }
    Write-Host '  Para confirmarlo a mano: ipconfig /all' -ForegroundColor DarkGray
    Write-Evento -Tipo 'RESTABLECER-TODO' -Severidad 'ACCION' -Detalle ("Placas: {0}. DNS de la VPN restantes: {1}. Sin resolver: {2}" -f (($placas | ForEach-Object { $_.Name }) -join ','), $quedan.Count, $fallas)
}

function Get-InterfazVpnDesdeLog {
    # El log de OpenVPN dice exactamente que placa abrio: "... device [NOMBRE] opened"
    $ov = Get-OpenVpnInfo
    if (-not $ov -or -not $ov.LogPath) { return $null }
    if (-not (Test-Path -LiteralPath $ov.LogPath)) { return $null }
    try {
        $lineas = Get-Content -LiteralPath $ov.LogPath -Tail 800 -ErrorAction Stop
        $texto  = [string]::Join("`n", $lineas)
        $ms = [regex]::Matches($texto, '(?i)(?:TAP-WIN32|tap-windows6|wintun|dco)\s+device\s+\[([^\]]+)\]\s+opened')
        if ($ms.Count -eq 0) { return $null }
        $nombre = $ms[$ms.Count - 1].Groups[1].Value
        $ad = Get-NetAdapter -Name $nombre -ErrorAction SilentlyContinue
        if ($ad -and $ad.Status -eq 'Up') { return $ad }
    } catch { }
    return $null
}

function Get-InterfazVpnAuto {
    $script:VpnOrigen = ''
    $delLog = Get-InterfazVpnDesdeLog
    if ($delLog) { $script:VpnOrigen = 'segun el log de OpenVPN (confiable)'; return $delLog }

    $cand = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.Status -eq 'Up' -and
        $_.InterfaceDescription -match 'TAP-Windows|TAP-Win32|Wintun|OpenVPN|WireGuard|Data Channel Offload'
    })
    if ($cand.Count -eq 1) { $script:VpnOrigen = 'por el nombre del adaptador (menos confiable)'; return $cand[0] }
    return $null
}

function Show-CandidatasVpn {
    Write-Host 'Interfaces con ruta por defecto:' -ForegroundColor Cyan
    foreach ($ix in (Get-IfIndexRutaDefecto)) {
        $ad  = Get-NetAdapter -ifIndex $ix -ErrorAction SilentlyContinue
        $rt  = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $ix -ErrorAction SilentlyContinue | Select-Object -First 1
        $dns = (Get-DnsClientServerAddress -InterfaceIndex $ix -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        Write-Host ("  ifIndex {0,-4} {1,-24} gw {2,-16} dns: {3}" -f `
            $ix, $(if($ad){$ad.Name}else{'?'}), $(if($rt){$rt.NextHop}else{'?'}),
            $(if($dns){($dns -join ', ')}else{'(automatico)'}))
    }
    Write-Host ''
}

function Get-DnsInternosEnOtras {
    param($Vpn)
    $lista = @()
    foreach ($d in (Get-DnsClientServerAddress -ErrorAction SilentlyContinue)) {
        if (-not $d.ServerAddresses) { continue }
        if ($Vpn -and $d.InterfaceIndex -eq $Vpn.ifIndex) { continue }
        $tiene = $false
        $dnsVpnL = @(Get-DnsVpn)
        foreach ($s in $d.ServerAddresses) {
            if ($dnsVpnL -contains $s) { $tiene = $true }
        }
        if ($tiene) {
            $lista += [PSCustomObject]@{
                IfIndex = $d.InterfaceIndex; Alias = $d.InterfaceAlias
                Familia = $d.AddressFamily; Dns = @($d.ServerAddresses)
            }
        }
    }
    return $lista
}

function Get-DnsIPv6EnOtras {
    param($Vpn)
    $lista = @()
    foreach ($d in (Get-DnsClientServerAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue)) {
        if (-not $d.ServerAddresses) { continue }
        if ($Vpn -and $d.InterfaceIndex -eq $Vpn.ifIndex) { continue }
        $ad = Get-NetAdapter -ifIndex $d.InterfaceIndex -ErrorAction SilentlyContinue
        if (-not $ad -or $ad.Status -ne 'Up') { continue }
        $lista += [PSCustomObject]@{
            IfIndex = $d.InterfaceIndex; Alias = $d.InterfaceAlias
            Nombre = $ad.Name; Dns = @($d.ServerAddresses)
        }
    }
    return $lista
}

function Add-EstadoOtra {
    param($IfIndex, $Alias, $Metrica, $AutoMetrica, $Dns)
    if (-not $script:EstadoOtras) { $script:EstadoOtras = @() }
    foreach ($e in $script:EstadoOtras) { if ($e.IfIndex -eq $IfIndex) { return } }
    $script:EstadoOtras += [PSCustomObject]@{
        IfIndex = $IfIndex; Alias = $Alias
        MetricaOriginal = $Metrica; AutoMetrica = $AutoMetrica
        DnsOriginal = $Dns
    }
}

function Save-EstadoCompleto {
    param($Vpn, $MetricaVpnOriginal, $DnsVpnOriginal)
    Initialize-Carpetas
    @{
        IfIndex         = $Vpn.ifIndex
        InterfaceAlias  = $Vpn.Name
        MetricaOriginal = $MetricaVpnOriginal
        DnsOriginal     = $DnsVpnOriginal
        Otras           = @($script:EstadoOtras)
        IPv6Apagado     = @($script:IPv6Apagado)
        Desde           = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    } | ConvertTo-Json -Depth 5 | Set-Content $stateFile
}

function Test-VpnEfectiva {
    param($Vpn)

    $todoOk = $true
    Write-Host ''
    Write-Host '--- VERIFICACION (esto es lo que importa) ---' -ForegroundColor Cyan

    # 1) por donde sale el trafico
    $g = Get-RutaGanadora
    if ($g -and $Vpn -and $g.ifIndex -eq $Vpn.ifIndex) {
        Write-Host ("  [OK]    El trafico sale por la VPN '{0}' (metrica efectiva {1})" -f `
            $Vpn.Name, ($g.RouteMetric + $g.InterfaceMetric)) -ForegroundColor Green
    } else {
        $nom = '?'
        if ($g) { $a = Get-NetAdapter -ifIndex $g.ifIndex -ErrorAction SilentlyContinue; if ($a) { $nom = $a.Name } }
        Write-Host ("  [FALLA] El trafico sigue saliendo por '{0}', no por la VPN." -f $nom) -ForegroundColor Red
        $todoOk = $false
    }

    # 2) DNS internos pegados en otras interfaces
    $sucias = Get-DnsInternosEnOtras -Vpn $Vpn
    if ($sucias.Count -eq 0) {
        Write-Host '  [OK]    Los DNS internos estan SOLO en la VPN.' -ForegroundColor Green
    } else {
        foreach ($s in $sucias) {
            Write-Host ("  [FALLA] '{0}' todavia tiene DNS internos ({1}) -> por ahi se cuelga nslookup." -f `
                $s.Alias, ($s.Dns -join ', ')) -ForegroundColor Red
        }
        $todoOk = $false
    }

    # 2b) fuga por IPv6
    $v6 = Get-DnsIPv6EnOtras -Vpn $Vpn
    if ($v6.Count -eq 0) {
        Write-Host '  [OK]    No hay DNS IPv6 de otras placas compitiendo.' -ForegroundColor Green
    } else {
        foreach ($f in $v6) {
            Write-Host ("  [aviso] '{0}' conserva DNS IPv6 ({1}). Windows los prefiere sobre IPv4." -f `
                $f.Nombre, ($f.Dns -join ', ')) -ForegroundColor Yellow
        }
    }

    # 3) resolucion real contra el DNS interno  (la prueba que manda)
    $resuelve = $false
    if ($script:NombrePrueba -and $script:DnsPrim) {
        $res = $null
        try {
            $res = Resolve-DnsName -Name $script:NombrePrueba -Server $script:DnsPrim `
                    -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
        } catch { $res = $null }
        if ($res) {
            $resuelve = $true
            $ips = @($res | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress)
            Write-Host ("  [OK]    {0} resuelve a {1} usando {2}" -f `
                $script:NombrePrueba, ($ips -join ', '), $script:DnsPrim) -ForegroundColor Green
        } else {
            Write-Host ("  [FALLA] {0} no resuelve contra {1}. Esto es lo mismo que te pasaba con nslookup." -f `
                $script:NombrePrueba, $script:DnsPrim) -ForegroundColor Red
            $todoOk = $false
        }
    }

    # 4) alcance del DNS  (solo informativo: hay DNS que no aceptan TCP/53)
    if ($script:DnsPrim -and -not $resuelve) {
        $alcanza = $false
        try {
            $alcanza = Test-NetConnection -ComputerName $script:DnsPrim -Port 53 `
                        -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        } catch { $alcanza = $false }
        if ($alcanza) {
            Write-Host ("  [aviso] {0} si contesta en TCP/53, pero no resolvio el nombre." -f $script:DnsPrim) -ForegroundColor Yellow
            Write-Host '          El camino esta bien; revisa el nombre de prueba o el servidor.' -ForegroundColor DarkYellow
        } else {
            Write-Host ("  [aviso] {0} no contesta en TCP/53 tampoco: no hay camino hasta el DNS." -f $script:DnsPrim) -ForegroundColor Yellow
        }
    }

    Write-Host ''
    if ($todoOk) {
        Write-Host '  RESULTADO: la salida esta forzada por la VPN y el DNS responde.' -ForegroundColor Green
        Write-Evento -Tipo 'VERIFICAR' -Severidad 'INFO' -Detalle 'Verificacion OK: ruta VPN + DNS responde'
    } else {
        Write-Host '  RESULTADO: quedo algo sin resolver. Mira las lineas [FALLA] de arriba.' -ForegroundColor Red
        Write-Evento -Tipo 'VERIFICAR' -Severidad 'AVISO' -Detalle 'Verificacion con fallas'
    }
    return $todoOk
}

function Invoke-ModoForzado {
    Write-Titulo 'MODO FORZADO: TODO EL TRAFICO Y EL DNS POR LA VPN'
    if (-not (Test-RequiereAdmin)) { return }
    if (-not (Confirm-DnsConfigurados)) { return }

    $script:EstadoOtras = @()
    $script:IPv6Apagado = @()

    # --- elegir la VPN ---
    $vpn = $null
    if ($script:VpnElegida) {
        $vpn = Get-NetAdapter -ifIndex $script:VpnElegida.ifIndex -ErrorAction SilentlyContinue
    }
    if (-not $vpn) {
        $auto = Get-InterfazVpnAuto
        if ($auto) {
            Write-Host ("Interfaz VPN detectada sola: '{0}'" -f $auto.Name) -ForegroundColor Green
            Write-Host ("  {0}" -f $auto.InterfaceDescription) -ForegroundColor DarkGray
            if ($script:VpnOrigen) { Write-Host ("  Detectada {0}" -f $script:VpnOrigen) -ForegroundColor DarkGray }
            Write-Host ''
            $r = Read-Host 'ENTER para usar esta, o C para elegir otra'
            if ($r -match '^[cC]') { $auto = $null } else { $vpn = $auto; $script:VpnElegida = $auto }
        }
    }
    if (-not $vpn) {
        Write-Host 'No pude detectar la VPN sola. Mira cual tiene el gateway de la VPN:' -ForegroundColor Yellow
        Write-Host ''
        Show-CandidatasVpn
        $vpn = Select-InterfazVpn -Forzar
    }
    if (-not $vpn) { Write-Host 'Cancelado, no se toco nada.' -ForegroundColor Yellow; return }

    Write-Host ''
    Write-Host ("Trabajando sobre '{0}' (ifIndex {1})" -f $vpn.Name, $vpn.ifIndex) -ForegroundColor Cyan
    Write-Host ''

    $metVpnOrig = (Get-NetIPInterface -InterfaceIndex $vpn.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
    $dnsVpnOrig = (Get-DnsClientServerAddress -InterfaceIndex $vpn.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses

    # --- PASO 1: sacar los DNS internos de las demas interfaces ---
    Write-Host 'PASO 1  Sacando los DNS internos de las otras interfaces...' -ForegroundColor Cyan
    $sucias = Get-DnsInternosEnOtras -Vpn $vpn
    if ($sucias.Count -eq 0) {
        Write-Host '        Ninguna otra interfaz los tenia. Nada que limpiar.' -ForegroundColor DarkGray
    } else {
        foreach ($s in $sucias) {
            $ii = Get-NetIPInterface -InterfaceIndex $s.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            Add-EstadoOtra -IfIndex $s.IfIndex -Alias $s.Alias `
                -Metrica $(if($ii){$ii.InterfaceMetric}else{$null}) `
                -AutoMetrica $(if($ii){[string]$ii.AutomaticMetric}else{'Enabled'}) `
                -Dns $s.Dns
            Write-Host ("        '{0}' tenia {1}: paso a automatico (DHCP) y verifico..." -f $s.Alias, ($s.Dns -join ', ')) -ForegroundColor Yellow
            $null = Set-DnsProveedor -IfIndex $s.IfIndex -Alias $s.Alias
            Write-Evento -Tipo 'LIMPIAR-DNS' -Severidad 'ACCION' -Detalle ("DNS internos quitados de {0}, vuelto a automatico" -f $s.Alias)
        }
    }

    # --- PASO 2: DNS internos solo en la VPN ---
    Write-Host ''
    Write-Host 'PASO 2  Poniendo los DNS internos en la VPN...' -ForegroundColor Cyan
    $dnsList = @($script:DnsPrim)
    if ($script:DnsSec) { $dnsList += $script:DnsSec }
    Set-DnsClientServerAddress -InterfaceIndex $vpn.ifIndex -ServerAddresses $dnsList
    Write-Host ("        '{0}' -> {1}" -f $vpn.Name, ($dnsList -join ', ')) -ForegroundColor Green

    # --- PASO 3: metricas ---
    Write-Host ''
    Write-Host 'PASO 3  Acomodando las metricas para que gane la VPN...' -ForegroundColor Cyan
    Set-NetIPInterface -InterfaceIndex $vpn.ifIndex -AddressFamily IPv4 -InterfaceMetric 1 -ErrorAction SilentlyContinue
    Set-NetIPInterface -InterfaceIndex $vpn.ifIndex -AddressFamily IPv6 -InterfaceMetric 1 -ErrorAction SilentlyContinue
    Write-Host ("        '{0}' -> metrica 1 (IPv4 e IPv6)" -f $vpn.Name) -ForegroundColor Green

    $todasDefecto = @(Get-IfIndexRutaDefecto) + @(
        Get-NetRoute -DestinationPrefix '::/0' -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty ifIndex -Unique )
    foreach ($ix in ($todasDefecto | Select-Object -Unique)) {
        if ($ix -eq $vpn.ifIndex) { continue }
        $ii = Get-NetIPInterface -InterfaceIndex $ix -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if (-not $ii) { continue }
        $ad = Get-NetAdapter -ifIndex $ix -ErrorAction SilentlyContinue
        $nom = if ($ad) { $ad.Name } else { "ifIndex $ix" }
        $dnsAct = (Get-DnsClientServerAddress -InterfaceIndex $ix -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        Add-EstadoOtra -IfIndex $ix -Alias $nom -Metrica $ii.InterfaceMetric `
            -AutoMetrica ([string]$ii.AutomaticMetric) -Dns $dnsAct
        Set-NetIPInterface -InterfaceIndex $ix -AddressFamily IPv4 -InterfaceMetric 70 -ErrorAction SilentlyContinue
        Set-NetIPInterface -InterfaceIndex $ix -AddressFamily IPv6 -InterfaceMetric 70 -ErrorAction SilentlyContinue
        Write-Host ("        '{0}' -> metrica 70 (antes {1}), IPv4 e IPv6" -f $nom, $ii.InterfaceMetric) -ForegroundColor Yellow
    }

    # --- PASO 3b: la fuga por IPv6 ---
    Write-Host ''
    Write-Host 'PASO 3b Revisando la fuga de DNS por IPv6...' -ForegroundColor Cyan
    $fugaV6 = Get-DnsIPv6EnOtras -Vpn $vpn
    if ($fugaV6.Count -eq 0) {
        Write-Host '        Sin DNS IPv6 en otras interfaces. Nada que hacer.' -ForegroundColor DarkGray
    } else {
        foreach ($f in $fugaV6) {
            Write-Host ("        '{0}' tiene DNS IPv6 del proveedor: {1}" -f $f.Nombre, ($f.Dns -join ', ')) -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Host '        Windows prefiere IPv6 antes que IPv4. Si el tunel es solo IPv4,' -ForegroundColor DarkYellow
        Write-Host '        los nombres se pueden seguir resolviendo por el proveedor de casa' -ForegroundColor DarkYellow
        Write-Host '        aunque el resto del trafico salga por la VPN.' -ForegroundColor DarkYellow
        Write-Host ''
        Write-Host '        Se puede apagar IPv6 en esas placas mientras dure la sesion.' -ForegroundColor Cyan
        Write-Host '        OJO: la placa se reinicia un segundo y se corta la conexion un instante.' -ForegroundColor Red
        Write-Host '        Se vuelve a prender sola con la opcion 4 (Restablecer).' -ForegroundColor DarkGray
        $rv6 = Read-Host '        Apagar IPv6 en esas placas? (S/N)'
        if ($rv6 -match '^[sS]') {
            foreach ($f in $fugaV6) {
                try {
                    $b = Get-NetAdapterBinding -Name $f.Nombre -ComponentID 'ms_tcpip6' -ErrorAction Stop
                    if ($b.Enabled) {
                        Disable-NetAdapterBinding -Name $f.Nombre -ComponentID 'ms_tcpip6' -Confirm:$false -ErrorAction Stop
                        $script:IPv6Apagado += $f.Nombre
                        Write-Host ("        IPv6 apagado en '{0}'." -f $f.Nombre) -ForegroundColor Green
                        Write-Evento -Tipo 'IPV6-OFF' -Severidad 'ACCION' -Detalle ("IPv6 desactivado en {0}" -f $f.Nombre)
                    }
                } catch {
                    Write-Host ("        No se pudo apagar IPv6 en '{0}': {1}" -f $f.Nombre, $_.Exception.Message) -ForegroundColor Red
                }
            }
            Start-Sleep -Seconds 3
        } else {
            Write-Host '        Se deja IPv6 como esta. Si algo no resuelve, este es el sospechoso.' -ForegroundColor DarkGray
        }
    }
    Write-Evento -Tipo 'MODO-FORZADO' -Severidad 'ACCION' -Detalle ("VPN {0} priorizada, otras a 70" -f $vpn.Name)

    # --- PASO 4: limpiar caches ---
    Write-Host ''
    Write-Host 'PASO 4  Limpiando cache DNS y tabla ARP...' -ForegroundColor Cyan
    Clear-DnsClientCache
    try { Get-NetNeighbor -AddressFamily IPv4 -State Reachable,Stale -ErrorAction SilentlyContinue |
            Remove-NetNeighbor -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    Write-Host '        Listo.' -ForegroundColor Green

    Save-EstadoCompleto -Vpn $vpn -MetricaVpnOriginal $metVpnOrig -DnsVpnOriginal $dnsVpnOrig

    Start-Sleep -Seconds 2
    $ok = Test-VpnEfectiva -Vpn $vpn

    if (-not $ok) {
        Write-Host ''
        Write-Host 'Si sigue fallando, lo mas probable en orden:' -ForegroundColor Yellow
        Write-Host '  1. La interfaz elegida no es la VPN  -> opcion I y fijate el gateway' -ForegroundColor DarkYellow
        Write-Host '  2. El tunel se cayo                  -> opcion 1, mira si OpenVPN sigue Running' -ForegroundColor DarkYellow
        Write-Host '  3. El DNS interno cambio             -> opcion 5' -ForegroundColor DarkYellow
    }
}

function Show-Menu {
    Clear-Host
    Write-Host ''
    Write-Host '  ############################################################' -ForegroundColor DarkCyan
    Write-Host '  #         DNS + RUTEO + MONITOREO DE VPN                   #' -ForegroundColor Cyan
    Write-Host '  ############################################################' -ForegroundColor DarkCyan
    Write-Host ''

    if ($script:EsAdmin) { Write-Host '  Permisos: Administrador' -ForegroundColor Green }
    else { Write-Host '  Permisos: LIMITADOS - solo diagnostico y monitoreo' -ForegroundColor Red }

    $dnsTxt = $script:DnsPrim
    if ($script:DnsSec) { $dnsTxt = "$($script:DnsPrim) / $($script:DnsSec)" }
    Write-Host ("  DNS a aplicar: {0}" -f $dnsTxt) -ForegroundColor DarkGray
    Write-Host ("  Logs         : {0}" -f $script:LogDir) -ForegroundColor DarkGray

    if ($script:VpnElegida) {
        Write-Host ("  Interfaz VPN : {0}" -f $script:VpnElegida.Name) -ForegroundColor DarkGray
    }
    if (Test-Path $stateFile) {
        Write-Host '  ESTADO: hay DNS forzados sin restablecer' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '   --- Red ---' -ForegroundColor DarkCyan
    Write-Host '   F) MODO FORZADO: todo por la VPN, limpia y verifica' -ForegroundColor Green
    Write-Host '      (es la que sirve cuando nslookup da timeout)' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '   1) Ver estado actual de la red      (no modifica nada)'
    Write-Host '   2) Forzar los DNS de la VPN'
    Write-Host '   3) Priorizar la VPN (metrica a 1)'
    Write-Host '   4) RESTABLECER TODO: DNS del proveedor, metricas, IPv6, cache DNS y ARP' -ForegroundColor Green
    Write-Host '   5) Cambiar los DNS a aplicar'
    Write-Host '   I) Cambiar la interfaz VPN elegida' -ForegroundColor Green
    Write-Host ''
    Write-Host '   --- Monitoreo ---' -ForegroundColor DarkCyan
    Write-Host '   6) Monitorear la VPN en vivo'
    Write-Host '   7) Historial de caidas'
    Write-Host '   8) Ver log de OpenVPN'
    Write-Host '   9) Borrar registros'
    Write-Host '   A) Informe para el administrador (un archivo con todo lo necesario)' -ForegroundColor Green
    Write-Host ''
    Write-Host '   0) Salir' -ForegroundColor DarkGray
    Write-Host ''
}

# ============================================================
# Arranque
# ============================================================

$script:EsAdmin = Test-EsAdmin
Initialize-Carpetas
Import-Config

if ($Restore) {
    if (-not $script:EsAdmin) {
        Write-Host 'Para restablecer hace falta correr como Administrador.' -ForegroundColor Red
        Wait-Enter
        exit 1
    }
    Invoke-RestablecerTodo
    Wait-Enter
    exit 0
}

if (-not $script:EsAdmin) {
    Write-Host ''
    Write-Host 'AVISO: no estas corriendo como Administrador.' -ForegroundColor Red
    Write-Host 'Vas a poder ver el estado y monitorear, pero no aplicar cambios.' -ForegroundColor Yellow
    Write-Host ''
    Read-Host 'ENTER para continuar igual' | Out-Null
}

$salir = $false
while (-not $salir) {

    Show-Menu
    $opcion = Read-Host '  Elegi una opcion'

    switch ($opcion.Trim()) {

        'F' { try { Invoke-ModoForzado }  catch { Show-ErrorAccion $_ }; Wait-Enter }
        'V' { try { Test-VpnEfectiva -Vpn (Select-InterfazVpn) } catch { Show-ErrorAccion $_ }; Wait-Enter }
        '1' { try { Show-EstadoRed }        catch { Show-ErrorAccion $_ }; Wait-Enter }
        '2' { try { Invoke-ForzarDns }      catch { Show-ErrorAccion $_ }; Wait-Enter }
        '3' { try { Invoke-PriorizarVpn }   catch { Show-ErrorAccion $_ }; Wait-Enter }
        '4' { try { Invoke-RestablecerTodo } catch { Show-ErrorAccion $_ }; Wait-Enter }
        '5' { try { Set-DnsPersonalizados } catch { Show-ErrorAccion $_ }; Wait-Enter }
        '6' { try { Start-MonitorVpn }      catch { Show-ErrorAccion $_ }; Wait-Enter }
        '7' { try { Show-HistorialCaidas }  catch { Show-ErrorAccion $_ }; Wait-Enter }
        '8' { try { Show-LogOpenVpn }       catch { Show-ErrorAccion $_ }; Wait-Enter }
        '9' { try { Clear-Registros }       catch { Show-ErrorAccion $_ }; Wait-Enter }
        'I' { try { Invoke-CambiarInterfaz } catch { Show-ErrorAccion $_ }; Wait-Enter }
        'A' { try { Export-InformeAdmin }   catch { Show-ErrorAccion $_ }; Wait-Enter }

        '0' {
            if (Test-Path $stateFile) {
                Write-Host ''
                Write-Host 'Todavia tenes los DNS forzados aplicados.' -ForegroundColor Yellow
                $r = Read-Host 'Ya terminaste de usar la VPN? ENTER = restablecer antes de salir | N = dejar como esta'
                if ([string]::IsNullOrWhiteSpace($r) -or $r -match '^[sSyY]') {
                    if ($script:EsAdmin) { Invoke-RestablecerTodo }
                    else { Write-Host 'Sin permisos. Corre como admin y usa la opcion 4.' -ForegroundColor Red }
                } else {
                    Write-Host ''
                    Write-Host 'Quedan activos. Para restablecer despues:' -ForegroundColor Yellow
                    Write-Host '  .\VPN-Prioridad.ps1 -Restore   (o VPN-Prioridad-TodoEnUno.bat -Restore)' -ForegroundColor Yellow
                }
                Write-Host ''
                Read-Host 'ENTER para salir' | Out-Null
            }
            $salir = $true
        }

        default {
            Write-Host ''
            Write-Host '  Opcion invalida.' -ForegroundColor Red
            Start-Sleep -Milliseconds 900
        }
    }
}

Write-Host ''
Write-Host 'Listo. Hasta la proxima.' -ForegroundColor Cyan
Write-Host ''
