<#
.SYNOPSIS
    Pruebas de balanceo del API Gateway (Fase 3): dos replicas del servicio dominio.

.DESCRIPTION
    Levanta tests/compose.stubs.yaml con "--scale dominio=2" (dos contenedores del MISMO
    servicio) en un proyecto Compose propio (por defecto gwbal), y comprueba:
      1. que existen dos contenedores reales y que cada respuesta indica de cual vino
         (el Hostname que informa traefik/whoami es el ID corto del contenedor Docker);
      2. que GET y POST llegan a ambas replicas (al menos 20% cada una, sin exigir 50/50);
      3. que si una replica se detiene, la restante atiende y, una vez estabilizado el DNS,
         TODAS las peticiones son atendidas por ella (los errores transitorios se registran);
      4. que el gateway detecta la recuperacion de la replica;
      5. que con ambas replicas detenidas responde 502 JSON (con un posible 504 transitorio
         mientras se actualiza el DNS) y se recupera cuando vuelven;
      6. que front, IA y /health no se ven afectados, que los logs no contienen datos
         personales ni identifican replicas, y que solo el gateway publica el puerto 8080.

    No usa un limite rigido de latencia: registra las latencias (incluida la maxima).
    No modifica nginx/default.conf, tests/compose.stubs.yaml ni tests/smoke.ps1.
    No detiene ni elimina el proyecto gwtest: si ocupa el puerto 8080, avisa y termina.

    LIMITACION CONOCIDA (documentada, no se corrige): Nginx no reintenta en otra replica
    una peticion no idempotente (POST) que YA fue enviada a una replica que luego muere
    (no se usa "non_idempotent"). Esta prueba cubre replicas que caen ENTRE peticiones;
    en ese caso Nginx si reintenta, incluso un POST, porque aun no se habia enviado.

    Requiere Docker Desktop en ejecucion. Compatible con Windows PowerShell 5.1 y PowerShell 7.
    El archivo esta escrito solo con caracteres ASCII a proposito.

.PARAMETER Requests
    Peticiones GET por rafaga de reparto (las rafagas POST usan la mitad). Minimo 20.

.PARAMETER Keep
    No destruye el entorno al terminar.

.PARAMETER OmitirAmbasCaidas
    Omite la seccion 6 (ambas replicas detenidas).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tests\balanceo.ps1
#>
[CmdletBinding()]
param(
    [string]$ComposeFile = '',
    [string]$Project = 'gwbal',
    [string]$BaseUrl = 'http://127.0.0.1:8080',
    [int]$Requests = 60,
    [switch]$Keep,
    [switch]$OmitirAmbasCaidas
)

# --- inicio resolucion ComposeFile
# $PSScriptRoot puede venir vacio (por ejemplo al ejecutar una seleccion del script o al pegarlo
# en la consola), por eso no se usa como valor por defecto del parametro. Se prueban varias
# ubicaciones y se usa la primera donde exista compose.stubs.yaml.
if ([string]::IsNullOrEmpty($ComposeFile)) {
    $searchDirs = @()
    if (-not [string]::IsNullOrEmpty($PSScriptRoot)) { $searchDirs += $PSScriptRoot }
    if ($MyInvocation.MyCommand.Path) { $searchDirs += (Split-Path -Parent $MyInvocation.MyCommand.Path) }
    $cwd = (Get-Location).Path
    $searchDirs += (Join-Path $cwd 'tests')
    $searchDirs += $cwd
    foreach ($d in $searchDirs) {
        $candidate = Join-Path $d 'compose.stubs.yaml'
        if (Test-Path $candidate) { $ComposeFile = $candidate; break }
    }
    if ([string]::IsNullOrEmpty($ComposeFile)) {
        Write-Host 'No se encontro compose.stubs.yaml. Ejecuta el script desde la raiz del repositorio o usa -ComposeFile.' -ForegroundColor Red
        exit 2
    }
}
# --- fin resolucion ComposeFile

# Con 'Continue' los avisos que docker escribe por stderr no abortan el script en PS 5.1.
$ErrorActionPreference = 'Continue'

if ($Requests -lt 20) { $Requests = 20 }
$MinGet = [int][math]::Ceiling($Requests / 5.0)             # 20% de las peticiones GET
$PostCount = [int][math]::Floor($Requests / 2)
$MinPost = [int][math]::Ceiling($PostCount / 5.0)           # 20% de las peticiones POST

