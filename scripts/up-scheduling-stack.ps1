param(
  [string]$EnvFile = ".env",
  [switch]$LocalTraefik
)

$ErrorActionPreference = "Stop"

function Read-RequiredEnvFileValue {
  param([string]$Path, [string]$Name)
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Env file not found: $Path"
  }
  $line = Get-Content -LiteralPath $Path |
    Where-Object { $_ -match "^\s*$([regex]::Escape($Name))=" } |
    Select-Object -First 1
  if (-not $line) {
    throw "$Name is required in $Path"
  }
  $value = ($line -replace "^\s*$([regex]::Escape($Name))=", "").Trim('"')
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "$Name cannot be blank"
  }
  return $value
}

function Assert-SqlIdentifier {
  param([string]$Value, [string]$Name)
  if ($Value -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
    throw "$Name must be a safe SQL identifier"
  }
}

$db = Read-RequiredEnvFileValue -Path $EnvFile -Name "POSTGRES_DB"
$su = Read-RequiredEnvFileValue -Path $EnvFile -Name "POSTGRES_USER"
$appUser = Read-RequiredEnvFileValue -Path $EnvFile -Name "APP_DB_USER"
$appPass = Read-RequiredEnvFileValue -Path $EnvFile -Name "APP_DB_PASSWORD"
Assert-SqlIdentifier -Value $su -Name "POSTGRES_USER"
Assert-SqlIdentifier -Value $appUser -Name "APP_DB_USER"

$composeFiles = @("-f", "docker-compose.yml")
if ($LocalTraefik) {
  $composeFiles += @("-f", "docker-compose.traefik-local.yml")
}

$compose = @("compose", "--env-file", $EnvFile) + $composeFiles
$profiles = @("--profile", "scheduling", "--profile", "observability", "--profile", "edge", "--profile", "tooling")

Write-Host "Starting base services..."
docker @compose @profiles up -d postgres rabbitmq otel-collector tempo traefik

Write-Host "Applying IAM schema..."
docker @compose @profiles run --rm liquibase-iam update

Write-Host "Applying Scheduling schema..."
docker @compose @profiles run --rm liquibase-scheduling update

Write-Host "Configuring least-privilege application database role..."
$escapedPass = $appPass.Replace("'", "''")
$sql = @"
DO `$do`$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='$appUser') THEN
    CREATE ROLE $appUser LOGIN PASSWORD '$escapedPass' INHERIT;
  ELSE
    ALTER ROLE $appUser WITH LOGIN PASSWORD '$escapedPass';
  END IF;
END `$do`$;
GRANT iam_writer TO $appUser;
GRANT scheduling_writer TO $appUser;
"@
$sql | docker @compose @profiles exec -T postgres psql -v ON_ERROR_STOP=1 -U $su -d $db

Write-Host "Starting IAM, Scheduling and observability services..."
docker @compose @profiles up -d iam-api scheduling-api prometheus loki grafana

Write-Host "Scheduling stack is running."
docker @compose @profiles ps
