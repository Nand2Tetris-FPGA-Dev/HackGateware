#!/usr/bin/env bash

# Exit on failure
set -e

# Colors
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NONE='\033[0m'

echo -e "${CYAN}Starting project setup...${NONE}"

# Check for pre-commit CLI
if ! command -v pre-commit &> /dev/null; then
  echo -e "${YELLOW}pre-commit CLI not found. Attempting to install...${NONE}"
  if [ command -v brew &> /dev/null ]; then
    brew install pre-commit
  elif command -v pip3 &> /dev/null; then
    pip3 install pre-commit
  elif command -v pip &> /dev/null; then
    pip install pre-commit
  else
    echo -e "${RED}ERROR: Neither Homebrew nor Python/pip was found to install pre-commit.${NONE}"
    echo -e "${RED}Please install pre-commit manually: https://pre-commit.com/#install${NONE}"
    exit 1
  fi
fi

# Install Git Hooks
echo -e "${YELLOW}Installing Git pre-commit hooks...${NONE}"
pre-commit install

# Run initial check on existing files
echo -e "${YELLOW}Running initial pre-commit checks on existing files...${NONE}"
pre-commit run --all-files || true

echo -e "${GREEN}Setup complete! You are ready to start development.${NONE}"
