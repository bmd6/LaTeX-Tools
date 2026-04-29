<#
.SYNOPSIS
    Removes LaTeX auxiliary and intermediate build files to enable a clean rebuild.

.DESCRIPTION
    Deletes the cruft LaTeX/BibTeX/Biber/MakeIndex/Glossaries/latexmk/SyncTeX leave
    behind (.aux, .toc, .log, .bbl, .bcf, .run.xml, .synctex.gz, etc.) so the next
    compile starts from a known-good state.

    Supports -WhatIf and -Confirm. Honors a project-local .latexcleanignore file
    (one filename or wildcard per line) so individually-tracked artifacts (e.g.
    a vendored .bbl) survive cleaning. Optionally also removes the final .pdf.

.PARAMETER Path
    Root directory to clean. Defaults to the current directory.

.PARAMETER Recurse
    Recurse into subdirectories. Off by default.

.PARAMETER IncludePdf
    Also delete .pdf files whose basename matches a .tex file in the same folder.

.PARAMETER ExtraExtensions
    Additional extensions (with leading dot) to remove. E.g. -ExtraExtensions .bak,.swp

.PARAMETER Force
    Skip the per-file confirmation prompt. Equivalent to -Confirm:$false.

.EXAMPLE
    .\Clear-LatexAux.ps1
    Cleans the current directory.

.EXAMPLE
    .\Clear-LatexAux.ps1 -Path .\thesis -Recurse -WhatIf
    Shows what would be deleted under .\thesis without removing anything.

.EXAMPLE
    .\Clear-LatexAux.ps1 -IncludePdf -Recurse
    Full clean including built PDFs, walking the whole tree.

.NOTES
    Safe: Never touches .tex, .bib, .cls, .sty, .bst, images, or anything not
    on the explicit extension list.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Position = 0)]
    [string]$Path = '.',

    [switch]$Recurse,

    [switch]$IncludePdf,

    [string[]]$ExtraExtensions = @(),

    [switch]$Force
)

# --- Extension list ----------------------------------------------------------
$auxExtensions = @(
    # Core LaTeX
    '.aux', '.log', '.out', '.toc', '.lof', '.lot', '.lol',
    # SyncTeX / file lists / latexmk
    '.synctex.gz', '.synctex', '.fls', '.fdb_latexmk',
    # BibTeX / Biber / biblatex
    '.bbl', '.blg', '.bcf', '.run.xml',
    # MakeIndex
    '.idx', '.ilg', '.ind',
    # Glossaries / acronyms / xindy
    '.glo', '.gls', '.glg', '.acn', '.acr', '.alg', '.xdy',
    # Beamer
    '.nav', '.snm', '.vrb',
    # todonotes / minted / external / pgfplots
    '.tdo', '.auxlock', '.figlist', '.makefile', '.dpth', '.md5',
    # Misc editor / aux
    '.bak', '.tmp'
) + $ExtraExtensions | Select-Object -Unique

# --- Resolve target ----------------------------------------------------------
try {
    $root = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
} catch {
    Write-Error "Path not found: $Path"
    exit 1
}

if ($Force) { $ConfirmPreference = 'None' }

# --- Load .latexcleanignore (optional) ---------------------------------------
$ignoreFile = Join-Path $root '.latexcleanignore'
$ignorePatterns = @()
if (Test-Path -LiteralPath $ignoreFile) {
    $ignorePatterns = Get-Content -LiteralPath $ignoreFile |
        Where-Object { $_ -and -not $_.StartsWith('#') } |
        ForEach-Object { $_.Trim() }
    Write-Verbose "Loaded $($ignorePatterns.Count) ignore pattern(s) from .latexcleanignore"
}

function Test-Ignored {
    param([System.IO.FileInfo]$File)
    foreach ($pat in $ignorePatterns) {
        if ($File.Name -like $pat) { return $true }
    }
    return $false
}

# --- Enumerate candidates ----------------------------------------------------
$gciParams = @{
    LiteralPath = $root
    File        = $true
    ErrorAction = 'SilentlyContinue'
}
if ($Recurse) { $gciParams.Recurse = $true }

$allFiles = Get-ChildItem @gciParams

# Match on full name (case-insensitive) so multi-dot extensions like
# ".synctex.gz" work correctly without false positives.
$candidates = $allFiles | Where-Object {
    $name = $_.Name.ToLowerInvariant()
    foreach ($ext in $auxExtensions) {
        if ($name.EndsWith($ext)) { return $true }
    }
    return $false
}

# Optionally include orphaned PDFs (only if a sibling .tex exists)
if ($IncludePdf) {
    $pdfCandidates = $allFiles | Where-Object {
        $_.Extension -ieq '.pdf' -and
        (Test-Path -LiteralPath (Join-Path $_.DirectoryName "$($_.BaseName).tex"))
    }
    $candidates = @($candidates) + @($pdfCandidates)
}

# --- Filter through ignore list ----------------------------------------------
$skipped = @()
$toDelete = foreach ($f in $candidates) {
    if (Test-Ignored -File $f) {
        $skipped += $f
        continue
    }
    $f
}

# --- Report & delete ---------------------------------------------------------
if (-not $toDelete) {
    Write-Host "Nothing to clean under '$root'." -ForegroundColor Green
    if ($skipped) { Write-Host "($($skipped.Count) file(s) preserved by .latexcleanignore)" -ForegroundColor DarkGray }
    return
}

$totalBytes = ($toDelete | Measure-Object -Property Length -Sum).Sum
$humanSize  = if ($totalBytes -ge 1MB) { "{0:N2} MB" -f ($totalBytes / 1MB) }
              elseif ($totalBytes -ge 1KB) { "{0:N1} KB" -f ($totalBytes / 1KB) }
              else { "$totalBytes B" }

Write-Host ""
Write-Host "Cleaning '$root'" -ForegroundColor Cyan
Write-Host ("  {0} file(s), {1}" -f $toDelete.Count, $humanSize) -ForegroundColor Cyan
if ($skipped) { Write-Host ("  {0} preserved by ignore list" -f $skipped.Count) -ForegroundColor DarkGray }
Write-Host ""

$deleted = 0
$failed  = @()
foreach ($f in $toDelete) {
    $relative = $f.FullName.Substring($root.Length).TrimStart('\','/')
    if ($PSCmdlet.ShouldProcess($f.FullName, "Remove")) {
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            Write-Host "  removed  $relative" -ForegroundColor DarkGray
            $deleted++
        } catch {
            Write-Host "  FAILED   $relative  ($($_.Exception.Message))" -ForegroundColor Red
            $failed += $f
        }
    }
}

Write-Host ""
Write-Host ("Done. Removed {0} of {1} file(s)." -f $deleted, $toDelete.Count) -ForegroundColor Green
if ($failed) {
    Write-Host ("{0} file(s) could not be removed (likely locked by an editor or viewer):" -f $failed.Count) -ForegroundColor Yellow
    $failed | ForEach-Object { Write-Host "  $($_.FullName)" -ForegroundColor Yellow }
    exit 2
}
