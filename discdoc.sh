#!/usr/bin/env bash
# =============================================================================
#  discdoc - Disk Health Doctor
#  Analizador interactivo de salud de discos usando SMART
#  Autor: (tu nombre)
#  Licencia: MIT
#  Uso: sudo ./discdoc.sh
# =============================================================================

set -o pipefail

# ---------- Colores ----------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
    C_MAGENTA=$'\033[35m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""
    C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_MAGENTA=""
fi

# ---------- Verificaciones iniciales ----------
check_deps() {
    local missing=()
    for cmd in smartctl lsblk whiptail awk grep sed lscpu badblocks dd hdparm; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        echo -e "${C_RED}Faltan dependencias: ${missing[*]}${C_RESET}"
        echo "En Debian/Ubuntu/Mint instalá con:"
        echo "  sudo apt install smartmontools whiptail util-linux e2fsprogs hdparm"
        exit 1
    fi
    # Chequeo de dependencias opcionales
    HAS_F3="no"
    if command -v f3write >/dev/null 2>&1 && command -v f3read >/dev/null 2>&1; then
        HAS_F3="yes"
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${C_RED}discdoc requiere permisos de root para leer SMART.${C_RESET}"
        echo "Corré: sudo $0"
        exit 1
    fi
}

# ---------- Detección de discos ----------
# Devuelve una lista de discos filtrados por transporte
# Argumento: "internal" (sata/nvme/ata) o "usb"
list_disks() {
    local filter="$1"
    local devs=()
    # Obtenemos todos los discos físicos (excluye loop, rom, part, lvm)
    while IFS= read -r line; do
        local name size tran type
        name=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        type=$(echo "$line" | awk '{print $3}')
        tran=$(echo "$line" | awk '{print $4}')
        [[ "$type" != "disk" ]] && continue
        [[ -z "$name" ]] && continue
        # Filtrado por transporte / tecnología
        case "$filter" in
            sata)
                # Solo SATA/ATA internos: excluye USB y NVMe
                if [[ "$tran" == "usb" ]]; then continue; fi
                if [[ "$name" =~ ^nvme ]]; then continue; fi
                ;;
            nvme)
                # Solo NVMe
                if [[ ! "$name" =~ ^nvme ]]; then continue; fi
                ;;
            usb)
                if [[ "$tran" != "usb" ]]; then continue; fi
                ;;
        esac
        devs+=("/dev/$name|$size|${tran:-unknown}")
    done < <(lsblk -dno NAME,SIZE,TYPE,TRAN)
    printf '%s\n' "${devs[@]}"
}

# Obtiene modelo del disco
get_model() {
    local dev="$1"
    local model
    model=$(smartctl -i "$dev" 2>/dev/null | grep -iE "^(Device Model|Model Number|Product):" | head -1 | sed 's/.*:[[:space:]]*//')
    if [[ -z "$model" ]]; then
        model=$(lsblk -dno MODEL "$dev" 2>/dev/null | head -1)
    fi
    echo "${model:-Desconocido}"
}

# Determina tipo del disco: SSD SATA, SSD NVMe, HDD, Pendrive USB, Disco USB
get_disk_type() {
    local dev="$1"
    if [[ "$dev" =~ nvme ]]; then
        echo "SSD NVMe"
        return
    fi
    # Detectar si es USB
    local devname
    devname=$(basename "$dev")
    local tran
    tran=$(lsblk -dno TRAN "$dev" 2>/dev/null)
    local size_bytes
    size_bytes=$(lsblk -dno SIZE -b "$dev" 2>/dev/null)
    if [[ "$tran" == "usb" ]]; then
        # Distinguir pendrive vs disco USB grande (arbitrario: < 64 GB = pendrive)
        if [[ -n "$size_bytes" && "$size_bytes" -lt 68719476736 ]]; then
            echo "Pendrive USB"
        else
            # Consultar rotational para saber si es HDD externo o SSD externo
            local rota
            rota=$(cat /sys/block/"$devname"/queue/rotational 2>/dev/null)
            if [[ "$rota" == "0" ]]; then
                echo "SSD USB"
            else
                echo "Disco USB"
            fi
        fi
        return
    fi
    local rota
    rota=$(cat /sys/block/"$devname"/queue/rotational 2>/dev/null)
    if [[ "$rota" == "0" ]]; then
        echo "SSD SATA"
    else
        echo "HDD"
    fi
}

# ---------- Parseo de SMART ----------
# Extrae un atributo SMART por ID o nombre para discos SATA
smart_get_raw() {
    local dev="$1"
    local id_or_name="$2"
    smartctl -A "$dev" 2>/dev/null | awk -v key="$id_or_name" '
        $1 == key || $2 == key {
            # RAW_VALUE es la última columna
            print $NF
            exit
        }
    '
}

# Para NVMe los atributos vienen con otro formato
nvme_get_field() {
    local dev="$1"
    local field="$2"
    smartctl -A "$dev" 2>/dev/null | grep -i "^${field}" | head -1 | sed 's/.*:[[:space:]]*//' | awk '{print $1}' | tr -d ','
}

# Health general
smart_health() {
    local dev="$1"
    smartctl -H "$dev" 2>/dev/null | grep -iE "SMART overall|SMART Health" | sed 's/.*:[[:space:]]*//'
}

# Detecta si el disco soporta SMART. Devuelve "yes" o "no".
smart_available() {
    local dev="$1"
    local out
    out=$(smartctl -i "$dev" 2>/dev/null)
    if echo "$out" | grep -qiE "SMART support is:[[:space:]]+Available"; then
        echo "yes"
    elif echo "$out" | grep -qiE "SMART support is:[[:space:]]+Unavailable"; then
        echo "no"
    else
        # Para NVMe smartctl no dice "Available" explícito pero funciona
        if smartctl -H "$dev" 2>/dev/null | grep -qi "SMART Health\|SMART overall"; then
            echo "yes"
        else
            echo "no"
        fi
    fi
}

# ---------- Análisis de dmesg para desconexiones ----------
# Para USB devuelve 0 si solo cuenta conexiones normales
count_disconnects() {
    local dev
    dev=$(basename "$1")
    local dtype="$2"   # opcional: tipo del disco para ajustar la lógica
    # Para pendrives/USB, solo contamos eventos SERIOS mencionando el device
    # (no meros connect/disconnect que son esperables al enchufarlos)
    dmesg 2>/dev/null | tail -n 3000 | \
        grep -iE "\b${dev}\b" | \
        grep -iE "(offline|hard resetting link|I/O error|failed command|medium error|unrecovered read error|device offline error)" | \
        grep -viE "(informational|normal)" | \
        wc -l
}