$script:Passed = 0
$script:Failed = 0
$script:Failures = @()
$script:AllLat = @()
$script:Fase = ''

# Datos "personales" de mentira que se envian en las URL para comprobar que no quedan en los logs.
$Marker1 = 'ana.prueba@example.cl'
$Marker2 = '11.111.111-1'

# ---------------------------------------------------------------- utilidades

function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) {
        $script:Passed++
        Write-Host ("  [OK]    " + $Name) -ForegroundColor Green
    } else {
        $script:Failed++
        $script:Failures += $Name
        Write-Host ("  [FALLA] " + $Name) -ForegroundColor Red
        if ($Detail) { Write-Host ("          " + $Detail) -ForegroundColor Yellow }
    }
}

function Section {
    param([string]$Title)
    $script:Fase = $Title
    Write-Host ""
    Write-Host ("== " + $Title) -ForegroundColor Cyan
}

# Datos que se registran pero no aprueban ni reprueban nada.
function Info {
    param([string]$Text)
    Write-Host ("  [DATO]  " + $Text) -ForegroundColor DarkCyan
}

function Dk {
    param([string[]]$DockerArgs)
    $out = & docker $DockerArgs 2>&1
    $script:DkExit = $LASTEXITCODE
    @($out | ForEach-Object { "$_" })
}

function Dc {
    param([string[]]$ComposeArgs)
    Dk (@('compose', '-f', $ComposeFile, '-p', $Project) + $ComposeArgs)
}

function Get-Cid {
    param([string]$Svc)
    Dc @('ps', '-q', $Svc) | Where-Object { $_ -match '^[0-9a-f]{12,64}$' } | Select-Object -First 1
}

function Get-Health {
    param([string]$Cid)
    Dk @('inspect', '--format', '{{.State.Health.Status}}', $Cid) | Select-Object -First 1
}

function Wait-Until {
    param([scriptblock]$Condition, [int]$TimeoutSec = 30, [int]$EveryMs = 500)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds $EveryMs
    }
    return $false
}

function Test-PortBusy {
    param([int]$Port)
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $tcp.BeginConnect('127.0.0.1', $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(1500) -and $tcp.Connected) { return $true }
        return $false
    } catch {
        return $false
    } finally {
        $tcp.Close()
    }
}

Add-Type -AssemblyName System.Net.Http
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $false
$handler.UseProxy = $false              # un proxy del sistema no debe interceptar el acceso local
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(40)

function Send-Gw {
    param(
        [string]$Method = 'GET',
        [string]$Path = '/',
        [string]$Body = $null,
        [string]$ContentType = 'application/json'
    )
    $req = New-Object System.Net.Http.HttpRequestMessage
    $req.Method = New-Object System.Net.Http.HttpMethod($Method)
    $req.RequestUri = New-Object System.Uri(($BaseUrl + $Path))
    if (-not [string]::IsNullOrEmpty($Body)) {
        $req.Content = New-Object System.Net.Http.StringContent($Body, [System.Text.Encoding]::UTF8, $ContentType)
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $sw.Stop()
        $h = @{}
        foreach ($x in $resp.Headers) { $h[$x.Key.ToLower()] = ($x.Value -join ',') }
        foreach ($x in $resp.Content.Headers) { $h[$x.Key.ToLower()] = ($x.Value -join ',') }
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = $text; Headers = $h; Ms = $sw.ElapsedMilliseconds; Error = '' }
    } catch {
        $sw.Stop()
        return [pscustomobject]@{ Status = 0; Body = ''; Headers = @{}; Ms = $sw.ElapsedMilliseconds; Error = $_.Exception.Message }
    }
}

function Get-Json {
    param([string]$Text)
    try { return ($Text | ConvertFrom-Json) } catch { return $null }
}

function Get-Lines {
    param($Response)
    @($Response.Body -split "\r?\n")
}

function Has-Line {
    param($Response, [string]$Line)
    (Get-Lines $Response) -contains $Line
}

function Is-Json {
    param($Response)
    [bool]($Response.Headers['content-type'] -like 'application/json*')
}

function Brief {
    param($Response)
    $t = ($Response.Body -replace "\s+", ' ')
    if ($t.Length -gt 120) { $t = $t.Substring(0, 120) }
    ("estado=" + $Response.Status + " " + $Response.Error + " cuerpo=" + $t)
}

