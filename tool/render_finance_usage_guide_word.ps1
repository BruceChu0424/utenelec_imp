param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
$wordApp = $null
$wordDocument = $null
$ownsWordInstance = $false
$previousSaveNormalPrompt = $null
$previousUpdateLinksAtOpen = $null
try {
    $sourcePath = (Resolve-Path -LiteralPath $InputPath).Path
    $pdfPath = [System.IO.Path]::GetFullPath($OutputPath)
    $wordApp = New-Object -ComObject Word.Application
    if ($wordApp.Visible -or $wordApp.Documents.Count -ne 0) {
        throw 'Refusing to use a Word instance that already has a visible session or documents.'
    }
    $ownsWordInstance = $true
    $wordApp.Visible = $false
    $wordApp.DisplayAlerts = 0
    $wordApp.AutomationSecurity = 3
    $previousSaveNormalPrompt = $wordApp.Options.SaveNormalPrompt
    $previousUpdateLinksAtOpen = $wordApp.Options.UpdateLinksAtOpen
    $wordApp.Options.SaveNormalPrompt = $false
    $wordApp.Options.UpdateLinksAtOpen = $false
    $wordDocument = $wordApp.Documents.Open($sourcePath, $false, $true, $false)
    $wordDocument.Repaginate()
    $wordDocument.Fields.Update() | Out-Null
    $wordDocument.ExportAsFixedFormat($pdfPath, 17)
    if (-not (Test-Path -LiteralPath $pdfPath -PathType Leaf)) {
        throw 'Microsoft Word did not produce a PDF.'
    }
    [PSCustomObject]@{
        renderer = 'Microsoft Word COM ExportAsFixedFormat'
        version = $wordApp.Version
        bytes = (Get-Item -LiteralPath $pdfPath).Length
    } | ConvertTo-Json -Compress
}
finally {
    if ($null -ne $wordDocument) {
        try { $wordDocument.Close(0) } finally {
            [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($wordDocument) | Out-Null
        }
    }
    if ($null -ne $wordApp) {
        if ($ownsWordInstance) {
            if ($null -ne $previousSaveNormalPrompt) { $wordApp.Options.SaveNormalPrompt = $previousSaveNormalPrompt }
            if ($null -ne $previousUpdateLinksAtOpen) { $wordApp.Options.UpdateLinksAtOpen = $previousUpdateLinksAtOpen }
            $wordApp.Quit()
        }
        [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($wordApp) | Out-Null
    }
}
