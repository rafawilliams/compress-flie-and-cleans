<#
.SYNOPSIS
    Comprime archivos mensualmente agrupados por fecha en el nombre o fecha de creacion.

.DESCRIPTION
    Lee un archivo config.json y por cada job definido busca archivos en las rutas
    indicadas, los agrupa por anio-mes y crea un ZIP por cada grupo.
    Nombre del ZIP: {zipPrefix}_{MMM}_{YYYY}.zip  (ej. backup_mccompletos_ENE_2026.zip)

.PARAMETER ConfigPath
    Ruta al archivo config.json. Por defecto: config.json en el mismo directorio del script.

.PARAMETER Force
    Sobrescribe ZIPs que ya existen en la ruta destino.

.PARAMETER LogToFile
    Fuerza escritura del log a archivo aunque logEnabled sea false en el config.

.EXAMPLE
    .\compress-monthly.ps1
    .\compress-monthly.ps1 -WhatIf
    .\compress-monthly.ps1 -Force -Verbose
    .\compress-monthly.ps1 -ConfigPath "D:\configs\mi-config.json" -LogToFile
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.json"),
    [switch]$Force,
    [switch]$LogToFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ----- Logging -----

$script:LogFilePath = $null
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
        Write-Host "[ERROR] No se pudo leer el config.json: $_" -ForegroundColor Red
        exit 1
    }

    # Validar settings
    if (-not $cfg.settings) {
        Write-Host "[ERROR] El config.json no tiene seccion 'settings'." -ForegroundColor Red
        exit 1
    }
    if (-not $cfg.settings.monthAbbreviations -or $cfg.settings.monthAbbreviations.Count -ne 12) {
        Write-Host "[ERROR] 'settings.monthAbbreviations' debe tener exactamente 12 entradas." -ForegroundColor Red
        exit 1
    }

    # Validar jobs
    if (-not $cfg.jobs -or $cfg.jobs.Count -eq 0) {
        Write-Host "[WARN] No hay jobs definidos en el config.json." -ForegroundColor Yellow
    }

    $requiredJobFields = @('name', 'sourcePaths', 'filePatterns', 'backupPath', 'zipPrefix', 'dateSource')
    foreach ($job in $cfg.jobs) {
        foreach ($field in $requiredJobFields) {
            if (-not $job.$field) {
                Write-Host "[ERROR] El job '$($job.name)' no tiene el campo requerido '$field'." -ForegroundColor Red
                exit 1
            }
        }
        if ($job.dateSource -eq 'filename' -and -not $job.filenameDateRegex) {
            Write-Host "[ERROR] El job '$($job.name)' usa dateSource='filename' pero no tiene 'filenameDateRegex'." -ForegroundColor Red
            exit 1
        }
    }

    return $cfg
}

#endregion

#region ----- Utiles -----

function Convert-GlobToRegex {
    param([string]$Pattern)
    # Escapa metacaracteres regex excepto * y ?
    $escaped = [regex]::Escape($Pattern)
    # Restaura * y ? como wildcards
    $escaped = $escaped -replace '\\\*', '.*'
    $escaped = $escaped -replace '\\\?', '.'
    return "^$escaped$"
}

function Get-FileDateKey {
    param(
        [System.IO.FileInfo]$File,
        [PSCustomObject]$Job,
        [string[]]$MonthAbbreviations
    )

    $year  = $null
    $month = $null

    if ($Job.dateSource -eq 'filename') {
        if ($File.Name -match $Job.filenameDateRegex) {
            $year  = [int]$Matches[1]
            $month = [int]$Matches[2]
        } else {
            Write-Log "Omitiendo '$($File.Name)' — el nombre no coincide con el regex de fecha." -Level WARN
            return $null
        }
    } elseif ($Job.dateSource -eq 'creationDate') {
        $year  = $File.CreationTime.Year
        $month = $File.CreationTime.Month
    } else {
        Write-Log "dateSource invalido '$($Job.dateSource)' en job '$($Job.name)'." -Level ERROR
        return $null
    }

    if ($month -lt 1 -or $month -gt 12) {
        Write-Log "Mes invalido ($month) para '$($File.Name)'. Omitiendo." -Level WARN
        return $null
    }

    $monthAbbr = $MonthAbbreviations[$month - 1]

    return [PSCustomObject]@{
        Year       = $year
        Month      = $month
        MonthAbbr  = $monthAbbr
        Key        = "$year-$($month.ToString('D2'))"
    }
}

#endregion

#region ----- Compresion -----

