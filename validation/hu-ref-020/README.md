# HU-REF-020: integración real Reference Data e IAM

Este entorno valida los criterios E1-E4 del backend. Usa el código de los repositorios hermanos, una base PostgreSQL nueva y usuarios de prueba reales. No incluye el microfrontend, el web-shell ni la validación de mensajería R1.

## Requisitos y estructura

Docker Desktop debe estar iniciado, con contenedores Linux y acceso a los registros de imágenes y dependencias. No se requiere Java instalado en Windows: IAM se compila con Maven y Java 21 en Docker. Reference Data y las pruebas usan Go 1.26.5 en Docker.

```text
carpeta-de-trabajo/
  design-software-reference-data-service/    rama hu-ref-020
  design-software-iam-service/               develop, código original
  database/
    design-software-iam-db/                  rama hu-ref-020
    design-software-reference-data-db/       develop, código original
  docker-infra/
    design-software-docker-infra/            rama hu-ref-020
```

Desde este repositorio de infraestructura, ejecutar en PowerShell:

```powershell
./validation/hu-ref-020/run.ps1
```

La primera compilación puede tardar varios minutos. El script genera contraseñas aleatorias en `.env`, excluido de Git; las siguientes ejecuciones reutilizan ese archivo y el volumen de base de datos. No borrar `.env` mientras se conserva ese volumen. La clave RSA se genera dentro de Docker y persiste en un volumen propio.

El script aplica primero los changelogs oficiales de IAM y Reference Data con los contextos `01_ddl,02_dml,03_dcl,04_tcl,dev`. No usar solo `dev`: eso excluye los cambios que heredan los contextos de DDL, DML y DCL. Luego prepara dos usuarios de aplicación sin superusuario, asigna los roles de dominio y configura las contraseñas de las fixtures IAM oficiales. El SQL se niega a modificar una base distinta de `hu_ref_020`.

IAM ejecuta `mvn -B -ntp -U -DskipTests install` desde la raíz del reactor completo, incluyendo `iam-core`, `iam-adapters`, `iam-api` y `contracts`. Cada ejecución del runner recrea los servicios y compila IAM en un directorio temporal nuevo para evitar validar clases de una copia anterior. La opción `-U` permite reintentar descargas fallidas; no modifica certificados ni desactiva TLS. Esa compilación no sustituye la suite propia de IAM. Después inicia el JAR con validación Hibernate del esquema. La prueba E2E posterior es real y obligatoria; las variables faltantes producen un fallo, nunca un `Skip` que pueda interpretarse como aprobación.

## Servicios

| Servicio | Dirección en Windows |
|---|---|
| IAM readiness | http://localhost:18082/ready |
| IAM JWKS | http://localhost:18082/api/v1/auth/.well-known/jwks.json |
| Reference Data readiness | http://localhost:18080/health/ready |
| Reference Data parámetros | http://localhost:18080/parameters |
| PostgreSQL | localhost:15438, base `hu_ref_020` |

El proyecto Compose se llama `hu-ref-020` y no usa los volúmenes del macroproyecto. IAM y Reference Data comparten el espacio de red local: IAM escucha en 8080 y Reference Data en 8088. Así JWKS usa `127.0.0.1` sin cambiar la política del validador que exige HTTPS fuera de loopback. Ambos puertos HTTP publicados en Windows se limitan a `127.0.0.1`. Esta disposición es para validación local; un despliegue con servicios separados debe ofrecer JWKS mediante HTTPS.

## Evidencias

El script guarda en `evidence/` los resultados de migraciones, esquema y roles, versiones Java/Maven, prueba E2E y estado de contenedores. `result.json` se inicia con estado `running` y solo indica `passed` después de comprobar el marcador PASS de la prueba; las excepciones registran `failed`. Esa carpeta generada se omite de Git. El informe de resultados incorpora los extractos relevantes de una ejecución final comprobada, sin tokens ni contraseñas.

La prueba inicia sesión como `ADMIN_STAFF` y como `LEARNER`, verifica issuer, subject, expiración y claims de roles/features, y exige estos resultados:

| Operación | Resultado esperado |
|---|---|
| ADMIN_STAFF consulta parámetros | 200 |
| ADMIN_STAFF crea parámetro | 201 |
| ADMIN_STAFF modifica parámetro | 200 |
| LEARNER consulta, crea o modifica parámetros | 403 |
| Token ausente, mal formado o con firma alterada | 401 |

Se reutilizan las fixtures históricas `hu-ref-018-*.test`; el nombre identifica su procedencia, no cambia la HU que se valida. La prueba elimina el parámetro temporal creado. El runner no imprime contraseñas ni JWT.

## Detener

Desde este repositorio de infraestructura:

```powershell
$env:WORKSPACE_ROOT = (Resolve-Path '../..').Path.Replace('\', '/')
docker compose --env-file validation/hu-ref-020/.env -f validation/hu-ref-020/compose.yml down
```

Esto conserva los datos y las claves. No es necesario eliminar los volúmenes para repetir la prueba.
