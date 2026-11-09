#!/usr/bin/env bash

# Exit on failure
set -e

# Colors
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NONE='\033[0m'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DEV_TOOLS_DIR="${SCRIPT_DIR}/../DevelopmentTools"
HACKTOOLS_DIR="${DEV_TOOLS_DIR}/tools/hacktools"

MISSING_CRITICAL=0

echo -e "${CYAN}=== Phase 1: Dependency Verification & Auto-Installation ===${NONE}"

# 1. Check Git CLI
if command -v git &> /dev/null; then
  echo -e "${GREEN}[OK] Git CLI detected.${NONE}"
else
  echo -e "${RED}[ERROR] Git CLI is required but not found on PATH.${NONE}"
  MISSING_CRITICAL=1
fi

# 2. Check Python 3 & pip
PYTHON_CMD=""
if command -v python3 &> /dev/null; then
  PYTHON_CMD="python3"
elif command -v python &> /dev/null; then
  PYTHON_CMD="python"
fi

if [ -n "$PYTHON_CMD" ] && "$PYTHON_CMD" -m pip --version &> /dev/null; then
  echo -e "${GREEN}[OK] Python ($PYTHON_CMD) and pip detected.${NONE}"
else
  echo -e "${RED}[ERROR] Python 3 and pip are required but not found on PATH.${NONE}"
  MISSING_CRITICAL=1
fi

# Exit early if core system binaries (Python/Git) are missing
if [ "$MISSING_CRITICAL" -eq 1 ]; then
  echo -e "\n${RED}ERROR: Core system prerequisites missing. Aborting setup.${NONE}"
  exit 1
fi

# 3. Check & Update DevelopmentTools Repository
if [ -d "$DEV_TOOLS_DIR" ] && [ -d "$HACKTOOLS_DIR" ]; then
  echo -e "${GREEN}[OK] DevelopmentTools directory structure found.${NONE}"
  echo -e "${YELLOW}     Pulling latest changes for DevelopmentTools...${NONE}"
  git -C "$DEV_TOOLS_DIR" pull || echo -e "${YELLOW}[WARN] Could not pull latest changes for DevelopmentTools.${NONE}"
else
  echo -e "${RED}[ERROR] DevelopmentTools directory structure not found at: ${DEV_TOOLS_DIR}${NONE}"
  MISSING_CRITICAL=1
fi

# 4. Attempt Installation of hacktools & Python dev dependencies
echo -e "${YELLOW}Attempting installation of hacktools[dev] via pip...${NONE}"
if "$PYTHON_CMD" -m pip install -e "${HACKTOOLS_DIR}[dev]"; then
  echo -e "${GREEN}[OK] Installed hacktools[dev] (including pytest) in editable mode.${NONE}"
else
  echo -e "${RED}[ERROR] Failed to install hacktools[dev] package.${NONE}"
  MISSING_CRITICAL=1
fi

# 5. Attempt Installation of pre-commit CLI
if ! command -v pre-commit &> /dev/null; then
  echo -e "${YELLOW}pre-commit CLI not found. Attempting auto-installation...${NONE}"
  if "$PYTHON_CMD" -m pip install pre-commit; then
    echo -e "${GREEN}[OK] Successfully installed pre-commit via pip.${NONE}"
  elif command -v brew &> /dev/null && brew install pre-commit; then
    echo -e "${GREEN}[OK] Successfully installed pre-commit via Homebrew.${NONE}"
  else
    echo -e "${RED}[ERROR] Failed to install pre-commit CLI.${NONE}"
    MISSING_CRITICAL=1
  fi
else
  echo -e "${GREEN}[OK] pre-commit CLI detected.${NONE}"
fi

# 6. Verify required CLI executables are active on PATH post-installation
for cmd in pytest pre-commit hacktools; do
  if command -v "$cmd" &> /dev/null; then
    echo -e "${GREEN}[OK] CLI executable '$cmd' verified on PATH.${NONE}"
  else
    echo -e "${RED}[ERROR] Executable '$cmd' not found on PATH after installation attempt.${NONE}"
    MISSING_CRITICAL=1
  fi
done

# 7. Check Hardware Toolchain: OSS CAD Suite (2026-08-21)
if command -v yosys &> /dev/null && command -v nextpnr-ice40 &> /dev/null; then
  echo -e "${GREEN}[OK] OSS CAD Suite binaries (yosys, nextpnr-ice40) detected on PATH.${NONE}"
else
  echo -e "${RED}[ERROR] OSS CAD Suite binaries (yosys, nextpnr-ice40) not found on PATH.${NONE}"
  echo -e "${RED}       Please ensure OSS CAD Suite 2026-08-21 is installed and active in your shell.${NONE}"
  MISSING_CRITICAL=1
fi

# Final gate check
if [ "$MISSING_CRITICAL" -eq 1 ]; then
  echo -e "\n${RED}ERROR: One or more dependency checks or installations failed. Aborting.${NONE}"
  exit 1
fi

echo -e "\n${GREEN}All dependencies verified and ready!${NONE}\n"

echo -e "${CYAN}=== Phase 2: Git Hooks Setup & Testing ===${NONE}"

# 1. Install Git Hooks & Run initial check
echo -e "${YELLOW}Installing Git pre-commit hooks...${NONE}"
pre-commit install

echo -e "${YELLOW}Running pre-commit check on repository files...${NONE}"
pre-commit run --all-files || true

# 2. Run Test Suite
echo -e "${YELLOW}Running test suite (pytest)...${NONE}"
pytest

echo -e "\n${GREEN}Setup and testing completed successfully!${NONE}"
echo -e "${CYAN}Available hardware workflow commands:${NONE}"
echo -e "  hacktools hw build spike_blinky"
echo -e "  hacktools hw load spike_blinky      # SRAM (lost on power-off)"
echo -e "  hacktools hw install spike_blinky   # Internal flash"