# El Hostname que informa traefik/whoami es el hostname del contenedor (ID corto de 12 caracteres).
function Get-ReplicaHost {
    param($Response)
    $m = [regex]::Match($Response.Body, '(?m)^Hostname:\s*(\S+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# Una peticion a dominio. Registra estado, replica que la atendio y latencia.
function Probe {
    param([string]$Method = 'GET', [int]$N = 0, [string]$Extra = '')
    $path = '/api/dominio/balanceo?n=' + $N + $Extra
    $body = ''
    if ($Method -eq 'POST') { $body = '{"n":' + $N + '}' }
    $r = Send-Gw $Method $path -Body $body
    $h = ''
    if ($r.Status -eq 200) { $h = Get-ReplicaHost $r }
    $script:AllLat += [pscustomobject]@{ Fase = $script:Fase; Ms = $r.Ms }
    return [pscustomobject]@{ Metodo = $Method; Status = $r.Status; Host = $h; Ms = $r.Ms; Error = $r.Error; T = 0 }
}

function Invoke-Burst {
    param([int]$Count, [string]$Method = 'GET', [string]$Extra = '')
    $out = @()
    for ($i = 1; $i -le $Count; $i++) { $out += Probe $Method $i $Extra }
    return $out
}

# Peticiones espaciadas durante unos segundos (GET y POST alternados), para cubrir el tiempo
# que tarda el DNS en actualizarse. Cada elemento guarda en T los ms transcurridos.
function Invoke-Window {
    param([int]$Seconds = 8, [int]$PauseMs = 150, [string]$Extra = '')
    $out = @()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $i = 0
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        $i++
        $m = 'GET'
        if (($i % 3) -eq 0) { $m = 'POST' }
        $p = Probe $m $i $Extra
        $p.T = [int]$sw.Elapsed.TotalMilliseconds
        $out += $p
        Start-Sleep -Milliseconds $PauseMs
    }
    return $out
}

function Get-Summary {
    param($Items)
    $list = @($Items)
    $lat = @($list | ForEach-Object { $_.Ms } | Sort-Object)
    $max = 0
    $med = 0
    if ($lat.Count -gt 0) {
        $max = $lat[$lat.Count - 1]
        $med = $lat[[int][math]::Floor(($lat.Count - 1) / 2)]
    }
    $byStatus = @{}
    $byHost = @{}
    foreach ($x in $list) {
        $k = [string]$x.Status
        if ($byStatus.ContainsKey($k)) { $byStatus[$k]++ } else { $byStatus[$k] = 1 }
        if ($x.Host) {
            if ($byHost.ContainsKey($x.Host)) { $byHost[$x.Host]++ } else { $byHost[$x.Host] = 1 }
        }
    }
    return [pscustomobject]@{
        Total = $list.Count
        Ok = @($list | Where-Object { $_.Status -eq 200 }).Count
        ByStatus = $byStatus
        ByHost = $byHost
        MaxMs = $max
        MedMs = $med
        Slow = @($list | Where-Object { $_.Ms -gt 1000 }).Count
    }
}

function Format-Counts {
    param($Table)
    if ($Table.Count -eq 0) { return '(ninguna)' }
    (($Table.Keys | Sort-Object | ForEach-Object { $_ + '=' + $Table[$_] }) -join ', ')
}

function Show-Data {
    param([string]$Label, $Sum)
    Info ($Label + ': ' + $Sum.Total + ' peticiones | estados {' + (Format-Counts $Sum.ByStatus) + '} | replicas {' + (Format-Counts $Sum.ByHost) + '} | latencia max=' + $Sum.MaxMs + ' ms, mediana=' + $Sum.MedMs + ' ms, lentas(>1 s)=' + $Sum.Slow)
}

# Espera hasta ver, en las respuestas, TODOS los hostnames indicados. Devuelve ms o -1.
function Wait-Seen {
    param([string[]]$Hosts, [int]$TimeoutSec = 60)
    $seen = @{}
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $p = Probe 'GET' 0
        if (($p.Status -eq 200) -and $p.Host) { $seen[$p.Host] = 1 }
        $missing = @($Hosts | Where-Object { -not $seen.ContainsKey($_) })
        if ($missing.Count -eq 0) { return [int]$sw.Elapsed.TotalMilliseconds }
        Start-Sleep -Milliseconds 200
    }
    return -1
}

