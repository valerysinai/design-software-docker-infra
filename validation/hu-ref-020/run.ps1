[CmdletBinding()]
param([switch]$PrepareOnly)
$ErrorActionPreference = 'Stop'
$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
$env:WORKSPACE_ROOT = $workspaceRoot.Replace('\', '/')
$envFile = Join-Path $PSScriptRoot '.env'
$composeFile = Join-Path $PSScriptRoot 'compose.yml'
$evidence = Join-Path $PSScriptRoot 'evidence'
New-Item -ItemType Directory -Force $evidence | Out-Null
$resultFile = Join-Path $evidence 'result.json'
# A new attempt must never leave a previous success looking like its result.
[IO.File]::WriteAllText($resultFile, '{"status":"running"}', [Text.UTF8Encoding]::new($false))

if (-not (Test-Path $envFile)) {
    $lines = foreach ($key in @('DB_PASSWORD', 'IAM_APP_PASSWORD', 'REFERENCE_APP_PASSWORD', 'FIXTURE_PASSWORD')) {
        $bytes = New-Object byte[] 32
        $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $generator.GetBytes($bytes); "$key=$([BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant())" }
        finally { $generator.Dispose(); [Array]::Clear($bytes, 0, $bytes.Length) }
    }
    [IO.File]::WriteAllLines($envFile, $lines, [Text.UTF8Encoding]::new($false))
}

function Invoke-Compose {
    param([string[]]$Arguments, [string]$LogName)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($LogName) {
            & docker compose --env-file $envFile -f $composeFile @Arguments 2>&1 |
                Tee-Object -FilePath (Join-Path $evidence $LogName) | ForEach-Object { Write-Host "$_" }
        } else {
            & docker compose --env-file $envFile -f $composeFile @Arguments | Out-Host
        }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($code -ne 0) { throw "Docker Compose failed ($code): $($Arguments -join ' ')" }
}

try {
    Invoke-Compose -Arguments @('config', '--quiet')
    Invoke-Compose -Arguments @('up', '-d', '--wait', 'postgres')
    Invoke-Compose -Arguments @('run', '--rm', 'migrate-iam') -LogName 'migrations-iam.log'
    Invoke-Compose -Arguments @('run', '--rm', 'migrate-reference') -LogName 'migrations-reference.log'
    Invoke-Compose -Arguments @('run', '--rm', 'fixtures') -LogName 'schema-and-fixtures.log'
    Invoke-Compose -Arguments @('up', '-d', '--force-recreate', 'iam', 'reference')
    if ($PrepareOnly) { [IO.File]::WriteAllText($resultFile, '{"status":"prepared"}', [Text.UTF8Encoding]::new($false)); Write-Host 'Services started. Run again without -PrepareOnly to execute the E2E.'; return }

    function Wait-Endpoint {
        param([string]$Url)
        $deadline = [DateTime]::UtcNow.AddMinutes(15)
        while ([DateTime]::UtcNow -lt $deadline) {
            try {
                $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3
                if ($response.StatusCode -eq 200) { Write-Host "READY $Url"; return }
            } catch { }
            $exited = @(& docker compose --env-file $envFile -f $composeFile ps --all --status exited -q iam reference)
            if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect validation services.' }
            if ($exited.Count -gt 0) { throw 'A validation service stopped. Inspect IAM/Reference Data logs before retrying.' }
            Start-Sleep -Seconds 3
        }
        throw "Timed out waiting for $Url. Check docker compose logs for this validation stack."
    }
    Wait-Endpoint 'http://localhost:18082/ready'
    Wait-Endpoint 'http://localhost:18082/api/v1/auth/.well-known/jwks.json'
    Wait-Endpoint 'http://localhost:18080/health/ready'
    Invoke-Compose -Arguments @('exec', '-T', 'iam', 'java', '-version') -LogName 'java-runtime.log'
    Invoke-Compose -Arguments @('exec', '-T', 'iam', 'mvn', '-version') -LogName 'maven-runtime.log'
    Invoke-Compose -Arguments @('run', '--rm', 'tests') -LogName 'e2e.log'
    if (-not (Select-String -Path (Join-Path $evidence 'e2e.log') -Pattern '^--- PASS: TestHURef020ParametersWithRealIAMJWT' -Quiet)) {
        throw 'E2E runner did not produce the required PASS marker.'
    }
    Invoke-Compose -Arguments @('ps') -LogName 'services.log'
    $result = [ordered]@{
        status = 'passed'
        completed_at_utc = [DateTime]::UtcNow.ToString('o')
        test = 'TestHURef020ParametersWithRealIAMJWT'
        criteria = @('E1', 'E2', 'E3', 'E4')
        scope = 'backend IAM + Reference Data; excludes R1 and microfrontend/web-shell'
    }
    [IO.File]::WriteAllText($resultFile, ($result | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    Write-Host 'HU-REF-020 E2E passed. Evidence is in validation/hu-ref-020/evidence.'
} catch {
    $failed = @{ status = 'failed'; failed_at_utc = [DateTime]::UtcNow.ToString('o'); error = $_.Exception.Message }
    [IO.File]::WriteAllText($resultFile, ($failed | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    throw
}