# ---------- Umbrales ----------
# Devuelve nivel: OK, ATENCION, DEGRADADO, CRITICO
level_reallocated() {
    local v; v=$(normalize_num "$1")
    [[ -z "$v" || ! "$v" =~ ^[0-9]+$ ]] && { echo "N/D"; return; }
    if   (( v == 0 ));   then echo "OK"
    elif (( v <= 50 ));  then echo "ATENCION"
    elif (( v <= 500 )); then echo "DEGRADADO"
    else                      echo "CRITICO"
    fi
}
level_pending() {
    local v; v=$(normalize_num "$1")
    [[ -z "$v" || ! "$v" =~ ^[0-9]+$ ]] && { echo "N/D"; return; }
    if   (( v == 0 ));    then echo "OK"
    elif (( v <= 10 ));   then echo "ATENCION"
    elif (( v <= 100 ));  then echo "DEGRADADO"
    else                       echo "CRITICO"
    fi
}
level_uncorrectable() {
    local v; v=$(normalize_num "$1")
    [[ -z "$v" || ! "$v" =~ ^[0-9]+$ ]] && { echo "N/D"; return; }
    if   (( v == 0 ));   then echo "OK"
    elif (( v <= 5 ));   then echo "ATENCION"
    elif (( v <= 50 ));  then echo "DEGRADADO"
    else                      echo "CRITICO"
    fi
}
level_crc() {
    local v; v=$(normalize_num "$1")
    [[ -z "$v" || ! "$v" =~ ^[0-9]+$ ]] && { echo "N/D"; return; }
    if   (( v == 0 ));    then echo "OK"
    elif (( v <= 10 ));   then echo "ATENCION"
    elif (( v <= 100 ));  then echo "DEGRADADO"
    else                       echo "CRITICO"
    fi
}
level_temp() {
    local v; v=$(normalize_num "$1")
    [[ -z "$v" || ! "$v" =~ ^[0-9]+$ ]] && { echo "N/D"; return; }
    if   (( v < 45 )); then echo "OK"
    elif (( v < 55 )); then echo "ATENCION"
    elif (( v < 65 )); then echo "DEGRADADO"
    else                    echo "CRITICO"
    fi
}

# NVMe: Available Spare (100 = todo el reserva intacto, 0 = agotado)
level_avail_spare() {
    local v; v=$(normalize_num "$1")
    local thresh; thresh=$(normalize_num "$2")
    [[ -z "$v" || ! "$v" =~ ^[0-9]+$ ]] && { echo "N/D"; return; }
    [[ -z "$thresh" ]] && thresh=10
    if   (( v > 50 ));                then echo "OK"
    elif (( v > 20 ));                then echo "ATENCION"
    elif (( v > thresh ));            then echo "DEGRADADO"
    else                                   echo "CRITICO"
    fi
}

# NVMe: Critical Warning (0x00 = todo bien; cualquier bit prendido = problema)
level_crit_warn() {
    local v="$1"
    [[ -z "$v" ]] && { echo "N/D"; return; }
    # Normalizar: sacar 0x, espacios
    v="${v#0x}"
    v="${v// /}"
    # Todo cero (uno o más "0")
    if [[ "$v" =~ ^0+$ ]]; then
        echo "OK"
    else
        # Cualquier bit activo es serio
        echo "CRITICO"
    fi
}

# NVMe: Error Info Log Entries (algunos errores esperables por la vida, muchos son mala señal)
level_err_log() {
    local v; v=$(normalize_num "$1")
    [[ -z "$v" || ! "$v" =~ ^[0-9]+$ ]] && { echo "N/D"; return; }
    if   (( v == 0 ));   then echo "OK"
    elif (( v <= 10 ));  then echo "ATENCION"
    elif (( v <= 100 )); then echo "DEGRADADO"
    else                      echo "CRITICO"
    fi
}
level_wear() {
    # Recibe "porcentaje usado" (0=nuevo, 100=agotado)
    local v
    v=$(normalize_num "$1")
    [[ -z "$v" || ! "$v" =~ ^[0-9]+$ ]] && { echo "N/D"; return; }
    if   (( v < 70 )); then echo "OK"
    elif (( v < 85 )); then echo "ATENCION"
    elif (( v < 95 )); then echo "DEGRADADO"
    else                    echo "CRITICO"
    fi
}

# Normaliza un valor numérico:
#   - Quita signo % (para "1%")
#   - Quita separadores de miles (punto o coma) (para "26.796")
#   - Toma solo la primera secuencia de dígitos (por si vienen unidades: "31 Celsius")
#   - Devuelve string vacío si no hay número
normalize_num() {
    local v="$1"
    [[ -z "$v" ]] && { echo ""; return; }
    # Sacamos %, separadores de miles, espacios y caracteres no-dígitos al principio
    v="${v//%/}"
    v="${v//[.,]/}"
    # Extraemos la primera secuencia de dígitos
    v=$(echo "$v" | grep -oE '[0-9]+' | head -1)
    echo "$v"
}

# Colorea un nivel
color_level() {
    case "$1" in
        OK)         echo "${C_GREEN}[OK]${C_RESET}" ;;
        ATENCION)   echo "${C_YELLOW}[ATENCION]${C_RESET}" ;;
        DEGRADADO)  echo "${C_YELLOW}${C_BOLD}[DEGRADADO]${C_RESET}" ;;
        CRITICO)    echo "${C_RED}${C_BOLD}[CRITICO]${C_RESET}" ;;
        N/D)        echo "${C_CYAN}[N/D]${C_RESET}" ;;
        *)          echo "[$1]" ;;
    esac
}

# Convierte nivel a peso para veredicto global
level_weight() {
    case "$1" in
        OK)         echo 0 ;;
        ATENCION)   echo 1 ;;
        DEGRADADO)  echo 2 ;;
        CRITICO)    echo 3 ;;
        *)          echo 0 ;;
    esac
}

# ---------- Barra de progreso ----------
show_progress() {
    local title="$1"
    (
        for pct in 10 25 40 60 80 95 100; do
            echo "$pct"
            sleep 0.15
        done
    ) | whiptail --gauge "$title" 8 60 0
}

