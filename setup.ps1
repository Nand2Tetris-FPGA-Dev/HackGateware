$ErrorActionPreference = "Stop"

Write-Host "Starting project setup..." -ForegroundColor Cyan

# Check for pre-commit CLI
if (-not (Get-Command pre-commit -ErrorAction SilentlyContinue)) {
  Write-Host "pre-commit CLI not found. Attempting to install..." -ForegroundColor Yellow
  if (Get-Command pip3 -ErrorAction SilentlyContinue) {
    pip3 install pre-commit
  }
  elseif (Get-Command pip -ErrorAction SilentlyContinue) {
    pip install pre-commit
  }
  else {
    Write-Host "ERROR: Neither Python/pip nor winget was found to install pre-commit." -ForegroundColor Red
    Write-Host "Please install pre-commit manually: https://pre-commit.com/#install" -ForegroundColor Red
    exit 1
  }
}

# Install Git Hooks
Write-Host "Installing Git pre-commit hooks..." -ForegroundColor Yellow
pre-commit install

# Run initial check on existing files
Write-Host "Running initial pre-commit checks on existing files..." -ForegroundColor Yellow
pre-commit run --all-files
$global:LASTEXITCODE = 0

Write-Host "Setup complete! You are ready to start development." -ForegroundColor Green
