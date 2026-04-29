# PowerShell — Compresión y Organización de Archivos

Scripts PowerShell para comprimir archivos mensualmente en ZIPs y organizar archivos en una estructura de carpetas por fecha.

---

## Scripts

| Script | Config | Descripción |
|--------|--------|-------------|
| `compress-monthly.ps1` | `config.json` | Agrupa archivos por mes y los comprime en ZIPs |
| `cleanup-compressed.ps1` | `config.json` | Elimina los archivos de origen que ya tienen ZIP de respaldo |
| `organizar-archivos.ps1` | `organizar-config.json` | Mueve archivos a carpetas `YYYY\YYYYMMDD\` según la fecha en el nombre |

---

## compress-monthly.ps1

Busca archivos en las rutas definidas, los agrupa por año-mes y crea un ZIP por grupo.

**Nombre del ZIP:** `{zipPrefix}_{MMM}_{YYYY}.zip`  
Ejemplo: `backup_mccompletos_ABR_2026.zip`

### Uso

```powershell
.\compress-monthly.ps1
.\compress-monthly.ps1 -WhatIf                                      # previsualiza sin comprimir
.\compress-monthly.ps1 -Force                                       # sobreescribe ZIPs existentes
.\compress-monthly.ps1 -ConfigPath "D:\configs\mi-config.json"
.\compress-monthly.ps1 -LogToFile                                   # fuerza escritura de log
```

### config.json

```json
{
  "settings": {
    "logFile": "C:\\logs\\compress-monthly.log",
    "logEnabled": true,
    "monthAbbreviations": ["ENE","FEB","MAR","ABR","MAY","JUN","JUL","AGO","SEP","OCT","NOV","DIC"]
  },
  "jobs": [
    {
      "name": "MC Completos",
      "enabled": true,
      "sourcePaths": ["D:\\datos\\mc\\completos"],
      "filePatterns": ["completoMC_*.txt"],
      "backupPath": "D:\\backups\\mc_completos",
      "zipPrefix": "backup_mccompletos",
      "dateSource": "filename",
      "filenameDateRegex": "_(\\d{4})(\\d{2})\\d{2}\\."
    }
  ]
}
```

**Campos del job:**

| Campo | Requerido | Descripción |
|-------|-----------|-------------|
| `name` | Sí | Nombre identificador del job |
| `enabled` | Sí | `true` para activar, `false` para omitir |
| `sourcePaths` | Sí | Lista de carpetas de origen |
| `filePatterns` | Sí | Patrones glob de archivos (`*.txt`, `reporte_*.csv`) |
| `backupPath` | Sí | Carpeta donde se guardan los ZIPs |
| `zipPrefix` | Sí | Prefijo del nombre del ZIP |
| `dateSource` | Sí | `"filename"` extrae la fecha del nombre; `"creationDate"` usa la fecha de creación del archivo |
| `filenameDateRegex` | Si `dateSource=filename` | Regex con grupos 1=año, 2=mes |

---

## cleanup-compressed.ps1

Elimina los archivos de origen **solo si existe el ZIP de respaldo correspondiente**. Nunca borra sin verificar el backup.

### Uso

```powershell
.\cleanup-compressed.ps1
.\cleanup-compressed.ps1 -WhatIf    # previsualiza qué se borraría
.\cleanup-compressed.ps1 -Force     # omite confirmación por archivo
```

Usa el mismo `config.json` que `compress-monthly.ps1`.

---

## organizar-archivos.ps1

Mueve archivos de una carpeta de origen a una estructura `destPath\YYYY\YYYYMMDD\` extrayendo la fecha del nombre del archivo.

### Patrones de fecha soportados

Los patrones se evalúan en este orden de prioridad:

| Nombre del archivo | Ejemplo | Carpeta destino |
|--------------------|---------|-----------------|
| `archivo_YYYYMMDD_HHMM.ext` | `reporte_20260429_1430.txt` | `2026\20260429\` |
| `archivo_YYYYMMDD.ext` | `reporte_20260429.txt` | `2026\20260429\` |
| `archivo_YYYY-MM-DD.ext` | `reporte_2026-04-29.txt` | `2026\20260429\` |
| Sin fecha (`T140*.txt`, etc.) | `T14098765432.txt` | Carpeta de ayer (T-1) si `fallbackToYesterday: true` |

### Uso

```powershell
.\organizar-archivos.ps1
.\organizar-archivos.ps1 -WhatIf                                      # previsualiza sin mover
.\organizar-archivos.ps1 -Force                                       # sobreescribe si el archivo ya existe en destino
.\organizar-archivos.ps1 -ConfigPath "D:\configs\organizar-config.json"
.\organizar-archivos.ps1 -LogToFile                                   # fuerza escritura de log
```

### organizar-config.json

```json
{
  "settings": {
    "logFile": "C:\\logs\\organizar-archivos.log",
    "logEnabled": false
  },
  "jobs": [
    {
      "name": "Ejemplo Job",
      "enabled": true,
      "sourcePath": "D:\\datos\\entrada",
      "destPath": "D:\\datos\\organizado",
      "filePatterns": [
        { "pattern": "archivox_*.txt", "useYesterday": true  },
        { "pattern": "archivoy_*.txt", "useYesterday": true  },
        { "pattern": "archivoz_*.txt", "useYesterday": false }
      ],
      "fallbackToYesterday": true
    }
  ]
}
```

**Campos del job:**

| Campo | Requerido | Descripción |
|-------|-----------|-------------|
| `name` | Sí | Nombre identificador del job |
| `enabled` | Sí | `true` para activar, `false` para omitir |
| `sourcePath` | Sí | Carpeta de origen |
| `destPath` | Sí | Carpeta raíz de destino (se crean subcarpetas automáticamente) |
| `filePatterns` | Sí | Lista de patrones (ver abajo) |
| `fallbackToYesterday` | No | `true` para mover archivos sin fecha a la carpeta de ayer; `false` para omitirlos (default: `true`) |

**Formato de `filePatterns`:**

Cada entrada puede ser un string simple o un objeto con `useYesterday`:

```json
"filePatterns": [
  "*.csv",
  { "pattern": "archivox_*.txt", "useYesterday": false },
  { "pattern": "archivoy_*.txt", "useYesterday": true  }
]
```

| Propiedad | Descripción |
|-----------|-------------|
| `pattern` | Patrón glob del nombre del archivo |
| `useYesterday` | `true`: usa la fecha de ayer aunque el nombre tenga fecha; `false` (default): extrae la fecha del nombre |

---

## Flujo recomendado

```
1. organizar-archivos.ps1   →  ordena los archivos en YYYY\YYYYMMDD\
2. compress-monthly.ps1     →  comprime cada mes en un ZIP
3. cleanup-compressed.ps1   →  elimina los originales con backup confirmado
```

---

## Requisitos

- Windows PowerShell 5.1 o PowerShell 7+
- Permisos de lectura/escritura en las rutas de origen y destino