# ---------- Recolectar datos del disco ----------
# Guarda resultados en variables globales para usarlos después
analyze_disk() {
    local dev="$1"

    D_DEV="$dev"
    D_MODEL=$(get_model "$dev")
    D_TYPE=$(get_disk_type "$dev")
    D_SIZE=$(lsblk -dno SIZE "$dev" 2>/dev/null)
    D_SMART_OK=$(smart_available "$dev")
    D_HEALTH=$(smart_health "$dev")

    if [[ "$D_TYPE" == "SSD NVMe" ]]; then
        # NVMe: atributos vienen con nombres textuales
        D_HOURS=$(nvme_get_field "$dev" "Power On Hours")
        D_TEMP=$(nvme_get_field "$dev" "Temperature")
        D_WEAR=$(nvme_get_field "$dev" "Percentage Used")
        D_REALLOC=""
        D_PENDING=""
        D_UNCORR=$(nvme_get_field "$dev" "Media and Data Integrity Errors")
        D_CRC=""
        # Atributos NVMe extra
        D_AVAIL_SPARE=$(nvme_get_field "$dev" "Available Spare")
        D_SPARE_THRESH=$(nvme_get_field "$dev" "Available Spare Threshold")
        D_CRIT_WARN=$(smartctl -A "$dev" 2>/dev/null | grep -i "^Critical Warning" | head -1 | sed 's/.*:[[:space:]]*//')
        D_ERR_LOG=$(nvme_get_field "$dev" "Error Information Log Entries")
    else
        # SATA/ATA
        D_HOURS=$(smart_get_raw "$dev" "9")
        D_TEMP=$(smart_get_raw "$dev" "194")
        [[ -z "$D_TEMP" ]] && D_TEMP=$(smart_get_raw "$dev" "190")
        D_REALLOC=$(smart_get_raw "$dev" "5")
        D_PENDING=$(smart_get_raw "$dev" "197")
        D_UNCORR=$(smart_get_raw "$dev" "198")
        D_CRC=$(smart_get_raw "$dev" "199")
        # Wear leveling: intento varios IDs habituales
        D_WEAR=$(smart_get_raw "$dev" "177")
        [[ -z "$D_WEAR" ]] && D_WEAR=$(smart_get_raw "$dev" "173")
        [[ -z "$D_WEAR" ]] && D_WEAR=$(smart_get_raw "$dev" "231")
    fi

    D_DISCONNECTS=$(count_disconnects "$dev")

    # Calculamos niveles
    L_REALLOC=$(level_reallocated "$D_REALLOC")
    L_PENDING=$(level_pending "$D_PENDING")
    L_UNCORR=$(level_uncorrectable "$D_UNCORR")
    L_CRC=$(level_crc "$D_CRC")
    L_TEMP=$(level_temp "$D_TEMP")
    L_WEAR=$(level_wear "$D_WEAR")
    # Niveles NVMe extra
    L_AVAIL_SPARE=$(level_avail_spare "$D_AVAIL_SPARE" "$D_SPARE_THRESH")
    L_CRIT_WARN=$(level_crit_warn "$D_CRIT_WARN")
    L_ERR_LOG=$(level_err_log "$D_ERR_LOG")

    # Si SMART no está disponible, veredicto INDETERMINADO
    if [[ "$D_SMART_OK" == "no" ]]; then
        D_VERDICT="INDETERMINADO"
        return
    fi

    # Veredicto global: peor caso
    local max_weight=0
    local all_levels=("$L_REALLOC" "$L_PENDING" "$L_UNCORR" "$L_CRC" "$L_TEMP" "$L_WEAR")
    if [[ "$D_TYPE" == "SSD NVMe" ]]; then
        all_levels+=("$L_AVAIL_SPARE" "$L_CRIT_WARN" "$L_ERR_LOG")
    fi
    for lv in "${all_levels[@]}"; do
        local w
        w=$(level_weight "$lv")
        (( w > max_weight )) && max_weight=$w
    done
    # Si health SMART reporta FAILED, forzar CRITICO
    if echo "$D_HEALTH" | grep -qi "FAIL"; then
        max_weight=3
    fi
    case $max_weight in
        0) D_VERDICT="SANO" ;;
        1) D_VERDICT="ATENCION" ;;
        2) D_VERDICT="DEGRADADO" ;;
        3) D_VERDICT="CRITICO" ;;
    esac
}

# ---------- Formateo del reporte ----------
fmt_value() {
    local val="$1"
    [[ -z "$val" ]] && echo "N/D" || echo "$val"
}

hours_to_years() {
    local h; h=$(normalize_num "$1")
    [[ -z "$h" || ! "$h" =~ ^[0-9]+$ ]] && { echo "N/D"; return; }
    awk -v h="$h" 'BEGIN { printf "%.1f años (24/7) / %.1f años (8h/día)", h/8760, h/2920 }'
}

# =============================================================================
# ANÁLISIS ALTERNATIVOS (para dispositivos sin SMART)
# =============================================================================

# Verifica que el device NO esté montado antes de un test destructivo
device_is_mounted() {
    local dev="$1"
    # Chequea el disco entero y sus particiones
    local devname
    devname=$(basename "$dev")
    lsblk -no MOUNTPOINT "$dev" 2>/dev/null | grep -v '^$' | head -1
}

