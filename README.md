# Nexus Gateway | API Gateway de Nexus Retail

API Gateway del sistema de recomendaciones de productos de **Nexus Retail SpA**, desarrollado para la Evaluación Parcial 2 de **ITY1102 — Arquitectura de Sistemas de Inteligencia Artificial**.

**Tecnologías:** Nginx 1.30.5 Alpine, Docker, Docker Compose, PowerShell, GitHub Actions y GitHub Container Registry (GHCR).

**Repositorio:** <https://github.com/ivvnzz/Api-GateWay->  
**Imagen Docker publicada:** `ghcr.io/ivvnzz/nexus-gateway:latest`

## 1. Objetivo y responsabilidades

El Gateway es el **punto de entrada HTTP** del sistema y el único servicio que debe publicar un puerto al computador anfitrión en el Compose final: **8080**. Recibe las solicitudes y las dirige al Frontend, al microservicio de Dominio o al microservicio de IA mediante la red interna de Docker.

Sus responsabilidades son el **enrutamiento**, la resolución dinámica de los nombres de servicio, el **balanceo de carga** hacia las réplicas de Dominio, el endpoint propio de salud y el tratamiento de ciertos errores de conexión. **No implementa recomendaciones, reglas de negocio ni acceso a la base de datos.**

## 2. Arquitectura

```text
                     Navegador / cliente HTTP
                              |
                       localhost:8080
                              |
                    +-------------------+
                    |  Gateway (Nginx)  |
                    +-------------------+
                        /      |       \
                       /       |        \
                front:80   dominio:3000   ia:8000
                    |       /       \       |
                Frontend  Dominio 1  Dominio 2  Modelo IA
                              \       /
                               \-----/
                                  |
                         BD (gestionada por
                         Dominio en el sistema final)
```

El flujo de negocio previsto para obtener recomendaciones es **Frontend → Gateway → Dominio → IA**. La ruta `/api/ia/` también está configurada en el Gateway para las solicitudes dirigidas a IA; su uso público definitivo debe acordarse con el equipo. El gráfico representa **integración prevista**, no una integración ya validada con los servicios reales.

## 3. Rutas y comportamiento

| Ruta pública | Destino | Comportamiento |
|---|---|---|
| `GET /health` | Gateway | Responde `200` con `{"status":"ok","service":"gateway"}`. `HEAD` también se admite. |
| `/` y demás rutas no API | `front:80` | Se reenvía la ruta original. El Gateway admite `GET` y `HEAD`. |
| `/api/dominio/...` | `dominio:3000` | Elimina `/api/dominio/` antes de reenviar. Conserva método, cuerpo y parámetros de consulta. |
| `/api/ia/...` | `ia:8000` | Elimina `/api/ia/` antes de reenviar. El Gateway admite `GET` y `POST`. |
| `/api/dominio` y `/api/ia` | Redirección | Redirige con `308` a la ruta equivalente con `/` final. |
| `/api/` sin destino conocido | Gateway | Devuelve `404` JSON. |

**Ejemplo:** `POST http://localhost:8080/api/ia/predict` llega al servicio `ia` como `POST /predict`.

Cuando Nginx no puede acceder a un servicio, el Gateway puede devolver `502` con el JSON `servicio_no_disponible`, o `504` con `tiempo_de_espera_agotado` si se agota el tiempo de conexión o respuesta. Los métodos no permitidos responden `405` donde corresponda.

La configuración de `nginx/default.conf` utiliza el DNS interno de Docker (`127.0.0.11`) y servidores `upstream` dinámicos para resolver los nombres `front`, `dominio` e `ia`. Con dos réplicas de `dominio`, Nginx puede distribuir peticiones entre ambas.

## 4. Archivos importantes

```text
Api-GateWay-/
├── .github/
│   └── workflows/
│       └── ci-cd.yml             # CI en PR y publicación de imágenes en GHCR
├── nginx/
│   └── default.conf              # Rutas, upstream, logs y manejo de errores
├── tests/
│   ├── compose.stubs.yaml        # Entorno de prueba con servicios simulados
│   ├── smoke.ps1                 # Pruebas de enrutamiento (F2)
│   └── balanceo.ps1              # Pruebas de dos réplicas (F3)
├── .dockerignore                 # Excluye archivos innecesarios del build
├── .gitignore                    # Exclusiones de Git
├── Dockerfile                    # Imagen Nginx, puerto 8080 y healthcheck
└── README.md                     # Documentación del Gateway
```

