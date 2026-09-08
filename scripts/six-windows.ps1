<#
.SYNOPSIS
    Build and run the Windows front (windows/), the recipe CLAUDE.md's Linux section asks every
    front to have: a script that survives being rediscovered from memory, instead of a paragraph of
    commands someone has to retype correctly every time.

.DESCRIPTION
    Three things a plain `swift build` in windows/ does not do on its own, all learned the hard way
    getting the rail to actually run:

    1. Swift on Windows needs the MSVC linker on PATH - `vcvars64.bat` sets that up, and this script
       imports its environment into the current PowerShell process rather than requiring a
       "Developer PowerShell" to already be running.
    2. The Swift toolchain's own bin directories are not on PATH by default even once installed.
    3. The built .exe depends on Universal CRT API-set DLLs, the Swift runtime DLLs, and now the
       real WebKit2 engine (WebKit2.dll and everything it loads - WebCore.dll, JavaScriptCore.dll,
       the WebKitWebProcess/WebKitNetworkProcess/WebKitGPUProcess helper .exes), none of which is
       guaranteed resolvable from a plain `CreateProcess` launch (a missing
       `api-ms-win-crt-utility-l1-1-0.dll` reads as `STATUS_DLL_NOT_FOUND`, 0xC0000135, with no
       further detail) - copying all three sets next to the .exe is the reliable fix, cheaper than
       chasing down why a system-wide install did not put them on the loader's path.

    windows/Package.swift takes `NiriLayout`/`KeyBindings`/`KeyContext` straight out of six/ with no
    package dependency in its graph - see that file and docs/windows.md for why - so there is
    nothing here about vcpkg, SQLite headers, or a resolved-package fetch. The WebKit engine is a
    real dependency, just not a Swift-package one: `windows/vendor/WebKit2` holds only the import
    library generated from the actual engine DLL's export table, and the DLL itself comes from
    wherever `playwright install webkit` put it - see `-PlaywrightWebKitDir` below.

    `-scratch-path` defaults to `windows/.build`, the same as a plain `swift build`; pass
    `-ScratchPath` to point elsewhere if that path is ever locked by a process Windows will not let
    anyone kill (it has happened).

    Non-ASCII punctuation is deliberately kept out of this file: PowerShell 5.1 parses a `.ps1`
    written without a BOM using the system codepage, not UTF-8, and an em dash in a string literal
    is enough to break the parser on a fresh machine - the first version of this script did exactly
    that.

.PARAMETER Command
    build - compile and copy the runtime DLLs next to the .exe (default).
    run   - build, then launch it.

.PARAMETER SwiftVersion
    The installed toolchain folder under %LOCALAPPDATA%\Programs\Swift\Toolchains, minus the
    `+Asserts` suffix every official Windows toolchain currently ships with. Default: 6.3.3, the
    version this front was last built and run against.

.PARAMETER WindowsSdkVersion
    The Windows Kits 10 version to pull the Universal CRT redistributable DLLs from. Default:
    26100.0, whatever this machine's installed SDK resolved to; check
    `C:\Program Files (x86)\Windows Kits\10\Redist` if the build's own SDKROOT differs.

.PARAMETER ScratchPath
    Passed to `swift build --scratch-path`. Default: windows/.build (swift build's own default).

.PARAMETER PlaywrightWebKitDir
    Where the real engine DLLs live. Default: auto-discovered as the newest
    `%LOCALAPPDATA%\ms-playwright\webkit-*` folder - what `playwright install webkit` (or `npx
    playwright install webkit`, run once from anywhere with Node available) creates. Pass this
    explicitly on a machine where that installer was never run, pointed at any WebKit2.dll build
    with a matching import library in windows/vendor/WebKit2.

.EXAMPLE
    ./scripts/six-windows.ps1 build
.EXAMPLE
    ./scripts/six-windows.ps1 run -SwiftVersion 6.3.3
#>
param(
    [ValidateSet("build", "run")]
    [string]$Command = "build",
    [string]$SwiftVersion = "6.3.3",
    [string]$WindowsSdkVersion = "26100.0",
    [string]$ScratchPath = "",
    [string]$PlaywrightWebKitDir = ""
)

$ErrorActionPreference = "Stop"

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

# vcvars64.bat only edits the environment of the cmd.exe it runs in; re-exporting its `set` output
# into this process is what makes cl.exe/link.exe resolve without a "Developer PowerShell" already
# being the shell this script was launched from.
$vsDevCmd = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vsDevCmd)) {
    throw "No VS Build Tools at $vsDevCmd - install 'Desktop development with C++'."
}
# vcvars64.bat prints a harmless "'vswhere.exe' is not recognized" warning on a machine without the
# full Visual Studio installer (Build Tools alone does not ship it) before falling back to its own
# default-instance lookup, which still finds cl.exe/link.exe fine. With $ErrorActionPreference set
# to Stop, PowerShell 5.1 turns that stderr line into a terminating error regardless of the `2>`
# redirect target, so the strict setting is relaxed for this one call and restored right after.
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

Push-Location $windowsDir
try {
    $buildArgs = @()
    if ($ScratchPath -ne "") { $buildArgs += @("--scratch-path", $ScratchPath) }
    & swift build @buildArgs
    if ($LASTEXITCODE -ne 0) { throw "swift build failed (exit $LASTEXITCODE)" }

    $outDir = if ($ScratchPath -ne "") { Join-Path $ScratchPath "x86_64-unknown-windows-msvc\debug" }
              else { Join-Path $windowsDir ".build\x86_64-unknown-windows-msvc\debug" }
    $exe = Join-Path $outDir "six-windows.exe"

    Copy-Item "$ucrtRedist\*.dll" $outDir -Force
    Copy-Item "$runtimeBin\*.dll" $outDir -Force
    Copy-Item "$PlaywrightWebKitDir\*" $outDir -Recurse -Force

    Write-Output "Built: $exe"
    Write-Output "Engine: $PlaywrightWebKitDir"

    if ($Command -eq "run") {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.UseShellExecute = $true
        [System.Diagnostics.Process]::Start($psi) | Out-Null
        Write-Output "Launched."
    }
} finally {
    Pop-Location
}
