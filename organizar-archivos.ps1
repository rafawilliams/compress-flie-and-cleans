<#
.SYNOPSIS
    Organiza archivos en una estructura de carpetas YYYY\YYYYMMDD\ segun la fecha en el nombre.

.DESCRIPTION
    Lee un archivo organizar-config.json y por cada job definido mueve los archivos de
    sourcePath a destPath\YYYY\YYYYMMDD\ extrayendo la fecha del nombre del archivo.

    Patrones de fecha soportados (en orden de prioridad):
      archivo_YYYYMMDD_HHMM.ext   →  extrae YYYYMMDD
      archivo_YYYYMMDD.ext        →  extrae YYYYMMDD
      archivo_YYYY-MM-DD.ext      →  extrae YYYY-MM-DD
      cualquier otro nombre       →  usa fecha de ayer (t-1) si fallbackToYesterday=true

.PARAMETER ConfigPath
    Ruta al archivo organizar-config.json. Por defecto: organizar-config.json en el mismo
    directorio del script.

.PARAMETER Force
    Sobreescribe archivos que ya existen en la carpeta destino sin confirmacion.

.PARAMETER LogToFile
    Fuerza escritura del log a archivo aunque logEnabled sea false en el config.

.EXAMPLE
    .\organizar-archivos.ps1
    .\organizar-archivos.ps1 -WhatIf
    .\organizar-archivos.ps1 -Force
    .\organizar-archivos.ps1 -ConfigPath "D:\configs\mi-config.json" -LogToFile
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "organizar-config.json"),
    [switch]$Force,
    [switch]$LogToFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ----- Logging -----

$script:LogFilePath    = $null
$script:LogFileEnabled = $false

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'DEBUG')]
        [string]$Level = 'INFO'
    )

    $colors = @{
        INFO    = 'Cyan'
        WARN    = 'Yellow'
        ERROR   = 'Red'
        SUCCESS = 'Green'
        DEBUG   = 'Gray'
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $levelPad  = $Level.PadRight(7)
    $line      = "[$timestamp] [$levelPad] $Message"

    if ($Level -eq 'DEBUG') {
        Write-Verbose $line
    } else {
        Write-Host $line -ForegroundColor $colors[$Level]
    }

    if ($script:LogFileEnabled -and $script:LogFilePath) {
        try {
            Add-Content -Path $script:LogFilePath -Value $line -Encoding UTF8
        } catch {
            Write-Host "[LOG-WRITE-ERROR] No se pudo escribir en el log: $_" -ForegroundColor Red
        }
    }
}

#endregion

#region ----- Configuracion -----

function Get-Config {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Host "[ERROR] Archivo de configuracion no encontrado: $Path" -ForegroundColor Red
        exit 1
    }

    try {
        $raw = Get-Content -Path $Path -Raw -Encoding UTF8
        $cfg = $raw | ConvertFrom-Json
    } catch {
        Write-Host "[ERROR] No se pudo leer el config JSON: $_" -ForegroundColor Red
        exit 1
    }

    if (-not $cfg.settings) {
        Write-Host "[ERROR] El config no tiene seccion 'settings'." -ForegroundColor Red
        exit 1
    }

    if (-not $cfg.jobs -or $cfg.jobs.Count -eq 0) {
        Write-Host "[WARN] No hay jobs definidos en el config." -ForegroundColor Yellow
    }

    $requiredJobFields = @('name', 'sourcePath', 'destPath', 'filePatterns')
    foreach ($job in $cfg.jobs) {
        foreach ($field in $requiredJobFields) {
            if (-not $job.$field) {
                Write-Host "[ERROR] El job '$($job.name)' no tiene el campo requerido '$field'." -ForegroundColor Red
                exit 1
            }
        }
    }

    return $cfg
}

#endregion

#region ----- Utiles -----

function Convert-GlobToRegex {
    param([string]$Pattern)
    $escaped = [regex]::Escape($Pattern)
    $escaped = $escaped -replace '\\\*', '.*'
    $escaped = $escaped -replace '\\\?', '.'
    return "^$escaped$"
}

