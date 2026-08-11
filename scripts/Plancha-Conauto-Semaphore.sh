#!/usr/bin/env bash
# Planchado controlado de bases Progress OpenEdge para ejecución desde Semaphore UI.
# Topología esperada:
#   Semaphore / Ansible controller : 172.20.54.160
#   Servidor origen de respaldos   : 172.20.54.202
#   Servidor destino QA            : 172.20.54.217
#
# Este script debe ejecutarse EN EL SERVIDOR QA, invocado por Ansible desde Semaphore.
# No debe ejecutarse directamente en Producción ni en el servidor Semaphore.

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# -----------------------------------------------------------------------------
# Configuración. Semaphore/Ansible puede sobrescribir estos valores por ambiente.
# -----------------------------------------------------------------------------
DLC="${DLC:-/usr/dlc}"
HOMEDB="${HOMEDB:-/home/Sistemas/Conauto}"
STS="${STS:-/usr/wrk/Sts/Conauto}"
PROBAKLOCAL="${PROBAKLOCAL:-/home/backups/Conauto/proBak}"

# Topología del proceso.
SEMAPHORE_SERVER_IP="${SEMAPHORE_SERVER_IP:-172.20.54.160}"
TARGET_QA_IP="${TARGET_QA_IP:-172.20.54.217}"
BACKUP_HOST="${BACKUP_HOST:-172.20.54.202}"
BACKUP_USER="${BACKUP_USER:-backup_reader}"
ORIGDB="${ORIGDB:-/home/backups/Conauto/proBak}"
BACKUP_SSH_KEY="${BACKUP_SSH_KEY:-/root/.ssh/id_ed25519_backup_reader}"
BACKUP_KNOWN_HOSTS="${BACKUP_KNOWN_HOSTS:-/root/.ssh/known_hosts}"
ALLOW_TARGET_IP_MISMATCH="${ALLOW_TARGET_IP_MISMATCH:-false}"

PAS_INSTANCE="${PAS_INSTANCE:-afnv8}"
SENTINEL="${SENTINEL:-/home/appDir/Sistemas/Conauto/com/wsApp/wsERP/tmp/Stop.txt}"
PF_FILE="${PF_FILE:-/root/bin/obj/conautov12.pf}"
POST_PROGRAM="${POST_PROGRAM:-/root/bin/obj/planchado_qa11x.r}"
LOG_DIR="${LOG_DIR:-/var/log/planchado-conauto}"
LOCK_FILE="${LOCK_FILE:-/var/lock/planchado-conauto.lock}"
ROLLBACK_ROOT="${ROLLBACK_ROOT:-${HOMEDB}/.rollback-planchado}"
CONFIRMACION="${CONFIRMACION:-}"
DRY_RUN="${DRY_RUN:-false}"
KEEP_PREVIOUS="${KEEP_PREVIOUS:-true}"
MIN_FREE_GB="${MIN_FREE_GB:-20}"
BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-48}"
RUN_ID="${SEMAPHORE_TASK_ID:-$(date +%Y%m%d_%H%M%S)}"

readonly REQUIRED_CONFIRMATION="PLANCHAR_CONAUTO"
readonly -a DBS=(admdata auxiliar bdmen_img conauto)
readonly -a DB_ALIASES=(conadmin conauxiliar conbdmen conconauto)
readonly -A SQL_PORTS=(
  [conauto]="11100:15000:15099"
  [bdmen_img]="11200:15100:15199"
  [auxiliar]="11300:15200:15299"
  [admdata]="11400:15300:15399"
)

LOG_FILE=""
STAGING_DIR=""
ROLLBACK_DIR=""
PHASE="inicio"

log() {
  local level="$1"; shift
  printf '%s [%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$PHASE" "$*" | tee -a "$LOG_FILE"
}

fail() {
  log ERROR "$*"
  exit 1
}

run() {
  log INFO "Ejecutando: $*"
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi
  "$@"
}

cleanup() {
  local rc=$?
  if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
    rm -rf -- "$STAGING_DIR"
  fi

  if (( rc != 0 )); then
    log ERROR "El proceso terminó con código $rc. Si ya se creó el centinela, se conserva para impedir la reanudación automática."
    log ERROR "Revise la bitácora y el directorio de recuperación: ${ROLLBACK_DIR:-no creado}."
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'log ERROR "Fallo en línea ${LINENO}: ${BASH_COMMAND}"' ERR

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "No se encontró el comando requerido: $1"
}

