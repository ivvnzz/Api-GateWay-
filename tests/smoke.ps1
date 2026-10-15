<#
.SYNOPSIS
    Pruebas de humo del API Gateway (Fase 2) contra servicios simulados.

.DESCRIPTION
    Levanta tests/compose.stubs.yaml (gateway real + tres servicios traefik/whoami),
    ejecuta las pruebas y, al terminar, destruye el entorno.
    Comprueba rutas, prefijos, metodos, cuerpos, errores, caida de servicios,
    arranque sin un servicio, ausencia de datos personales en los logs y que
    solo el gateway publique un puerto.

    Requiere Docker Desktop en ejecucion. Compatible con Windows PowerShell 5.1
    y con PowerShell 7. El archivo esta escrito solo con caracteres ASCII a proposito.

.PARAMETER Keep
    No destruye el entorno al terminar (sirve para inspeccionarlo a mano).

.PARAMETER OmitirLentas
    Omite la prueba de tiempo de espera (504), que demora unos 11 segundos.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tests\smoke.ps1
#>
[CmdletBinding()]
param(
    [string]$ComposeFile = '',
    [string]$Project = 'gwtest',
    [string]$BaseUrl = 'http://127.0.0.1:8080',
    [switch]$Keep,
    [switch]$OmitirLentas
)

# Buscar el compose una vez terminado param(...). Esto evita evaluar Join-Path
# con PSScriptRoot vacio durante la inicializacion de parametros en PS 5.1.
if ([string]::IsNullOrEmpty($ComposeFile)) {
    $dirs = @()
    if (-not [string]::IsNullOrEmpty($PSScriptRoot)) { $dirs += $PSScriptRoot }
    if ($MyInvocation.MyCommand.Path) {
        $dirs += (Split-Path -Parent $MyInvocation.MyCommand.Path)
    }
    $cwd = (Get-Location).Path
    $dirs += (Join-Path $cwd 'tests')
    $dirs += $cwd
    foreach ($dir in $dirs) {
        $candidate = Join-Path $dir 'compose.stubs.yaml'
        if (Test-Path $candidate) {
            $ComposeFile = (Resolve-Path $candidate).Path
            break
        }
    }
    if ([string]::IsNullOrEmpty($ComposeFile)) {
        Write-Host 'No se encontro compose.stubs.yaml. Ejecuta desde la raiz del repositorio o usa -ComposeFile.' -ForegroundColor Red
        exit 2
    }
}

# Con 'Continue' los avisos que docker escribe por stderr no abortan el script en PS 5.1.
$ErrorActionPreference = 'Continue'

$script:Passed = 0
$script:Failed = 0
$script:Failures = @()

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

function Section { param([string]$Title) Write-Host ""; Write-Host ("== " + $Title) -ForegroundColor Cyan }

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

Add-Type -AssemblyName System.Net.Http
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $false     # para poder ver las redirecciones 308
$handler.UseProxy = $false              # un proxy del sistema no debe interceptar el acceso local
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(40)

function Send-Gw {
    param(
        [string]$Method = 'GET',
        [string]$Path = '/',
        [string]$Body = $null,
        [string]$ContentType = 'application/json',
        [hashtable]$Headers = @{}
    )
    $req = New-Object System.Net.Http.HttpRequestMessage
    $req.Method = New-Object System.Net.Http.HttpMethod($Method)
    $req.RequestUri = New-Object System.Uri(($BaseUrl + $Path))
    foreach ($k in $Headers.Keys) { [void]$req.Headers.TryAddWithoutValidation($k, [string]$Headers[$k]) }
    if (-not [string]::IsNullOrEmpty($Body)) {
        $req.Content = New-Object System.Net.Http.StringContent($Body, [System.Text.Encoding]::UTF8, $ContentType)
    }
    $sentLen = ''
    if ($req.Content) { $sentLen = [string]$req.Content.Headers.ContentLength }
    $sentChunked = [bool]$req.Headers.TransferEncodingChunked
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $sw.Stop()
        $h = @{}
        foreach ($x in $resp.Headers) { $h[$x.Key.ToLower()] = ($x.Value -join ',') }
        foreach ($x in $resp.Content.Headers) { $h[$x.Key.ToLower()] = ($x.Value -join ',') }
        $loc = ''
        if ($resp.Headers.Location) { $loc = $resp.Headers.Location.OriginalString }
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = $text; Headers = $h; Location = $loc; Ms = $sw.ElapsedMilliseconds; Error = ''; SentLength = $sentLen; SentChunked = $sentChunked }
    } catch {
        $sw.Stop()
        return [pscustomobject]@{ Status = 0; Body = ''; Headers = @{}; Location = ''; Ms = $sw.ElapsedMilliseconds; Error = $_.Exception.Message; SentLength = $sentLen; SentChunked = $sentChunked }
    }
}

