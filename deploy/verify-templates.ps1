$ErrorActionPreference = 'Stop'

$nginxPath = Join-Path $PSScriptRoot 'nginx/uten-imp.conf.example'
$systemdPath = Join-Path $PSScriptRoot 'systemd/uten-imp.service.example'
$watchdogServicePath = Join-Path $PSScriptRoot 'systemd/uten-imp-watchdog.service.example'
$watchdogTimerPath = Join-Path $PSScriptRoot 'systemd/uten-imp-watchdog.timer.example'
$watchdogScriptPath = Join-Path $PSScriptRoot 'watchdog/uten-imp-watchdog.sh'
$entryWatchdogServicePath = Join-Path $PSScriptRoot 'systemd/uten-imp-entry-watchdog.service.example'
$entryWatchdogTimerPath = Join-Path $PSScriptRoot 'systemd/uten-imp-entry-watchdog.timer.example'
$entryWatchdogScriptPath = Join-Path $PSScriptRoot 'watchdog/uten-imp-entry-watchdog.sh'
$nginxOverridePath = Join-Path $PSScriptRoot 'systemd/nginx-uten-imp-override.conf.example'
$readmePath = Join-Path $PSScriptRoot 'README.md'
$cloudNginxPath = Join-Path $PSScriptRoot 'cloud/nginx-cloud.conf.example'
$cloudSystemdPath = Join-Path $PSScriptRoot 'cloud/uten-imp-cloud.service.example'
$cloudReadmePath = Join-Path $PSScriptRoot 'cloud/README-cloud.md'
$preparePrimaryPath = Join-Path $PSScriptRoot 'postgres/prepare-primary.sh'
$cloneReplicaPath = Join-Path $PSScriptRoot 'postgres/clone-replica.sh'
$prepareStandbyHbaPath = Join-Path $PSScriptRoot 'postgres/prepare-standby-hba.sh'
$replicationHarnessPath = Join-Path $PSScriptRoot 'postgres/verify-replication-docker.ps1'

$nginx = Get-Content -LiteralPath $nginxPath -Raw -Encoding UTF8
$systemd = Get-Content -LiteralPath $systemdPath -Raw -Encoding UTF8
$watchdogService = Get-Content -LiteralPath $watchdogServicePath -Raw -Encoding UTF8
$watchdogTimer = Get-Content -LiteralPath $watchdogTimerPath -Raw -Encoding UTF8
$watchdogScript = Get-Content -LiteralPath $watchdogScriptPath -Raw -Encoding UTF8
$entryWatchdogService = Get-Content -LiteralPath $entryWatchdogServicePath -Raw -Encoding UTF8
$entryWatchdogTimer = Get-Content -LiteralPath $entryWatchdogTimerPath -Raw -Encoding UTF8
$entryWatchdogScript = Get-Content -LiteralPath $entryWatchdogScriptPath -Raw -Encoding UTF8
$nginxOverride = Get-Content -LiteralPath $nginxOverridePath -Raw -Encoding UTF8
$readme = Get-Content -LiteralPath $readmePath -Raw -Encoding UTF8
$cloudNginx = Get-Content -LiteralPath $cloudNginxPath -Raw -Encoding UTF8
$cloudSystemd = Get-Content -LiteralPath $cloudSystemdPath -Raw -Encoding UTF8
$cloudReadme = Get-Content -LiteralPath $cloudReadmePath -Raw -Encoding UTF8
$preparePrimary = Get-Content -LiteralPath $preparePrimaryPath -Raw -Encoding UTF8
$cloneReplica = Get-Content -LiteralPath $cloneReplicaPath -Raw -Encoding UTF8
$prepareStandbyHba = Get-Content -LiteralPath $prepareStandbyHbaPath -Raw -Encoding UTF8
$replicationHarness = Get-Content -LiteralPath $replicationHarnessPath -Raw -Encoding UTF8

function Assert-Contains {
    param(
        [string] $Text,
        [string] $Expected,
        [string] $Label
    )
    if (-not $Text.Contains($Expected)) {
        throw "Missing deployment contract: $Label"
    }
}

