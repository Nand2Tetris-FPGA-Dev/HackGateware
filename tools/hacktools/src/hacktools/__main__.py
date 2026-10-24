"""Lets `python -m hacktools ...` work when the `hacktools` script isn't on PATH."""

import sys

from hacktools.cli import main

sys.exit(main())
