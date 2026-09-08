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
    The version folder under %LOCALAPPDATA%\Programs\Swift\Toolchains, minus the variant suffix.
    Default: 6.3.3, what this front was last built against.

.PARAMETER SwiftVariant
    Which of the two toolchains swift.org's installer carries to build with. Default NoAsserts, and
    that default is load-bearing rather than a preference: swift-structured-queries, which arrives
    through SQLiteData, trips an assertion in the constraint solver that only an assertions-enabled
    compiler can reach - so +Asserts, the one the installer puts on PATH, cannot build this front at
    all. The installer ships +NoAsserts too but does not install it by default; docs/windows.md has
    the one-line command.

.PARAMETER WindowsSdkVersion
    Which Windows Kits 10 version to take the Universal CRT redistributable DLLs from.

.PARAMETER ScratchPath
    Passed to `swift build --scratch-path`. Worth pointing elsewhere when the default is locked by a
    process Windows will not let anyone kill - it has happened.

.PARAMETER WebKitDir
    Where the engine DLLs live. Any WebKit2.dll build whose exports still match
    windows/vendor/WebKit2's import library will do - a CI build, a local one - which is the point of
    the parameter. It only defaults to Playwright's because that is the one build already on this
    machine: the newest %LOCALAPPDATA%\ms-playwright\webkit-*, what `npx playwright install webkit`
    creates.

.EXAMPLE
    ./scripts/six-windows.ps1 build
.EXAMPLE
    ./scripts/six-windows.ps1 run -SwiftVersion 6.3.3
#>
param(
    [ValidateSet("build", "run", "stop")]
    [string]$Command = "build",
    [string]$SwiftVersion = "6.3.3",
    [string]$SwiftVariant = "NoAsserts",
    [string]$WindowsSdkVersion = "26100.0",
    [string]$ScratchPath = "",
    [string]$WebKitDir = ""
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

# PowerShell 5.1 turns any line a native program writes to stderr into a terminating error while
# $ErrorActionPreference is Stop - whatever the redirection - so a perfectly healthy `swift build`
# dies on its own "Fetching ..." progress. Every native call below goes through here instead and is
# judged by its exit code, which is the only thing that actually says whether it worked. This did
# not bite while windows/Package.swift had no dependencies at all: there was nothing to resolve, so
# nothing to print.
function Invoke-Native {
    param([scriptblock]$Command, [string]$What)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & $Command } finally { $ErrorActionPreference = $previous }
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE)" }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$windowsDir = Join-Path $repoRoot "windows"
$swiftRoot = "$env:LOCALAPPDATA\Programs\Swift"
$toolchainBin = "$swiftRoot\Toolchains\$SwiftVersion+$SwiftVariant\usr\bin"
$runtimeBin = "$swiftRoot\Runtimes\$SwiftVersion\usr\bin"
$sdkRoot = "$swiftRoot\Platforms\$SwiftVersion\Windows.platform\Developer\SDKs\Windows.sdk\"
$ucrtRedist = "C:\Program Files (x86)\Windows Kits\10\Redist\10.0.$WindowsSdkVersion\ucrt\DLLs\x64"

if ($WebKitDir -eq "") {
    $found = Get-ChildItem "$env:LOCALAPPDATA\ms-playwright" -Directory -Filter "webkit-*" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($found) { $WebKitDir = $found.FullName }
}
if ($WebKitDir -eq "" -or -not (Test-Path $WebKitDir)) {
    throw "No WebKit build found. Pass -WebKitDir, or run 'npx playwright install webkit' to put one under $env:LOCALAPPDATA\ms-playwright for the default to find."
}

