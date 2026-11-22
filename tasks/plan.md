# Implementation Plan: rate limiting de campañas

## Overview

Añadir dos cuotas Nginx por IP y método para las rutas de campañas, sin romper
el polling del front ni las pruebas existentes. El cambio se entrega primero en
Gateway; la publicación por digest y el despliegue se ejecutan después como
módulos separados del mapa `CAPABILITY-MAP-EP3-FINAL.md`.

## Dependency Graph

```text
Contrato de pruebas de aliases y 429
        ↓
Claves de cliente + zonas GET/POST
        ↓
Aplicación en ambos aliases + JSON 429
        ↓
Smoke, balanceo, build y nginx -t
        ↓
PR feat → dev → main
```

## Architecture Decisions

- Dos `limit_req_zone`, no una cuota común: POST `3r/m` y GET/HEAD `60r/m`.
- Dos variables `map` dependientes del método. Una clave vacía excluye métodos
  no cubiertos sin usar `if` para rate limiting.
- La clave primaria toma `X-Forwarded-For` de Caddy y cae a
  `$binary_remote_addr` en pruebas/directo. Gateway no se publica en producción,
  por lo que Caddy es el límite de confianza.
- Ambos aliases usan las mismas zonas: agotar una ruta también limita la otra.
- Un named location propio entrega 429 JSON y `Retry-After: 60` sin filtrar IP,
  ruta, API key ni parámetros a logs.
- No se toca Dominio, Front, Compose ni EC2 en esta fase.

## Implementation Order

### Phase 1: contrato rojo

1. Extender `tests/smoke.ps1` con el enrutamiento de ambos aliases.
2. Añadir comprobaciones de polling normal, ráfagas GET/POST, JSON 429,
   `Retry-After` y ausencia de bypass.
3. Ejecutar el smoke enfocado y conservar la evidencia de que falla antes de la
   configuración Nginx.

### Checkpoint: tests rojos correctos

- Las rutas normales llegan al stub de Dominio.
- La falla se debe únicamente a que aún no existe HTTP 429.
- Ninguna aserción existente fue debilitada.

### Phase 2: configuración mínima

4. Añadir mapas de IP/método y zonas en `nginx/default.conf`.
5. Añadir el alias específico `/api/dominio/campanas/` antes de la ruta genérica.
6. Aplicar ambas zonas en los dos aliases y registrar el handler JSON 429.
7. Ejecutar `nginx -t` y el smoke hasta verde.

### Checkpoint: contrato del rate limiter

- POST excesivo y GET excesivo devuelven 429.
- GET normal y ambos aliases funcionan.
- El alias compatible no evade una zona agotada.

### Phase 3: regresión completa y publicación

8. Ejecutar `tests/smoke.ps1` completo y `tests/balanceo.ps1` completo.
9. Construir linux/amd64, validar arquitectura y configuración Nginx.
10. Revisar diff, secretos y logs; crear commits atómicos de código/pruebas y
    documentación.
11. Abrir PR hacia `dev`, esperar CI verde y luego promover a `main` con
    autorización.

### Checkpoint final del módulo

- Todos los criterios de `SPEC-CAMPAIGN-RATE-LIMIT.md` están cubiertos.
- `main` publica una imagen `latest` con revisión OCI del merge aprobado.
- El digest se entrega al módulo `immutable-application-images`.

## Verification Commands

```powershell
docker build -t nexus-gateway:rate-limit .
docker run --rm nexus-gateway:rate-limit nginx -t
powershell -ExecutionPolicy Bypass -File .\tests\smoke.ps1
powershell -ExecutionPolicy Bypass -File .\tests\balanceo.ps1
git diff --check
```

## Risks and Mitigations

| Riesgo | Impacto | Mitigación |
|---|---|---|
| Todos los clientes comparten la IP de Caddy | Alto | Usar `X-Forwarded-For` de Caddy y fallback solo cuando falta |
| Un cliente falsifica el encabezado | Alto | Gateway no publica puerto; Caddy reemplaza el encabezado en el límite público |
| GET polling consume la cuota POST | Alto | Zonas y claves separadas por método |
| Alias genérico evade el límite | Alto | Location específica para `/api/dominio/campanas/` con las mismas zonas |
| Pruebas flakey por algoritmo de ráfaga | Medio | Afirmar umbrales y estado final, no el índice exacto de cada 429 |
| 429 filtra datos en logs | Medio | Reutilizar formato de logs sin IP/ruta y probar marcadores existentes |
| Rate limiting afecta balanceo | Bajo | Ejecutar suite completa de dos réplicas antes del PR |

## Parallelization

No conviene paralelizar esta fase: pruebas y configuración modifican el mismo
contrato y deben avanzar en ciclo rojo-verde. La publicación de digests comienza
solo después del merge a `main`.

## Open Questions

Ninguna.
