<#
.SYNOPSIS
Runs an isolated PostgreSQL 16 physical-replication verification with Docker.

.DESCRIPTION
Creates only randomly suffixed uten-repl-verify-* containers, volumes and one
network. It never starts, stops, connects to, or removes uten-imp-postgres.
The test exercises prepare-primary.sh and clone-replica.sh, then proves real
insert/update/delete replay, WAL backlog while disconnected and catch-up to a
recorded LSN after reconnection.
#>
[CmdletBinding()]
param(
    [string]$Image = "postgres:16",
    [switch]$KeepArtifacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Docker {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & docker @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    if ($exitCode -ne 0) {
        throw "docker $($Arguments -join ' ') failed ($exitCode):`n$($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine).Trim()
}

function Test-DockerObject {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "SilentlyContinue"
        & docker @Arguments *> $null
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    return $exitCode -eq 0
}

function Remove-DockerObject {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "SilentlyContinue"
        & docker @Arguments *> $null
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
}

function New-RandomSecret {
    $bytes = New-Object byte[] 32
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    } finally {
        $generator.Dispose()
    }
    return ([BitConverter]::ToString($bytes)).Replace("-", "").ToLowerInvariant()
}

function Wait-ForCondition {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][scriptblock]$Probe,
        [int]$Attempts = 60,
        [int]$DelaySeconds = 1
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            if (& $Probe) {
                Write-Host "PASS: $Description"
                return
            }
        } catch {
            if ($attempt -eq $Attempts) { throw }
        }
        Start-Sleep -Seconds $DelaySeconds
    }
    throw "Timed out: $Description"
}

function Assert-SafeGeneratedName {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not $Name.StartsWith("uten-repl-verify-", [StringComparison]::Ordinal) -or
        $Name -eq "uten-imp-postgres") {
        throw "Refusing unsafe Docker target name: $Name"
    }
}

$dockerVersion = Invoke-Docker -Arguments @("version", "--format", "{{.Server.Version}}")
Write-Host "Docker server: $dockerVersion"

$timestamp = [DateTime]::UtcNow.ToString("yyyyMMddHHmmss")
$suffix = "$PID-$timestamp"
$primaryName = "uten-repl-verify-primary-$suffix"
$replicaName = "uten-repl-verify-replica-$suffix"
$networkName = "uten-repl-verify-network-$suffix"
$primaryVolume = "uten-repl-verify-primary-data-$suffix"
$replicaVolume = "uten-repl-verify-replica-parent-$suffix"
$allGeneratedNames = @($primaryName, $replicaName, $networkName, $primaryVolume, $replicaVolume)
$allGeneratedNames | ForEach-Object { Assert-SafeGeneratedName -Name $_ }

$protectedBefore = $null
if (Test-DockerObject -Arguments @("container", "inspect", "uten-imp-postgres")) {
    $protectedBefore = Invoke-Docker -Arguments @(
        "container", "inspect", "--format",
        "{{.Id}}|{{.State.Status}}|{{.State.StartedAt}}", "uten-imp-postgres"
    )
    Write-Host "Protected existing container observed read-only: $protectedBefore"
}

foreach ($name in @($primaryName, $replicaName)) {
    if (Test-DockerObject -Arguments @("container", "inspect", $name)) {
        throw "Generated container name unexpectedly exists: $name"
    }
}
foreach ($name in @($primaryVolume, $replicaVolume)) {
    if (Test-DockerObject -Arguments @("volume", "inspect", $name)) {
        throw "Generated volume name unexpectedly exists: $name"
    }
}
if (Test-DockerObject -Arguments @("network", "inspect", $networkName)) {
    throw "Generated network name unexpectedly exists: $networkName"
}

$systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tempDirectory = [IO.Path]::GetFullPath((Join-Path $systemTemp "uten-repl-verify-secrets-$suffix"))
if (-not $tempDirectory.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -or
    -not ([IO.Path]::GetFileName($tempDirectory)).StartsWith("uten-repl-verify-secrets-", [StringComparison]::Ordinal)) {
    throw "Unsafe temporary directory: $tempDirectory"
}
if (Test-Path -LiteralPath $tempDirectory) {
    throw "Temporary directory already exists: $tempDirectory"
}
[void](New-Item -ItemType Directory -Path $tempDirectory)