# Confirmación doble para operaciones destructivas
confirm_destructive() {
    local dev="$1"
    local test_name="$2"

    if ! whiptail --title "⚠ AVISO DESTRUCTIVO ⚠" --yesno \
"El test \"$test_name\" es DESTRUCTIVO.

Se van a BORRAR TODOS LOS DATOS en $dev.

¿Ya hiciste backup de todo lo importante?" 12 60; then
        return 1
    fi

    # Verificar que no esté montado
    local mnt
    mnt=$(device_is_mounted "$dev")
    if [[ -n "$mnt" ]]; then
        whiptail --title "Error" --msgbox \
"El dispositivo $dev tiene particiones montadas en:
  $mnt

Desmontá primero con:
  sudo umount $dev*

Y volvé a intentarlo." 12 60
        return 1
    fi

    # Segunda confirmación con texto tipeado
    local answer
    answer=$(whiptail --title "Confirmación final" --inputbox \
"Última chance de cancelar.

Escribí BORRAR (en mayúsculas) para confirmar
que querés destruir los datos de $dev:" 12 60 3>&1 1>&2 2>&3)
    if [[ "$answer" != "BORRAR" ]]; then
        whiptail --title "Cancelado" --msgbox "Operación cancelada. Nada se modificó." 8 50
        return 1
    fi
    return 0
}

# Test 1: velocidad de lectura secuencial (no destructivo)
test_read_speed() {
    local dev="$1"
    clear
    echo -e "${C_BOLD}${C_BLUE}============================================${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}  TEST: Velocidad de lectura${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}  Dispositivo: $dev${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}============================================${C_RESET}"
    echo
    echo "Ejecutando hdparm -t (lectura secuencial, cache limpio)..."
    echo "Esto NO modifica ningún dato."
    echo
    local out
    out=$(hdparm -t "$dev" 2>&1)
    echo "$out"
    echo
    local mbps
    mbps=$(echo "$out" | grep -oE '[0-9.]+ MB/sec' | head -1 | awk '{print $1}')
    if [[ -n "$mbps" ]]; then
        echo -e "${C_BOLD}--- Interpretación ---${C_RESET}"
        printf "  Velocidad de lectura: %s MB/s\n" "$mbps"
        local mbps_int
        mbps_int=$(printf "%.0f" "$mbps")
        if   (( mbps_int > 400 )); then echo -e "  ${C_GREEN}Excelente (SSD SATA moderno o USB 3.x rápido)${C_RESET}"
        elif (( mbps_int > 150 )); then echo -e "  ${C_GREEN}Buena (SSD, HDD rápido o USB 3.0 decente)${C_RESET}"
        elif (( mbps_int > 80 ));  then echo -e "  ${C_YELLOW}Aceptable (HDD estándar, USB 2.0 alto)${C_RESET}"
        elif (( mbps_int > 20 ));  then echo -e "  ${C_YELLOW}Lenta (pendrive básico, USB 2.0)${C_RESET}"
        else                            echo -e "  ${C_RED}Muy lenta (posible falla o pendrive de baja calidad)${C_RESET}"
        fi
    fi
    echo
    echo -e "${C_CYAN}Presioná Enter para volver al menú...${C_RESET}"
    read -r
}

# Test 2: lectura completa con dd (no destructivo)
# Lee todo el disco a /dev/null. Reporta velocidad y errores I/O.
test_dd_read() {
    local dev="$1"
    clear
    echo -e "${C_BOLD}${C_BLUE}============================================${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}  TEST: Lectura completa (dd)${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}  Dispositivo: $dev${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}============================================${C_RESET}"
    echo
    local size_gb
    size_gb=$(lsblk -dno SIZE -b "$dev" 2>/dev/null | awk '{printf "%.1f", $1/1024/1024/1024}')
    echo "Se va a leer TODO el dispositivo ($size_gb GB) a /dev/null."
    echo "Esto NO modifica ningún dato, solo lee."
    echo
    echo "Tiempo estimado: variable según velocidad del disco."
    echo "  - Pendrive lento (10 MB/s):  ~$(awk -v s="$size_gb" 'BEGIN{printf "%d", s*100}') min"
    echo "  - SSD rápido (400 MB/s):    ~$(awk -v s="$size_gb" 'BEGIN{printf "%d", s*2.5}') min"
    echo
    echo -e "${C_YELLOW}Podés cancelar con Ctrl+C en cualquier momento.${C_RESET}"
    echo
    read -r -p "Presioná Enter para arrancar (o Ctrl+C para cancelar)..."
    echo
    echo "Leyendo... (podés ver progreso con 'kill -USR1 <pid>' en otra terminal)"
    echo
    local tmp_err
    tmp_err=$(mktemp)
    local start_ts
    start_ts=$(date +%s)
    if dd if="$dev" of=/dev/null bs=4M status=progress conv=noerror 2>"$tmp_err"; then
        local end_ts elapsed
        end_ts=$(date +%s)
        elapsed=$((end_ts - start_ts))
        echo
        echo -e "${C_BOLD}--- Resultado ---${C_RESET}"
        cat "$tmp_err" | tail -5
        echo "Tiempo total: ${elapsed}s"
        # Contar errores I/O en dmesg desde el inicio del test
        local ioerr
        ioerr=$(dmesg 2>/dev/null | grep -c "I/O error.*$(basename "$dev")" || echo 0)
        echo "Errores I/O detectados durante el test: $ioerr"
        if (( ioerr > 0 )); then
            echo -e "  ${C_RED}⚠ El disco tuvo errores de lectura reales.${C_RESET}"
        else
            echo -e "  ${C_GREEN}Sin errores de lectura.${C_RESET}"
        fi
    else
        echo
        echo -e "${C_RED}El test falló o fue interrumpido.${C_RESET}"
        cat "$tmp_err" | tail -10
    fi
    rm -f "$tmp_err"
    echo
    echo -e "${C_CYAN}Presioná Enter para volver al menú...${C_RESET}"
    read -r
}

# Test 3: badblocks no destructivo
test_badblocks_safe() {
    local dev="$1"
    clear
    echo -e "${C_BOLD}${C_BLUE}============================================${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}  TEST: Superficie no destructiva (badblocks -n)${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}  Dispositivo: $dev${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}============================================${C_RESET}"
    echo
    local mnt
    mnt=$(device_is_mounted "$dev")
    if [[ -n "$mnt" ]]; then
        echo -e "${C_RED}El dispositivo tiene particiones montadas ($mnt).${C_RESET}"
        echo "Desmontá primero con: sudo umount $dev*"
        echo
        echo -e "${C_CYAN}Presioná Enter para volver al menú...${C_RESET}"
        read -r
        return
    fi
    echo "badblocks -n hace 4 pasadas: lee el contenido original,"
    echo "escribe un patrón, verifica y restaura los datos originales."
    echo
    echo -e "${C_YELLOW}Es \"no destructivo\" en teoría pero puede fallar si el disco${C_RESET}"
    echo -e "${C_YELLOW}se apaga durante el test. Recomendamos hacer backup igual.${C_RESET}"
    echo
    echo "Tiempo: puede tardar HORAS en pendrives o discos grandes."
    echo
    if ! whiptail --title "Confirmar" --yesno \
"¿Ejecutar badblocks -n en $dev?

Puede tardar mucho tiempo. Podés cancelar con Ctrl+C." 10 60; then
        return
    fi
    clear
    echo "Ejecutando badblocks -n -v -s $dev ..."
    echo "Cancelar con Ctrl+C."
    echo
    local tmp_bb
    tmp_bb=$(mktemp)
    if badblocks -n -v -s "$dev" 2>&1 | tee "$tmp_bb"; then
        echo
        local bad_count
        bad_count=$(grep -c "^" "$tmp_bb" 2>/dev/null || echo 0)
        echo -e "${C_BOLD}--- Resultado ---${C_RESET}"
        local bad_found
        bad_found=$(grep -oE "[0-9]+ bad blocks? found" "$tmp_bb" | head -1)
        if [[ -n "$bad_found" ]]; then
            echo -e "${C_YELLOW}$bad_found${C_RESET}"
        else
            echo -e "${C_GREEN}Sin sectores dañados detectados.${C_RESET}"
        fi
    else
        echo -e "${C_RED}El test falló o fue interrumpido.${C_RESET}"
    fi
    rm -f "$tmp_bb"
    echo
    echo -e "${C_CYAN}Presioná Enter para volver al menú...${C_RESET}"
    read -r
}

# Test 4: badblocks DESTRUCTIVO
test_badblocks_destructive() {
    local dev="$1"
    if ! confirm_destructive "$dev" "badblocks -w (test destructivo con patrones)"; then
        return
    fi
    clear
    echo -e "${C_BOLD}${C_BLUE}============================================${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}  TEST: Superficie DESTRUCTIVO (badblocks -w)${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}  Dispositivo: $dev${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}============================================${C_RESET}"
    echo
    echo "Escribiendo 4 patrones (0xAA, 0x55, 0xFF, 0x00) y verificando..."
    echo "Cancelar con Ctrl+C."
    echo
    local tmp_bb
    tmp_bb=$(mktemp)
    if badblocks -w -v -s "$dev" 2>&1 | tee "$tmp_bb"; then
        echo
        echo -e "${C_BOLD}--- Resultado ---${C_RESET}"
        local bad_found
        bad_found=$(grep -oE "[0-9]+ bad blocks? found" "$tmp_bb" | head -1)
        if [[ -n "$bad_found" ]]; then
            echo -e "${C_RED}$bad_found${C_RESET}"
            echo "El dispositivo tiene sectores físicamente dañados."
        else
            echo -e "${C_GREEN}Sin sectores dañados detectados.${C_RESET}"
        fi
    else
        echo -e "${C_RED}El test falló o fue interrumpido.${C_RESET}"
    fi
    rm -f "$tmp_bb"
    echo
    echo -e "${C_YELLOW}Recordá: el dispositivo quedó sin datos y sin filesystem.${C_RESET}"
    echo -e "${C_YELLOW}Formatealo antes de usarlo (ej. mkfs.vfat, mkfs.ext4).${C_RESET}"
    echo
    echo -e "${C_CYAN}Presioná Enter para volver al menú...${C_RESET}"
    read -r
}

# Test 5: f3 (detección de pendrives falsos)
test_f3() {
    local dev="$1"
    if [[ "$HAS_F3" != "yes" ]]; then
        whiptail --title "f3 no instalado" --msgbox \
"El paquete f3 no está instalado.

Instalá con:
  sudo apt install f3

f3write y f3read detectan pendrives falsos que
mienten sobre su capacidad (típicos de mercados
online baratos)." 12 60
        return
    fi

    if ! confirm_destructive "$dev" "f3 (detección de capacidad falsa)"; then
        return
    fi

    # f3 requiere que el dispositivo tenga filesystem montado.
    # Se lo indicamos al usuario para que decida.
    whiptail --title "Preparación f3" --msgbox \
"f3write/f3read trabajan sobre un filesystem montado,
no sobre el device crudo.

Pasos manuales necesarios ANTES de continuar:

1. Formatear el dispositivo:
   sudo mkfs.vfat -I $dev

2. Montarlo en un punto conocido:
   sudo mkdir -p /mnt/f3test
   sudo mount $dev /mnt/f3test

Cuando termines los pasos, presioná Enter y
te pido el mountpoint." 18 66

    local mountpoint
    mountpoint=$(whiptail --title "Mountpoint" --inputbox \
"Ingresá el mountpoint donde montaste el dispositivo:" 10 60 "/mnt/f3test" 3>&1 1>&2 2>&3)
    if [[ -z "$mountpoint" || ! -d "$mountpoint" ]]; then
        whiptail --title "Error" --msgbox "Mountpoint inválido o no existe: $mountpoint" 8 60
        return
    fi

    clear
    echo -e "${C_BOLD}${C_BLUE}============================================${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}  TEST: Capacidad real (f3)${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}  Mountpoint: $mountpoint${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}============================================${C_RESET}"
    echo
    echo "PASO 1/2: f3write llena el dispositivo con archivos de prueba..."
    echo
    if ! f3write "$mountpoint"; then
        echo -e "${C_RED}f3write falló.${C_RESET}"
        echo -e "${C_CYAN}Presioná Enter para volver al menú...${C_RESET}"
        read -r
        return
    fi
    echo
    echo "PASO 2/2: f3read verifica los archivos escritos..."
    echo
    local tmp_f3
    tmp_f3=$(mktemp)
    if f3read "$mountpoint" 2>&1 | tee "$tmp_f3"; then
        echo
        echo -e "${C_BOLD}--- Resultado ---${C_RESET}"
        # f3read reporta "Data OK" y "Data LOST"
        local data_ok data_lost
        data_ok=$(grep -oE "Data OK: [0-9.]+ [KMGT]?Bytes" "$tmp_f3" | head -1)
        data_lost=$(grep -oE "Data LOST: [0-9.]+ [KMGT]?Bytes" "$tmp_f3" | head -1)
        echo "  $data_ok"
        echo "  $data_lost"
        if echo "$data_lost" | grep -qE "^Data LOST: 0[.]?0? "; then
            echo -e "  ${C_GREEN}✓ La capacidad real coincide con la nominal.${C_RESET}"
        else
            echo -e "  ${C_RED}⚠ Se perdieron datos → pendrive falso o defectuoso.${C_RESET}"
            echo -e "  ${C_RED}  La capacidad real es MENOR a la que reporta.${C_RESET}"
        fi
    fi
    rm -f "$tmp_f3"
    echo
    echo -e "${C_YELLOW}Recordá desmontar y limpiar:${C_RESET}"
    echo "  sudo umount $mountpoint"
    echo "  sudo rm -f $mountpoint/*.h2w"
    echo
    echo -e "${C_CYAN}Presioná Enter para volver al menú...${C_RESET}"
    read -r
}

# Submenú principal de análisis alternativos
alternative_analysis_menu() {
    local dev="$1"
    while true; do
        local f3_label
        if [[ "$HAS_F3" == "yes" ]]; then
            f3_label="[DESTRUCTIVO] Detección de capacidad falsa (f3)"
        else
            f3_label="[DESTRUCTIVO] Detección de capacidad falsa (f3) - NO INSTALADO"
        fi
        local sel
        sel=$(whiptail --title "Análisis alternativos - $dev" \
            --menu "Elegí un test (los seguros no modifican datos):" 18 72 8 \
            "1" "[Seguro]      Velocidad de lectura (hdparm)" \
            "2" "[Seguro]      Lectura completa (dd, detecta errores I/O)" \
            "3" "[Casi seguro] Test superficial (badblocks -n)" \
            "4" "[DESTRUCTIVO] Test con patrones (badblocks -w)" \
            "5" "$f3_label" \
            "b" "Volver" \
            3>&1 1>&2 2>&3)
        local rc=$?
        [[ $rc -ne 0 || "$sel" == "b" ]] && return
        case "$sel" in
            1) test_read_speed "$dev" ;;
            2) test_dd_read "$dev" ;;
            3) test_badblocks_safe "$dev" ;;
            4) test_badblocks_destructive "$dev" ;;
            5) test_f3 "$dev" ;;
        esac
    done
}