function Invoke-CompressionJob {
    param(
        [PSCustomObject]$Job,
        [PSCustomObject]$Settings
    )

    Write-Log "=== Iniciando job: $($Job.name) ===" -Level INFO

    # Crear backupPath si no existe
    if (-not (Test-Path $Job.backupPath)) {
        if ($PSCmdlet.ShouldProcess($Job.backupPath, 'Crear directorio de backup')) {
            try {
                New-Item -ItemType Directory -Path $Job.backupPath -Force | Out-Null
                Write-Log "Directorio de backup creado: $($Job.backupPath)" -Level INFO
            } catch {
                Write-Log "No se pudo crear el directorio de backup '$($Job.backupPath)': $_" -Level ERROR
                return
            }
        }
    }

    # Recopilar archivos de todas las rutas y patrones
    $allFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($sourcePath in $Job.sourcePaths) {
        if (-not (Test-Path $sourcePath)) {
            Write-Log "Ruta de origen no encontrada, se omite: '$sourcePath'" -Level WARN
            continue
        }

        $sourceFiles = Get-ChildItem -Path $sourcePath -File -ErrorAction SilentlyContinue

        foreach ($pattern in $Job.filePatterns) {
            $regex = Convert-GlobToRegex -Pattern $pattern
            foreach ($file in $sourceFiles) {
                if ($file.Name -match $regex) {
                    if ($seenPaths.Add($file.FullName)) {
                        $allFiles.Add($file)
                    }
                }
            }
        }
    }

    if ($allFiles.Count -eq 0) {
        Write-Log "No se encontraron archivos para el job '$($Job.name)'." -Level INFO
        return
    }

    Write-Log "Archivos encontrados: $($allFiles.Count)" -Level INFO

    # Determinar clave de fecha para cada archivo y agrupar
    $groups = @{}
    $groupMeta = @{}

    foreach ($file in $allFiles) {
        $dateKey = Get-FileDateKey -File $file -Job $Job -MonthAbbreviations $Settings.monthAbbreviations
        if ($null -eq $dateKey) { continue }

        if (-not $groups.ContainsKey($dateKey.Key)) {
            $groups[$dateKey.Key] = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
            $groupMeta[$dateKey.Key] = $dateKey
        }
        $groups[$dateKey.Key].Add($file)
    }

    if ($groups.Count -eq 0) {
        Write-Log "Ningun archivo con fecha valida para el job '$($Job.name)'." -Level WARN
        return
    }

    $createdCount = 0
    $skippedCount = 0

    # Procesar cada grupo ordenado cronologicamente
    foreach ($key in ($groups.Keys | Sort-Object)) {
        $meta      = $groupMeta[$key]
        $files     = $groups[$key]
        $zipName   = "$($Job.zipPrefix)_$($meta.MonthAbbr)_$($meta.Year).zip"
        $zipPath   = Join-Path $Job.backupPath $zipName

        Write-Log "Grupo $key ($($meta.MonthAbbr) $($meta.Year)): $($files.Count) archivo(s) → $zipName" -Level DEBUG

        if (Test-Path $zipPath) {
            if (-not $Force) {
                Write-Log "ZIP ya existe, se omite (use -Force para sobrescribir): $zipName" -Level INFO
                $skippedCount++
                continue
            }
            Write-Log "Sobrescribiendo ZIP existente: $zipName" -Level INFO
        }

        if ($PSCmdlet.ShouldProcess($zipPath, "Crear ZIP con $($files.Count) archivo(s)")) {
            $tempDir = Join-Path $env:TEMP "compress-monthly_$([System.Guid]::NewGuid().ToString('N'))"

            try {
                New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

                # Copiar archivos al directorio temporal (resolver colisiones de nombre)
                $nameCounts = @{}
                foreach ($file in $files) {
                    $destName = $file.Name
                    if ($nameCounts.ContainsKey($file.Name)) {
                        $nameCounts[$file.Name]++
                        $base = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                        $ext  = $file.Extension
                        $destName = "${base}_$($nameCounts[$file.Name])${ext}"
                    } else {
                        $nameCounts[$file.Name] = 0
                    }
                    Copy-Item -Path $file.FullName -Destination (Join-Path $tempDir $destName) -Force
                    Write-Log "  + $($file.FullName)" -Level DEBUG
                }

                # Comprimir
                if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
                Compress-Archive -Path "$tempDir\*" -DestinationPath $zipPath -ErrorAction Stop

                Write-Log "Creado: $zipName ($($files.Count) archivos)" -Level SUCCESS
                $createdCount++

            } catch {
                Write-Log "Error al crear '${zipName}': $_" -Level ERROR
            } finally {
                if (Test-Path $tempDir) {
                    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    Write-Log "Job '$($Job.name)' finalizado — ZIPs creados: $createdCount, omitidos: $skippedCount" -Level INFO
}

#endregion

#region ----- Main -----

function Invoke-Main {
    Write-Log "compress-monthly.ps1 iniciado — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level INFO
    Write-Log "Config: $ConfigPath" -Level DEBUG

    $config = Get-Config -Path $ConfigPath

    # Inicializar log a archivo
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
            Invoke-CompressionJob -Job $job -Settings $config.settings
        } catch {
            Write-Log "Error inesperado en job '$($job.name)': $_" -Level ERROR
        }
    }

    Write-Log "compress-monthly.ps1 completado." -Level INFO
}

Invoke-Main

#endregion
