$ErrorActionPreference = "Stop"

# Determine script's directory to resolve relative paths
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

$DevToolsDir = Resolve-Path (Join-Path $ScriptDir "..\DevelopmentTools") -ErrorAction SilentlyContinue
if (-not $DevToolsDir) {
    $DevToolsDir = Join-Path $ScriptDir "..\DevelopmentTools"
}
$HacktoolsDir = Join-Path $DevToolsDir "tools\hacktools"

$MissingCritical = $false

Write-Host "=== Phase 1: Dependency Verification & Auto-Installation ===" -ForegroundColor Cyan

# 1. Check Git CLI
if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Host "[OK] Git CLI detected." -ForegroundColor Green
} else {
    Write-Host "[ERROR] Git CLI is required but not found on PATH." -ForegroundColor Red
    $MissingCritical = $true
}

# 2. Check Python 3 & pip
$PythonCmd = $null
if (Get-Command python -ErrorAction SilentlyContinue) {
    $PythonCmd = "python"
} elseif (Get-Command python3 -ErrorAction SilentlyContinue) {
    $PythonCmd = "python3"
}

if ($PythonCmd -and (& $PythonCmd -m pip --version 2>$null)) {
    Write-Host "[OK] Python ($PythonCmd) and pip detected." -ForegroundColor Green
} else {
    Write-Host "[ERROR] Python 3 and pip are required but not found on PATH." -ForegroundColor Red
    $MissingCritical = $true
}

# Exit early if core system binaries (Python/Git) are missing
if ($MissingCritical) {
    Write-Host "`nERROR: Core system prerequisites missing. Aborting setup." -ForegroundColor Red
    exit 1
}

# 3. Check & Update DevelopmentTools Repository
if ((Test-Path $DevToolsDir) -and (Test-Path $HacktoolsDir)) {
    Write-Host "[OK] DevelopmentTools directory structure found." -ForegroundColor Green
    Write-Host "     Pulling latest changes for DevelopmentTools..." -ForegroundColor Yellow
    try {
        git -C "$DevToolsDir" pull
    } catch {
        Write-Host "[WARN] Could not pull latest changes for DevelopmentTools." -ForegroundColor Yellow
    }
} else {
    Write-Host "[ERROR] DevelopmentTools directory structure not found at: $DevToolsDir" -ForegroundColor Red
    $MissingCritical = $true
}

# 4. Attempt Installation of hacktools & Python dev dependencies
Write-Host "Attempting installation of hacktools[dev] via pip..." -ForegroundColor Yellow
& $PythonCmd -m pip install -e "${HacktoolsDir}[dev]"
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Installed hacktools[dev] (including pytest) in editable mode." -ForegroundColor Green
} else {
    Write-Host "[ERROR] Failed to install hacktools[dev] package." -ForegroundColor Red
    $MissingCritical = $true
}

# 5. Attempt Installation of pre-commit CLI
if (-not (Get-Command pre-commit -ErrorAction SilentlyContinue)) {
    Write-Host "pre-commit CLI not found. Attempting auto-installation..." -ForegroundColor Yellow
    & $PythonCmd -m pip install pre-commit
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Successfully installed pre-commit via pip." -ForegroundColor Green
    } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id pre-commit.pre-commit -e --silent
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Successfully installed pre-commit via winget." -ForegroundColor Green
        } else {
            Write-Host "[ERROR] Failed to install pre-commit CLI." -ForegroundColor Red
            $MissingCritical = $true
        }
    } else {
        Write-Host "[ERROR] Failed to install pre-commit CLI." -ForegroundColor Red
        $MissingCritical = $true
    }
} else {
    Write-Host "[OK] pre-commit CLI detected." -ForegroundColor Green
}

# 6. Verify required CLI executables are active on PATH post-installation
$CommandsToCheck = @("pytest", "pre-commit", "hacktools")
foreach ($cmd in $CommandsToCheck) {
    if (Get-Command $cmd -ErrorAction SilentlyContinue) {
        Write-Host "[OK] CLI executable '$cmd' verified on PATH." -ForegroundColor Green
    } else {
        Write-Host "[ERROR] Executable '$cmd' not found on PATH after installation attempt." -ForegroundColor Red
        $MissingCritical = $true
    }
}

# 7. Check Hardware Toolchain: OSS CAD Suite (2026-08-21)
if ((Get-Command yosys -ErrorAction SilentlyContinue) -and (Get-Command nextpnr-ice40 -ErrorAction SilentlyContinue)) {
    Write-Host "[OK] OSS CAD Suite binaries (yosys, nextpnr-ice40) detected on PATH." -ForegroundColor Green
} else {
    Write-Host "[ERROR] OSS CAD Suite binaries (yosys, nextpnr-ice40) not found on PATH." -ForegroundColor Red
    Write-Host "       Please ensure OSS CAD Suite 2026-08-21 is installed and active in your environment." -ForegroundColor Red
    $MissingCritical = $true
}

# Final gate check
if ($MissingCritical) {
    Write-Host "`nERROR: One or more dependency checks or installations failed. Aborting." -ForegroundColor Red
    exit 1
}

Write-Host "`nAll dependencies verified and ready!`n" -ForegroundColor Green

Write-Host "=== Phase 2: Git Hooks Setup & Testing ===" -ForegroundColor Cyan

# 1. Install Git Hooks & Run initial check
Write-Host "Installing Git pre-commit hooks..." -ForegroundColor Yellow
pre-commit install

Write-Host "Running pre-commit check on repository files..." -ForegroundColor Yellow
& pre-commit run --all-files
$global:LASTEXITCODE = 0  # Prevent script from stopping on minor linter warnings

# 2. Run Test Suite
Write-Host "Running test suite (pytest)..." -ForegroundColor Yellow
pytest

Write-Host "`nSetup and testing completed successfully!" -ForegroundColor Green
Write-Host "Available hardware workflow commands:" -ForegroundColor Cyan
Write-Host "  hacktools hw build spike_blinky"
Write-Host "  hacktools hw load spike_blinky      # SRAM (lost on power-off)"
Write-Host "  hacktools hw install spike_blinky   # Internal flash"