# Espera hasta que N peticiones SEGUIDAS sean 200 y atendidas por la replica indicada.
function Wait-Stable {
    param([string]$Survivor, [int]$Consecutive = 20, [int]$TimeoutSec = 60)
    $run = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $p = Probe 'GET' 0
        if (($p.Status -eq 200) -and ($p.Host -eq $Survivor)) { $run++ } else { $run = 0 }
        if ($run -ge $Consecutive) { return [int]$sw.Elapsed.TotalMilliseconds }
        Start-Sleep -Milliseconds 100
    }
    return -1
}

# Resume una lista de estados como "504 x3 -> 502 x10".
function Compress-Seq {
    param($Values)
    $parts = @()
    $prev = $null
    $n = 0
    foreach ($v in @($Values)) {
        if (($null -ne $prev) -and ($v -eq $prev)) { $n++ }
        else {
            if ($null -ne $prev) { $parts += ([string]$prev + ' x' + $n) }
            $prev = $v
            $n = 1
        }
    }
    if ($null -ne $prev) { $parts += ([string]$prev + ' x' + $n) }
    ($parts -join ' -> ')
}

# Reparto: todo 200, solo hostnames de los dos contenedores reales y al menos MinEach por replica.
function Check-Distribution {
    param([string]$Label, $Items, [int]$MinEach)
    $s = Get-Summary $Items
    Show-Data $Label $s
    $unknown = @(@($Items) | Where-Object { ($_.Status -eq 200) -and (-not ($script:Reps -contains $_.Host)) }).Count
    Check ($Label + ': todas las respuestas son 200') ($s.Ok -eq $s.Total) ('estados: ' + (Format-Counts $s.ByStatus))
    Check ($Label + ': cada respuesta indica uno de los dos contenedores reales') (($unknown -eq 0) -and ($s.Ok -gt 0)) ('respuestas con hostname desconocido: ' + $unknown)
    foreach ($rep in $script:Reps) {
        $n = 0
        if ($s.ByHost.ContainsKey($rep)) { $n = $s.ByHost[$rep] }
        Check ($Label + ': la replica ' + $rep + ' recibe al menos ' + $MinEach + ' (20%)') ($n -ge $MinEach) ('recibio ' + $n + ' de ' + $s.Total)
    }
}

# Front, IA y /health del gateway no deben verse afectados por lo que ocurra con dominio.
function Check-Others {
    param([string]$Context)
    $r = Send-Gw 'GET' '/health'
    $j = Get-Json $r.Body
    Check ($Context + ': GET /health -> 200 JSON del gateway') (($r.Status -eq 200) -and (Is-Json $r) -and ($j.service -eq 'gateway')) (Brief $r)
    $r = Send-Gw 'GET' '/'
    Check ($Context + ': GET / -> 200 atendido por front') (($r.Status -eq 200) -and (Has-Line $r 'Name: front')) (Brief $r)
    $r = Send-Gw 'GET' '/api/ia/'
    Check ($Context + ': GET /api/ia/ -> 200 atendido por ia') (($r.Status -eq 200) -and (Has-Line $r 'Name: ia')) (Brief $r)
}

# ---------------------------------------------------------------- preparacion

Section 'Preparacion'
$null = Dk @('compose', 'version')
if ($DkExit -ne 0) {
    Write-Host 'No se pudo ejecutar "docker compose". Abre Docker Desktop y espera a que diga Engine running.' -ForegroundColor Red
    exit 2
}
if (-not (Test-Path $ComposeFile)) {
    Write-Host ("No existe " + $ComposeFile) -ForegroundColor Red
    exit 2
}
Write-Host ("  Limpiando restos de ejecuciones anteriores del proyecto " + $Project + " (solo ese proyecto)...")
$null = Dc @('down', '-v', '--remove-orphans')

# El puerto 8080 debe estar libre. NO se detiene nada ajeno a este proyecto: solo se avisa.
$port = ([System.Uri]$BaseUrl).Port
$gwtestIds = @()
$o = Dk @('ps', '-q', '--filter', 'label=com.docker.compose.project=gwtest')
if ($DkExit -eq 0) { $gwtestIds = @($o | Where-Object { $_ -match '^[0-9a-f]{12,64}$' }) }
$publishers = @()
$o = Dk @('ps', '--filter', ('publish=' + $port), '--format', '{{.Names}}')
if ($DkExit -eq 0) { $publishers = @($o | Where-Object { $_ -match '\S' }) }