# =============================================================================
# REPORTE FORMATEADO
# =============================================================================

print_report() {
    clear
    echo -e "${C_BOLD}${C_BLUE}============================================${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}  ANÁLISIS: $D_DEV${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}============================================${C_RESET}"
    echo
    echo -e "${C_BOLD}Modelo:${C_RESET}          $D_MODEL"
    echo -e "${C_BOLD}Tipo:${C_RESET}            $D_TYPE"
    echo -e "${C_BOLD}Tamaño:${C_RESET}          $D_SIZE"

    # Caso especial: dispositivo sin soporte SMART (típico pendrives)
    if [[ "$D_SMART_OK" == "no" ]]; then
        echo -e "${C_BOLD}Soporte SMART:${C_RESET}   ${C_YELLOW}No disponible${C_RESET}"
        echo
        echo -e "${C_YELLOW}Este dispositivo no expone datos SMART, así que no${C_RESET}"
        echo -e "${C_YELLOW}se puede evaluar su salud con la controladora.${C_RESET}"
        echo
        echo -e "${C_CYAN}Causas comunes:${C_RESET}"
        echo "  - Pendrives baratos: la controladora es mínima y no"
        echo "    implementa el estándar SMART."
        echo "  - Adaptadores USB-SATA de baja calidad que no pasan"
        echo "    los comandos SMART al disco."
        echo "  - Enclosures externos con puentes que bloquean SMART."
        echo
        echo -e "${C_CYAN}Análisis alternativos disponibles:${C_RESET}"
        echo "  - Test de velocidad (hdparm) - no destructivo"
        echo "  - Test de lectura completa (dd) - no destructivo"
        echo "  - Test de superficie (badblocks) - seguro o destructivo"
        echo "  - Detección de pendrives falsos (f3) - destructivo"
        echo
        echo -e "${C_BOLD}${C_BLUE}============================================${C_RESET}"
        echo -e "${C_BOLD}${C_CYAN}  VEREDICTO: INDETERMINADO ?${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}============================================${C_RESET}"
        echo
        # Ofrecemos ir al submenú
        if whiptail --title "Análisis alternativos" --yesno \
"El dispositivo $D_DEV no expone SMART.

¿Querés ejecutar un análisis alternativo?

(Los tests seguros no modifican tus datos.
 Los destructivos piden confirmación adicional.)" 12 62; then
            alternative_analysis_menu "$D_DEV"
        fi
        return
    fi

    echo -e "${C_BOLD}Estado SMART:${C_RESET}    $(fmt_value "$D_HEALTH")"
    echo
    echo -e "${C_BOLD}--- Atributos críticos ---${C_RESET}"

    if [[ "$D_TYPE" == "SSD NVMe" ]]; then
        # NVMe: solo los atributos que este estándar realmente reporta
        printf "  %-34s %-10s %s\n" "Warning crítico (flags):"        "$(fmt_value "$D_CRIT_WARN")"    "$(color_level "$L_CRIT_WARN")"
        printf "  %-34s %-10s %s\n" "Errores de integridad de datos:" "$(fmt_value "$D_UNCORR")"       "$(color_level "$L_UNCORR")"
        printf "  %-34s %-10s %s\n" "Reserva disponible (%):"         "$(fmt_value "$D_AVAIL_SPARE")"  "$(color_level "$L_AVAIL_SPARE")"
        printf "  %-34s %-10s %s\n" "Umbral mínimo de reserva (%):"   "$(fmt_value "$D_SPARE_THRESH")" ""
        printf "  %-34s %-10s %s\n" "Entradas de log de errores:"     "$(fmt_value "$D_ERR_LOG")"      "$(color_level "$L_ERR_LOG")"
        printf "  %-34s %-10s %s\n" "Vida útil usada (%):"            "$(fmt_value "$D_WEAR")"         "$(color_level "$L_WEAR")"
        printf "  %-34s %-10s %s\n" "Temperatura (°C):"               "$(fmt_value "$D_TEMP")"         "$(color_level "$L_TEMP")"
        echo
        echo -e "  ${C_CYAN}Nota: los NVMe no exponen \"sectores reasignados/pendientes\"${C_RESET}"
        echo -e "  ${C_CYAN}como los SATA. \"Reserva disponible\" cumple ese rol: mide${C_RESET}"
        echo -e "  ${C_CYAN}cuántas celdas de reserva quedan para reemplazar celdas malas.${C_RESET}"
    else
        # SATA/HDD/SSD: la tabla clásica
        printf "  %-34s %-10s %s\n" "Sectores reasignados:"    "$(fmt_value "$D_REALLOC")"  "$(color_level "$L_REALLOC")"
        printf "  %-34s %-10s %s\n" "Sectores pendientes:"     "$(fmt_value "$D_PENDING")"  "$(color_level "$L_PENDING")"
        printf "  %-34s %-10s %s\n" "Sectores no corregibles:" "$(fmt_value "$D_UNCORR")"   "$(color_level "$L_UNCORR")"
        printf "  %-34s %-10s %s\n" "Errores CRC (cable/USB):" "$(fmt_value "$D_CRC")"      "$(color_level "$L_CRC")"
        printf "  %-34s %-10s %s\n" "Temperatura (°C):"        "$(fmt_value "$D_TEMP")"     "$(color_level "$L_TEMP")"
        # Wear leveling: solo si es SSD
        if [[ "$D_TYPE" == "SSD SATA" || "$D_TYPE" == "SSD USB" ]]; then
            printf "  %-34s %-10s %s\n" "Vida útil usada (%):" "$(fmt_value "$D_WEAR")"     "$(color_level "$L_WEAR")"
        fi
    fi
    echo
    echo -e "${C_BOLD}--- Tiempo de vida ---${C_RESET}"
    printf "  %-32s %s\n" "Horas encendido:"    "$(fmt_value "$D_HOURS")"
    printf "  %-32s %s\n" "Equivalente:"        "$(hours_to_years "$D_HOURS")"
    echo
    echo -e "${C_BOLD}--- Estabilidad eléctrica / conexión ---${C_RESET}"
    printf "  %-32s %s\n" "Desconexiones detectadas (dmesg):" "$(fmt_value "$D_DISCONNECTS")"
    if [[ "$D_DISCONNECTS" =~ ^[0-9]+$ ]] && (( D_DISCONNECTS > 0 )); then
        # Mensaje adaptado al tipo de dispositivo
        case "$D_TYPE" in
            "SSD SATA"|"HDD")
                echo -e "  ${C_YELLOW}⚠ Eventos anómalos detectados. Puede indicar cable${C_RESET}"
                echo -e "  ${C_YELLOW}  SATA suelto, puerto dañado o falla eléctrica del disco.${C_RESET}"
                ;;
            "SSD NVMe")
                echo -e "  ${C_YELLOW}⚠ Eventos anómalos detectados. Puede indicar problema${C_RESET}"
                echo -e "  ${C_YELLOW}  del slot M.2, sobrecalentamiento o firmware defectuoso.${C_RESET}"
                ;;
            "Pendrive USB"|"SSD USB"|"Disco USB")
                echo -e "  ${C_YELLOW}⚠ Eventos anómalos detectados. Puede indicar puerto USB${C_RESET}"
                echo -e "  ${C_YELLOW}  con baja corriente, cable dañado o adaptador defectuoso.${C_RESET}"
                ;;
        esac
    fi
    echo
    echo -e "${C_BOLD}${C_BLUE}============================================${C_RESET}"
    case "$D_VERDICT" in
        SANO)
            echo -e "${C_BOLD}${C_GREEN}  VEREDICTO: SANO ✓${C_RESET}"
            echo -e "${C_BOLD}${C_BLUE}============================================${C_RESET}"
            echo
            echo -e "${C_GREEN}El disco funciona normalmente. Mantené backups${C_RESET}"
            echo -e "${C_GREEN}periódicos como buena práctica.${C_RESET}"
            ;;
        ATENCION)
            echo -e "${C_BOLD}${C_YELLOW}  VEREDICTO: ATENCIÓN ⚠${C_RESET}"
            echo -e "${C_BOLD}${C_BLUE}============================================${C_RESET}"
            echo
            echo -e "${C_YELLOW}Aparecen indicios tempranos de desgaste o fallo.${C_RESET}"
            echo -e "${C_YELLOW}Acciones recomendadas:${C_RESET}"
            echo "  1. Reforzar la frecuencia de backups."
            echo "  2. Monitorear la evolución (correr discdoc periódicamente)."
            echo "  3. Si el disco tiene años, planificar reemplazo."
            ;;
        DEGRADADO)
            echo -e "${C_BOLD}${C_YELLOW}  VEREDICTO: DEGRADADO ⚠⚠${C_RESET}"
            echo -e "${C_BOLD}${C_BLUE}============================================${C_RESET}"
            echo
            echo -e "${C_YELLOW}El disco muestra deterioro serio. Todavía funciona${C_RESET}"
            echo -e "${C_YELLOW}pero está en riesgo. Acciones recomendadas:${C_RESET}"
            echo "  1. Backup COMPLETO de datos críticos ya mismo."
            echo "  2. Reducir uso intensivo (evitar escrituras masivas)."
            echo "  3. Planificar reemplazo en el corto plazo."
            ;;
        CRITICO)
            echo -e "${C_BOLD}${C_RED}  VEREDICTO: CRÍTICO 🔴${C_RESET}"
            echo -e "${C_BOLD}${C_BLUE}============================================${C_RESET}"
            echo
            echo -e "${C_RED}El disco está fallando activamente. Riesgo alto${C_RESET}"
            echo -e "${C_RED}de pérdida de datos en cualquier momento.${C_RESET}"
            echo -e "${C_RED}Acciones URGENTES:${C_RESET}"
            echo "  1. Backup INMEDIATO de todo lo importante."
            echo "  2. NO reiniciar ni forzar más escrituras."
            echo "  3. Considerar clonado con ddrescue si hay datos"
            echo "     críticos sin respaldo."
            echo "  4. Reemplazar el disco cuanto antes."
            ;;
    esac
    echo
    echo -e "${C_CYAN}Presioná Enter para volver al menú...${C_RESET}"
    read -r
}

