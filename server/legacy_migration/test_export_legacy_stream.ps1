# Byte-for-byte regression for the CLR CSV hot loop. No database required.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Data
$exporter = Join-Path $PSScriptRoot 'export_legacy.ps1'
$parseTokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($exporter, [ref]$parseTokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count -ne 0) { throw 'Exporter does not parse in this PowerShell runtime' }
$source = [System.IO.File]::ReadAllText($exporter)
$match = [regex]::Match($source, "(?s)csvWriterSource = @'\r?\n(.*?)\r?\n'@")
if (-not $match.Success) { throw 'Streaming writer definition not found' }
if (-not ('UtenLegacyCsvStream' -as [type])) {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        Add-Type -TypeDefinition $match.Groups[1].Value
    } else {
        Add-Type -ReferencedAssemblies System.Data -TypeDefinition $match.Groups[1].Value
    }
}

function Write-OriginalCsv {
    param([System.Data.IDataReader]$Reader, [string]$Path, [char]$Delimiter)
    $stream = [System.IO.File]::Create($Path)
    $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
    try {
        $headers = for ($column = 0; $column -lt $Reader.FieldCount; $column++) { $Reader.GetName($column) }
        $writer.WriteLine(($headers -join $Delimiter))
        $count = 0
        while ($Reader.Read()) {
            $values = for ($column = 0; $column -lt $Reader.FieldCount; $column++) {
                if ($Reader.IsDBNull($column)) { '' }
                else {
                    $value = $Reader.GetValue($column).ToString()
                    if ($value.Contains([string]$Delimiter) -or $value.Contains('"') -or $value.Contains("`r") -or $value.Contains("`n")) {
                        '"' + ($value -replace '"', '""') + '"'
                    } else { $value }
                }
            }
            $writer.WriteLine(($values -join $Delimiter))
            $count++
        }
        return $count
    } finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('uten-csv-regression-' + [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$previousCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
try {
    $table = New-Object System.Data.DataTable
    $types = @([string], [string], [decimal], [double], [datetime], [bool], [int], [long])
    for ($i = 0; $i -lt $types.Count; $i++) { $table.Columns.Add(('column_' + $i), $types[$i]) | Out-Null }
    $unicode = [string][char]0x4F18 + [char]0x817E + [char]::ConvertFromUtf32(0x1F4E6)
    $texts = @('', 'plain', 'a|b', 'a,b', 'a"b', '""', "a`rb", "a`nb", "a`r`nb", ' space ', $unicode, [DBNull]::Value)
    foreach ($text in $texts) {
        $table.Rows.Add(@($text, [DBNull]::Value, [decimal]'123.4500', [double]0.125,
                         [datetime]::new(2026, 7, 24, 13, 5, 9), $true, -17, [long]2147483648)) | Out-Null
    }
    $cases = 0
    foreach ($culture in @('en-US', 'zh-CN', 'de-DE')) {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($culture)
        foreach ($delimiter in @([char]'|', [char]',')) {
            foreach ($data in @($table, $table.Clone())) {
                $original = Join-Path $tempRoot 'original.csv'
                $current = Join-Path $tempRoot 'current.csv'
                $beforeReader = $data.CreateDataReader()
                $afterReader = $data.CreateDataReader()
                try {
                    $expectedCount = Write-OriginalCsv -Reader $beforeReader -Path $original -Delimiter $delimiter
                    $actualCount = [UtenLegacyCsvStream]::Write($afterReader, $current, $delimiter)
                    if ($expectedCount -ne $actualCount) { throw 'CSV row count differs' }
                    if ($afterReader.IsClosed) { throw 'Writer closed the caller-owned reader' }
                    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $original).Hash -ne
                        (Get-FileHash -Algorithm SHA256 -LiteralPath $current).Hash) {
                        throw ('CSV bytes differ for culture ' + $culture + ' delimiter ' + $delimiter)
                    }
                    $bytes = [System.IO.File]::ReadAllBytes($current)
                    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
                        throw 'Unexpected UTF-8 BOM'
                    }
                    $cases++
                } finally {
                    $beforeReader.Dispose()
                    $afterReader.Dispose()
                }
            }
        }
    }
    Write-Host ('PASS ' + $cases + ' byte-identical CSV cases; cultures, delimiters, empty sets, Unicode and RFC quoting')
} finally {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture
    # Remove only this explicitly-created regression workspace.
    $resolved = [System.IO.Path]::GetFullPath($tempRoot)
    $parent = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not $resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -or
        [System.IO.Path]::GetFileName($resolved) -notlike 'uten-csv-regression-*') {
        throw 'Refusing to remove an unexpected regression workspace'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