# Patrones de fecha probados en orden de especificidad (mas especifico primero)
$script:DatePatterns = @(
    # archivo_YYYYMMDD_HHMM.ext
    [regex]'_(\d{4})(\d{2})(\d{2})_\d{4}\.',
    # archivo_YYYYMMDD.ext
    [regex]'_(\d{4})(\d{2})(\d{2})\.',
    # archivo_YYYY-MM-DD.ext
    [regex]'_(\d{4})-(\d{2})-(\d{2})\.'
)

function Get-DateFromFilename {
    param(
        [string]$FileName,
        [bool]$FallbackToYesterday,
        [bool]$UseYesterday = $false
    )

    # Si el patron tiene useYesterday=true, ignorar la fecha del nombre
    if ($UseYesterday) {
        $yesterday = (Get-Date).AddDays(-1)
        return [PSCustomObject]@{
            Year   = $yesterday.Year
            Month  = $yesterday.Month
            Day    = $yesterday.Day
            Source = 'yesterday'
        }
    }

    foreach ($pattern in $script:DatePatterns) {
        $m = $pattern.Match($FileName)
        if ($m.Success) {
            $year  = [int]$m.Groups[1].Value
            $month = [int]$m.Groups[2].Value
            $day   = [int]$m.Groups[3].Value

            # Validacion basica de rango
            if ($month -ge 1 -and $month -le 12 -and $day -ge 1 -and $day -le 31) {
                return [PSCustomObject]@{
                    Year   = $year
                    Month  = $month
                    Day    = $day
                    Source = 'filename'
                }
            }
        }
    }

    if ($FallbackToYesterday) {
        $yesterday = (Get-Date).AddDays(-1)
        return [PSCustomObject]@{
            Year   = $yesterday.Year
            Month  = $yesterday.Month
            Day    = $yesterday.Day
            Source = 'fallback'
        }
    }

    return $null
}

function Get-UniqueDestPath {
    param(
        [string]$FolderPath,
        [string]$FileName
    )

    $destPath = Join-Path $FolderPath $FileName
    if (-not (Test-Path $destPath)) { return $destPath }

    $base    = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $ext     = [System.IO.Path]::GetExtension($FileName)
    $counter = 2

    do {
        $destPath = Join-Path $FolderPath "${base}_${counter}${ext}"
        $counter++
    } while ((Test-Path $destPath))

    return $destPath
}

#endregion

#region ----- Organizacion -----