Assert-Contains $nginx 'zone=uten_health_ip:10m rate=1000r/s;' 'independent finite health rate zone'
Assert-Contains $nginx 'zone=uten_auth_ip:10m rate=300r/s;' 'shared-NAT auth flood zone'
Assert-Contains $nginx 'limit_req zone=uten_health_ip burst=5000 nodelay;' 'health recovery burst'
Assert-Contains $nginx 'limit_req zone=uten_auth_ip burst=2000 nodelay;' 'auth recovery burst'
Assert-Contains $nginx 'auth/(?:login|refresh|logout)' 'staff auth bucket paths'
Assert-Contains $nginx 'visitor/auth/(?:send-code|login|refresh|logout)' 'visitor auth bucket paths'
Assert-Contains $nginx 'root /opt/uten-imp/current/web;' 'versioned web symlink root'
Assert-Contains $nginx 'listen 127.0.0.1:8081;' 'loopback-only static entry probe'
Assert-Contains $nginx 'try_files $uri =503;' 'entry probe requires immutable index'
Assert-Contains $nginx 'Never copy files through this path in place.' 'web in-place overwrite guard'
Assert-Contains $nginx 'server 127.0.0.1:8080;' 'on-prem loopback backend boundary'
Assert-Contains $nginx 'allow __OFFICE_CIDR__;' 'on-prem exact office CIDR placeholder'
Assert-Contains $nginx 'allow __VPN_CIDR__;' 'on-prem exact VPN CIDR placeholder'
if ($nginx.Contains('allow 10.0.0.0/8;') -or
    $nginx.Contains('allow 172.16.0.0/12;') -or
    $nginx.Contains('allow 192.168.0.0/16;')) {
    throw 'On-prem Nginx must not ship broad RFC1918 allow rules'
}

$exactHealth = $nginx.IndexOf('location = /actuator/health {')
$probeHealth = $nginx.IndexOf('location ~ ^/actuator/health/(?:liveness|readiness)$ {')
$actuatorDeny = $nginx.IndexOf('location /actuator/ {')
$spaFallback = $nginx.LastIndexOf('location / {')
if ($exactHealth -lt 0 -or $probeHealth -lt 0 -or $actuatorDeny -lt 0 -or $spaFallback -lt 0) {
    throw 'Missing one or more Actuator/SPA locations'
}
if ($actuatorDeny -lt $exactHealth -or $actuatorDeny -lt $probeHealth) {
    throw 'Allowed health locations must be declared before the generic Actuator deny'
}
if ($actuatorDeny -gt $spaFallback) {
    throw 'Generic Actuator deny must be declared before the SPA fallback'
}
if ($nginx.Contains('location ^~ /actuator/ {')) {
    throw 'Generic Actuator deny must not use ^~ because probe regex locations must win'
}
$healthBucketUses = ([regex]::Matches(
        $nginx,
        [regex]::Escape('limit_req zone=uten_health_ip burst=5000 nodelay;'))).Count
if ($healthBucketUses -ne 2) {
    throw "Expected exactly two health bucket uses, found $healthBucketUses"
}
$openBraces = ([regex]::Matches($nginx, [regex]::Escape('{'))).Count
$closeBraces = ([regex]::Matches($nginx, [regex]::Escape('}'))).Count
if ($openBraces -ne $closeBraces) {
    throw "Unbalanced Nginx braces: open=$openBraces close=$closeBraces"
}

Assert-Contains $systemd 'WorkingDirectory=/opt/uten-imp/current' 'versioned service working directory'
Assert-Contains $systemd 'ExecStartPre=/usr/bin/test -L /opt/uten-imp/current' 'current symlink guard'
Assert-Contains $systemd '/opt/uten-imp/current/server/uten-imp-server.jar' 'versioned JAR path'
Assert-Contains $systemd 'Never overwrite files through it.' 'JAR in-place overwrite guard'
Assert-Contains $systemd 'A separate host watchdog or orchestrator' 'external liveness supervision'

Assert-Contains $watchdogService 'After=network-online.target uten-imp.service' 'watchdog startup ordering'
Assert-Contains $watchdogService 'RuntimeDirectory=uten-imp-watchdog' 'watchdog volatile state directory'
Assert-Contains $watchdogService '/opt/uten-imp/current/deploy/watchdog/uten-imp-watchdog.sh' 'versioned watchdog script'
Assert-Contains $watchdogService 'ReadWritePaths=/run/uten-imp-watchdog' 'watchdog write boundary'
Assert-Contains $watchdogTimer 'OnBootSec=120s' 'watchdog startup grace'
Assert-Contains $watchdogTimer 'OnUnitActiveSec=15s' 'watchdog probe interval'
Assert-Contains $watchdogScript '/actuator/health/liveness' 'direct liveness endpoint'
Assert-Contains $watchdogScript 'jq -e' 'strict liveness jq invocation'
Assert-Contains $watchdogScript '.status == "UP"' 'strict liveness JSON check'
Assert-Contains $watchdogScript 'flock -n 9' 'single-flight watchdog lock'
Assert-Contains $watchdogScript 'failures < FAILURE_THRESHOLD' 'consecutive failure threshold'
Assert-Contains $watchdogScript 'systemctl restart uten-imp.service' 'supervised restart action'

Assert-Contains $entryWatchdogService 'After=network-online.target nginx.service' 'entry watchdog startup ordering'
Assert-Contains $entryWatchdogService 'RuntimeDirectory=uten-imp-entry-watchdog' 'entry watchdog state directory'
Assert-Contains $entryWatchdogTimer 'OnUnitActiveSec=15s' 'entry watchdog probe interval'
Assert-Contains $entryWatchdogScript '127.0.0.1:8081/index.html' 'loopback entry URL'
Assert-Contains $entryWatchdogScript 'flutter_bootstrap.js' 'entry artifact marker'
Assert-Contains $entryWatchdogScript 'systemctl restart "${NGINX_SERVICE}"' 'nginx supervised restart action'
Assert-Contains $nginxOverride 'Restart=on-failure' 'nginx abnormal-exit recovery'
Assert-Contains $nginxOverride 'StartLimitBurst=5' 'nginx restart storm guard'

