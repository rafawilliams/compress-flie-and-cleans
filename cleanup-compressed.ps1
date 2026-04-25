<#
.SYNOPSIS
    Elimina archivos de origen que ya fueron comprimidos en un ZIP mensual.

.DESCRIPTION
    Lee el mismo config.json que compress-monthly.ps1. Por cada archivo en las
    rutas de origen, determina su ZIP correspondiente ({zipPrefix}_{MMM}_{YYYY}.zip)
    y, si ese ZIP existe en backupPath, elimina el archivo original.
    Solo elimina archivos cuyo ZIP ya existe — nunca elimina si el ZIP falta.

.PARAMETER ConfigPath
    Ruta al config.json. Por defecto: config.json en el mismo directorio del script.

.PARAMETER Force
    Elimina sin pedir confirmacion individual por archivo.

.EXAMPLE
    .\cleanup-compressed.ps1 -WhatIf
    .\cleanup-compressed.ps1 -Force
    .\cleanup-compressed.ps1 -ConfigPath "D:\configs\mi-config.json" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.json"),
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
        Write-Host "[ERROR] No se pudo leer el config.json: $_" -ForegroundColor Red
        exit 1
    }

    if (-not $cfg.settings -or -not $cfg.settings.monthAbbreviations -or
        $cfg.settings.monthAbbreviations.Count -ne 12) {
        Write-Host "[ERROR] config.json invalido: falta 'settings.monthAbbreviations' con 12 entradas." -ForegroundColor Red
        exit 1
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
            Write-Log "Sin coincidencia de fecha en nombre: '$($File.Name)' — omitiendo." -Level WARN
            return $null
        }
    } elseif ($Job.dateSource -eq 'creationDate') {
        $year  = $File.CreationTime.Year
        $month = $File.CreationTime.Month
    } else {
        Write-Log "dateSource invalido '$($Job.dateSource)'." -Level ERROR
        return $null
    }

    if ($month -lt 1 -or $month -gt 12) {
        Write-Log "Mes invalido ($month) para '$($File.Name)'. Omitiendo." -Level WARN
        return $null
    }

    return [PSCustomObject]@{
        Year      = $year
        Month     = $month
        MonthAbbr = $MonthAbbreviations[$month - 1]
        Key       = "$year-$($month.ToString('D2'))"
    }
}

#endregion

#region ----- Limpieza -----

function Invoke-CleanupJob {
    param(
        [PSCustomObject]$Job,
        [PSCustomObject]$Settings
    )

    Write-Log "=== Iniciando limpieza: $($Job.name) ===" -Level INFO

    if (-not (Test-Path $Job.backupPath)) {
        Write-Log "backupPath no existe, no hay ZIPs que verificar: '$($Job.backupPath)'" -Level WARN
        return
    }

    # Recopilar archivos de origen
    $allFiles  = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
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
        Write-Log "No se encontraron archivos de origen para el job '$($Job.name)'." -Level INFO
        return
    }

    Write-Log "Archivos de origen encontrados: $($allFiles.Count)" -Level INFO

    $deletedCount  = 0
    $skippedCount  = 0
    $noZipCount    = 0

    foreach ($file in $allFiles) {
        $dateKey = Get-FileDateKey -File $file -Job $Job -MonthAbbreviations $Settings.monthAbbreviations
        if ($null -eq $dateKey) {
            $skippedCount++
            continue
        }

        $zipName = "$($Job.zipPrefix)_$($dateKey.MonthAbbr)_$($dateKey.Year).zip"
        $zipPath = Join-Path $Job.backupPath $zipName

        if (-not (Test-Path $zipPath)) {
            Write-Log "ZIP no existe, no se elimina: '$($file.Name)' (esperaba $zipName)" -Level DEBUG
            $noZipCount++
            continue
        }

        # Confirmar y eliminar
        $confirmMsg = "Eliminar '$($file.FullName)' (comprimido en $zipName)"

        if ($Force) {
            $shouldDelete = $PSCmdlet.ShouldProcess($file.FullName, 'Eliminar archivo ya comprimido')
        } else {
            $shouldDelete = $PSCmdlet.ShouldProcess($file.FullName, 'Eliminar archivo ya comprimido')
        }

        if ($shouldDelete) {
            try {
                Remove-Item -Path $file.FullName -Force
                Write-Log "Eliminado: $($file.FullName)  [$zipName]" -Level SUCCESS
                $deletedCount++
            } catch {
                Write-Log "Error al eliminar '$($file.FullName)': $_" -Level ERROR
            }
        }
    }

    Write-Log ("Job '$($Job.name)' finalizado — " +
               "Eliminados: $deletedCount | " +
               "Sin ZIP (no eliminados): $noZipCount | " +
               "Omitidos (sin fecha): $skippedCount") -Level INFO
}

#endregion

#region ----- Main -----

function Invoke-Main {
    Write-Log "cleanup-compressed.ps1 iniciado — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level INFO

    $config = Get-Config -Path $ConfigPath

    $script:LogFileEnabled = $config.settings.logEnabled -or $LogToFile
    $script:LogFilePath    = $config.settings.logFile

    if ($script:LogFileEnabled -and $script:LogFilePath) {
        $logDir = Split-Path $script:LogFilePath -Parent
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
    }

    if (-not $Force -and -not $WhatIfPreference) {
        Write-Host ""
        Write-Host "ATENCION: Este script elimina archivos originales que ya estan en un ZIP." -ForegroundColor Yellow
        Write-Host "Use -WhatIf para ver que se eliminaria sin borrar nada." -ForegroundColor Yellow
        Write-Host "Use -Force para omitir la confirmacion por archivo." -ForegroundColor Yellow
        Write-Host ""
    }

    $enabledJobs = @($config.jobs | Where-Object { $_.enabled -ne $false })
    Write-Log "Jobs habilitados: $($enabledJobs.Count)" -Level INFO

    foreach ($job in $enabledJobs) {
        try {
            Invoke-CleanupJob -Job $job -Settings $config.settings
        } catch {
            Write-Log "Error inesperado en job '$($job.name)': $_" -Level ERROR
        }
    }

    Write-Log "cleanup-compressed.ps1 completado." -Level INFO
}

Invoke-Main

#endregion
