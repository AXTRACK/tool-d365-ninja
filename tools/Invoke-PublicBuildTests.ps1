$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$manifest = Get-Content -LiteralPath 'axtrack/overlay.json' -Raw -Encoding UTF8 | ConvertFrom-Json
if ($manifest.id -ne 'axtrack-local-metadata-v2') { throw 'NINJA_OVERLAY_ID_MISMATCH' }
if ($manifest.baseRevision -ne 'ba598cc346864b41c6426b58a620e082ecc34b27') { throw 'NINJA_OVERLAY_BASE_MISMATCH' }
if (-not (Test-Path -LiteralPath 'axtrack/Apply.ps1' -PathType Leaf)) { throw 'NINJA_OVERLAY_SCRIPT_MISSING' }
$expected = (Get-Content -LiteralPath 'axtrack/Apply.ps1' -Raw -Encoding UTF8).Length
if ($expected -lt 100000) { throw 'NINJA_OVERLAY_SCRIPT_TRUNCATED' }
dotnet test 'd365fo-cli.slnx' --configuration Release --nologo
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host 'NINJA_PUBLIC_BUILD_TESTS_PASS'