assert_safe_path() {
  local path="$1"
  [[ -n "$path" && "$path" == /* && "$path" != "/" ]] || fail "Ruta insegura o inválida: '$path'"
}

validate_integer() {
  [[ "$2" =~ ^[0-9]+$ ]] || fail "$1 debe ser un entero no negativo: '$2'"
}

validate_boolean() {
  local name="$1"
  local value="$2"
  [[ "$value" == "true" || "$value" == "false" ]] || fail "$name solo acepta true o false. Valor recibido: '$value'."
}

validate_target_host() {
  local ips
  ips="$(hostname -I 2>/dev/null | tr ' ' '\n' | sed '/^$/d' || true)"

  log INFO "Topología declarada: Semaphore=${SEMAPHORE_SERVER_IP}; Producción respaldos=${BACKUP_HOST}; Destino QA=${TARGET_QA_IP}."
  log INFO "IPs detectadas en este servidor: ${ips//$'\n'/, }."

  if [[ "$ALLOW_TARGET_IP_MISMATCH" != "true" ]]; then
    echo "$ips" | grep -Fx -- "$TARGET_QA_IP" >/dev/null \
      || fail "Este script debe ejecutarse en QA ${TARGET_QA_IP}. No se detectó esa IP en el servidor actual. Para excepción controlada use ALLOW_TARGET_IP_MISMATCH=true."
  else
    log WARN "ALLOW_TARGET_IP_MISMATCH=true: no se bloqueará la ejecución aunque la IP local no coincida con TARGET_QA_IP."
  fi

  if [[ "${SSH_CONNECTION:-}" == "${SEMAPHORE_SERVER_IP}"* ]]; then
    log INFO "La conexión SSH parece provenir del servidor Semaphore ${SEMAPHORE_SERVER_IP}."
  elif [[ -n "${SSH_CONNECTION:-}" ]]; then
    log WARN "SSH_CONNECTION=${SSH_CONNECTION}. No coincide claramente con Semaphore ${SEMAPHORE_SERVER_IP}; validar si hay NAT, salto SSH o ejecución manual."
  else
    log WARN "No se detectó SSH_CONNECTION. Ansible con become/sudo puede ocultarlo; continuar solo si la ejecución viene desde Semaphore."
  fi
}

remote_file_epoch() {
  local remote_file="$1"
  ssh "${SSH_OPTIONS[@]}" "${BACKUP_USER}@${BACKUP_HOST}" "stat -c %Y -- '$remote_file'"
}

copy_remote_backup() {
  local db="$1"
  local remote_file="${ORIGDB}/${db}.proBak"
  local local_file="${STAGING_DIR}/${db}.proBak"
  local epoch now age_hours

  log INFO "Validando respaldo remoto en Producción: ${BACKUP_USER}@${BACKUP_HOST}:${remote_file}"
  ssh "${SSH_OPTIONS[@]}" "${BACKUP_USER}@${BACKUP_HOST}" "test -s '$remote_file'" \
    || fail "El respaldo remoto no existe o está vacío: ${BACKUP_USER}@${BACKUP_HOST}:$remote_file"

  epoch="$(remote_file_epoch "$remote_file")" || fail "No fue posible obtener la fecha de $remote_file"
  now="$(date +%s)"
  age_hours=$(( (now - epoch) / 3600 ))
  (( age_hours <= BACKUP_MAX_AGE_HOURS )) \
    || fail "El respaldo $remote_file tiene ${age_hours} horas; máximo permitido: ${BACKUP_MAX_AGE_HOURS}."

  run scp "${SCP_OPTIONS[@]}" "${BACKUP_USER}@${BACKUP_HOST}:${remote_file}" "$local_file"
  [[ "$DRY_RUN" == "true" || -s "$local_file" ]] || fail "El respaldo local quedó vacío: $local_file"
}

stop_database() {
  local db="$1"
  local prefix="${HOMEDB}/${db}/${db}"

  log INFO "Deteniendo base $db"
  if [[ "$DRY_RUN" != "true" ]]; then
    "$DLC/bin/proshut" "$prefix" -by >>"$LOG_FILE" 2>&1 || log WARN "proshut devolvió error; se verificará el archivo .lk."
    sleep 2
    [[ ! -e "${prefix}.lk" ]] || fail "La base $db continúa activa (${prefix}.lk existe)."
  fi
}

preserve_previous_database() {
  local db="$1"
  local dbdir="${HOMEDB}/${db}"
  local rollback_db="${ROLLBACK_DIR}/${db}"

  mkdir -p "$rollback_db"

  if [[ "$KEEP_PREVIOUS" == "true" ]]; then
    log INFO "Moviendo versión anterior de $db a $rollback_db"
    if [[ "$DRY_RUN" != "true" ]]; then
      find "$dbdir" -mindepth 1 -maxdepth 1 ! -name '.rollback-planchado' -exec mv -t "$rollback_db" -- {} +
    fi
  else
    log WARN "KEEP_PREVIOUS=false: se eliminará el contenido anterior de $db."
    if [[ "$DRY_RUN" != "true" ]]; then
      find "$dbdir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    fi
  fi
}

restore_database() {
  local db="$1"
  local dbdir="${HOMEDB}/${db}"
  local prefix="${dbdir}/${db}"
  local backup="${PROBAKLOCAL}/${db}.proBak"
  local st_file="${STS}/${db}.st"

  run install -m 0640 "$st_file" "${dbdir}/${db}.st"
  log INFO "Restaurando $db con prorest <destino_db> <archivo_backup>"
  run "$DLC/bin/prorest" "$prefix" "$backup"

  log INFO "Ejecutando prostrct repair sobre $prefix"
  run "$DLC/bin/prostrct" repair "$prefix"

  if [[ "$DRY_RUN" != "true" ]]; then
    [[ -s "${prefix}.db" ]] || fail "No se encontró la base restaurada: ${prefix}.db"
  fi
}

start_sql_broker() {
  local db="$1"
  local prefix="${HOMEDB}/${db}/${db}"
  local service minport maxport
  IFS=: read -r service minport maxport <<<"${SQL_PORTS[$db]}"

  run "$DLC/bin/proserve" "$prefix" -m3 -N tcp -S "$service" \
      -Mi 8 -Ma 10 -Mpb 2 -ServerType SQL -n 25 \
      -minport "$minport" -maxport "$maxport"
}

# -----------------------------------------------------------------------------
# Inicio
# -----------------------------------------------------------------------------
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/planchado_${RUN_ID}.log"
touch "$LOG_FILE"
exec 9>"$LOCK_FILE"
flock -n 9 || fail "Ya existe otro planchado en ejecución. Lock: $LOCK_FILE"

PHASE="validaciones"
log INFO "Inicio del planchado. RUN_ID=$RUN_ID DRY_RUN=$DRY_RUN"

[[ "$CONFIRMACION" == "$REQUIRED_CONFIRMATION" ]] \
  || fail "Confirmación inválida. Debe establecer CONFIRMACION=$REQUIRED_CONFIRMATION."
validate_boolean DRY_RUN "$DRY_RUN"
validate_boolean KEEP_PREVIOUS "$KEEP_PREVIOUS"
validate_boolean ALLOW_TARGET_IP_MISMATCH "$ALLOW_TARGET_IP_MISMATCH"
validate_integer MIN_FREE_GB "$MIN_FREE_GB"
validate_integer BACKUP_MAX_AGE_HOURS "$BACKUP_MAX_AGE_HOURS"

for path in "$DLC" "$HOMEDB" "$STS" "$PROBAKLOCAL" "$LOG_DIR" "$ROLLBACK_ROOT" "$ORIGDB"; do
  assert_safe_path "$path"
done

for cmd in flock ssh scp stat find install df awk date tee hostname grep sed; do
  require_command "$cmd"
done
for cmd in proshut prorest prostrct pro dbman pasman proserve; do
  [[ -x "$DLC/bin/$cmd" ]] || fail "No existe o no es ejecutable: $DLC/bin/$cmd"
done

validate_target_host

[[ "$BACKUP_HOST" != "$TARGET_QA_IP" ]] || fail "BACKUP_HOST no puede ser igual al destino QA. Producción=${BACKUP_HOST}, QA=${TARGET_QA_IP}."
[[ -d "$HOMEDB" ]] || fail "No existe HOMEDB: $HOMEDB"
[[ -d "$STS" ]] || fail "No existe STS: $STS"
[[ -r "$PF_FILE" ]] || fail "No se puede leer PF_FILE: $PF_FILE"
[[ -r "$POST_PROGRAM" ]] || fail "No se puede leer POST_PROGRAM: $POST_PROGRAM"
[[ -r "$BACKUP_SSH_KEY" ]] || fail "No se puede leer BACKUP_SSH_KEY en QA: $BACKUP_SSH_KEY"
[[ -r "$BACKUP_KNOWN_HOSTS" ]] || fail "No se puede leer BACKUP_KNOWN_HOSTS en QA: $BACKUP_KNOWN_HOSTS"

for db in "${DBS[@]}"; do
  [[ -d "${HOMEDB}/${db}" ]] || fail "No existe el directorio de la base: ${HOMEDB}/${db}"
  [[ -r "${STS}/${db}.st" ]] || fail "Falta el archivo de estructura: ${STS}/${db}.st"
done

available_gb="$(df -Pk "$HOMEDB" | awk 'NR==2 {print int($4/1024/1024)}')"
(( available_gb >= MIN_FREE_GB )) \
  || fail "Espacio libre insuficiente en $HOMEDB: ${available_gb} GB; mínimo: ${MIN_FREE_GB} GB."

SSH_OPTIONS=(
  -o BatchMode=yes
  -o ConnectTimeout=15
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${BACKUP_KNOWN_HOSTS}"
  -i "$BACKUP_SSH_KEY"
)
SCP_OPTIONS=("${SSH_OPTIONS[@]}")

ssh "${SSH_OPTIONS[@]}" "${BACKUP_USER}@${BACKUP_HOST}" "test -d '$ORIGDB'" \
  || fail "No fue posible acceder al directorio remoto ${BACKUP_USER}@${BACKUP_HOST}:${ORIGDB}"

PHASE="descarga_respaldos"
run mkdir -p "$PROBAKLOCAL"
STAGING_DIR="$(mktemp -d "${PROBAKLOCAL}/.staging_${RUN_ID}_XXXX")"
for db in "${DBS[@]}"; do
  copy_remote_backup "$db"
done

if [[ "$DRY_RUN" != "true" ]]; then
  for db in "${DBS[@]}"; do
    install -m 0640 "${STAGING_DIR}/${db}.proBak" "${PROBAKLOCAL}/${db}.proBak"
  done
fi

PHASE="detencion_servicios"
run mkdir -p "$(dirname "$SENTINEL")"
run touch "$SENTINEL"

if [[ "$DRY_RUN" != "true" ]]; then
  "$DLC/bin/pasman" oeserver -I "$PAS_INSTANCE" -stop >>"$LOG_FILE" 2>&1 \
    || log WARN "PASOE devolvió error al detenerse; valide que ya estuviera detenido."
fi

for db in "${DBS[@]}"; do
  stop_database "$db"
done

PHASE="resguardo_anterior"
ROLLBACK_DIR="${ROLLBACK_ROOT}/${RUN_ID}"
run mkdir -p "$ROLLBACK_DIR"
for db in "${DBS[@]}"; do
  preserve_previous_database "$db"
done

PHASE="restauracion"
for db in "${DBS[@]}"; do
  restore_database "$db"
done

PHASE="post_planchado"
log INFO "Ejecutando programa postplanchado en modo batch"
run "$DLC/bin/pro" -b -pf "$PF_FILE" -p "$POST_PROGRAM"

PHASE="arranque_servicios"
for alias in "${DB_ALIASES[@]}"; do
  run "$DLC/bin/dbman" -start -database "$alias"
done

run "$DLC/bin/pasman" oeserver -I "$PAS_INSTANCE" -start

for db in conauto bdmen_img auxiliar admdata; do
  start_sql_broker "$db"
done

PHASE="validacion_final"
if [[ "$DRY_RUN" != "true" ]]; then
  for db in "${DBS[@]}"; do
    [[ -e "${HOMEDB}/${db}/${db}.lk" ]] \
      || log WARN "No se encontró .lk para $db; confirme su estado mediante OpenEdge Management."
  done
fi

PHASE="finalizacion"
run rm -f -- "$SENTINEL"
log INFO "Planchado completado correctamente en QA ${TARGET_QA_IP}. Resguardo anterior: $ROLLBACK_DIR"
