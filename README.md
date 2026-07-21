# discdoc — Disk Health Doctor

Analizador interactivo de salud de discos (SSD, HDD, NVMe, USB) basado en SMART, con menús estilo TUI (whiptail) y explicación en lenguaje llano de cada atributo.

Pensado para sys admins que quieren un diagnóstico rápido en Linux sin memorizar los IDs de SMART.

## Características

- **Menú interactivo** con navegación por flechas y Enter (whiptail).
- **Detección automática** de discos SATA/HDD/SSD, discos NVMe y dispositivos USB.
- **Análisis SMART completo** con atributos críticos coloreados por severidad:
  - Discos SATA: sectores reasignados, pendientes, no corregibles, CRC, temperatura, wear.
  - Discos NVMe: critical warning flags, media integrity errors, available spare, error log entries, wear, temperatura.
- **Detección de tipo real** del dispositivo (Pendrive USB, SSD USB, Disco USB, SSD SATA, SSD NVMe, HDD).
- **Detección de desconexiones anómalas** parseando `dmesg`, con mensajes adaptados al tipo de dispositivo.
- **Veredicto global** con acciones recomendadas concretas:
  - SANO / ATENCIÓN / DEGRADADO / CRÍTICO / INDETERMINADO
- **Menú de "Info de referencia"** con explicaciones de cada atributo, umbrales y vida útil esperada por tipo de disco.
- **Análisis alternativos** para dispositivos sin SMART (típico pendrives):
  - Velocidad de lectura (hdparm) — no destructivo
  - Lectura completa (dd) — no destructivo, detecta errores I/O
  - Test de superficie (badblocks -n) — no destructivo
  - Test destructivo con patrones (badblocks -w) — con doble confirmación
  - Detección de pendrives falsos (f3) — con doble confirmación
- **Doble confirmación** en todas las operaciones destructivas (yes/no + escribir "BORRAR").
- **Output con colores ANSI** (se desactivan solos si redirigís a archivo).
- **Barra de progreso** durante el análisis.

## Requisitos

Linux (probado en Linux Mint 22.3, Ubuntu 24.04, Debian 12).

**Dependencias obligatorias:**

```bash
sudo apt install smartmontools whiptail util-linux e2fsprogs hdparm
```

**Dependencia opcional** (para detección de pendrives falsos):

```bash
sudo apt install f3
```

## Uso

Requiere root para acceder a SMART y ejecutar tests de superficie.

```bash
sudo ./discdoc.sh
```

## Menú principal

```
1. Analizar discos SATA (HDD / SSD)
2. Analizar discos / memorias NVMe
3. Analizar dispositivos USB
4. Info de referencia
5. Salir
```

## Umbrales de referencia

### SATA / SSD

| Atributo               | Sano | Atención | Degradado | Crítico |
|------------------------|------|----------|-----------|---------|
| Reallocated Sectors    | 0    | 1–50     | 51–500    | > 500   |
| Pending Sectors        | 0    | 1–10     | 11–100    | > 100   |
| Uncorrectable Sectors  | 0    | 1–5      | 6–50      | > 50    |
| CRC Errors             | 0    | 1–10     | 11–100    | > 100   |
| Temperatura (°C)       | < 45 | 45–55    | 55–65     | > 65    |
| Wear / Percentage Used | < 70%| 70–85%   | 85–95%    | > 95%   |

### NVMe

| Atributo               | Sano | Atención | Degradado | Crítico |
|------------------------|------|----------|-----------|---------|
| Critical Warning       | 0x00 | -        | -         | != 0x00 |
| Data Integrity Errors  | 0    | 1–5      | 6–50      | > 50    |
| Available Spare        | > 50%| 20–50%   | 10–20%    | < 10%   |
| Error Log Entries      | 0    | 1–10     | 11–100    | > 100   |

## Análisis alternativos (para dispositivos sin SMART)

Cuando el dispositivo no expone SMART (pendrives baratos, algunos adaptadores USB), el script ofrece un submenú de tests alternativos:

- **hdparm -t**: velocidad de lectura secuencial, sin cache.
- **dd read**: lee todo el dispositivo a /dev/null. Detecta errores I/O reales.
- **badblocks -n**: test de superficie no destructivo. Lento.
- **badblocks -w**: test destructivo con 4 patrones. Muy confiable pero **borra todo**.
- **f3 (opcional)**: detecta pendrives falsos comparando capacidad real vs nominal.

Los tests destructivos requieren:
1. Confirmación yes/no de que hiciste backup.
2. Verificación de que el dispositivo no esté montado.
3. Escribir "BORRAR" en mayúsculas para confirmar.

## Roadmap

- [ ] Modo no-interactivo con flags para cron
- [ ] Export a JSON
- [ ] Traducción a inglés
- [ ] Persistencia de histórico

## Licencia

MIT