if (-not (Test-Path $toolchainBin)) {
    $hint = if ($SwiftVariant -eq "NoAsserts") {
        "The swift.org installer carries this toolchain but leaves it out by default. Re-run it as: swift-$SwiftVersion-RELEASE-windows10.exe OptionsInstallNoAssertsToolchain=1 - it lands beside +Asserts and replaces nothing. docs/windows.md says why this front needs it."
    } else {
        "Install it from https://www.swift.org/install/windows/ or pass -SwiftVersion."
    }
    throw "No Swift $SwiftVersion+$SwiftVariant toolchain at $toolchainBin. $hint"
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

# Windows has no system SQLite - no sqlite3.h anywhere, and no import library - so GRDB's
# `GRDBSQLite` system-library target has nothing to resolve against and the build dies on
# "'sqlite3.h' file not found" before any Swift is reached. This is the same gap the Linux
# container fills with libsqlite3-dev; here the amalgamation is the whole of it. Kept out of the
# repository and in a user-scope cache for the same reason node is, and compiled once: the .lib is
# 4.5 MB and the .c takes about a minute.
#
# The defines are not free choices. GRDB declares SQLITE_ENABLE_SNAPSHOT and SQLITE_ENABLE_FTS5 as
# Swift flags on every platform but Linux, so its own source calls those APIs and the library it
# links has to have been built with them, or the link fails on symbols that read like GRDB's fault.
function Resolve-Sqlite {
    $version = "3500400"   # 3.50.4
    $year = "2025"
    $root = Join-Path $env:LOCALAPPDATA "six-tools\sqlite-amalgamation-$version"
    $header = Join-Path $root "sqlite3.h"
    $library = Join-Path $root "sqlite3.lib"

    if (-not (Test-Path $header)) {
        New-Item -ItemType Directory -Force (Split-Path -Parent $root) | Out-Null
        $zip = Join-Path $env:TEMP "sqlite-amalgamation-$version.zip"
        Write-Output "Fetching the SQLite amalgamation $version"
        Invoke-Native { & curl.exe -sL --retry 3 -o $zip "https://sqlite.org/$year/sqlite-amalgamation-$version.zip" } "downloading the SQLite amalgamation"
        Expand-Archive -Path $zip -DestinationPath (Split-Path -Parent $root) -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path $header)) { throw "no sqlite3.h under $root after unpacking" }

    if (-not (Test-Path $library)) {
        Write-Output "Compiling sqlite3.c (once)"
        Push-Location $root
        try {
            $defines = @(
                "-DSQLITE_ENABLE_FTS5", "-DSQLITE_ENABLE_FTS4", "-DSQLITE_ENABLE_SNAPSHOT",
                "-DSQLITE_ENABLE_COLUMN_METADATA", "-DSQLITE_ENABLE_RTREE",
                "-DSQLITE_ENABLE_DBSTAT_VTAB", "-DSQLITE_THREADSAFE=1"
            )
            Invoke-Native { & cl /nologo /c /O2 /MD @defines sqlite3.c | Out-Null } "compiling sqlite3.c"
            Invoke-Native { & lib /nologo /OUT:sqlite3.lib sqlite3.obj | Out-Null } "archiving sqlite3.lib"
        } finally { Pop-Location }
    }
    return $root
}

# Clang and the linker read these the way MSVC does, which is how a dependency's own system-library
# target - GRDBSQLite, whose modulemap this build never sees - gets the header and the .lib.
$sqliteDir = Resolve-Sqlite
$env:INCLUDE = "$sqliteDir;$env:INCLUDE"
$env:LIB = "$sqliteDir;$env:LIB"

# combine-schedulers arrives through SQLiteData -> Sharing -> swift-dependencies, and no released
# version of it compiles on Windows: its non-Darwin lock reaches for pthread_mutex_t on the strength
# of `import Foundation`, true on Linux and false here. UPSTREAM.md section 4 is the report; the fix
# is twenty lines of SRWLOCK, kept as a patch in windows/patches so it survives without a fork and
# is ready to send upstream.
#
# SwiftPM's own mirror mechanism is what substitutes it, and it takes only an absolute path - hence
# writing mirrors.json here rather than committing it. The clone is a sibling of the repository, not
# a copy inside it, so it stays a real git checkout that a remote can later be added to.
function Resolve-CombineSchedulers {
    $clone = Join-Path (Split-Path -Parent $repoRoot) "combine-schedulers"
    $patch = Join-Path $repoRoot "windows\patches\combine-schedulers-1.2.0-srwlock.patch"

    if (-not (Test-Path (Join-Path $clone ".git"))) {
        Write-Output "Cloning combine-schedulers to $clone"
        Invoke-Native { & git clone -q https://github.com/pointfreeco/combine-schedulers.git $clone } "cloning combine-schedulers"
        Invoke-Native { & git -C $clone checkout -q -b windows-srwlock 1.2.0 } "checking out combine-schedulers 1.2.0"
        Invoke-Native { & git -C $clone am --keep-cr $patch } "applying $patch"
        # The mirror is resolved by version, and 1.2.0 is what six pins everywhere else, so the tag
        # has to name the patched commit or SwiftPM would hand back the unpatched one.
        Invoke-Native { & git -C $clone tag -f 1.2.0 | Out-Null } "tagging the patched commit"
    }

    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $head = (& git -C $clone rev-parse "1.2.0^{commit}")
    $subject = (& git -C $clone log -1 --format=%s $head)
    $ErrorActionPreference = $previous
    $subject = "$subject".Trim()
    if ($subject -notmatch "Windows branch") {
        throw "the 1.2.0 tag in $clone is not the patched commit ($subject). Re-tag it, or delete the clone and let this script rebuild it."
    }

    $configuration = Join-Path $windowsDir ".swiftpm\configuration"
    New-Item -ItemType Directory -Force $configuration | Out-Null
    $mirrors = @{
        version = 1
        object = @(@{ original = "https://github.com/pointfreeco/combine-schedulers"; mirror = $clone })
    }
    $mirrors | ConvertTo-Json -Depth 5 | Out-File -Encoding utf8 (Join-Path $configuration "mirrors.json")
    return $clone
}

$combineSchedulers = Resolve-CombineSchedulers

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
# same-size files also keeps the engine copy from rewriting a few hundred MB on every build.
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
    Invoke-Native { & swift build @buildArgs } "swift build"

    Copy-RuntimeFiles -Source $ucrtRedist -Filter "*.dll"
    Copy-RuntimeFiles -Source $runtimeBin -Filter "*.dll"
    Copy-RuntimeFiles -Source $WebKitDir

    Write-Output "Built: $exe"
    Write-Output "Engine: $WebKitDir"
    Write-Output "SQLite: $sqliteDir"
    Write-Output "combine-schedulers: $combineSchedulers"

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
