# HU-REF-020 y R1: validación visual real

Este perfil monta el microfrontend real de Reference Data dentro de web-shell y utiliza IAM, PostgreSQL y RabbitMQ reales. Complementa la prueba técnica de backend; no simula permisos ni sustituye la sustentación individual.

## Carpetas esperadas

Dentro de una misma carpeta de trabajo: `design-software-web-shell`, `design-software-reference-data-mfe`, `design-software-frontend-platform`, `design-software-design-system`, `design-software-iam-service`, `design-software-reference-data-service`, `database/design-software-iam-db`, `database/design-software-reference-data-db` y `docker-infra/design-software-docker-infra`.

Los cuatro repositorios con cambios de esta integración usan `hu-ref-020-integracion-visual`, derivada de `develop`: web-shell, reference-data-mfe, frontend-platform y docker-infra. El backend y las bases deben contener las entregas HU-REF-020 y R1 previamente integradas. No se necesita ejecutar el BFF con su sesión fija ni desplegar los otros dominios.

## Ejecutar en PowerShell

Requisitos: Docker Desktop con Compose v2 que soporte `!override`, Node.js compatible con Playwright (se verificó Node 24 en los contenedores), npm y acceso a las descargas iniciales. Deja libres los puertos 5000 y 5105. Desde la raíz de docker-infra:

```powershell
./validation/frontend-reference/run.ps1
```

El comando prepara/migra el backend mediante el runner R1, levanta el perfil `frontend-reference`, espera los endpoints reales, ejecuta tres pruebas de integración Go y tres escenarios Chromium. Las dependencias están fijadas por los lockfiles; las imágenes usan las etiquetas declaradas en Compose. No se garantiza una primera ejecución dentro de los diez minutos de sustentación.

Si el backend R1 ya está preparado y sus credenciales no cambiaron:

```powershell
./validation/frontend-reference/run.ps1 -SkipBackendPreparation
```

Para dejar las pantallas disponibles sin ejecutar las pruebas:

```powershell
./validation/frontend-reference/run.ps1 -SkipBackendPreparation -PrepareOnly
```

Abre http://localhost:5000/reference-data/parametrizacion. Las cuentas de prueba son `hu-ref-018-admin@example.test` y `hu-ref-018-learner@example.test`; su contraseña generada es `FIXTURE_PASSWORD` en `validation/r1-reference/.env`. Consulta ese archivo localmente; no lo publiques, no lo incluyas en capturas y no uses esas cuentas en producción. El prefijo histórico 018 de la fixture no cambia la HU evaluada.

## Qué se comprueba

1. Backend HU-REF-020: login real, claims, permisos del administrador y rechazo del aprendiz/sin token/token alterado.
2. Backend R1: commit y rollback del outbox, inbox y efecto atómicos, duplicados concurrentes, reintentos, DLQ y replay manual real.
3. Navegador: crear y editar un parámetro; recargar y comprobar persistencia; logout remoto 204 y limpieza del token.
4. Navegador: el aprendiz puede leer catálogos, pero no gestionar catálogos ni abrir la pestaña de parámetros; petición directa de parámetros 403 y sin JWT/JWT inválido 401.
5. Navegador + caos: crear catálogo A; detener RabbitMQ; crear B desde la misma pantalla; verificar negocio y outbox persistidos sin proyección; reiniciar Reference Data con el broker detenido; recargar B; recuperar RabbitMQ; comprobar dos efectos para dos eventos originales.
6. Deduplicación: desde el verificador, volver a poner en `pending` los mismos dos registros outbox de prueba; el relay republica sus IDs/cuerpos originales. Crear un catálogo adicional como barrera FIFO, esperar su efecto y comprobar que los dos originales siguen teniendo dos registros inbox y dos efectos. La barrera se excluye de esas métricas. Esto modifica solo datos generados de la base aislada de validación.

R1 no requiere una pantalla de colas. La evidencia completa combina la operación visual con las consultas y las pruebas del broker real. No se implementaron nuevas pantallas de administración de mensajería.

## Evidencia y resultados

`evidence/result.json` indica `running`, `prepared`, `failed` o `passed`. Solo `passed` acredita la ejecución completa: `backend_passed: 3`, `browser_passed: 3`, `skipped: 0`. Una ejecución `PrepareOnly` no prueba el flujo. Cada intento reemplaza el estado anterior al comenzar.

Se generan `backend-hu-ref-020.log`, `backend-r1.log`, `playwright-result.json` y cuatro capturas. Los archivos crudos y credenciales están ignorados. El informe revisado y las capturas seleccionadas se publican por separado en este directorio. No se guardan traces, videos ni HAR que puedan contener credenciales.

El test restaura RabbitMQ en `finally` si falla una aserción durante la caída. Ante una interrupción forzada, restáuralo antes de repetir. El runner deja los servicios levantados para la demostración. Una instancia RabbitMQ con volumen persistente no constituye alta disponibilidad ni cubre pérdida permanente del disco.

## Decisión de arquitectura

ADR compartido en web-shell: `docs/adr/ADR-HU-REF-020-real-frontend-integration.md`. Los ajustes de JWT del microfrontend y el login de frontend-platform pertenecen a sus repositorios; Docker y el runner pertenecen a docker-infra. No se cambian IAM Service, las migraciones ni el funcionamiento de R1 en esta integración.
