# SPDX-License-Identifier: Unlicense

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

& (Join-Path $PSScriptRoot 'validate.ps1')

Push-Location $root
try {
    uv run --python 3.13 python .\scripts\check_markdown_links.py
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    uv run --python 3.13 --with 'lupa==2.6' --with 'pyyaml==6.0.3' python .\scripts\run_lua_tests.py
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
finally {
    Pop-Location
}