function Invoke-OrganizeJob {
    param([PSCustomObject]$Job)

    Write-Log "=== Iniciando job: $($Job.name) ===" -Level INFO

    if (-not (Test-Path $Job.sourcePath)) {
        Write-Log "Ruta de origen no encontrada: '$($Job.sourcePath)'" -Level ERROR
        return
    }

    $fallback = if ($null -ne $Job.fallbackToYesterday) { [bool]$Job.fallbackToYesterday } else { $true }

    # Recopilar archivos que coinciden con los patrones
    # Cada entrada guarda el archivo y si debe usar t-1 segun su patron
    $sourceFiles = Get-ChildItem -Path $Job.sourcePath -File -ErrorAction SilentlyContinue
    $matched   = [System.Collections.Generic.List[PSCustomObject]]::new()
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($patternEntry in $Job.filePatterns) {
        # Soporta string simple "*.txt" o objeto { pattern, useYesterday }
        if ($patternEntry -is [string]) {
            $globPattern  = $patternEntry
            $useYesterday = $false
        } else {
            $globPattern  = $patternEntry.pattern
            $useYesterday = if ($null -ne $patternEntry.useYesterday) { [bool]$patternEntry.useYesterday } else { $false }
        }

        $regex = Convert-GlobToRegex -Pattern $globPattern
        foreach ($file in $sourceFiles) {
            if ($file.Name -match $regex -and $seenPaths.Add($file.FullName)) {
                $matched.Add([PSCustomObject]@{ File = $file; UseYesterday = $useYesterday })
            }
        }
    }

    if ($matched.Count -eq 0) {
        Write-Log "No se encontraron archivos para el job '$($Job.name)'." -Level INFO
        return
    }

    Write-Log "Archivos encontrados: $($matched.Count)" -Level INFO

    $movedCount   = 0
    $skippedCount = 0
    $errorCount   = 0

    foreach ($entry in $matched) {
        $file     = $entry.File
        $dateInfo = Get-DateFromFilename -FileName $file.Name -FallbackToYesterday $fallback -UseYesterday $entry.UseYesterday

        if ($null -eq $dateInfo) {
            Write-Log "Sin fecha y fallback desactivado, omitiendo: '$($file.Name)'" -Level WARN
            $skippedCount++
            continue
        }

        $yyyy       = $dateInfo.Year.ToString()
        $yyyymmdd   = '{0}{1:D2}{2:D2}' -f $dateInfo.Year, $dateInfo.Month, $dateInfo.Day
        $destFolder = Join-Path $Job.destPath $yyyy $yyyymmdd

        if ($dateInfo.Source -eq 'yesterday') {
            Write-Log "useYesterday=true en patron, usando t-1 ($yyyymmdd): '$($file.Name)'" -Level DEBUG
        } elseif ($dateInfo.Source -eq 'fallback') {
            Write-Log "Sin fecha en nombre, usando t-1 ($yyyymmdd): '$($file.Name)'" -Level DEBUG
        }

        # Crear estructura de carpetas si no existe
        if (-not (Test-Path $destFolder)) {
            if ($PSCmdlet.ShouldProcess($destFolder, 'Crear carpeta')) {
                try {
                    New-Item -ItemType Directory -Path $destFolder -Force | Out-Null
                    Write-Log "Carpeta creada: $destFolder" -Level DEBUG
                } catch {
                    Write-Log "No se pudo crear la carpeta '$destFolder': $_" -Level ERROR
                    $errorCount++
                    continue
                }
            }
        }

        $destPath = if ($Force) {
            Join-Path $destFolder $file.Name
        } else {
            Get-UniqueDestPath -FolderPath $destFolder -FileName $file.Name
        }

        if ($PSCmdlet.ShouldProcess($file.FullName, "Mover a $destPath")) {
            try {
                Move-Item -Path $file.FullName -Destination $destPath -Force:$Force -ErrorAction Stop
                Write-Log "Movido: $($file.Name) → $destFolder\" -Level SUCCESS
                $movedCount++
            } catch {
                Write-Log "Error al mover '$($file.Name)': $_" -Level ERROR
                $errorCount++
            }
        }
    }

    Write-Log "Job '$($Job.name)' finalizado — movidos: $movedCount, omitidos: $skippedCount, errores: $errorCount" -Level INFO
}

#endregion

#region ----- Main -----

function Invoke-Main {
    Write-Log "organizar-archivos.ps1 iniciado — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level INFO
    Write-Log "Config: $ConfigPath" -Level DEBUG

    $config = Get-Config -Path $ConfigPath

    $script:LogFileEnabled = $config.settings.logEnabled -or $LogToFile
    $script:LogFilePath    = $config.settings.logFile

    if ($script:LogFileEnabled -and $script:LogFilePath) {
        $logDir = Split-Path $script:LogFilePath -Parent
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
    }

    $enabledJobs = @($config.jobs | Where-Object { $_.enabled -ne $false })
    Write-Log "Jobs habilitados: $($enabledJobs.Count)" -Level INFO

    foreach ($job in $enabledJobs) {
        try {
            Invoke-OrganizeJob -Job $job
        } catch {
            Write-Log "Error inesperado en job '$($job.name)': $_" -Level ERROR
        }
    }

    Write-Log "organizar-archivos.ps1 completado." -Level INFO
}

Invoke-Main

#endregion