# ---------- Info de referencia ----------
info_reallocated() {
    whiptail --title "Sectores reasignados" --msgbox \
"SECTORES REASIGNADOS (Reallocated Sector Count)

Son sectores físicos del disco que fallaron y fueron
reemplazados por sectores de reserva.

Analogía: es como una \"goma de repuesto\". El disco
tiene un stock limitado de sectores de reserva, y
cuando se agota, no puede seguir reparándose solo.

Referencia:
  - Sano:      0
  - Atención:  1 - 50
  - Degradado: 51 - 500
  - Crítico:   > 500

Cualquier valor > 0 indica que hubo daño físico
en el disco. En un SSD nuevo o HDD sano el valor
esperado es SIEMPRE 0." 22 70
}

info_pending() {
    whiptail --title "Sectores pendientes" --msgbox \
"SECTORES PENDIENTES (Current Pending Sector)

Son sectores que están fallando AHORA MISMO y
esperan ser reasignados en la próxima escritura.

A diferencia de los reasignados (que ya se
resolvieron), estos son bombas de tiempo:
contienen datos que podrían no poder leerse más.

Referencia:
  - Sano:      0
  - Atención:  1 - 10
  - Degradado: 11 - 100
  - Crítico:   > 100

Valor > 0 significa que hay pérdida de datos
en curso o inminente." 22 70
}

