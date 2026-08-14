$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$commands = @('sandwich', 'node', 'npm', 'npx', 'pnpm', 'yarn', 'corepack')
$shimDir = Join-Path $root '.windows-bin'

$bun = Get-Command bun -CommandType Application -ErrorAction Stop | Select-Object -First 1
$git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
$gitRoot = Split-Path -Parent (Split-Path -Parent $git.Source)
$bash = Join-Path $gitRoot 'bin\bash.exe'

if (-not (Test-Path -LiteralPath $bash -PathType Leaf)) {
    throw "Git for Windows Bash was not found: $bash"
}

function Convert-ToBashPath {
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^([A-Za-z]):\\(.*)$') {
        throw "Expected a local Windows path: $full"
    }
    return "/$($Matches[1].ToLowerInvariant())/$($Matches[2] -replace '\\', '/')"
}

function Set-PathEntryFirst {
    param([string]$PathValue, [string]$Candidate)

    $comparison = [StringComparison]::OrdinalIgnoreCase
    $remaining = @()
    foreach ($entry in ($PathValue -split ';')) {
        $trimmed = $entry.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed) -and
            -not [string]::Equals($trimmed.TrimEnd('\'), $Candidate.TrimEnd('\'), $comparison)) {
            $remaining += $trimmed
        }
    }
    return (@($Candidate) + $remaining) -join ';'
}

$rootBash = Convert-ToBashPath $root
$bunBash = Convert-ToBashPath $bun.Source
New-Item -ItemType Directory -Path $shimDir -Force | Out-Null

$dispatcher = @"
#!/usr/bin/env bash
export SANDWICH_BUN='$bunBash'
export PATH='$rootBash/bin':"`$PATH"
export DO_NOT_TRACK=1
command_name="`$1"
shift
exec '$rootBash/bin/'"`$command_name" "`$@"
"@
$dispatcherPath = Join-Path $shimDir 'dispatch.sh'
$dispatcher = $dispatcher -replace "`r`n", "`n"
[IO.File]::WriteAllText($dispatcherPath, $dispatcher, [Text.UTF8Encoding]::new($false))

foreach ($name in $commands) {
    $entrypoint = Join-Path $root "bin\$name"
    if (-not (Test-Path -LiteralPath $entrypoint -PathType Leaf)) {
        throw "Sandwich entrypoint not found: $entrypoint"
    }

    $wrapper = @"
@echo off
"$bash" "$shimDir\dispatch.sh" $name %*
exit /b %ERRORLEVEL%
"@
    Set-Content -LiteralPath (Join-Path $shimDir "$name.cmd") -Value $wrapper -Encoding ascii
}

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$newUserPath = Set-PathEntryFirst -PathValue $userPath -Candidate $shimDir
if (-not [string]::Equals($userPath, $newUserPath, [StringComparison]::OrdinalIgnoreCase)) {
    [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
    Write-Host "Added to the front of user PATH: $shimDir"
} else {
    Write-Host "User PATH already starts with: $shimDir"
}

$env:Path = Set-PathEntryFirst -PathValue $env:Path -Candidate $shimDir

$sandwich = Get-Command sandwich -CommandType Application -ErrorAction Stop | Select-Object -First 1
Write-Host "sandwich: $($sandwich.Source)"
Write-Host 'The current PowerShell process and future shells can now use Sandwich.'
Write-Host 'Run: sandwich doctor'