- **`Dockerfile`:** utiliza `nginx:1.30.5-alpine`, copia `nginx/default.conf`, declara el puerto `8080` y define un `HEALTHCHECK` que consulta `/health`.
- **`nginx/default.conf`:** concentra las reglas de enrutamiento, la resolución de servicios, los timeouts, el balanceo y las respuestas de error.
- **`tests/compose.stubs.yaml`:** levanta el Gateway junto con tres servicios simulados mediante `traefik/whoami:v1.12.0`. Usa `build:` **solo para las pruebas**; no es el Compose definitivo de la evaluación.
- **`tests/smoke.ps1`:** verifica rutas, prefijos, métodos, cuerpos HTTP, servicios caídos y recuperados, logs y puerto publicado.
- **`tests/balanceo.ps1`:** ejecuta Dominio con **dos réplicas** del mismo servicio, comprueba distribución, caída, recuperación y aislamiento respecto del Front e IA.
- **`.github/workflows/ci-cd.yml`:** ejecuta las pruebas de F2 y F3 en GitHub Actions, valida la imagen y gestiona su publicación en GHCR.

## 5. Requisitos para desarrollar y probar

- Docker Desktop con motor Linux y Docker Compose v2.
- Windows PowerShell 5.1 o PowerShell 7 para ejecutar los scripts en Windows; el workflow de GitHub utiliza `pwsh` en Ubuntu.
- Git y acceso al repositorio.
- Puerto `8080` disponible para las pruebas.

Desde la carpeta raíz del repositorio:

```powershell
# Verificar herramientas
docker version
docker compose version

# Revisar los servicios definidos para las pruebas
docker compose -f tests/compose.stubs.yaml config --services
```

### Pruebas de enrutamiento (F2)

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\smoke.ps1
```

**Resultado obtenido:** **52 comprobaciones correctas, 0 fallidas** en Docker Desktop. Las pruebas también se han ejecutado satisfactoriamente mediante GitHub Actions.

### Pruebas de balanceo (F3)

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\balanceo.ps1
```

**Resultado obtenido:** **61 comprobaciones correctas, 0 fallidas** en Docker Desktop. El script escala el servicio `dominio` a **dos contenedores**, comprueba que las peticiones llegan a ambos y verifica el funcionamiento cuando uno o ambos dejan de estar disponibles.

Ambos scripts gestionan contenedores temporalmente. Si el puerto `8080` está ocupado, revisa los contenedores antes de ejecutarlos. El script de balanceo utiliza el proyecto Compose `gwbal`; el de enrutamiento usa `gwtest`.

### Prueba manual sencilla

```powershell
# Levantar gateway y servicios simulados
docker compose -f tests/compose.stubs.yaml -p gwtest up -d --build

# Verificar salud del Gateway y enrutamiento
curl.exe -i http://localhost:8080/health
curl.exe -i http://localhost:8080/
curl.exe -i http://localhost:8080/api/dominio/prueba
curl.exe -i http://localhost:8080/api/ia/prueba

# Liberar los recursos
docker compose -f tests/compose.stubs.yaml -p gwtest down -v
```

Para una comprobación manual con dos réplicas, usa `--scale dominio=2` en el comando `up` del entorno de pruebas. No es necesario crear dos definiciones de servicio distintas.

## 6. Integración continua y publicación (CI/CD)

El workflow en `.github/workflows/ci-cd.yml` establece los siguientes eventos:

| Evento | Acciones |
|---|---|
| Pull Request hacia `dev` o `main` | Ejecuta pruebas F2 y F3, construye y valida la imagen `linux/amd64`. **No publica.** |
| Push a `main` | Vuelve a validar y publica `latest` y `sha-<SHA completo>` en GHCR. |
| Push del tag Git `ep2` | Valida y reutiliza la imagen `sha-<SHA>` ya publicada para crear la etiqueta de contenedor `ep2`. |

La imagen publicada usa el nombre:

```text
ghcr.io/ivvnzz/nexus-gateway:latest
```

