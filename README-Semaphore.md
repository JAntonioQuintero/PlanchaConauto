# Planchado Conauto para Semaphore UI

## Topología actualizada

El proceso debe ejecutarse bajo esta topología:

| Rol | IP | Función |
|---|---:|---|
| Semaphore UI / Ansible controller | 172.20.54.160 | Lanza el template y ejecuta Ansible. No almacena ni restaura bases. |
| Servidor Producción / respaldos | 172.20.54.202 | Origen de los archivos `.proBak`. Solo debe permitir lectura controlada. |
| Servidor destino QA | 172.20.54.217 | Recibe los respaldos, detiene servicios, restaura bases y levanta el ambiente. |

Flujo de ejecución:

```text
172.20.54.160 Semaphore UI
        |
        | SSH / Ansible
        v
172.20.54.217 QA
        |
        | SSH / SCP de solo lectura
        v
172.20.54.202 Producción / respaldos
```

El script se instala y ejecuta únicamente en **172.20.54.217**. La IP **172.20.54.202** se usa solo para copiar los cuatro respaldos esperados. El servidor **172.20.54.160** actúa como orquestador.

## Archivos

- `scripts/Plancha-Conauto-Semaphore.sh`: proceso mejorado y no interactivo.
- `playbooks/plancha_conauto.yml`: playbook que debe usar el template de Semaphore.
- `inventory/inventory.example.ini`: inventario ajustado a QA `172.20.54.217`.
- `config/variable-group.example.json`: variables iniciales del proyecto con las IPs reales.

## Cambios principales

1. Se usa `set -Eeuo pipefail`, bitácora por ejecución y código de salida distinto de cero ante fallos.
2. Se impiden ejecuciones simultáneas mediante `flock`.
3. Se exige la confirmación exacta `PLANCHAR_CONAUTO`.
4. Se valida que el host gestionado por Ansible sea el QA esperado `172.20.54.217`.
5. Se valida espacio, comandos, directorios, archivos `.st`, PF, programa postplanchado, llave SSH y respaldos.
6. Solo se copian los cuatro archivos `.proBak` esperados desde `172.20.54.202`.
7. Se valida que los respaldos no estén vacíos y que su antigüedad no exceda el límite.
8. Se sustituye la eliminación directa por un resguardo en `${HOMEDB}/.rollback-planchado/<RUN_ID>`.
9. Se corrige la restauración a `prorest <destino_db> <archivo_backup>`.
10. Se corrige `prostrct repair` para operar sobre el prefijo real de cada base.
11. El programa ABL posterior se ejecuta en modo batch (`-b`).
12. Ante un error se conserva el archivo centinela para evitar que el demonio reanude operaciones sobre un estado incompleto.
13. Se incorpora `DRY_RUN=true` para validar el flujo antes de una ejecución real.

## Configuración en Semaphore UI en 172.20.54.160

1. Ingresar a Semaphore UI en el servidor `172.20.54.160`.
2. Crear o actualizar el repositorio Git con este directorio.
3. Crear un proyecto en Semaphore y vincular el repositorio.
4. Registrar en **Key Store** la llave SSH que Semaphore usará para conectarse a QA `172.20.54.217` como `semaphore_ops`.
5. Registrar, si aplica, la credencial de `sudo` para que `semaphore_ops` pueda instalar y ejecutar el script como `root` en QA.
6. Crear el inventario usando `inventory/inventory.example.ini`.
7. Crear un grupo de variables con el contenido de `config/variable-group.example.json`.
8. Crear un Task Template de tipo **Ansible** y seleccionar `playbooks/plancha_conauto.yml`.
9. Mantener deshabilitada la ejecución paralela del template.
10. Agregar variables de encuesta/prompt:
    - `confirmacion`: texto obligatorio. El operador debe escribir `PLANCHAR_CONAUTO`.
    - `dry_run`: lista `true/false`; valor inicial `true`.
    - `keep_previous`: lista `true/false`; valor recomendado `true`.
    - `ambiente`: lista permitida `QA` o `DESARROLLO`.
