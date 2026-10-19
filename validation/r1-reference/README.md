# R1: resiliencia y mensajería de Reference Data

Desde este repositorio, ejecutar en PowerShell con Docker Desktop iniciado:

```powershell
./validation/r1-reference/run.ps1
```

O desde Reference Data Service: `./scripts/run-r1-verification.ps1`.

Usa las mismas rutas de repositorios hermanos que HU-REF-020. Reference Data Service, Reference Data DB y Docker Infra deben incluir sus cambios de `r1-resiliencia-mensajeria`. IAM Service y su DB usan el código ya integrado en `develop`.

El runner reutiliza el Compose versionado de HU-REF-020 y añade `compose.override.yml`. El proyecto aislado se llama `r1-reference`: sus volúmenes, red, credenciales y contenedores no son los del entorno anterior. Conserva el nombre de base `hu_ref_020` para reutilizar las fixtures IAM protegidas, pero es una instancia PostgreSQL independiente.

| Recurso | Puerto local |
|---|---|
| IAM | 18092 |
| Reference Data | 18090 |
| PostgreSQL | 15439 |
| RabbitMQ | Interno, sin puerto publicado |

Las contraseñas se generan en `.env`, excluido de Git. No borrar ese archivo mientras se conservan los volúmenes. La clave de firma se genera dentro de Docker. Java 21 y Go 1.26.5 se ejecutan en contenedores.

## Secuencia automatizada

1. Migrar IAM y Reference Data y preparar sus cuentas de prueba.
2. Arrancar RabbitMQ persistente e IAM/Reference Data desde el código local.
3. Comprobar outbox transaccional y rollback ante error de serialización.
4. Comprobar doce entregas concurrentes con un efecto, fallo real de PostgreSQL, backoff de 1/2/4 segundos, DLQ y replay manual.
5. Crear tres catálogos por HTTP con JWT real, y esperar sus efectos.
6. **Detener el contenedor RabbitMQ** y crear otros tres catálogos; sus eventos deben seguir en PostgreSQL.
7. **Reiniciar Reference Data mientras RabbitMQ sigue detenido**.
8. Recuperar RabbitMQ; exigir los seis eventos y seis efectos.
9. Reenviar doce duplicados, esperar una barrera FIFO y comprobar cero efectos duplicados.

`evidence/` contiene logs por fase y un `result.json`. El runner exige marcadores PASS explícitos y se detiene ante un fallo; no aprueba pruebas omitidas. La carpeta es generada y está excluida de Git. El informe en Reference Data Service conserva los extractos revisados para entrega.

## Replay manual

Después de corregir la causa del fallo, desde el repositorio de infraestructura:

```powershell
$env:WORKSPACE_ROOT = (Resolve-Path '../..').Path.Replace('\', '/')
docker compose -p r1-reference --env-file validation/r1-reference/.env -f validation/hu-ref-020/compose.yml -f validation/r1-reference/compose.override.yml run --rm tests go run -mod=readonly ./cmd/reference-data-replay -limit 10
```

El comando preserva IDs y payloads y no expone credenciales. No vaciar la DLQ ni borrar el inbox como forma de recuperar un evento.

## Detener conservando los datos

```powershell
$env:WORKSPACE_ROOT = (Resolve-Path '../..').Path.Replace('\', '/')
docker compose -p r1-reference --env-file validation/r1-reference/.env -f validation/hu-ref-020/compose.yml -f validation/r1-reference/compose.override.yml down
```

El runner detiene únicamente el broker de `r1-reference` durante el caos. Si una fase falla mientras está detenido, reejecutar el runner lo recupera antes de la siguiente prueba. No se requiere eliminar volúmenes.
