[CmdletBinding(DefaultParameterSetName = "Paths", SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CommitMessage,

    [Parameter(Mandatory = $true, ParameterSetName = "Paths")]
    [ValidateNotNullOrEmpty()]
    [string[]]$Paths,

    [Parameter(Mandatory = $true, ParameterSetName = "All")]
    [switch]$All,

    [Parameter(Mandatory = $true, ParameterSetName = "All")]
    [ValidateSet("UPLOAD_ALL_REVIEWED")]
    [string]$ConfirmFullSnapshot,

    [ValidateSet("origin")]
    [string]$Remote = "origin",

    [string]$Branch,

    [switch]$DisableProxyForThisRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$Capture,
        [switch]$Network
    )

    $prefix = @()
    if ($Network -and $DisableProxyForThisRun) {
        $prefix = @("-c", "http.proxy=", "-c", "https.proxy=")
    }

    if ($Capture) {
        $output = @(& git @prefix @Arguments 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "git $($Arguments -join ' ') failed (exit=$LASTEXITCODE)"
        }
        return $output
    }

    & git @prefix @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed (exit=$LASTEXITCODE)"
    }
}

function Get-BlockedStagedPath {
    param([Parameter(Mandatory = $true)][string[]]$StagedPaths)

    foreach ($path in $StagedPaths) {
        $normalized = $path.Replace("\", "/")
        $isEnv = $normalized -match "(?i)(^|/)\.env($|\.)"
        $isEnvExample = $normalized -match "(?i)\.env(\.[^/]+)?\.example$"
        $isGenerated = $normalized -match "(?i)(^|/)(build|target|\.dart_tool|node_modules|\.next|coverage)(/|$)"
        $isRuntime = $normalized -match "(?i)^(website/public/uploads|server/backups|website/prisma/backups)/"
        $isPrivateMaterial = $normalized -match "(?i)(^|/)(id_rsa|id_ed25519)$" -or
            $normalized -match "(?i)\.(pem|key|p12|pfx|jks|keystore|dump|bak|xlsx?|csv)$"

        if (($isEnv -and -not $isEnvExample) -or $isGenerated -or $isRuntime -or $isPrivateMaterial) {
            $normalized
        }
    }
}

function Assert-NoObviousSecretAddition {
    $diff = Invoke-Git -Arguments @(
        "diff", "--cached", "--no-color", "--unified=0", "--no-ext-diff"
    ) -Capture
    $added = $diff | Where-Object { $_ -like "+*" -and $_ -notlike "+++*" }
    $patterns = [ordered]@{
        "private-key-header" = "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"
        "aws-access-key" = "AKIA[0-9A-Z]{16}"
        "github-token" = "gh[pousr]_[A-Za-z0-9]{20,}"
        "aliyun-access-key" = "LTAI[0-9A-Za-z]{12,}"
        "credential-assignment" = '(?i)(password|passwd|secret|api[_-]?key|access[_-]?key|private[_-]?key|token)\s*[:=]\s*[''"][^''"<>${}]{8,}[''"]'
        "credentialed-database-url" = '(?i)(postgres(ql)?|mysql|mongodb(\+srv)?):\/\/[^:\s]+:[^@\s]+@'
    }

    foreach ($entry in $patterns.GetEnumerator()) {
        if ($added -match $entry.Value) {
            throw "Potential secret pattern '$($entry.Key)' found in staged additions. Inspect locally and rotate any real credential before publishing."
        }
    }
}

$root = (Invoke-Git -Arguments @("rev-parse", "--show-toplevel") -Capture | Select-Object -First 1).Trim()
Push-Location $root
$stagingStarted = $false
$commitCreated = $false
try {
    $currentBranch = (Invoke-Git -Arguments @("branch", "--show-current") -Capture | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($currentBranch)) {
        throw "Detached HEAD is not publishable. Switch to a named feature branch first."
    }
    if ($currentBranch -in @("main", "master")) {
        throw "Direct publication from '$currentBranch' is disabled. Use a feature branch and merge only after CI."
    }
    if (-not [string]::IsNullOrWhiteSpace($Branch) -and $Branch -ne $currentBranch) {
        throw "Requested branch '$Branch' differs from current branch '$currentBranch'."
    }
    $Branch = $currentBranch
    $initialHead = (Invoke-Git -Arguments @("rev-parse", "HEAD") -Capture | Select-Object -First 1).Trim()

    foreach ($gitState in @("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD")) {
        $statePath = (Invoke-Git -Arguments @("rev-parse", "--git-path", $gitState) -Capture |
            Select-Object -First 1).Trim()
        if (Test-Path -LiteralPath $statePath) {
            throw "Git operation '$gitState' is in progress. Finish it before publishing."
        }
    }
    foreach ($gitState in @("rebase-merge", "rebase-apply")) {
        $statePath = (Invoke-Git -Arguments @("rev-parse", "--git-path", $gitState) -Capture |
            Select-Object -First 1).Trim()
        if (Test-Path -LiteralPath $statePath) {
            throw "Git rebase is in progress. Finish it before publishing."
        }
    }

    if ($All -and $Branch -notmatch "^uimp/solo-maintainer-full-upload-[0-9]{8}$") {
        throw "-All is allowed only on uimp/solo-maintainer-full-upload-YYYYMMDD."
    }
    if (-not $All) {
        $rootFull = [IO.Path]::GetFullPath($root).TrimEnd("\", "/")
        $rootPrefix = $rootFull + [IO.Path]::DirectorySeparatorChar
        foreach ($path in $Paths) {
            if ([string]::IsNullOrWhiteSpace($path) -or $path -in @(".", "./", ".\") -or
                $path.StartsWith(":") -or [IO.Path]::IsPathRooted($path) -or
                $path -match "(^|[\\/])\.\.([\\/]|$)" -or
                $path -match "[*?\[\]]") {
                throw "Path '$path' must name one literal repository-relative file without '.', pathspec magic, '..', or glob characters."
            }
            $fullPath = [IO.Path]::GetFullPath((Join-Path $root $path))
            if ($fullPath -ne $rootFull -and
                -not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Path '$path' resolves outside the repository."
            }
            if (Test-Path -LiteralPath $fullPath -PathType Container) {
                throw "Path '$path' is a directory. Enumerate individual files, or use the reviewed -All snapshot mode."
            }
        }
        $blockedDeclared = @(Get-BlockedStagedPath -StagedPaths $Paths)
        if ($blockedDeclared.Count -gt 0) {
            throw "Blocked sensitive/generated path(s): $($blockedDeclared -join ', ')"
        }
    }

    $remoteUrl = (Invoke-Git -Arguments @("remote", "get-url", $Remote) -Capture | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($remoteUrl)) {
        throw "Remote '$Remote' has no URL."
    }

    $alreadyStaged = @(Invoke-Git -Arguments @("diff", "--cached", "--name-only") -Capture |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($alreadyStaged.Count -gt 0) {
        throw "The index already contains $($alreadyStaged.Count) staged path(s). Commit or unstage them before using this helper."
    }

    Write-Host "Repository: $root"
    Write-Host "Target:     $Remote/$Branch ($remoteUrl)"
    Invoke-Git -Arguments @("status", "--short", "--branch")

    if (-not $PSCmdlet.ShouldProcess(
            "$Remote/$Branch",
            "stage, validate, commit, push, and verify reviewed changes")) {
        return
    }

    $stagingStarted = $true
    if ($All) {
        Invoke-Git -Arguments @("add", "-A")
    }
    else {
        Invoke-Git -Arguments (@("--literal-pathspecs", "add", "--") + $Paths)
    }
    $stagedPaths = @(Invoke-Git -Arguments @("-c", "core.quotepath=false", "diff", "--cached", "--name-only") -Capture |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($stagedPaths.Count -eq 0) {
        throw "No staged changes were produced."
    }
    if (-not $All) {
        $declaredPaths = @($Paths | ForEach-Object { $_.Replace("\", "/") -replace '^\./+', '' } |
            Sort-Object -Unique)
        $actualPaths = @($stagedPaths | ForEach-Object { $_.Replace("\", "/") } |
            Sort-Object -Unique)
        if (Compare-Object $declaredPaths $actualPaths) {
            throw "Staged path set differs from the explicitly declared file set."
        }
    }

    $blocked = @(Get-BlockedStagedPath -StagedPaths $stagedPaths)
    if ($blocked.Count -gt 0) {
        throw "Blocked sensitive/generated path(s): $($blocked -join ', ')"
    }

    Invoke-Git -Arguments @("diff", "--cached", "--check")
    Assert-NoObviousSecretAddition
    $stagedTree = (Invoke-Git -Arguments @("write-tree") -Capture | Select-Object -First 1).Trim()

    Write-Host "`nStaged paths:"
    Invoke-Git -Arguments @("-c", "core.quotepath=false", "diff", "--cached", "--name-status")
    Write-Host "`nStaged summary:"
    Invoke-Git -Arguments @("diff", "--cached", "--stat")

    $headBeforeCommit = (Invoke-Git -Arguments @("rev-parse", "HEAD") -Capture | Select-Object -First 1).Trim()
    $branchBeforeCommit = (Invoke-Git -Arguments @("branch", "--show-current") -Capture |
        Select-Object -First 1).Trim()
    $stagedPathsBeforeCommit = @(Invoke-Git -Arguments @(
            "-c", "core.quotepath=false", "diff", "--cached", "--name-only"
        ) -Capture | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $stagedTreeBeforeCommit = (Invoke-Git -Arguments @("write-tree") -Capture |
        Select-Object -First 1).Trim()
    if ($headBeforeCommit -ne $initialHead -or $branchBeforeCommit -ne $Branch -or
        (Compare-Object $stagedPaths $stagedPathsBeforeCommit) -or
        $stagedTreeBeforeCommit -ne $stagedTree) {
        throw "HEAD, branch, staged paths, or staged bytes changed during validation; publication aborted."
    }

    Invoke-Git -Arguments @("commit", "-m", $CommitMessage)
    $commitCreated = $true
    $localSha = (Invoke-Git -Arguments @("rev-parse", "HEAD") -Capture | Select-Object -First 1).Trim()
    Invoke-Git -Arguments @("push", "-u", $Remote, $Branch) -Network

    $remoteLine = (Invoke-Git -Arguments @("ls-remote", $Remote, "refs/heads/$Branch") -Capture -Network |
        Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($remoteLine)) {
        throw "Remote branch '$Remote/$Branch' was not readable after push."
    }
    $remoteSha = ($remoteLine -split "\s+")[0]
    if ($localSha -ne $remoteSha) {
        throw "Remote SHA '$remoteSha' differs from local HEAD '$localSha'."
    }

    Write-Host "`nPUBLISHED: $Remote/$Branch @ $localSha"
    Invoke-Git -Arguments @("status", "--short", "--branch")
}
catch {
    if ($stagingStarted -and -not $commitCreated) {
        & git restore --staged -- . 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Automatic index rollback failed; inspect git diff --cached before continuing."
        }
    }
    throw
}
finally {
    Pop-Location
}
