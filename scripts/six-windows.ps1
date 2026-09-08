<#
.SYNOPSIS
    Build and run the Windows front (windows/).

.DESCRIPTION
    Three things a plain `swift build` in windows/ does not do on its own, each of which cost real
    time to work out:

    1. Swift on Windows needs the MSVC linker on PATH. This script imports `vcvars64.bat`'s
       environment into the current process rather than requiring a "Developer PowerShell".
    2. The Swift toolchain's own bin directories are not on PATH even once installed.
    3. The built .exe needs the Universal CRT API-set DLLs, the Swift runtime DLLs and the WebKit2
       engine copied next to it. None is reliably resolvable from a plain `CreateProcess` launch,
       and a missing one reads only as `STATUS_DLL_NOT_FOUND` (0xC0000135) - copying all three sets
       is cheaper than chasing down why a system-wide install did not put them on the loader path.

    Non-ASCII punctuation is deliberately kept out of this file: PowerShell 5.1 parses a BOM-less
    .ps1 in the system codepage, and one em dash in a string literal is enough to break the parser
    on a fresh machine.

.PARAMETER Command
    build - compile and copy the runtime DLLs next to the .exe (default).
    run   - stop whatever is running, build, then launch exactly one instance.
    stop  - stop whatever is running and do nothing else.

    All three are idempotent: `run` twice in a row leaves one window, not two, and never asks
    whether anything was running first.

.PARAMETER SwiftVersion
    The folder under %LOCALAPPDATA%\Programs\Swift\Toolchains, minus the `+Asserts` suffix every
    official Windows toolchain ships with. Default: 6.3.3, what this front was last built against.

.PARAMETER WindowsSdkVersion
    Which Windows Kits 10 version to take the Universal CRT redistributable DLLs from.

.PARAMETER ScratchPath
    Passed to `swift build --scratch-path`. Worth pointing elsewhere when the default is locked by a
    process Windows will not let anyone kill - it has happened.

.PARAMETER PlaywrightWebKitDir
    Where the real engine DLLs live. Defaults to the newest %LOCALAPPDATA%\ms-playwright\webkit-*,
    what `npx playwright install webkit` creates. Pass it explicitly on a machine where that was
    never run, pointed at any WebKit2.dll build matching windows/vendor/WebKit2's import library.

.EXAMPLE
    ./scripts/six-windows.ps1 build
.EXAMPLE
    ./scripts/six-windows.ps1 run -SwiftVersion 6.3.3
#>
param(
    [ValidateSet("build", "run", "stop")]
    [string]$Command = "build",
    [string]$SwiftVersion = "6.3.3",
    [string]$WindowsSdkVersion = "26100.0",
    [string]$ScratchPath = "",
    [string]$PlaywrightWebKitDir = ""
)

$ErrorActionPreference = "Stop"

# Every command starts by putting the machine in the same state - nothing of ours running - so that
# `run` twice in a row leaves one window rather than two, and nobody has to know what was up before.
# A six-windows that has already stopped can still be listed here with 0 threads and no image path,
# refusing taskkill with "Access is denied"; that state outlives the session that made it and clears
# only on a reboot. It has no window and does no harm, so it is reported once and ignored - what it
# does still do is hold the build directory's files mapped, which Clear-MappedOutput handles.
function Stop-SixWindows {
    $running = @(Get-Process -Name six-windows -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) { return }
    foreach ($process in $running) {
        try { $process.CloseMainWindow() | Out-Null } catch { }
    }
    Start-Sleep -Milliseconds 700
    foreach ($process in @(Get-Process -Name six-windows -ErrorAction SilentlyContinue)) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { }
    }
    Start-Sleep -Milliseconds 300
    $left = @(Get-Process -Name six-windows -ErrorAction SilentlyContinue)
    if ($left.Count -gt 0) {
        Write-Output ("Left behind, unkillable until a reboot (no window, harmless): PID " +
            (($left | ForEach-Object { $_.Id }) -join ", "))
    }
}

Stop-SixWindows
if ($Command -eq "stop") { return }

$repoRoot = Split-Path -Parent $PSScriptRoot
$windowsDir = Join-Path $repoRoot "windows"
$swiftRoot = "$env:LOCALAPPDATA\Programs\Swift"
$toolchainBin = "$swiftRoot\Toolchains\$SwiftVersion+Asserts\usr\bin"
$runtimeBin = "$swiftRoot\Runtimes\$SwiftVersion\usr\bin"
$sdkRoot = "$swiftRoot\Platforms\$SwiftVersion\Windows.platform\Developer\SDKs\Windows.sdk\"
$ucrtRedist = "C:\Program Files (x86)\Windows Kits\10\Redist\10.0.$WindowsSdkVersion\ucrt\DLLs\x64"

