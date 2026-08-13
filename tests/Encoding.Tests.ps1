<#
    Windows PowerShell 5.1 — the edition the double-click launcher uses — decodes
    a script it cannot prove is Unicode using the machine's ANSI code page. On a
    Western install that is Windows-1252, where the three UTF-8 bytes of an em
    dash come back as three separate characters, and the last of them is U+201D.

    PowerShell accepts curly quotes as real string delimiters. So an em dash
    inside a single-quoted string opens a string that is never closed, and the
    file fails to parse — not at the em dash, but at the end of the file, with a
    message about a missing terminator. The tool would not start at all.

    A byte-order mark settles it: with one, both editions read UTF-8. This file
    checks the marks are there, because the failure is silent everywhere the
    tests actually run (PowerShell 7 reads BOM-less UTF-8 correctly) and total
    on the one machine that matters.
#>

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Get-SourceFile {
    param([string[]] $Extension)

    $files = foreach ($extension in $Extension) {
        Get-ChildItem -LiteralPath $repoRoot -Filter "*.$extension" -File -Recurse |
            Where-Object { $_.FullName -notlike "*$([System.IO.Path]::DirectorySeparatorChar).git$([System.IO.Path]::DirectorySeparatorChar)*" }
    }
    return @($files)
}

function Test-Utf8Bom {
    param([string] $Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 3) { return $false }
    return ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

function Get-NonAsciiCharacter {
    param([string] $Path)

    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return @($text.ToCharArray() | Where-Object { [int]$_ -gt 127 } | Select-Object -Unique)
}

Describe 'Source encoding' {

    It 'writes every PowerShell source and the XAML as UTF-8 with a mark' {
        foreach ($file in (Get-SourceFile -Extension @('ps1', 'psm1', 'psd1', 'xaml'))) {
            Assert-True (Test-Utf8Bom -Path $file.FullName) `
                ("$($file.Name) has no UTF-8 byte-order mark. Windows PowerShell 5.1 will read it " +
                    'as ANSI, and any em dash in it becomes a stray quote that breaks the parse.')
        }
    }

    It 'keeps the double-click launchers to plain ASCII' {
        # .cmd files are read by cmd.exe in the OEM code page, where a byte-order
        # mark is printed as literal garbage before the first line runs.
        foreach ($file in (Get-SourceFile -Extension @('cmd'))) {
            Assert-True (-not (Test-Utf8Bom -Path $file.FullName)) `
                "$($file.Name) starts with a byte-order mark, which cmd.exe will echo as text."

            $unusual = @(Get-NonAsciiCharacter -Path $file.FullName)
            Assert-Equal 0 $unusual.Count `
                "$($file.Name) contains non-ASCII ($($unusual -join ' ')), which cmd.exe renders unpredictably."
        }
    }

    It 'parses every source file the way Windows PowerShell would read it' {
        # The real check: decode each file the way an ANSI-defaulting host would
        # if the mark were missing, and confirm the mark is what is saving us.
        # Code page 1252 needs registering on some .NET runtimes; where it is not
        # to be had, the parse check above still runs.
        $western = try { [System.Text.Encoding]::GetEncoding(1252) } catch { $null }
        foreach ($file in (Get-SourceFile -Extension @('ps1', 'psm1', 'psd1'))) {
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
            Assert-Equal 0 @($errors).Count "$($file.Name) does not parse: $(@($errors)[0])"

            if (-not $western) { continue }
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            $asAnsi = $western.GetString($bytes)
            foreach ($quote in @([char]0x2018, [char]0x2019, [char]0x201C, [char]0x201D)) {
                if ($asAnsi.IndexOf($quote) -ge 0) {
                    # It would break without the mark, so the mark had better be there.
                    Assert-True (Test-Utf8Bom -Path $file.FullName) `
                        "$($file.Name) would break on Windows PowerShell 5.1 without its byte-order mark."
                }
            }
        }
    }
}