function Get-Json {
    param([string]$Text)
    try { return ($Text | ConvertFrom-Json) } catch { return $null }
}

# Las lineas del cuerpo de traefik/whoami (Name:, GET /ruta HTTP/1.1, cabeceras...).
function Get-Lines {
    param($Response)
    @($Response.Body -split "\r?\n")
}

function Has-Line {
    param($Response, [string]$Line)
    (Get-Lines $Response) -contains $Line
}

function Has-Prefix {
    param($Response, [string]$Prefix)
    @((Get-Lines $Response) | Where-Object { $_.StartsWith($Prefix) }).Count -gt 0
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

# Una sola respuesta 200 puede ser transitoria justo despues de docker start.
# Exigir varias respuestas consecutivas evita continuar durante el refresco DNS.
# Si no se estabiliza antes del timeout, las comprobaciones siguientes fallaran.
function Wait-StableRoute {
    param([string]$Path, [int]$Status = 200, [int]$Consecutive = 5, [int]$TimeoutSec = 60)
    $streak = 0
    $last = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $response = Send-Gw 'GET' $Path
        $last = $response.Status
        if ($response.Status -eq $Status) { $streak++ } else { $streak = 0 }
        if ($streak -ge $Consecutive) { return $true }
        Start-Sleep -Milliseconds 750
    }
    Write-Host ("  [AVISO] Ruta " + $Path + " no se estabilizo en " + $TimeoutSec + " s. Esperado=" + $Status + "; ultimo=" + $last) -ForegroundColor Yellow
    return $false
}