if ($PlaywrightWebKitDir -eq "") {
    $found = Get-ChildItem "$env:LOCALAPPDATA\ms-playwright" -Directory -Filter "webkit-*" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($found) { $PlaywrightWebKitDir = $found.FullName }
}
if ($PlaywrightWebKitDir -eq "" -or -not (Test-Path $PlaywrightWebKitDir)) {
    throw "No Playwright WebKit build found under $env:LOCALAPPDATA\ms-playwright - run 'npx playwright install webkit' or pass -PlaywrightWebKitDir."
}

if (-not (Test-Path $toolchainBin)) {
    throw "No Swift $SwiftVersion toolchain at $toolchainBin - install it from https://www.swift.org/install/windows/ or pass -SwiftVersion."
}

# vcvars64.bat only edits the environment of the cmd.exe it runs in, so its `set` output is
# re-exported into this process.
$vsDevCmd = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vsDevCmd)) {
    throw "No VS Build Tools at $vsDevCmd - install 'Desktop development with C++'."
}
# On a machine with Build Tools but no full Visual Studio, vcvars64.bat prints a harmless
# "'vswhere.exe' is not recognized" before falling back to its own lookup - and PowerShell 5.1 turns
# that stderr line into a terminating error under Stop, whatever the `2>` target. Hence the relax.
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$vcvars = & cmd /c "`"$vsDevCmd`" && set" 2>$null
$ErrorActionPreference = $previousErrorActionPreference
foreach ($line in $vcvars) {
    if ($line -match '^([^=]+)=(.*)$') {
        [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
    }
}

$env:Path = "$toolchainBin;$runtimeBin;$env:Path"
$env:SDKROOT = $sdkRoot

$outDir = if ($ScratchPath -ne "") { Join-Path $ScratchPath "x86_64-unknown-windows-msvc\debug" }
          else { Join-Path $windowsDir ".build\x86_64-unknown-windows-msvc\debug" }
$exe = Join-Path $outDir "six-windows.exe"

# Windows will not overwrite a file some process still has mapped, and a six-windows that has already
# stopped can go on holding this whole directory: 0 threads, no image path left, and taskkill
# answering "Access is denied" - a state that outlives the session it came from and clears only on a
# reboot. Left alone it fails the build in two different places (the linker on six-windows.exe,
# Copy-Item on BlocksRuntime.dll), so neither step is allowed to depend on overwriting anything.
# Renaming is what still works on a mapped image, so the old .exe is moved aside rather than deleted.
function Clear-MappedOutput {
    if (-not (Test-Path $outDir)) { return }
    Get-ChildItem (Join-Path $outDir "stale-*.exe") -ErrorAction SilentlyContinue | ForEach-Object {
        try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch { }
    }
    if (Test-Path $exe) {
        try { Remove-Item $exe -Force -ErrorAction Stop }
        catch {
            $aside = "stale-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".exe"
            Rename-Item $exe $aside -ErrorAction SilentlyContinue
        }
    }
}

# Same reason, the other half: a locked DLL here is by definition already present, and it is the same
# build artefact the copy would have written, so a failure to overwrite it is not a failure. Skipping
# same-size files also keeps the Playwright engine copy from rewriting ~400 MB on every build.
function Copy-RuntimeFiles {
    param([string]$Source, [string]$Filter = "*")
    $prefix = (Resolve-Path $Source).Path.TrimEnd("\")
    foreach ($file in Get-ChildItem $Source -Filter $Filter -Recurse -File) {
        $target = Join-Path $outDir $file.FullName.Substring($prefix.Length).TrimStart("\")
        $targetDir = Split-Path -Parent $target
        if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Force $targetDir | Out-Null }
        if ((Test-Path $target) -and ((Get-Item $target).Length -eq $file.Length)) { continue }
        try { Copy-Item $file.FullName $target -Force -ErrorAction Stop }
        catch { Write-Warning "in use, keeping the copy already there: $target" }
    }
}

Push-Location $windowsDir
try {
    Clear-MappedOutput

    $buildArgs = @()
    if ($ScratchPath -ne "") { $buildArgs += @("--scratch-path", $ScratchPath) }
    & swift build @buildArgs
    if ($LASTEXITCODE -ne 0) { throw "swift build failed (exit $LASTEXITCODE)" }

    Copy-RuntimeFiles -Source $ucrtRedist -Filter "*.dll"
    Copy-RuntimeFiles -Source $runtimeBin -Filter "*.dll"
    Copy-RuntimeFiles -Source $PlaywrightWebKitDir

    Write-Output "Built: $exe"
    Write-Output "Engine: $PlaywrightWebKitDir"

    if ($Command -eq "run") {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.UseShellExecute = $true
        $started = [System.Diagnostics.Process]::Start($psi)
        Write-Output "Launched: PID $($started.Id)"
    }
} finally {
    Pop-Location
}