Assert-Contains $readme 'sha256sum -c SHA256SUMS' 'checksum verification'
Assert-Contains $readme 'deploy/watchdog/uten-imp-watchdog.sh' 'versioned backend watchdog artifact'
Assert-Contains $readme 'deploy/watchdog/uten-imp-entry-watchdog.sh' 'versioned entry watchdog artifact'
Assert-Contains $readme 'mv -Tf ".current-<version>" current' 'atomic symlink rename'
Assert-Contains $readme '/actuator/info' 'non-health Actuator negative check'
Assert-Contains $readme '1,000' 'shared-NAT recovery capacity check'
Assert-Contains $readme 'enable --now uten-imp-watchdog.timer' 'watchdog installation command'
Assert-Contains $readme 'uten-imp-entry-watchdog.timer' 'entry watchdog installation command'
Assert-Contains $readme 'stop uten-imp-watchdog.timer uten-imp-entry-watchdog.timer' 'maintenance watchdog stop guard'
Assert-Contains $readme '不支持集群滚动升级' 'unsupported rolling-upgrade boundary'
if ([regex]::IsMatch($readme, '(?m)\+\s{2,}')) {
    throw 'Deployment README contains patch-residue plus markers in commands'
}

Assert-Contains $cloudNginx 'server 127.0.0.1:8080;' 'cloud loopback backend boundary'
Assert-Contains $cloudNginx 'ssl_certificate __TLS_CERT_PATH__;' 'cloud TLS certificate placeholder'
Assert-Contains $cloudNginx 'https://__OSS_PUBLIC_HOST__' 'cloud exact OSS CSP placeholder'
Assert-Contains $cloudSystemd 'ExecStartPre=/usr/bin/test -r /opt/uten-imp/current/server/uten-imp-server.jar' 'cloud readable JAR guard'
Assert-Contains $cloudSystemd 'ProtectSystem=full' 'cloud systemd filesystem hardening'
Assert-Contains $cloudSystemd 'TimeoutStopSec=90' 'cloud graceful shutdown budget'

Assert-Contains $cloudReadme 'UTEN_PROFILE=cloud,prod' 'combined cloud and production profiles'
Assert-Contains $cloudReadme 'flutter build web --release --no-pub --no-web-resources-cdn' 'self-hosted Flutter Web resources'
Assert-Contains $cloudReadme '禁止新旧 JAR 滚动混跑' 'two-site mixed-version prohibition'
Assert-Contains $cloudReadme 'oss:GetObjectVersion' 'OSS pinned-version read permission'
Assert-Contains $cloudReadme 'oss:ListObjectVersions' 'separate OSS version audit permission'
Assert-Contains $cloudReadme '不得用 Bucket 生命周期或批量脚本无对账清理' 'confirmed OSS version cleanup guard'
Assert-Contains $cloudReadme '生产启用版本控制时**不得要求或放行 `x-oss-forbid-overwrite`' 'versioned PUT header boundary'
Assert-Contains $cloudReadme 'SLOT_NAME=uten_onprem_replica' 'reverse replication slot procedure'
Assert-Contains $cloudReadme 'RECREATE_INVALID_SLOT=yes' 'invalid slot explicit recovery acknowledgement'
Assert-Contains $cloudReadme "grep -nE '__[A-Z0-9_]+__'" 'Nginx unresolved-placeholder guard'

Assert-Contains $preparePrimary 'RECREATE_INVALID_SLOT="${RECREATE_INVALID_SLOT:-no}"' 'invalid slot recreation defaults closed'
Assert-Contains $preparePrimary 'pg_create_physical_replication_slot(' 'physical slot creation'
Assert-Contains $preparePrimary 'ON_PREM_REPLICA_CIDR' 'reverse replication HBA input'
Assert-Contains $cloneReplica '--wal-method stream' 'streaming base backup'
Assert-Contains $cloneReplica 'primary_slot_name' 'permanent standby slot assignment'
if ($cloneReplica.Contains('--slot "$SLOT_NAME"')) {
    throw 'pg_basebackup must not claim the permanent slot while the healthy old standby is active'
}
Assert-Contains $prepareStandbyHba 'refusing to prepare standby HBA on a writable primary' 'standby-only HBA guard'
Assert-Contains $prepareStandbyHba 'connected standby hba_file is' 'exact standby HBA path guard'
Assert-Contains $replicationHarness 'Re-cloning while the permanent slot is active' 'live-slot replacement regression scenario'

'Deployment template contract checks passed.'
