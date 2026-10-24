# Template-Repository

Template repository for Nand2Tetris FPGA development

## Prerequisites

Before running the setup scripts, ensure your system meets the following requirements:

- **Git:** Installed and configured

## Quick Start

1. **Clone the repository:**

   ```bash
   git clone <repository_url>
   cd <repository_name>
   ```

2. **Run the setup script:** Run the setup script for your operating system to install dependencies and register pre-commit Git hooks:
   - **macOS / Linux / WSL:**

     ```bash
     ./setup.sh
     ```

   - **Windows (PowerShell):**

     ```powershell
     ./setup.ps1

     # IF you get an error about running scripts
     powershell -ExecutionPolicy Bypass -File setup.ps1
     ```