if ($gwtestIds.Count -gt 0) {
    Write-Host ""
    Write-Host "AVISO: el entorno de pruebas de F2 (proyecto gwtest) esta en ejecucion y ocupa el puerto $port." -ForegroundColor Yellow
    Write-Host "Este script NO lo detiene automaticamente. Detenlo tu con este comando y vuelve a ejecutar:" -ForegroundColor Yellow
    Write-Host "    docker compose -f tests/compose.stubs.yaml -p gwtest down -v" -ForegroundColor White
    exit 2
}
if ($publishers.Count -gt 0) {
    Write-Host ""
    Write-Host "AVISO: otro contenedor ya publica el puerto $port : $($publishers -join ', ')" -ForegroundColor Yellow
    Write-Host "Este script NO lo detiene automaticamente. Detenlo tu (docker stop <nombre>) y vuelve a ejecutar." -ForegroundColor Yellow
    exit 2
}
if (Test-PortBusy $port) {
    Write-Host ""
    Write-Host "AVISO: algo que no es un contenedor de Docker esta usando el puerto $port en este computador." -ForegroundColor Yellow
    Write-Host "Cierra ese programa y vuelve a ejecutar." -ForegroundColor Yellow
    exit 2
}

try {

    # ------------------------------------------------------------ 1. dos replicas del mismo servicio
    Section '1. Dos replicas del mismo servicio dominio'
    Write-Host "  Construyendo y levantando gateway, front, ia y dominio (2 replicas con --scale)..."
    $out = Dc @('up', '-d', '--build', '--scale', 'dominio=2', 'gateway', 'front', 'dominio', 'ia')
    if ($DkExit -ne 0) {
        Write-Host "  Fallo 'docker compose up':" -ForegroundColor Red
        $out | ForEach-Object { Write-Host ("    " + $_) }
        exit 2
    }
    $gw = Get-Cid 'gateway'
    $healthy = Wait-Until { (Get-Health $gw) -eq 'healthy' } 90 1000
    Check 'El contenedor del gateway llega a healthy' $healthy ("estado: " + (Get-Health $gw))
    if (-not $healthy) {
        Write-Host "  Logs del gateway:" -ForegroundColor Yellow
        Dk @('logs', $gw) | ForEach-Object { Write-Host ("    " + $_) }
        exit 1
    }

    $ids = @(Dc @('ps', '-q', 'dominio') | Where-Object { $_ -match '^[0-9a-f]{12,64}$' })
    Check 'El servicio dominio tiene exactamente 2 contenedores' ($ids.Count -eq 2) ("contenedores: " + $ids.Count)
    if ($ids.Count -ne 2) { exit 1 }
    $idA = $ids[0]
    $idB = $ids[1]
    $repA = $idA.Substring(0, 12)
    $repB = $idB.Substring(0, 12)
    $script:Reps = @($repA, $repB)
    Check 'Los dos contenedores son distintos (IDs cortos distintos)' ($repA -ne $repB) ("A=" + $repA + " B=" + $repB)
    $hnA = (Dk @('inspect', '--format', '{{.Config.Hostname}}', $idA) | Select-Object -First 1)
    $hnB = (Dk @('inspect', '--format', '{{.Config.Hostname}}', $idB) | Select-Object -First 1)
    Check 'El hostname de cada contenedor Docker es su ID corto de 12 caracteres' (($hnA -eq $repA) -and ($hnB -eq $repB)) ("hostnames: " + $hnA + ", " + $hnB)
    Info ("replica A = " + $repA + " | replica B = " + $repB)

    # ------------------------------------------------------------ 2. identificacion
    Section '2. Cada respuesta identifica la replica que la atendio'
    $r = Send-Gw 'GET' '/api/dominio/balanceo?n=0'
    $h = Get-ReplicaHost $r
    Check 'GET /api/dominio/... -> 200 atendido por el servicio dominio' (($r.Status -eq 200) -and (Has-Line $r 'Name: dominio')) (Brief $r)
    Check 'La respuesta trae un Hostname que es el de uno de los dos contenedores' ($script:Reps -contains $h) ("Hostname recibido: '" + $h + "'")
    Check 'El prefijo se quita y la query se conserva (la replica recibe GET /balanceo?n=0)' (Has-Line $r 'GET /balanceo?n=0 HTTP/1.1') (Brief $r)

    # ------------------------------------------------------------ 3. reparto
    Section '3. Reparto entre las dos replicas'
    $ms = Wait-Seen $script:Reps 40
    Check 'El gateway llega a usar ambas replicas (en menos de 40 s)' ($ms -ge 0) 'no se vieron ambos hostnames'
    if ($ms -ge 0) { Info ("tiempo hasta ver ambas replicas: " + $ms + " ms") }

    $getItems = @(Invoke-Burst $Requests 'GET')
    Check-Distribution ('GET x' + $Requests) $getItems $MinGet
    $postItems = @(Invoke-Burst $PostCount 'POST')
    Check-Distribution ('POST x' + $PostCount) $postItems $MinPost
    Check-Others 'Con 2 replicas'

    # ------------------------------------------------------------ 4. falla de una replica
    Section '4. Una replica se detiene'
    Write-Host '  [NOTA] Limitacion conocida: un POST ya enviado a una replica que muere no se reintenta' -ForegroundColor DarkYellow
    Write-Host '         (Nginx no reintenta metodos no idempotentes y no se usa "non_idempotent").' -ForegroundColor DarkYellow
    $victim = $repA
    $survivor = $repB
    Write-Host ("  Deteniendo la replica A (" + $victim + ") con docker stop...")
    $null = Dk @('stop', '-t', '1', $idA)
    Check 'docker stop detuvo la replica A' ($DkExit -eq 0) ("codigo de salida: " + $DkExit)

    Write-Host '  Enviando peticiones espaciadas durante 8 s para cubrir la actualizacion del DNS...'
    $win = @(Invoke-Window 8 150 ('&correo=' + $Marker1))
    $winSum = Get-Summary $win
    Show-Data 'Ventana de transicion' $winSum
    $errs = @($win | Where-Object { $_.Status -ne 200 })
    if ($errs.Count -eq 0) {
        Info 'Errores transitorios durante la transicion: ninguno'
    } else {
        $lastT = ($errs | ForEach-Object { $_.T } | Measure-Object -Maximum).Maximum
        Info ('Errores transitorios durante la transicion: ' + $errs.Count + ' (el ultimo a los ' + $lastT + ' ms de la ventana)')
        $errs | Select-Object -First 8 | ForEach-Object { Info ('  t=' + $_.T + ' ms  ' + $_.Metodo + '  estado=' + $_.Status + '  ' + $_.Ms + ' ms  ' + $_.Error) }
    }
    $fromDead = @($win | Where-Object { ($_.Status -eq 200) -and ($_.Host -eq $victim) }).Count
    Check 'Ninguna respuesta 200 proviene de la replica detenida' ($fromDead -eq 0) ("respuestas de la replica detenida: " + $fromDead)
    Check 'Durante la transicion la replica restante atendio peticiones' ((@($win | Where-Object { ($_.Status -eq 200) -and ($_.Host -eq $survivor) }).Count) -gt 0) ('estados: ' + (Format-Counts $winSum.ByStatus))

    $stableMs = Wait-Stable $survivor 20 60
    Check 'El sistema se estabiliza: 20 peticiones seguidas 200, todas de la replica restante (en menos de 60 s)' ($stableMs -ge 0) 'no se alcanzo una racha de 20 respuestas 200 de la replica restante'
    if ($stableMs -ge 0) { Info ("tiempo hasta estabilizarse: " + $stableMs + " ms") }

    $stGet = @(Invoke-Burst 40 'GET')
    $stPost = @(Invoke-Burst 20 'POST')
    $stAll = @($stGet) + @($stPost)
    $stSum = Get-Summary $stAll
    Show-Data 'Tras estabilizarse' $stSum
    $others = @($stAll | Where-Object { ($_.Status -eq 200) -and ($_.Host -ne $survivor) }).Count
    Check 'Estabilizado: las 60 peticiones (GET y POST) son 200' ($stSum.Ok -eq $stSum.Total) ('estados: ' + (Format-Counts $stSum.ByStatus))
    Check 'Estabilizado: todas las peticiones las atiende la replica restante' (($others -eq 0) -and ($stSum.Ok -gt 0)) ("respuestas de otra replica: " + $others)
    Check-Others 'Con 1 replica detenida'

    # ------------------------------------------------------------ 5. recuperacion
    Section '5. La replica detenida se recupera'
    Write-Host ("  Iniciando de nuevo la replica A (" + $victim + ") con docker start...")
    $null = Dk @('start', $idA)
    Check 'docker start inicio la replica A' ($DkExit -eq 0) ("codigo de salida: " + $DkExit)
    $recMs = Wait-Seen $script:Reps 60
    Check 'El gateway vuelve a enviar trafico a la replica recuperada (en menos de 60 s)' ($recMs -ge 0) 'la replica A no volvio a aparecer en las respuestas'
    if ($recMs -ge 0) { Info ("tiempo hasta volver a ver ambas replicas: " + $recMs + " ms") }
    $recGet = @(Invoke-Burst $Requests 'GET')
    Check-Distribution ('Recuperada, GET x' + $Requests) $recGet $MinGet
    $recPost = @(Invoke-Burst $PostCount 'POST')
    Check-Distribution ('Recuperada, POST x' + $PostCount) $recPost $MinPost

    # ------------------------------------------------------------ 6. ambas replicas caidas
    if ($OmitirAmbasCaidas) {
        Section '6. Ambas replicas detenidas'
        Write-Host '  (omitida)' -ForegroundColor DarkYellow
    } else {
        Section '6. Ambas replicas detenidas y su recuperacion'
        Write-Host '  Deteniendo las dos replicas...'
        $null = Dk @('stop', '-t', '1', $idA, $idB)
        Check 'docker stop detuvo las dos replicas' ($DkExit -eq 0) ("codigo de salida: " + $DkExit)

        # Mientras el DNS se actualiza puede haber un 504 transitorio (conexion agotada hacia una
        # IP que ya no existe) antes del 502 definitivo (el nombre ya no resuelve).
        $seq = @()
        $stable502 = 0
        $last = $null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 60) {
            $last = Send-Gw 'GET' ('/api/dominio/balanceo?correo=' + $Marker1 + '&rut=' + $Marker2)
            $script:AllLat += [pscustomobject]@{ Fase = $script:Fase; Ms = $last.Ms }
            $seq += $last.Status
            if ($last.Status -eq 502) { $stable502++ } else { $stable502 = 0 }
            if ($stable502 -ge 10) { break }
            Start-Sleep -Milliseconds 300
        }
        Info ('Secuencia de estados observada: ' + (Compress-Seq $seq))
        $unexpected = @($seq | Where-Object { ($_ -ne 502) -and ($_ -ne 504) }).Count
        $j = Get-Json $last.Body
        Check 'Con ambas detenidas el gateway termina respondiendo 502 de forma estable (10 seguidas)' ($stable502 -ge 10) ('secuencia: ' + (Compress-Seq $seq))
        Check 'El 502 es JSON servicio_no_disponible / dominio' (($last.Status -eq 502) -and (Is-Json $last) -and ($j.error -eq 'servicio_no_disponible') -and ($j.servicio -eq 'dominio')) (Brief $last)
        Check 'La transicion solo contiene 504 (transitorio) y 502' ($unexpected -eq 0) ('secuencia: ' + (Compress-Seq $seq))
        Check-Others 'Con ambas replicas detenidas'

        Write-Host '  Iniciando de nuevo las dos replicas...'
        $null = Dk @('start', $idA, $idB)
        Check 'docker start inicio las dos replicas' ($DkExit -eq 0) ("codigo de salida: " + $DkExit)
        $up = Wait-Until { (Send-Gw 'GET' '/api/dominio/balanceo?n=0').Status -eq 200 } 60 500
        Check 'dominio vuelve a responder 200 (en menos de 60 s)' $up
        $both = Wait-Seen $script:Reps 60
        Check 'El gateway vuelve a usar ambas replicas (en menos de 60 s)' ($both -ge 0) 'no se vieron ambos hostnames'
        $finGet = @(Invoke-Burst $Requests 'GET')
        Check-Distribution ('Tras recuperar ambas, GET x' + $Requests) $finGet $MinGet
    }

    # ------------------------------------------------------------ 7. logs
    Section '7. Logs sin datos personales ni identificacion de replicas'
    $logs = Dk @('logs', $gw)
    $acc = @($logs | Where-Object { $_ -match '^metodo=' })
    $fmt = '^metodo=[A-Z]+ estado=\d{3} bytes=\d+ duracion=[0-9.]+ upstream=[-0-9., :]+ ruta=(front|dominio|ia|gateway)$'
    $badFmt = @($acc | Where-Object { $_ -notmatch $fmt })
    $retried = @($acc | Where-Object { $_ -match 'upstream=[0-9.]+, [0-9.]+' }).Count
    Info ('lineas de acceso=' + $acc.Count + ' | con reintento en otra replica (dos tiempos de upstream)=' + $retried)
    Check 'Log de acceso: hay registros' ($acc.Count -gt 0) ("lineas=" + $acc.Count)
    Check 'Log de acceso: todas las lineas (incluidos los reintentos) tienen el formato esperado' ($badFmt.Count -eq 0) (($badFmt | Select-Object -First 2) -join ' | ')

    $leakPattern = 'example\.cl|ana\.prueba|11\.111|correo=|rut=|/api|/health|\?'
    $leakAcc = @($acc | Where-Object { ($_ -match $leakPattern) -or ($_ -match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b') })
    Check 'Log de acceso: sin IP, sin rutas, sin parametros ni datos personales' ($leakAcc.Count -eq 0) (($leakAcc | Select-Object -First 2) -join ' | ')

    $errLines = @($logs | Where-Object { $_ -match '\[(error|crit|alert|emerg)\]' })
    $leakErr = @($errLines | Where-Object { $_ -match 'client:|request:|upstream: ' -or $_ -match $leakPattern })
    Check 'Log de errores: sin la peticion, sin IP y sin datos personales' ($leakErr.Count -eq 0) (($leakErr | Select-Object -First 2) -join ' | ')

    $allText = ($logs -join "`n")
    Check 'Ningun log contiene los datos personales de prueba' (($allText -notmatch 'ana\.prueba') -and ($allText -notmatch '11\.111\.111')) ''
    Check 'Ningun log identifica a una replica (ni su ID corto ni su ID completo)' (($allText -notmatch $repA) -and ($allText -notmatch $repB) -and ($allText -notmatch $idA) -and ($allText -notmatch $idB)) ''

    # ------------------------------------------------------------ 8. puertos
    Section '8. Solo el gateway publica un puerto'
    $ps = Dk @('ps', '--filter', ('label=com.docker.compose.project=' + $Project), '--format', '{{.Names}}|{{.Ports}}')
    $rows = @($ps | Where-Object { $_ -match '\|' })
    $published = @($rows | Where-Object { ($_ -split '\|', 2)[1] -match '->' })
    $hostPorts = @($published | ForEach-Object { [regex]::Matches(($_ -split '\|', 2)[1], ':(\d+)->') | ForEach-Object { $_.Groups[1].Value } } | Select-Object -Unique)
    Check 'Hay 5 contenedores (gateway, front, ia y 2 de dominio)' ($rows.Count -eq 5) ("contenedores=" + $rows.Count)
    Check 'Solo un contenedor publica puertos y es el gateway' (($published.Count -eq 1) -and ($published[0] -match 'gateway')) (($rows | ForEach-Object { $_ }) -join ' ; ')
    Check 'El unico puerto publicado hacia el host es el 8080' (($hostPorts.Count -eq 1) -and ($hostPorts[0] -eq '8080')) ("puertos=" + ($hostPorts -join ','))

    # ------------------------------------------------------------ latencias
    Section 'Latencias registradas (no aprueban ni reprueban)'
    foreach ($g in @($script:AllLat | Group-Object Fase)) {
        $mx = ($g.Group | ForEach-Object { $_.Ms } | Measure-Object -Maximum).Maximum
        $sl = @($g.Group | Where-Object { $_.Ms -gt 1000 }).Count
        Info ($g.Name + ' -> ' + $g.Count + ' peticiones, latencia max=' + $mx + ' ms, lentas(>1 s)=' + $sl)
    }
    $gmax = ($script:AllLat | ForEach-Object { $_.Ms } | Measure-Object -Maximum).Maximum
    Info ('Latencia maxima global: ' + $gmax + ' ms')

}
finally {
    if ($Keep) {
        Write-Host ""
        Write-Host ("Entorno conservado. Para destruirlo: docker compose -f tests/compose.stubs.yaml -p " + $Project + " down -v") -ForegroundColor DarkYellow
    } else {
        Write-Host ""
        Write-Host "Destruyendo el entorno de pruebas..."
        $null = Dc @('down', '-v', '--remove-orphans')
    }
}

# ---------------------------------------------------------------- resumen
Write-Host ""
Write-Host "================ RESUMEN ================" -ForegroundColor Cyan
Write-Host ("  Correctas: " + $script:Passed) -ForegroundColor Green
if ($script:Failed -gt 0) {
    Write-Host ("  Fallidas : " + $script:Failed) -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host ("    - " + $_) -ForegroundColor Red }
    exit 1
}
Write-Host "  Fallidas : 0" -ForegroundColor Green
exit 0