info_uncorrectable() {
    whiptail --title "Sectores no corregibles" --msgbox \
"SECTORES NO CORREGIBLES (Offline Uncorrectable)

Sectores donde ni siquiera el ECC (código de
corrección de errores) del disco puede recuperar
los datos.

Son PÉRDIDA TOTAL: los archivos que estaban en
esos sectores no se pueden leer más.

Referencia:
  - Sano:      0
  - Atención:  1 - 5
  - Degradado: 6 - 50
  - Crítico:   > 50

Cualquier valor > 0 implica pérdida real de
datos. Backup urgente." 22 70
}

info_hours() {
    whiptail --title "Horas encendido" --msgbox \
"HORAS ENCENDIDO (Power-On Hours)

Total de horas que el disco estuvo alimentado.
Es el mejor indicador de \"edad real\" del disco.

Vida útil esperada por tipo:

SSD SATA de consumo:
  30.000 - 50.000 h (~3-6 años 24/7)
  5-8 años uso normal (8h/día)

SSD NVMe consumo:
  20.000 - 40.000 h
  3-6 años uso normal

HDD de consumo:
  15.000 - 40.000 h (~2-5 años 24/7)
  3-5 años uso normal

HDD/SSD enterprise:
  100.000 h+ (10+ años)

Nota: la edad NO define el estado. Un disco
con 60.000 h y SMART limpio puede seguir bien;
uno con 5.000 h y sectores reasignados está mal." 26 70
}

info_wear() {
    whiptail --title "Vida útil / Wear Leveling (SSDs)" --msgbox \
"VIDA ÚTIL USADA (Wear Leveling / Percentage Used)

Solo aplica a SSDs. Mide cuánto se gastó la
memoria flash por escrituras acumuladas.

Los SSDs tienen un límite de ciclos de escritura
por celda (TBW o DWPD según fabricante). Este
atributo indica el porcentaje consumido:

  0%   = disco nuevo
  100% = fin de vida útil por escrituras

Referencia:
  - Sano:      < 70%
  - Atención:  70 - 85%
  - Degradado: 85 - 95%
  - Crítico:   > 95%

Superado el 100% el SSD suele pasar a modo
solo-lectura para proteger datos. En NVMe suele
aparecer como \"Percentage Used\"." 24 70
}

info_temp() {
    whiptail --title "Temperatura" --msgbox \
"TEMPERATURA DEL DISCO

Temperatura actual reportada por el sensor
interno del disco.

Referencia:
  - Sano:      < 45°C
  - Atención:  45 - 55°C
  - Degradado: 55 - 65°C
  - Crítico:   > 65°C

Temperaturas altas aceleran el desgaste:
  - HDD: expansión térmica de platos y cabezales
  - SSD: degradación de celdas NAND

Si un disco corre siempre caliente, revisá
ventilación del gabinete, cableado que bloquee
flujo de aire, o ubicación cercana a otras
fuentes de calor (GPU, VRM)." 22 70
}

info_crc() {
    whiptail --title "Errores CRC (proxy eléctrico)" --msgbox \
"ERRORES CRC (UDMA CRC Error Count)

Errores de integridad detectados durante la
transferencia de datos entre disco y controladora.

NO indica falla del disco en sí, sino problemas
en el CANAL de comunicación:
  - Cable SATA suelto, dañado o de mala calidad
  - Conector SATA con oxidación
  - Adaptador USB-SATA con corriente insuficiente
  - Puerto USB con voltaje inestable
  - Interferencia eléctrica

Referencia:
  - Sano:      0
  - Atención:  1 - 10
  - Degradado: 11 - 100
  - Crítico:   > 100

Solución: probar otro cable/puerto/adaptador
antes de asumir que el disco está mal.

Nota: los valores no se reinician solos, así que
errores viejos siguen contando. Un pico puntual
en el pasado puede reflejarse como crítico." 26 74
}

