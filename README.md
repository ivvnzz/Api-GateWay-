# Nexus Gateway

API Gateway del sistema de recomendacion de productos de **Nexus Retail SpA**.
Proyecto de la Evaluacion Parcial 2 de ITY1102 . Arquitectura de Sistemas de Inteligencia Artificial.

## Rol en la arquitectura

El gateway es la **unica puerta de entrada** del sistema y el unico servicio que publica un puerto hacia el host: el **8080**. Esta hecho con Nginx. No contiene logica de negocio.

## Estado

**Fase 0 . bootstrap.** El repositorio solo tiene la documentacion inicial. Todavia no hay Dockerfile, configuracion de Nginx, pruebas ni pipeline.

## Diseño previsto (aun no implementado, sujeto a confirmacion del equipo)

| Ruta externa | Destino interno | Observacion |
|---|---|---|
| `/` | `front:80` | Interfaz del usuario |
| `/api/dominio/` | `dominio:3000` | Se quita el prefijo antes de reenviar |
| `/api/ia/` | `ia:8000` | Se quita el prefijo antes de reenviar |
| `/health` | respuesta local | Healthcheck del propio gateway |

Imagen prevista: `ghcr.io/ivvnzz/nexus-gateway`.

## Flujo de trabajo (Gitflow minimo)

- `main`: lo que se entrega. Solo se modifica mediante pull request desde `dev`.
- `dev`: integracion. Solo se modifica mediante pull request desde una rama `feat/`.
- `feat/&lt;descripcion&gt;`: una funcionalidad a la vez. Se crea desde `dev` y se borra al integrarse.
- Nadie hace push directo a `main` ni a `dev` despues de la inicializacion.

## Equipo

| Integrante | Usuario de GitHub |
|---|---|
| (completar) | `ivvnzz` |
| (completar) | (completar) |