11. Ejecutar primero con `dry_run=true`.
12. Para la ejecución real usar `dry_run=false` y conservar `keep_previous=true`.

## Inventario esperado

```ini
[planchado_conauto]
conauto-qa ansible_host=172.20.54.217 ansible_user=semaphore_ops

[planchado_conauto:vars]
ansible_become=true
ansible_become_method=sudo
ansible_python_interpreter=/usr/bin/python3
```

## Variables principales

```json
{
  "ambiente": "QA",
  "semaphore_server_ip": "172.20.54.160",
  "target_qa_ip": "172.20.54.217",
  "backup_host": "172.20.54.202",
  "backup_user": "backup_reader",
  "origdb": "/home/backups/Conauto/proBak",
  "probaklocal": "/home/backups/Conauto/proBak",
  "dry_run": true,
  "keep_previous": true
}
```

## Autenticación requerida

### 1. Semaphore 172.20.54.160 hacia QA 172.20.54.217

Desde el servidor Semaphore se requiere conectividad SSH hacia QA:

```bash
ssh semaphore_ops@172.20.54.217
```

El usuario `semaphore_ops` debe poder ejecutar con `sudo` las tareas requeridas por el playbook.

### 2. QA 172.20.54.217 hacia Producción 172.20.54.202

El script realiza una segunda conexión SSH desde QA hacia el servidor de respaldos. Instale en QA una llave exclusiva, sin contraseña, para el usuario de solo lectura `backup_reader`:

```bash
install -d -m 0700 /root/.ssh
install -m 0600 id_ed25519_backup_reader /root/.ssh/id_ed25519_backup_reader
ssh-keyscan -H 172.20.54.202 >> /root/.ssh/known_hosts
chmod 0600 /root/.ssh/known_hosts
```

Prueba desde QA:

```bash
ssh -i /root/.ssh/id_ed25519_backup_reader backup_reader@172.20.54.202 \
  "ls -lh /home/backups/Conauto/proBak/*.proBak"
```

No se recomienda usar `root@172.20.54.202` para la copia de respaldos.

## Pruebas mínimas

Desde el servidor Semaphore `172.20.54.160` o desde el entorno donde se ejecute Ansible:

```bash
bash -n scripts/Plancha-Conauto-Semaphore.sh
ansible-playbook --syntax-check -i inventory/inventory.example.ini playbooks/plancha_conauto.yml
ansible-playbook -i inventory/inventory.example.ini playbooks/plancha_conauto.yml \
  -e confirmacion=PLANCHAR_CONAUTO \
  -e dry_run=true \
  -e keep_previous=true \
  -e ambiente=QA
```

Desde QA `172.20.54.217`, validar acceso a Producción `172.20.54.202`:

```bash
ssh -i /root/.ssh/id_ed25519_backup_reader backup_reader@172.20.54.202 \
  "test -s /home/backups/Conauto/proBak/admdata.proBak && echo OK"
```

## Ejecución real

En Semaphore UI:

```text
confirmacion = PLANCHAR_CONAUTO
ambiente     = QA
dry_run      = false
keep_previous = true
```

## Consideraciones de recuperación

Si una ejecución falla después de detener los servicios, el centinela permanece creado. Revise la bitácora en `/var/log/planchado-conauto` y el resguardo anterior antes de retirar manualmente el centinela o arrancar servicios.

Ruta del resguardo:

```text
/home/Sistemas/Conauto/.rollback-planchado/<RUN_ID>/
```

## Regla de seguridad

El template de Semaphore debe tener un único host destino: `172.20.54.217`. Nunca debe agregarse `172.20.54.202` al grupo `[planchado_conauto]`, ya que Producción solo participa como origen de archivos de respaldo.