# Mostrar detalles solo si falla una solicitud con cuerpo grande.
function Show-Diag {
    param($Response)
    $t = ($Response.Body -replace "\s+", ' ')
    if ($t.Length -gt 160) { $t = $t.Substring(0, 160) }
    Write-Host ("          enviado : Content-Length=" + $Response.SentLength + " chunked=" + $Response.SentChunked) -ForegroundColor Yellow
    Write-Host ("          recibido: estado=" + $Response.Status + " ms=" + $Response.Ms + " error='" + $Response.Error + "'") -ForegroundColor Yellow
    Write-Host ("          cuerpo  : " + $t) -ForegroundColor Yellow
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
Write-Host "  Limpiando restos de ejecuciones anteriores..."
$null = Dc @('down', '-v', '--remove-orphans')

try {

    # ------------------------------------------------------------ 1. arranque sin ia
    Section '1. El gateway arranca aunque el servicio ia no exista'
    Write-Host "  Construyendo y levantando gateway, front y dominio (sin ia)..."
    $out = Dc @('up', '-d', '--build', 'gateway', 'front', 'dominio')
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
    $startedAt = (Dk @('inspect', '--format', '{{.State.StartedAt}}', $gw) | Select-Object -First 1)

    $r = Send-Gw 'GET' '/health'
    $j = Get-Json $r.Body
    Check 'GET /health -> 200, JSON {"status":"ok","service":"gateway"}' (($r.Status -eq 200) -and (Is-Json $r) -and ($j.status -eq 'ok') -and ($j.service -eq 'gateway')) (Brief $r)

    $r = Send-Gw 'GET' '/'
    Check 'GET / -> 200 atendido por front' (($r.Status -eq 200) -and (Has-Line $r 'Name: front')) (Brief $r)

    $r = Send-Gw 'GET' '/api/dominio/'
    Check 'GET /api/dominio/ -> 200 atendido por dominio' (($r.Status -eq 200) -and (Has-Line $r 'Name: dominio')) (Brief $r)

    $r = Send-Gw 'GET' '/api/ia/prueba'
    $j = Get-Json $r.Body
    Check 'GET /api/ia/... sin ia -> 502 JSON servicio_no_disponible / ia' (($r.Status -eq 502) -and (Is-Json $r) -and ($j.error -eq 'servicio_no_disponible') -and ($j.servicio -eq 'ia')) (Brief $r)

    # ------------------------------------------------------------ 2. ia aparece despues
    Section '2. El servicio ia aparece despues, sin reiniciar el gateway'
    $null = Dc @('up', '-d', 'ia')
    $iaUp = Wait-Until { (Send-Gw 'GET' '/api/ia/').Status -eq 200 } 40 1000
    Check 'GET /api/ia/ pasa a 200 solo (en menos de 40 s)' $iaUp
    $startedAt2 = (Dk @('inspect', '--format', '{{.State.StartedAt}}', $gw) | Select-Object -First 1)
    $restarts = (Dk @('inspect', '--format', '{{.RestartCount}}', $gw) | Select-Object -First 1)
    Check 'El contenedor del gateway no se reinicio' (($startedAt -eq $startedAt2) -and ($restarts -eq '0')) ("inicio antes=" + $startedAt + " despues=" + $startedAt2 + " reinicios=" + $restarts)

    # ------------------------------------------------------------ 3. rutas y prefijos
    Section '3. Rutas, prefijos y parametros de consulta'
    $r = Send-Gw 'GET' '/'
    Check '/ llega al front como GET /' (Has-Line $r 'GET / HTTP/1.1') (Brief $r)

    $r = Send-Gw 'GET' '/pagina?x=1'
    Check '/pagina?x=1 llega al front sin cambios' ((Has-Line $r 'Name: front') -and (Has-Line $r 'GET /pagina?x=1 HTTP/1.1')) (Brief $r)

    $r = Send-Gw 'GET' '/api/dominio/prueba/ruta?x=1&y=dos'
    Check '/api/dominio/prueba/ruta?x=1&y=dos -> dominio recibe GET /prueba/ruta?x=1&y=dos (sin prefijo, con query)' ((Has-Line $r 'Name: dominio') -and (Has-Line $r 'GET /prueba/ruta?x=1&y=dos HTTP/1.1')) (Brief $r)

    $r = Send-Gw 'GET' '/api/ia/prueba?m=1'
    Check '/api/ia/prueba?m=1 -> ia recibe GET /prueba?m=1 (sin prefijo, con query)' ((Has-Line $r 'Name: ia') -and (Has-Line $r 'GET /prueba?m=1 HTTP/1.1')) (Brief $r)

    $r = Send-Gw 'GET' '/api/dominio/'
    Check '/api/dominio/ -> dominio recibe GET /' (Has-Line $r 'GET / HTTP/1.1') (Brief $r)

    $r = Send-Gw 'GET' '/api/dominio/a%20b?q=a%26b'
    Check 'Caracteres codificados (%20 en la ruta, %26 en la query) llegan intactos' (Has-Line $r 'GET /a%20b?q=a%26b HTTP/1.1') (Brief $r)

    $r = Send-Gw 'GET' '/api/dominio/x' -Headers @{ 'X-Forwarded-For' = '6.6.6.6' }
    Check 'El servicio recibe X-Forwarded-Proto y una X-Forwarded-For propia (la falsificada por el cliente se descarta)' ((Has-Prefix $r 'X-Forwarded-Proto: http') -and (Has-Prefix $r 'X-Forwarded-For: ') -and -not (Has-Line $r 'X-Forwarded-For: 6.6.6.6')) (Brief $r)

    # ------------------------------------------------------------ 4. metodos y cuerpos
    Section '4. Metodos HTTP y cuerpos de la peticion'
    foreach ($m in @('GET', 'POST', 'PUT', 'PATCH', 'DELETE')) {
        $body = ''
        if (@('POST', 'PUT', 'PATCH') -contains $m) { $body = '{"k":1}' }
        $r = Send-Gw $m '/api/dominio/metodo' -Body $body
        Check ("dominio recibe el metodo " + $m) (Has-Line $r ($m + ' /metodo HTTP/1.1')) (Brief $r)
    }

    $json = '{"usuario":"u1","k":[1,2,3]}'
    $r = Send-Gw 'POST' '/api/ia/prueba' -Body $json
    Check 'POST /api/ia/... entrega a ia el cuerpo JSON intacto y su Content-Type' (($r.Body.Contains($json)) -and (Has-Prefix $r 'Content-Type: application/json')) (Brief $r)

    # La prueba anterior revisaba el eco de whoami, que no es un indicador fiable
    # de un cuerpo grande. /health decodifica un numero JSON del cuerpo recibido.
    # Si 200 esta al FINAL de 900000 bytes, el servidor debe leer hasta ese punto.
    $null = Send-Gw 'POST' '/api/dominio/health' -Body '503'
    $beforeBig = Send-Gw 'GET' '/api/dominio/health'
    $big = (' ' * 899997) + '200'
    $r = Send-Gw 'POST' '/api/dominio/health' -Body $big
    $afterBig = Send-Gw 'GET' '/api/dominio/health'
    $bigOk = (($beforeBig.Status -eq 503) -and ($r.Status -eq 200) -and ($afterBig.Status -eq 200) -and ($r.SentLength -eq '900000'))
    Check 'Un cuerpo de 900000 bytes llega completo a dominio' $bigOk ("antes=" + $beforeBig.Status + " POST=" + $r.Status + " despues=" + $afterBig.Status + " enviado=" + $r.SentLength)
    if (-not $bigOk) { Show-Diag $r }
    # Restablecer el estado de whoami para evitar errores en pruebas posteriores.
    $null = Send-Gw 'POST' '/api/dominio/health' -Body '200'

    $r = Send-Gw 'POST' '/'
    $j = Get-Json $r.Body
    Check 'POST / -> 405 JSON metodo_no_permitido' (($r.Status -eq 405) -and (Is-Json $r) -and ($j.error -eq 'metodo_no_permitido')) (Brief $r)

    $r = Send-Gw 'PUT' '/api/ia/prueba' -Body '{}'
    # .NET separa "GET, POST" en dos valores; se normalizan los espacios antes de comparar.
    $allow = ('' + $r.Headers['allow']) -replace '\s', ''
    Check 'PUT /api/ia/... -> 405 con cabecera Allow: GET, POST' (($r.Status -eq 405) -and ($allow -eq 'GET,POST')) ("estado=" + $r.Status + " allow=" + $allow)

    $r = Send-Gw 'HEAD' '/'
    Check 'HEAD / -> 200' ($r.Status -eq 200) (Brief $r)

    $r = Send-Gw 'POST' '/health'
    Check 'POST /health -> 405' ($r.Status -eq 405) (Brief $r)

    # ------------------------------------------------------------ 5. rutas desconocidas y redirecciones
    Section '5. Rutas desconocidas y redirecciones'
    foreach ($p in @('/api', '/api/', '/api/otro/x')) {
        $r = Send-Gw 'GET' $p
        $j = Get-Json $r.Body
        Check ("GET " + $p + " -> 404 JSON ruta_no_encontrada") (($r.Status -eq 404) -and (Is-Json $r) -and ($j.error -eq 'ruta_no_encontrada')) (Brief $r)
    }
    $r = Send-Gw 'GET' '/api/dominio'
    Check 'GET /api/dominio -> 308 hacia /api/dominio/' (($r.Status -eq 308) -and ($r.Location -eq '/api/dominio/')) ("estado=" + $r.Status + " location=" + $r.Location)
    $r = Send-Gw 'GET' '/api/ia?q=1'
    Check 'GET /api/ia?q=1 -> 308 hacia /api/ia/?q=1' (($r.Status -eq 308) -and ($r.Location -eq '/api/ia/?q=1')) ("estado=" + $r.Status + " location=" + $r.Location)

# Una replica ausente puede causar 502 (sin upstream) o 504 (timeout), segun Docker/DNS.
# Ambos son fallos controlados validos, pero cada estado exige su JSON correspondiente.
function Is-GatewayUnavailable {
    param($Response, [string]$Service)
    if ($null -eq $Response -or -not (Is-Json $Response)) { return $false }
    $j = Get-Json $Response.Body
    if ($null -eq $j -or $j.servicio -ne $Service) { return $false }
    return (($Response.Status -eq 502 -and $j.error -eq 'servicio_no_disponible') -or
            ($Response.Status -eq 504 -and $j.error -eq 'tiempo_de_espera_agotado'))
}

    # ------------------------------------------------------------ 6. caida de servicios
    Section '6. Caida y recuperacion de servicios'

    # Acepta 502 o 504 si el JSON coincide con el codigo y el servicio apagado.
    # Docker Desktop y runners Ubuntu pueden resolver esta caida de forma diferente.
    $null = Dc @('stop', 'dominio')
    $script:r = $null
    $null = Wait-Until { $script:r = Send-Gw 'GET' ('/api/dominio/consulta?correo=' + $Marker1 + '&rut=' + $Marker2); (Is-GatewayUnavailable $script:r 'dominio') } 30 500
    $r = $script:r
    Check 'dominio detenido -> 502/504 JSON correcto / dominio' (Is-GatewayUnavailable $r 'dominio') (Brief $r)
    Check 'Con dominio detenido el gateway sigue sano (/health 200)' ((Send-Gw 'GET' '/health').Status -eq 200)
    Check 'Con dominio detenido el front sigue respondiendo (200)' ((Send-Gw 'GET' '/').Status -eq 200)
    Check 'Con dominio detenido ia sigue respondiendo (200)' ((Send-Gw 'GET' '/api/ia/').Status -eq 200)
    $null = Dc @('start', 'dominio')
    $back = Wait-StableRoute '/api/dominio/' 200 5 60
    Check 'dominio vuelve a responder 200 de forma estable sin reiniciar el gateway' $back

    $null = Dc @('stop', 'ia')
    $script:r = $null
    $null = Wait-Until { $script:r = Send-Gw 'POST' ('/api/ia/prueba?nombre=' + $Marker1) -Body '{"k":1}'; (Is-GatewayUnavailable $script:r 'ia') } 30 500
    $r = $script:r
    Check 'ia detenido -> 502/504 JSON correcto / ia' (Is-GatewayUnavailable $r 'ia') (Brief $r)
    $null = Dc @('start', 'ia')
    $back = Wait-StableRoute '/api/ia/' 200 5 60
    Check 'ia vuelve a responder 200 de forma estable' $back

    $null = Dc @('stop', 'front')
    $script:r = $null
    $null = Wait-Until { $script:r = Send-Gw 'GET' '/'; (Is-GatewayUnavailable $script:r 'front') } 30 500
    $r = $script:r
    Check 'front detenido -> 502/504 JSON correcto / front' (Is-GatewayUnavailable $r 'front') (Brief $r)
    # Permitir que la ruta no relacionada con front termine de estabilizarse.
    # Un 502 persistente durante 60 s sigue siendo un fallo real.
    $apiAlive = Wait-StableRoute '/api/dominio/' 200 5 60
    Check 'Con front detenido las rutas /api siguen funcionando de forma estable' $apiAlive
    $null = Dc @('start', 'front')
    $back = Wait-StableRoute '/' 200 5 60
    Check 'front vuelve a responder 200 de forma estable' $back

    # ------------------------------------------------------------ 7. respuestas propias del servicio y tiempo de espera
    Section '7. Errores del propio servicio y tiempo de espera'

    # traefik/whoami permite fijar el codigo que devuelve su /health con un POST.
    # La ruta debe estar estable tras el ciclo de paradas antes de cambiar el estado.
    $null = Wait-StableRoute '/api/dominio/' 200 5 60
    $set503 = Send-Gw 'POST' '/api/dominio/health' -Body '503'
    $ready503 = Wait-StableRoute '/api/dominio/health' 503 2 30
    $r = Send-Gw 'GET' '/api/dominio/health'
    Check 'Si el servicio responde 503 por su cuenta, el gateway lo entrega tal cual (sin reemplazarlo)' (($set503.Status -eq 200) -and $ready503 -and ($r.Status -eq 503) -and (-not $r.Body.Contains('servicio_no_disponible'))) ("POST=" + $set503.Status + " GET=" + (Brief $r))
    $set200 = Send-Gw 'POST' '/api/dominio/health' -Body '200'
    $ready200 = Wait-StableRoute '/api/dominio/health' 200 5 30
    Check 'El servicio vuelve a responder 200 en /health' (($set200.Status -eq 200) -and $ready200) ("POST=" + $set200.Status + " recuperado=" + $ready200)

    if ($OmitirLentas) {
        Write-Host '  (omitida) prueba de tiempo de espera 504' -ForegroundColor DarkYellow
    } else {
        Write-Host '  Probando tiempo de espera (el servicio tarda 13 s; el gateway espera 10 s)...'
        $r = Send-Gw 'GET' ('/api/dominio/?wait=13s&correo=' + $Marker1)
        $j = Get-Json $r.Body
        Check 'Servicio lento -> 504 JSON tiempo_de_espera_agotado / dominio' (($r.Status -eq 504) -and (Is-Json $r) -and ($j.error -eq 'tiempo_de_espera_agotado') -and ($j.servicio -eq 'dominio')) (Brief $r)
        Check 'El 504 llega a los ~10 s (entre 9 y 13 s)' (($r.Ms -ge 9000) -and ($r.Ms -le 13000)) ("duracion=" + $r.Ms + " ms")
    }

    # ------------------------------------------------------------ 8. logs
    Section '8. Logs sin datos personales'
    $logs = Dk @('logs', $gw)
    $acc = @($logs | Where-Object { $_ -match '^metodo=' })
    $fmt = '^metodo=[A-Z]+ estado=\d{3} bytes=\d+ duracion=[0-9.]+ upstream=[-0-9., :]+ ruta=(front|dominio|ia|gateway)$'
    $badFmt = @($acc | Where-Object { $_ -notmatch $fmt })
    Check 'Log de acceso: hay registros' ($acc.Count -gt 0) ("lineas=" + $acc.Count)
    Check 'Log de acceso: todas las lineas tienen el formato metodo/estado/bytes/duracion' ($badFmt.Count -eq 0) (($badFmt | Select-Object -First 2) -join ' | ')

    $leakPattern = 'example\.cl|ana\.prueba|11\.111|correo=|rut=|nombre=|/api|/health|\?'
    $leakAcc = @($acc | Where-Object { ($_ -match $leakPattern) -or ($_ -match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b') })
    Check 'Log de acceso: sin IP del cliente, sin rutas ni parametros ni datos personales' ($leakAcc.Count -eq 0) (($leakAcc | Select-Object -First 2) -join ' | ')

    $errLines = @($logs | Where-Object { $_ -match '\[(error|crit|alert|emerg)\]' })
    $leakErr = @($errLines | Where-Object { $_ -match 'client:|request:|upstream: ' -or $_ -match $leakPattern })
    Check 'Log de errores: sin la peticion, sin IP y sin datos personales' ($leakErr.Count -eq 0) (($leakErr | Select-Object -First 2) -join ' | ')

    $allText = ($logs -join "`n")
    Check ('Ningun log (acceso ni errores) contiene "' + $Marker1 + '" ni "' + $Marker2 + '"') (($allText -notmatch 'ana\.prueba') -and ($allText -notmatch '11\.111\.111')) ''

    Write-Host "  Ultimas lineas del log de acceso:"
    $acc | Select-Object -Last 4 | ForEach-Object { Write-Host ("    " + $_) -ForegroundColor DarkGray }

    # ------------------------------------------------------------ 9. puertos
    Section '9. Solo el gateway publica un puerto'
    $ps = Dk @('ps', '--filter', ('label=com.docker.compose.project=' + $Project), '--format', '{{.Names}}|{{.Ports}}')
    $rows = @($ps | Where-Object { $_ -match '\|' })
    $published = @($rows | Where-Object { ($_ -split '\|', 2)[1] -match '->' })
    $hostPorts = @($published | ForEach-Object { [regex]::Matches(($_ -split '\|', 2)[1], ':(\d+)->') | ForEach-Object { $_.Groups[1].Value } } | Select-Object -Unique)
    Check 'Hay 4 contenedores en el entorno de pruebas' ($rows.Count -eq 4) ("contenedores=" + $rows.Count)
    Check 'Solo un contenedor publica puertos y es el gateway' (($published.Count -eq 1) -and ($published[0] -match 'gateway')) (($rows | ForEach-Object { $_ }) -join ' ; ')
    Check 'El unico puerto publicado hacia el host es el 8080' (($hostPorts.Count -eq 1) -and ($hostPorts[0] -eq '8080')) ("puertos=" + ($hostPorts -join ','))

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
