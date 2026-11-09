# Installs the Windows app's toolchain in a Windows 11 ARM64 guest:
# Zig and the .NET SDK under C:\tools, on the machine PATH.
# Run as the guest's administrator; see README.md.
param(
    [string]$Zig = '0.17.0',
    [string]$Dotnet = '10.0'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$tools = 'C:\tools'
New-Item -ItemType Directory -Force $tools | Out-Null

$index = Invoke-RestMethod https://ziglang.org/download/index.json
$url = $index.$Zig.'aarch64-windows'.tarball
Invoke-WebRequest -UseBasicParsing $url -OutFile "$tools\zig.zip"
Expand-Archive "$tools\zig.zip" "$tools\zig" -Force
Remove-Item "$tools\zig.zip"

Invoke-WebRequest -UseBasicParsing https://dot.net/v1/dotnet-install.ps1 `
    -OutFile "$tools\dotnet-install.ps1"
& "$tools\dotnet-install.ps1" -Channel $Dotnet -Architecture arm64 `
    -InstallDir "$tools\dotnet"
Remove-Item "$tools\dotnet-install.ps1"

$zigDir = (Get-ChildItem "$tools\zig" -Directory | Select-Object -First 1).FullName
$path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
[Environment]::SetEnvironmentVariable('Path', "$path;$zigDir;$tools\dotnet", 'Machine')
[Environment]::SetEnvironmentVariable('DOTNET_ROOT', "$tools\dotnet", 'Machine')
[Environment]::SetEnvironmentVariable('DOTNET_CLI_TELEMETRY_OPTOUT', '1', 'Machine')
