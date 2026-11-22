# Spec: rate limiting de campañas en API Gateway

## Objective

Proteger las rutas públicas de campañas frente a ráfagas y abuso sin romper el
polling del front. Nginx aplicará cuotas separadas por IP de cliente y método:

- `POST`: 3 solicitudes por minuto, `burst=2`, `nodelay`.
- `GET` y `HEAD`: 60 solicitudes por minuto, `burst=20`, `nodelay`.

Se protegen ambos aliases para impedir bypass:

- `/api/campanas/{id-o-usuario}`
- `/api/dominio/campanas/{id-o-usuario}`

El exceso devuelve HTTP 429, JSON estable y `Retry-After: 60`. El límite de
PostgreSQL y la autenticación `X-API-Key` del Dominio continúan como defensas
independientes.

## Tech Stack

- Nginx `1.30.5-alpine`.
- Docker Compose para smoke tests con `traefik/whoami` como upstream.
- PowerShell 5.1/7 para `tests/smoke.ps1` y `tests/balanceo.ps1`.
- Caddy es el único punto público en producción; Gateway solo escucha en la red
  interna del Compose.

## Commands

Validar configuración y construir:

```powershell
docker build -t nexus-gateway:rate-limit .
docker run --rm nexus-gateway:rate-limit nginx -t
```

Pruebas completas:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\smoke.ps1
powershell -ExecutionPolicy Bypass -File .\tests\balanceo.ps1
```

Inspección del diff:

```powershell
git diff --check
git diff -- nginx/default.conf tests/smoke.ps1
```

## Project Structure

```text
nginx/default.conf   → zonas, claves por método, rutas y respuesta 429
tests/smoke.ps1      → contrato de cuotas, aliases, JSON y Retry-After
tests/balanceo.ps1   → regresión de balanceo y disponibilidad
Dockerfile           → imagen de Nginx validada por CI
```

## Code Style

La configuración conserva nombres en español y respuestas JSON pequeñas:

```nginx
map $request_method $campanas_post_key {
    default "";
    POST $nexus_client_key;
}

limit_req_zone $campanas_post_key zone=campanas_post:10m rate=3r/m;
```

No se registran IP, URL, API key ni parámetros personales.

## Client IP and trust boundary

Caddy establece `X-Forwarded-For` con la IP del cliente antes de enviar la
petición a Gateway. Nginx usa ese valor como clave y cae a `$binary_remote_addr`
si el encabezado no existe.

Esta confianza es válida porque el Gateway no publica puertos en el Compose de
producción: solo Caddy puede alcanzarlo. Nginx continúa reemplazando el
`X-Forwarded-For` que entrega al upstream para que un encabezado falsificado no
llegue al Dominio ni a sus logs.

## Testing Strategy

`tests/smoke.ps1` debe demostrar:

1. Las dos rutas llegan a `/campanas/...` en Dominio.
2. Una cantidad normal de GET consecutivos no recibe 429.
3. Una ráfaga excesiva de GET termina en 429 JSON.
4. Una ráfaga excesiva de POST termina en 429 JSON.
5. Después de agotar el alias corto, el alias `/api/dominio/campanas/` también
   devuelve 429; no existe bypass.
6. El 429 incluye `Retry-After: 60` y no contiene datos personales.
7. Predicción, IA, front, health, errores controlados y balanceo permanecen
   verdes.

Los smoke tests usan upstreams simulados; la verificación HTTPS en EC2 se hace
en el módulo `production-rollout` con una API key real que nunca se registra.

## Boundaries

### Always

- Escribir primero pruebas que fallen sin los límites.
- Limitar por separado lectura y creación.
- Aplicar las mismas cuotas a ambos aliases.
- Mantener JSON y `Retry-After` en respuestas 429.
- Ejecutar smoke y balanceo completos antes del PR.

### Ask first

- Cambiar cuotas, bursts o ventana de 60 segundos.
- Publicar un puerto del Gateway en producción.
- Limitar `/api/predict`, health, assets, IA u otras rutas.
- Añadir AWS WAF, ALB, CloudFront o dependencias nuevas.

### Never

- Imprimir o registrar `X-API-Key` o IP de clientes.
- Aplicar una cuota única compartida por todos los usuarios detrás de Caddy.
- Permitir bypass por `/api/dominio/campanas/`.
- Desactivar las pruebas existentes para conseguir CI verde.

## Success Criteria

1. POST de campañas: `3r/m`, `burst=2`; exceso HTTP 429.
2. GET/HEAD de campañas: `60r/m`, `burst=20`; exceso HTTP 429.
3. Ambos aliases comparten las mismas zonas y no permiten bypass.
4. Respuesta: JSON `{"error":"limite_de_solicitudes_excedido"}` y cabecera
   `Retry-After: 60`.
5. El polling normal cada 2 segundos no recibe 429.
6. Smoke, balanceo, `nginx -t` y CI quedan verdes.
7. No cambia ninguna ruta fuera de campañas.

## Open Questions

Ninguna. Las cuotas y el alcance fueron aprobados el 22/11/2026.
