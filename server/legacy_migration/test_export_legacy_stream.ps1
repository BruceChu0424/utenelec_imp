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
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $numberStyle = [System.Globalization.NumberStyles]::Float
    $preciseDecimal = [decimal]::Parse('0.9141234567890123456789', $invariant)
    $scaledDecimal = [decimal]::Parse('12.3400000000000000000000', $invariant)
    $preciseDouble = [double]::Parse('1.2345678901234567', $invariant)
    $nextDouble = [double]::Parse('1.0000000000000002', $invariant)
    $preciseSingle = [single]::Parse('1.23456789', $invariant)
    # Framework Double.ToString() defaults to G15; prove that loses real bits.
    $legacyG15 = [double]::Parse($preciseDouble.ToString('G15', $invariant), $numberStyle, $invariant)
    if ([BitConverter]::DoubleToInt64Bits($legacyG15) -eq [BitConverter]::DoubleToInt64Bits($preciseDouble)) {
        throw 'The selected precision fixture does not expose the historical G15 loss'
    }
    if ($PSVersionTable.PSEdition -ne 'Core') {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $invariant
        $legacyDefault = [double]::Parse($preciseDouble.ToString(), $numberStyle, $invariant)
        if ([BitConverter]::DoubleToInt64Bits($legacyDefault) -eq [BitConverter]::DoubleToInt64Bits($preciseDouble)) {
            throw 'The Framework default-format regression fixture no longer demonstrates precision loss'
        }
    }

    $priceTable = New-Object System.Data.DataTable
    $priceNames = @('price', 'a_price', 'price2', 'sprice', 'material_price', 'die_cast_price', 'machining_price', 'other_float', 'price_style')
    $priceTypes = @([decimal], [double], [single], [double], [decimal], [double], [double], [double], [int])
    $priceValues = @($preciseDecimal, $preciseDouble, $preciseSingle, $nextDouble, $scaledDecimal,
                     [double]-0.125, [double]0.00000000000012345678901234567, $preciseDouble, 17)
    for ($i = 0; $i -lt $priceNames.Count; $i++) { $priceTable.Columns.Add($priceNames[$i], $priceTypes[$i]) | Out-Null }
    $priceTable.Rows.Add($priceValues) | Out-Null
    $priceTable.Rows.Add(@([DBNull]::Value, [double]0, [single]0, [double]-0.0, [decimal]0, [double]0, [double]0, [double]0, 0)) | Out-Null
    $priceCases = 0
    foreach ($culture in @('en-US', 'zh-CN', 'de-DE', 'fr-FR')) {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($culture)
        foreach ($delimiter in @([char]'|', [char]',')) {
            $pricePath = Join-Path $tempRoot 'prices.csv'
            $priceReader = $priceTable.CreateDataReader()
            try {
                $priceCount = [UtenLegacyCsvStream]::Write($priceReader, $pricePath, $delimiter)
                if ($priceCount -ne 2) { throw 'Price writer lost a row' }
                if ($priceReader.IsClosed) { throw 'Price writer closed the caller-owned reader' }
            } finally { $priceReader.Dispose() }
            $exported = @(Import-Csv -LiteralPath $pricePath -Delimiter $delimiter)
            if ($exported[0].price -ne '0.9141234567890123456789' -or $exported[0].material_price -ne '12.3400000000000000000000') {
                throw ('Decimal price digits or scale changed for culture ' + $culture)
            }
            foreach ($field in @('a_price', 'sprice', 'die_cast_price', 'machining_price')) {
                $parsed = [double]::Parse($exported[0].$field, $numberStyle, $invariant)
                $originalValue = [double]$priceTable.Rows[0][$field]
                if ([BitConverter]::DoubleToInt64Bits($parsed) -ne [BitConverter]::DoubleToInt64Bits($originalValue)) {
                    throw ('Double price bits changed for ' + $field + ' culture ' + $culture)
                }
            }
            $parsedSingle = [single]::Parse($exported[0].price2, $numberStyle, $invariant)
            if ([BitConverter]::ToInt32([BitConverter]::GetBytes($parsedSingle), 0) -ne
                [BitConverter]::ToInt32([BitConverter]::GetBytes($preciseSingle), 0)) {
                throw ('Single price bits changed for culture ' + $culture)
            }
            if ($exported[0].other_float -ne $preciseDouble.ToString() -or $exported[0].price_style -ne '17') {
                throw 'A non-price column was reformatted'
            }
            if ($exported[1].price -ne '' -or $exported[1].a_price -ne '0' -or $exported[1].price2 -ne '0') {
                throw 'Null or zero price was changed into another fact'
            }
            if ([UtenLegacyCsvStream]::FormatValue($preciseDecimal, 'A_PRICE') -ne '0.9141234567890123456789') {
                throw 'Price column recognition should ignore case'
            }
            if ([System.Threading.Thread]::CurrentThread.CurrentCulture.Name -ne $culture) { throw 'Writer changed caller culture' }
            $priceCases++
        }
    }
    Write-Host ('PASS ' + $cases + ' byte-identical non-price CSV cases; ' + $priceCases + ' exact price cases; invariant decimal digits and floating-point round-trip bits')
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