info_nvme_extra() {
    whiptail --title "Atributos exclusivos NVMe" --msgbox \
"ATRIBUTOS ESPECÍFICOS DE NVMe

▸ WARNING CRÍTICO (Critical Warning)
  Registro de banderas del controlador. Cada bit
  encendido es una alarma:
    bit 0: reserva bajó del umbral
    bit 1: temperatura excedida
    bit 2: confiabilidad NVM degradada (¡grave!)
    bit 3: media en modo solo lectura
    bit 4: falló backup de energía volátil
  Esperable: 0x00. Cualquier otro valor: crítico.

▸ RESERVA DISPONIBLE (Available Spare)
  Porcentaje de celdas flash de reserva que le
  quedan al SSD para reemplazar celdas dañadas.
  100 = todo intacto, 0 = agotado.
  Es el equivalente NVMe a \"sectores de reserva\"
  de los SATA.

▸ UMBRAL DE RESERVA (Available Spare Threshold)
  Valor bajo el cual el fabricante considera que
  el disco está en riesgo (típico: 10%). Si la
  reserva disponible baja de este umbral, se
  enciende el bit 0 del Critical Warning.

▸ ENTRADAS DE LOG DE ERRORES
  Cantidad total de errores fatales/críticos que
  el disco registró durante toda su vida.
  Esperable: 0 - pocos. Muchos → problema serio." 26 74
}

info_sata_vs_nvme() {
    whiptail --title "Diferencia SATA vs NVMe" --msgbox \
"¿POR QUÉ ALGUNOS ATRIBUTOS APARECEN SOLO EN SATA?

Los discos SATA (HDD y SSD) y los NVMe usan
estándares SMART completamente distintos.

En SATA/ATA los atributos son la tabla clásica
numerada por IDs (5, 9, 197, etc.) heredada de
los HDDs de los 90s.

En NVMe los atributos son textuales y adaptados
a memoria flash moderna.

Equivalencias conceptuales:

  SATA                     |  NVMe
  ─────────────────────────┼────────────────────
  Reallocated Sector Ct    |  Percentage Used
  Current Pending Sector   |  (no aplica)
  Offline Uncorrectable    |  Media and Data
                           |  Integrity Errors
  Wear Leveling            |  Percentage Used
  Power-On Hours           |  Power On Hours
  UDMA CRC Error Count     |  (no aplica igual)

Por eso en un NVMe verás \"N/D\" o directamente
no verás sectores reasignados/pendientes: no es
que el disco esté mal, es que ese concepto no
existe en su estándar." 26 74
}

info_disconnects() {
    whiptail --title "Desconexiones" --msgbox \
"DESCONEXIONES DETECTADAS

discdoc parsea el buffer del kernel (dmesg)
buscando eventos anómalos en el disco:

  - USB disconnect / reconnect
  - SATA link reset
  - Device offline / I/O error
  - Command timeouts

Causas típicas:

  ADAPTADORES USB-SATA baratos:
    - No entregan suficiente corriente al disco
    - Cable USB corto/dañado
    - Puerto USB 2.0 en lugar de 3.0

  CONEXIÓN SATA INTERNA:
    - Cable de datos suelto
    - Cable de alimentación flojo
    - Puerto SATA de la mother con problemas

  DISCO EN SÍ:
    - Falla intermitente de firmware
    - Consumo excesivo por falla de electrónica

Múltiples eventos → revisar la conexión física
antes de culpar al disco." 26 70
}

show_info_menu() {
    while true; do
        local sel
        sel=$(whiptail --title "Info de referencia" \
            --menu "¿Qué querés consultar?" 24 74 14 \
            "1"   "Sectores reasignados" \
            "2"   "Sectores pendientes" \
            "3"   "Sectores no corregibles" \
            "4"   "Horas encendido" \
            "5"   "Vida útil / Wear (SSDs)" \
            "6"   "Temperatura" \
            "7"   "Errores CRC (proxy eléctrico)" \
            "8"   "Desconexiones" \
            "9"   "Diferencia SATA vs NVMe" \
            "10"  "Atributos exclusivos NVMe" \
            "b"   "Volver al menú principal" \
            3>&1 1>&2 2>&3)
        local rc=$?
        [[ $rc -ne 0 ]] && return
        case "$sel" in
            1)  info_reallocated ;;
            2)  info_pending ;;
            3)  info_uncorrectable ;;
            4)  info_hours ;;
            5)  info_wear ;;
            6)  info_temp ;;
            7)  info_crc ;;
            8)  info_disconnects ;;
            9)  info_sata_vs_nvme ;;
            10) info_nvme_extra ;;
            b)  return ;;
        esac
    done
}

# ---------- Menú de discos ----------
disk_selection_menu() {
    local filter="$1"   # sata | nvme | usb
    local title
    case "$filter" in
        sata) title="Discos SATA (HDD/SSD) detectados" ;;
        nvme) title="Discos/memorias NVMe detectados" ;;
        usb)  title="Dispositivos USB detectados" ;;
    esac

    local raw
    raw=$(list_disks "$filter")
    if [[ -z "$raw" ]]; then
        whiptail --title "$title" --msgbox "No se detectaron dispositivos en esta categoría." 8 50
        return
    fi

    # Armamos las opciones para whiptail
    local menu_args=()
    local i=1
    local -a devs
    while IFS='|' read -r dev size tran; do
        local model
        model=$(get_model "$dev")
        local dtype
        dtype=$(get_disk_type "$dev")
        menu_args+=("$i" "$dev  $model  ($dtype, $size)")
        devs+=("$dev")
        ((i++))
    done <<< "$raw"
    menu_args+=("b" "Volver")

    local sel
    sel=$(whiptail --title "$title" \
        --menu "Elegí un disco para analizar:" 20 78 12 \
        "${menu_args[@]}" 3>&1 1>&2 2>&3)
    local rc=$?
    [[ $rc -ne 0 || "$sel" == "b" ]] && return

    local idx=$((sel - 1))
    local chosen_dev="${devs[$idx]}"

    show_progress "Analizando $chosen_dev..."
    analyze_disk "$chosen_dev"
    print_report
}

# ---------- Menú principal ----------
main_menu() {
    while true; do
        local sel
        sel=$(whiptail --title "discdoc v1.1 - Disk Health Doctor" \
            --menu "Elegí una opción:" 18 62 8 \
            "1" "Analizar discos SATA (HDD / SSD)" \
            "2" "Analizar discos / memorias NVMe" \
            "3" "Analizar dispositivos USB" \
            "4" "Info de referencia" \
            "5" "Salir" \
            3>&1 1>&2 2>&3)
        local rc=$?
        if [[ $rc -ne 0 || "$sel" == "5" ]]; then
            clear
            echo -e "${C_CYAN}Gracias por usar discdoc. Chau!${C_RESET}"
            exit 0
        fi
        case "$sel" in
            1) disk_selection_menu "sata" ;;
            2) disk_selection_menu "nvme" ;;
            3) disk_selection_menu "usb" ;;
            4) show_info_menu ;;
        esac
    done
}

# ---------- Entry point ----------
check_deps
check_root
main_menu
