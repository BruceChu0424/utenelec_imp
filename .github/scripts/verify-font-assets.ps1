$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$manifestPath = Join-Path $repositoryRoot 'web\fallback_fonts\SHA256SUMS.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 |
    ConvertFrom-Json

$flutterInfo = (& flutter --version --machine | ConvertFrom-Json)
if ($manifest.flutter.version -ne $flutterInfo.frameworkVersion) {
    throw "Fallback font manifest targets Flutter $($manifest.flutter.version), " +
        "but CI is using $($flutterInfo.frameworkVersion). Regenerate the " +
        'version-pinned fallback shards before upgrading Flutter.'
}

function Assert-PinnedAsset {
    param(
        [Parameter(Mandatory)]
        [object] $File,
        [Parameter(Mandatory)]
        [string] $RelativePath
    )
    $assetPath = Join-Path $repositoryRoot $relativePath
    if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
        throw "Missing pinned font asset: $($File.path)"
    }

    $asset = Get-Item -LiteralPath $assetPath
    if ($asset.Length -ne [long]$File.bytes) {
        throw "Font asset size mismatch for $($File.path): " +
            "expected $($File.bytes), found $($asset.Length)"
    }

    $actualHash = (
        Get-FileHash -LiteralPath $assetPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    if ($actualHash -ne $File.sha256) {
        throw "Font asset SHA256 mismatch for $($File.path): " +
            "expected $($File.sha256), found $actualHash"
    }
}

foreach ($file in $manifest.files) {
    Assert-PinnedAsset `
        -File $file `
        -RelativePath (Join-Path 'web\fallback_fonts' $file.path)
}

foreach ($file in $manifest.local_assets) {
    Assert-PinnedAsset -File $file -RelativePath $file.path
}

$verifiedCount = $manifest.files.Count + $manifest.local_assets.Count
Write-Host (
    "Verified {0} version-pinned font assets for Flutter {1}." -f
    $verifiedCount,
    $manifest.flutter.version
)