$adminSecretPath = Join-Path $tempDirectory "admin.password"
$replSecretPath = Join-Path $tempDirectory "repl.password"
$appSecretPath = Join-Path $tempDirectory "app.password"
$utf8NoBom = New-Object Text.UTF8Encoding($false)

$scriptsDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "."))
$database = "uten_repl_verify"
$slot = "uten_cloud_replica"
$applicationName = "uten_cloud_replica"
$replicaPgData = "/var/lib/postgresql/replica/data"
$createdNetwork = $false
$createdPrimaryVolume = $false
$createdReplicaVolume = $false
$createdPrimary = $false
$createdReplica = $false
$testSucceeded = $false

function Query-Primary {
    param([Parameter(Mandatory = $true)][string]$Sql)
    return Invoke-Docker -Arguments @(
        "exec", "--user", "postgres", $primaryName,
        "psql", "-X", "-v", "ON_ERROR_STOP=1", "-Atq", "-U", "postgres", "-d", $database, "-c", $Sql
    )
}

function Query-Replica {
    param([Parameter(Mandatory = $true)][string]$Sql)
    return Invoke-Docker -Arguments @(
        "exec", "--user", "postgres", $replicaName,
        "psql", "-X", "-v", "ON_ERROR_STOP=1", "-Atq", "-U", "postgres", "-d", $database, "-c", $Sql
    )
}

