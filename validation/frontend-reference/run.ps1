[CmdletBinding()]
param([switch]$SkipBackendPreparation, [switch]$PrepareOnly)
$ErrorActionPreference = 'Stop'
$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
$env:WORKSPACE_ROOT = $workspaceRoot.Replace('\', '/')
$envFile = Join-Path $PSScriptRoot '../r1-reference/.env'
$evidence = Join-Path $PSScriptRoot 'evidence'
New-Item -ItemType Directory -Force $evidence | Out-Null
$resultFile = Join-Path $evidence 'result.json'
[IO.File]::WriteAllText($resultFile, '{"status":"running"}', [Text.UTF8Encoding]::new($false))
function Invoke-Checked {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed with exit code $LASTEXITCODE" }
}
try {
    if (-not $SkipBackendPreparation) { & (Join-Path $PSScriptRoot '../r1-reference/run.ps1') -PrepareOnly }
    if (-not (Test-Path $envFile)) { throw 'Prepare the R1 backend before using -SkipBackendPreparation.' }
    $composeArgs = @('compose', '--env-file', $envFile, '-p', 'r1-reference',
        '-f', (Join-Path $PSScriptRoot '../hu-ref-020/compose.yml'),
        '-f', (Join-Path $PSScriptRoot '../r1-reference/compose.override.yml'),
        '-f', (Join-Path $PSScriptRoot 'compose.override.yml'), '--profile', 'frontend-reference')
    Invoke-Checked docker ($composeArgs + @('config', '--quiet'))
    # Each container copies source into an isolated build directory: recreate it
    # on every run so a previous build cannot hide new source changes.
    Invoke-Checked docker ($composeArgs + @('up', '-d', '--force-recreate', '--wait', '--wait-timeout', '360', 'web-shell', 'reference-mfe'))
    foreach ($url in @('http://localhost:18092/ready', 'http://localhost:18090/health/ready', 'http://localhost:5000', 'http://localhost:5105/remoteEntry.js')) {
        $deadline = [DateTime]::UtcNow.AddMinutes(15)
        do {
            try { $ready = (Invoke-WebRequest -Uri $url -TimeoutSec 5 -UseBasicParsing).StatusCode -eq 200 } catch { $ready = $false }
            if (-not $ready) { Start-Sleep -Seconds 3 }
        } until ($ready -or [DateTime]::UtcNow -gt $deadline)
        if (-not $ready) { throw "Endpoint unavailable: $url" }
    }
    if ($PrepareOnly) {
        [IO.File]::WriteAllText($resultFile, '{"status":"prepared"}', [Text.UTF8Encoding]::new($false))
        Write-Host 'Open http://localhost:5000/reference-data/parametrizacion. Credentials remain in validation/r1-reference/.env.'
        return
    }
    # The UI starts the business flow; these existing Go integration tests also
    # verify JWT claims, transactional rollback, retries, DLQ and actual replay.
    foreach ($suite in @(
        @{ Package='./internal/adapter/in/http/hierarchy'; Pattern='^TestHURef020ParametersWithRealIAMJWT$'; Names=@('TestHURef020ParametersWithRealIAMJWT'); Log='backend-hu-ref-020.log' },
        @{ Package='./internal/adapter/out/messaging'; Pattern='^TestR1(TransactionalOutbox|AtomicInboxAndDLQ)$'; Names=@('TestR1TransactionalOutbox','TestR1AtomicInboxAndDLQ'); Log='backend-r1.log' }
    )) {
        $logPath = Join-Path $evidence $suite.Log
        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & docker @composeArgs run --rm tests go test -mod=readonly -count=1 -v $suite.Package -run $suite.Pattern 2>&1 |
                Tee-Object -FilePath $logPath | ForEach-Object { Write-Host "$_" }
            $testCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $oldPreference }
        if ($testCode -ne 0) { throw "Backend integration failed: $($suite.Log)" }
        $log = Get-Content $logPath -Raw
        if ($log -match '--- SKIP:') { throw 'Skipped backend integration tests are not accepted.' }
        foreach ($name in $suite.Names) {
            if ($log -notmatch "--- PASS: $([regex]::Escape($name)) ") { throw "Missing PASS for $name" }
        }
    }
    Push-Location (Join-Path $workspaceRoot 'design-software-web-shell')
    try {
        Invoke-Checked npm.cmd @('ci', '--no-audit', '--no-fund')
        Invoke-Checked npm.cmd @('exec', '--', 'playwright', 'install', 'chromium')
        $env:FRONTEND_RUN_ID = [guid]::NewGuid().ToString('N').Substring(0, 12).ToUpperInvariant()
        Invoke-Checked npm.cmd @('exec', '--', 'playwright', 'test', '--config', 'playwright.reference.config.ts')
        $report = Get-Content 'test-results/reference-result.json' -Raw | ConvertFrom-Json
        if ($report.stats.expected -ne 3 -or $report.stats.unexpected -ne 0 -or $report.stats.skipped -ne 0) {
            throw 'All three real browser tests must pass without skips.'
        }
        Copy-Item 'test-results/reference-result.json' (Join-Path $evidence 'playwright-result.json')
    } finally { Pop-Location; Remove-Item Env:FRONTEND_RUN_ID -ErrorAction SilentlyContinue }
    $result = @{ status = 'passed'; browser_passed = 3; backend_passed = 3; skipped = 0; completed_at = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json
    [IO.File]::WriteAllText($resultFile, $result, [Text.UTF8Encoding]::new($false))
} catch {
    [IO.File]::WriteAllText($resultFile, '{"status":"failed"}', [Text.UTF8Encoding]::new($false))
    throw
}