Se confirmó la ejecución exitosa de GitHub Actions al fusionar código en `main` y la descarga de `latest` mediante Docker Desktop. El paquete GHCR está configurado como **público**.

Para descargar la imagen:

```powershell
docker pull ghcr.io/ivvnzz/nexus-gateway:latest
```

**Importante:** el tag **`ep2`** es parte del proceso de entrega, pero **aún no se ha creado ni verificado** al momento de redactar este README. No debe presentarse como publicado hasta ejecutar y validar el flujo de etiquetado.

## 7. Privacidad y límites de seguridad

El formato de logs de acceso del Gateway registra **método, código de respuesta, bytes, duración, tiempo del upstream y categoría de ruta** (`front`, `dominio`, `ia` o `gateway`). No registra la URL completa, los parámetros de consulta ni la IP del cliente en el access log. Se han ejecutado pruebas con datos ficticios para comprobarlo.

La configuración limita además el nivel del registro de errores a `crit`, lo que reduce información potencialmente sensible, pero **también dificulta el diagnóstico**. El Gateway sí transmite al servicio interno una cabecera `X-Forwarded-For` generada a partir de la IP recibida; por tanto, los logs y controles de privacidad de **los otros microservicios** deben revisarse por separado.

Este proyecto no implementa por sí solo autenticación, autorización, controles de acceso por usuario ni cifrado TLS de producción. Esas capacidades no deben darse por implementadas por el hecho de existir un Gateway.

## 8. Repositorios del equipo e integración pendiente

| Componente | Repositorio | Situación |
|---|---|---|
| API Gateway | [ivvnzz/Api-GateWay-](https://github.com/ivvnzz/Api-GateWay-) | Construido, probado y publicado. |
| Frontend | [JaimeBarrales/Frontend-Nexus](https://github.com/JaimeBarrales/Frontend-Nexus) | Desarrollo del equipo; integración real pendiente. |
| Modelo y microservicio de IA | [Gaborilincio/modelo-nexus](https://github.com/Gaborilincio/modelo-nexus) | Desarrollo del equipo; integración real pendiente. |
| Microservicio de Dominio | Pendiente de creación | Será desarrollado en un repositorio independiente. |

### Acuerdos técnicos necesarios

- **Frontend:** nombre de servicio Docker `front`, puerto interno `80`.
- **Dominio:** nombre Docker `dominio`, puerto interno `3000`; `GET /health`, reglas de negocio y acceso a la base de datos. Se levantarán **dos réplicas** del mismo servicio.
- **IA:** nombre Docker `ia`, puerto interno `8000`; endpoints `GET /health` y `POST /predict`.
- Los servicios reales deben compartir la red Docker del Gateway y acordar sus contratos de entrada/salida HTTP.
- El **Compose final de la EP2** debe usar imágenes publicadas mediante `image:` (sin `build:`), incluir los demás servicios obligatorios y respetar el diagrama de arquitectura C4 del equipo.

Las pruebas actuales usan **stubs** y no demuestran todavía la integración funcional de los sistemas reales, la base de datos ni los requisitos de negocio de recomendaciones.

## 9. Flujo de trabajo Git

1. Crear una rama `feat/...` desde `dev`.
2. Implementar y probar localmente.
3. Abrir un Pull Request de `feat/...` hacia `dev`.
4. Una vez aprobada la integración, abrir un Pull Request de `dev` hacia `main`.
5. GitHub Actions valida cada PR; los pushes a `main` publican la imagen.
6. Cuando la versión de entrega esté validada, generar el tag Git `ep2` apuntando al commit correspondiente de `main` y verificar el job de publicación.

No se desarrollan funcionalidades directamente en `main` o `dev`. La documentación se actualiza mediante el mismo flujo de Pull Requests.

## 10. Estado del proyecto

**Completado en el Gateway:** imagen Docker, endpoint `/health`, enrutamiento, resolución dinámica, balanceo simulado de dos réplicas de Dominio, pruebas F2/F3, CI y publicación de la imagen `latest` en GHCR.

**Pendiente:** validar la imagen con tag `ep2`, actualizar la evidencia final de entrega y ejecutar la integración con Front, Dominio, IA y demás servicios reales del Compose del equipo.