try {
    [IO.File]::WriteAllText($adminSecretPath, (New-RandomSecret) + "`n", $utf8NoBom)
    [IO.File]::WriteAllText($replSecretPath, (New-RandomSecret) + "`n", $utf8NoBom)
    [IO.File]::WriteAllText($appSecretPath, (New-RandomSecret) + "`n", $utf8NoBom)

    if (-not (Test-DockerObject -Arguments @("image", "inspect", $Image))) {
        Write-Host "Pulling $Image ..."
        Write-Host (Invoke-Docker -Arguments @("pull", $Image))
    }

    Write-Host "Creating isolated Docker objects with suffix $suffix"
    [void](Invoke-Docker -Arguments @("network", "create", $networkName))
    $createdNetwork = $true
    $networkCidr = Invoke-Docker -Arguments @(
        "network", "inspect", "--format", "{{(index .IPAM.Config 0).Subnet}}", $networkName
    )
    if ($networkCidr -notmatch "^[0-9a-fA-F:./]+$") {
        throw "Docker returned unsafe network CIDR: $networkCidr"
    }

    [void](Invoke-Docker -Arguments @("volume", "create", $primaryVolume))
    $createdPrimaryVolume = $true
    [void](Invoke-Docker -Arguments @("volume", "create", $replicaVolume))
    $createdReplicaVolume = $true

    $primaryRun = @(
        "run", "--detach", "--name", $primaryName,
        "--network", $networkName,
        "--mount", "type=volume,source=$primaryVolume,target=/var/lib/postgresql/data",
        "--mount", "type=bind,source=$scriptsDirectory,target=/work,readonly",
        "--mount", "type=bind,source=$adminSecretPath,target=/run/secrets/admin.password,readonly",
        "--mount", "type=bind,source=$replSecretPath,target=/run/secrets/repl.password,readonly",
        "--mount", "type=bind,source=$appSecretPath,target=/run/secrets/app.password,readonly",
        "--env", "POSTGRES_PASSWORD_FILE=/run/secrets/admin.password",
        "--env", "POSTGRES_DB=$database",
        $Image
    )
    [void](Invoke-Docker -Arguments $primaryRun)
    $createdPrimary = $true

    Wait-ForCondition -Description "primary accepts SQL" -Probe {
        & docker exec --user postgres $primaryName pg_isready -U postgres -d $database *> $null
        return $LASTEXITCODE -eq 0
    }

    $prepareArgs = @(
        "exec", "--user", "postgres",
        "--env", "PRIMARY_PGDATA=/var/lib/postgresql/data",
        "--env", "PRIMARY_PG_HBA_FILE=/var/lib/postgresql/data/pg_hba.conf",
        "--env", "PGHOST=127.0.0.1",
        "--env", "PGPORT=5432",
        "--env", "PGDATABASE=postgres",
        "--env", "PGUSER=postgres",
        "--env", "PGSSLMODE=disable",
        "--env", "ALLOW_INSECURE_TESTING=yes",
        "--env", "HBA_RECORD_TYPE=host",
        "--env", "ADMIN_PASSWORD_FILE=/run/secrets/admin.password",
        "--env", "REPL_PASSWORD_FILE=/run/secrets/repl.password",
        "--env", "APP_PASSWORD_FILE=/run/secrets/app.password",
        "--env", "REPLICATION_CIDR=$networkCidr",
        "--env", "CLOUD_APP_CIDR=$networkCidr",
        "--env", "ON_PREM_REPLICA_CIDR=$networkCidr",
        "--env", "ON_PREM_APP_CIDR=$networkCidr",
        "--env", "REPL_USER=uten_repl",
        "--env", "APP_USER=uten",
        "--env", "APP_DATABASE=$database",
        "--env", "SLOT_NAME=$slot",
        "--env", "APPLICATION_NAME=$applicationName",
        "--env", "WAL_KEEP_SIZE=64MB",
        "--env", "MAX_SLOT_WAL_KEEP_SIZE=256MB",
        $primaryName, "bash", "/work/prepare-primary.sh"
    )
    Write-Host (Invoke-Docker -Arguments $prepareArgs)
    [void](Invoke-Docker -Arguments @("restart", $primaryName))
    Wait-ForCondition -Description "restarted primary accepts SQL" -Probe {
        & docker exec --user postgres $primaryName pg_isready -U postgres -d $database *> $null
        return $LASTEXITCODE -eq 0
    }

    $replicaRun = @(
        "run", "--detach", "--name", $replicaName,
        "--network", $networkName,
        # postgres:16 declares /var/lib/postgresql/data as a VOLUME. Use a
        # different parent mount so REPLICA_PGDATA itself is not a mount point;
        # clone-replica.sh intentionally refuses mount-point directory swaps.
        "--mount", "type=volume,source=$replicaVolume,target=/var/lib/postgresql/replica",
        "--mount", "type=bind,source=$scriptsDirectory,target=/work,readonly",
        "--mount", "type=bind,source=$replSecretPath,target=/run/secrets/repl.password,readonly",
        $Image, "bash", "-lc", "trap : TERM INT; sleep infinity & wait"
    )
    [void](Invoke-Docker -Arguments $replicaRun)
    $createdReplica = $true
    [void](Invoke-Docker -Arguments @("exec", $replicaName, "chown", "postgres:postgres", "/var/lib/postgresql/replica"))

    $cloneArgs = @(
        "exec", "--user", "postgres",
        "--env", "PRIMARY_HOST=$primaryName",
        "--env", "PRIMARY_PORT=5432",
        "--env", "PRIMARY_SSLMODE=disable",
        "--env", "ALLOW_INSECURE_TESTING=yes",
        "--env", "REPL_USER=uten_repl",
        "--env", "REPL_PASSWORD_FILE=/run/secrets/repl.password",
        "--env", "SLOT_NAME=$slot",
        "--env", "APPLICATION_NAME=$applicationName",
        "--env", "APP_DATABASE=$database",
        "--env", "REPLICA_PGDATA=$replicaPgData",
        "--env", "CONFIRM_REPLICA_PGDATA=$replicaPgData",
        "--env", "REPLICA_SERVICE_MANAGER=pg_ctl",
        "--env", "REPLICA_VERIFY_SOCKET=/var/run/postgresql",
        $replicaName, "bash", "/work/clone-replica.sh"
    )
    Write-Host (Invoke-Docker -Arguments $cloneArgs)

    Wait-ForCondition -Description "replica is in recovery" -Probe {
        return (Query-Replica -Sql "SELECT pg_is_in_recovery()") -eq "t"
    }
    Wait-ForCondition -Description "primary reports streaming replica" -Probe {
        return (Query-Primary -Sql "SELECT count(*) FROM pg_stat_replication WHERE application_name='$applicationName' AND state='streaming'") -eq "1"
    }

    # Re-run the clone while the healthy old standby still owns the permanent
    # slot. clone-replica.sh must stage through pg_basebackup's temporary slot,
    # then transfer SLOT_NAME only during the final stop/swap/start window.
    Write-Host "Re-cloning while the permanent slot is active..."
    Write-Host (Invoke-Docker -Arguments $cloneArgs)
    Wait-ForCondition -Description "re-cloned replica is in recovery" -Probe {
        return (Query-Replica -Sql "SELECT pg_is_in_recovery()") -eq "t"
    }
    Wait-ForCondition -Description "re-cloned replica reacquires permanent slot" -Probe {
        return (Query-Primary -Sql "SELECT count(*) FROM pg_stat_replication WHERE application_name='$applicationName' AND state='streaming'") -eq "1"
    }
    Write-Host "PASS: healthy live-slot replica was staged and replaced without dropping its permanent slot"

    [void](Query-Primary -Sql @"
CREATE TABLE public.uten_replication_probe (
  id integer PRIMARY KEY,
  payload text NOT NULL,
  changed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO public.uten_replication_probe(id, payload) VALUES (1, 'inserted'), (2, 'delete-me');
"@)
    $insertLsn = Query-Primary -Sql "SELECT pg_current_wal_lsn()"
    Wait-ForCondition -Description "insert replays through target LSN $insertLsn" -Probe {
        return (Query-Replica -Sql "SELECT coalesce(pg_last_wal_replay_lsn() >= '$insertLsn'::pg_lsn, false)") -eq "t"
    }
    $insertRows = Query-Replica -Sql "SELECT string_agg(id::text || ':' || payload, ',' ORDER BY id) FROM public.uten_replication_probe"
    if ($insertRows -ne "1:inserted,2:delete-me") {
        throw "Unexpected insert replay result: $insertRows"
    }
    Write-Host "PASS: insert values replayed: $insertRows"

    [void](Query-Primary -Sql "BEGIN; UPDATE public.uten_replication_probe SET payload='updated', changed_at=clock_timestamp() WHERE id=1; DELETE FROM public.uten_replication_probe WHERE id=2; COMMIT;")
    $mutateLsn = Query-Primary -Sql "SELECT pg_current_wal_lsn()"
    Wait-ForCondition -Description "update/delete replay through target LSN $mutateLsn" -Probe {
        return (Query-Replica -Sql "SELECT coalesce(pg_last_wal_replay_lsn() >= '$mutateLsn'::pg_lsn, false)") -eq "t"
    }
    $mutateRows = Query-Replica -Sql "SELECT string_agg(id::text || ':' || payload, ',' ORDER BY id) FROM public.uten_replication_probe"
    if ($mutateRows -ne "1:updated") {
        throw "Unexpected update/delete replay result: $mutateRows"
    }
    Write-Host "PASS: update and delete replayed: $mutateRows"

    $beforeDisconnect = Query-Primary -Sql "SELECT active || '|' || wal_status || '|' || coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)::bigint,0) FROM pg_replication_slots WHERE slot_name='$slot'"
    [void](Invoke-Docker -Arguments @("network", "disconnect", $networkName, $replicaName))
    Wait-ForCondition -Description "slot becomes inactive after network disconnect" -Probe {
        return (Query-Primary -Sql "SELECT NOT active FROM pg_replication_slots WHERE slot_name='$slot'") -eq "t"
    }

    [void](Query-Primary -Sql "INSERT INTO public.uten_replication_probe(id, payload) SELECT value, 'backlog-' || value FROM generate_series(100,1099) AS value; SELECT pg_switch_wal();")
    $backlogLsn = Query-Primary -Sql "SELECT pg_current_wal_lsn()"
    $duringDisconnect = Query-Primary -Sql "SELECT active || '|' || wal_status || '|' || coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)::bigint,0) FROM pg_replication_slots WHERE slot_name='$slot'"
    $duringParts = $duringDisconnect.Split("|")
    if ($duringParts.Count -ne 3 -or $duringParts[0] -ne "false" -or [int64]$duringParts[2] -le 0) {
        throw "Expected inactive slot with retained WAL during disconnect, got: $duringDisconnect"
    }
    Write-Host "PASS: primary kept writing while disconnected; slot evidence=$duringDisconnect target_lsn=$backlogLsn"

    [void](Invoke-Docker -Arguments @("network", "connect", $networkName, $replicaName))
    Wait-ForCondition -Description "replica reconnects and streams" -Probe {
        return (Query-Primary -Sql "SELECT count(*) FROM pg_stat_replication WHERE application_name='$applicationName' AND state='streaming'") -eq "1"
    } -Attempts 90
    Wait-ForCondition -Description "replica catches up through backlog LSN $backlogLsn" -Probe {
        return (Query-Replica -Sql "SELECT coalesce(pg_last_wal_replay_lsn() >= '$backlogLsn'::pg_lsn, false)") -eq "t"
    } -Attempts 90

    $finalCount = Query-Replica -Sql "SELECT count(*) FROM public.uten_replication_probe"
    $finalRows = Query-Replica -Sql "SELECT string_agg(id::text || ':' || payload, ',' ORDER BY id) FROM public.uten_replication_probe WHERE id IN (1,2,100,1099)"
    $replicaLsn = Query-Replica -Sql "SELECT pg_last_wal_replay_lsn()"
    $afterCatchup = Query-Primary -Sql "SELECT active || '|' || wal_status || '|' || coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)::bigint,0) FROM pg_replication_slots WHERE slot_name='$slot'"
    if ($finalCount -ne "1001" -or $finalRows -ne "1:updated,100:backlog-100,1099:backlog-1099") {
        throw "Catch-up data mismatch: count=$finalCount rows=$finalRows"
    }

    Write-Host ""
    Write-Host "REAL REPLICATION EVIDENCE"
    Write-Host "  slot before disconnect : $beforeDisconnect"
    Write-Host "  slot during disconnect : $duringDisconnect"
    Write-Host "  target backlog LSN     : $backlogLsn"
    Write-Host "  replica replay LSN     : $replicaLsn"
    Write-Host "  slot after catch-up    : $afterCatchup"
    Write-Host "  final row count        : $finalCount"
    Write-Host "  sampled final rows     : $finalRows"
    Write-Host "PASS: real insert/update/delete, disconnected WAL retention and catch-up verified."
    $testSucceeded = $true
}
finally {
    if (-not $KeepArtifacts) {
        Write-Host "Cleaning only generated Docker objects with suffix $suffix"
        if ($createdReplica -or (Test-DockerObject -Arguments @("container", "inspect", $replicaName))) {
            Remove-DockerObject -Arguments @("container", "rm", "--force", "--volumes", $replicaName)
        }
        if ($createdPrimary -or (Test-DockerObject -Arguments @("container", "inspect", $primaryName))) {
            Remove-DockerObject -Arguments @("container", "rm", "--force", "--volumes", $primaryName)
        }
        if ($createdReplicaVolume -or (Test-DockerObject -Arguments @("volume", "inspect", $replicaVolume))) {
            Remove-DockerObject -Arguments @("volume", "rm", $replicaVolume)
        }
        if ($createdPrimaryVolume -or (Test-DockerObject -Arguments @("volume", "inspect", $primaryVolume))) {
            Remove-DockerObject -Arguments @("volume", "rm", $primaryVolume)
        }
        if ($createdNetwork -or (Test-DockerObject -Arguments @("network", "inspect", $networkName))) {
            Remove-DockerObject -Arguments @("network", "rm", $networkName)
        }
    } else {
        Write-Warning "Artifacts retained by request: $($allGeneratedNames -join ', '); secret directory: $tempDirectory"
    }

    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $tempDirectory)) {
        $resolvedTemp = [IO.Path]::GetFullPath($tempDirectory)
        if ($resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and
            ([IO.Path]::GetFileName($resolvedTemp)).StartsWith("uten-repl-verify-secrets-", [StringComparison]::Ordinal)) {
            Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
        } else {
            Write-Error "Refusing to remove unsafe temp path: $resolvedTemp"
        }
    }

    if ($null -ne $protectedBefore) {
        $protectedAfter = Invoke-Docker -Arguments @(
            "container", "inspect", "--format",
            "{{.Id}}|{{.State.Status}}|{{.State.StartedAt}}", "uten-imp-postgres"
        )
        if ($protectedAfter -ne $protectedBefore) {
            throw "Protected uten-imp-postgres state changed unexpectedly: before=$protectedBefore after=$protectedAfter"
        }
        Write-Host "PASS: protected uten-imp-postgres remained unchanged."
    }
}

if (-not $testSucceeded) {
    throw "Replication verification did not complete successfully."
}
