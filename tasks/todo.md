# Tasks: rate limiting de campañas

## Task 1: Escribir el contrato de aliases y cuotas

**Description:** Extender el smoke test para cubrir ambas rutas de campañas y
las cuotas GET/POST antes de modificar Nginx.

**Acceptance criteria:**
- [x] `/api/campanas/x` y `/api/dominio/campanas/x` llegan a `/campanas/x`.
- [x] Una ráfaga POST y una ráfaga GET exigen 429 JSON con `Retry-After: 60`.
- [x] La prueba exige que el alias alternativo no evada una zona agotada.

**Verification:**
- [x] El smoke falla únicamente en las nuevas aserciones de rate limiting.
- [x] Las comprobaciones previas continúan verdes hasta ese punto.

**Dependencies:** None.

**Files likely touched:**
- `tests/smoke.ps1`

**Estimated scope:** S.

## Checkpoint 1: evidencia roja

- [x] La falla actual es reproducible y corresponde a ausencia de 429.
- [x] No se eliminaron ni relajaron pruebas existentes.

## Task 2: Implementar claves y zonas por método

**Description:** Definir la identidad del cliente y zonas separadas para
creación y polling, sin limitar métodos o rutas ajenos.

**Acceptance criteria:**
- [x] POST usa `3r/m`, GET/HEAD usa `60r/m`.
- [x] Las claves vacías excluyen métodos no cubiertos.
- [x] La IP viene de Caddy y tiene fallback para ejecución directa.

**Verification:**
- [x] `docker build -t nexus-gateway:rate-limit .` termina correctamente.
- [x] `docker run --rm nexus-gateway:rate-limit nginx -t` pasa.

**Dependencies:** Task 1.

**Files likely touched:**
- `nginx/default.conf`

**Estimated scope:** S.

## Task 3: Proteger ambos aliases y responder 429 JSON

**Description:** Aplicar ambas zonas a las dos rutas de campañas y añadir una
respuesta controlada compartida.

**Acceptance criteria:**
- [x] Ambos aliases usan las mismas zonas.
- [x] 429 devuelve `{"error":"limite_de_solicitudes_excedido"}`.
- [x] 429 incluye `Retry-After: 60`.

**Verification:**
- [x] `tests/smoke.ps1` completo queda verde (60 comprobaciones).
- [x] El polling normal probado no recibe 429.

**Dependencies:** Task 2.

**Files likely touched:**
- `nginx/default.conf`
- `tests/smoke.ps1`

**Estimated scope:** M.

## Checkpoint 2: contrato de rate limiting

- [x] GET y POST excesivos terminan en 429.
- [x] No existe bypass entre aliases.
- [x] Predicción, front, health e IA siguen verdes.

## Task 4: Ejecutar regresión de balanceo y build

**Description:** Demostrar que las cuotas no alteran balanceo, recuperación de
réplicas, arquitectura de imagen ni privacidad de logs.

**Acceptance criteria:**
- [x] Smoke completo verde (60 comprobaciones).
- [x] Balanceo completo verde (61 comprobaciones).
- [x] Imagen linux/amd64 y `nginx -t` correctos.

**Verification:**
- [x] `powershell -ExecutionPolicy Bypass -File .\tests\smoke.ps1`.
- [x] `powershell -ExecutionPolicy Bypass -File .\tests\balanceo.ps1`.
- [x] `git diff --check` sin errores.

**Dependencies:** Task 3.

**Files likely touched:**
- Ninguno adicional; solo ejecución y evidencia.

**Estimated scope:** S.

## Task 5: Publicar el módulo aprobado

**Description:** Crear commits atómicos, PR hacia `dev`, promover a `main` tras
CI verde y capturar el digest de la imagen resultante.

**Acceptance criteria:**
- [ ] Commits pertenecen a Gaborilincio y no contienen secretos.
- [ ] PR hacia `dev` y PR `dev → main` tienen CI verde.
- [ ] Se registra el digest nuevo de `nexus-gateway:latest`.

**Verification:**
- [ ] SHA de `origin/main`, revisión OCI y workflow coinciden.
- [ ] El digest se entrega al siguiente módulo sin desplegar todavía.

**Dependencies:** Task 4 y autorización explícita para merges.

**Files likely touched:**
- `nginx/default.conf`
- `tests/smoke.ps1`
- `SPEC-CAMPAIGN-RATE-LIMIT.md`
- `tasks/plan.md`
- `tasks/todo.md`

**Estimated scope:** M.

## Checkpoint final

- [ ] Todos los criterios de la especificación están demostrados.
- [ ] Gateway está listo para fijarse por digest.
- [ ] EC2 todavía no cambió; rollback y producción permanecen estables.
