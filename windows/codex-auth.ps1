param(
    [Parameter(Position = 0)]
    [string]$Command = "help",

    [Parameter(Position = 1)]
    [string]$Email,

    [Parameter(Position = 2, ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"

function Get-DefaultCodexHome {
    if ($env:CODEX_AUTH_HOME) {
        return [System.IO.Path]::GetFullPath($env:CODEX_AUTH_HOME)
    }

    if ($env:CODEX_AUTH_DEFAULT_HOME) {
        return [System.IO.Path]::GetFullPath($env:CODEX_AUTH_DEFAULT_HOME)
    }

    return (Join-Path $env:USERPROFILE ".codex")
}

$DefaultCodexHome = Get-DefaultCodexHome
$ActiveAuthFile = Join-Path $DefaultCodexHome "auth.json"
$ProfilesDir = Join-Path $DefaultCodexHome "auth-profiles"
$ProfileHomesDir = Join-Path $ProfilesDir "homes"
$MetaFile = Join-Path $ProfilesDir "profiles.json"
$ToolCmd = Join-Path $PSScriptRoot "codex-auth.cmd"

function Show-Help {
    @"
codex-auth - local Codex auth profile manager

Usage:
  codex-auth login <email>         Open a terminal to login with a private CODEX_HOME
  codex-auth use <email|index>     Save refreshed auth, then activate a saved account
  codex-auth next                  Switch to the next saved account with auth
  codex-auth next-run              Switch to the next account and open shared-history Codex
  codex-auth run <email|index>     Open Codex with that account and default /resume history
  codex-auth run-isolated <email|index> Open Codex with a private CODEX_HOME
  codex-auth sessions [--all]      List saved sessions from every local account
  codex-auth resume-all [--all]    Pick a saved session across accounts and resume it
  codex-auth list                  List saved accounts with indexes
  codex-auth remove <email|index>  Remove a saved account home
  codex-auth status                Show active default auth and matching account
  codex-auth verify                Ask a fresh Codex process which account it loaded
  codex-auth doctor                Check profiles, token emails, PATH, and env issues
  codex-auth clean [options]       Remove generated leftovers and optional old backups
  codex-auth install-user [options] Install codex-auth into .codex\bin
  codex-auth env                   Show CODEX_HOME cleanup commands
  codex-auth help                  Show this help

Recommended setup:
  1. codex-auth login acc1@company.com
  2. codex-auth login acc2@company.com
  3. codex-auth login acc3@company.com
  4. codex-auth list
  5. codex-auth use 1
  6. codex
  7. codex-auth next
  8. codex-auth run 2             Launch Codex with shared /resume history

Notes:
  - Do not use "codex logout" for accounts you want to keep; logout may revoke tokens.
  - Profile files contain login tokens. Keep the .codex folder private.
  - codex-auth sets CLI credential storage to "file" in its Codex homes.
  - Start a new Codex process after switching accounts.
  - use/next stop the shared daemon; quit active Codex sessions before switching.
  - run-isolated keeps separate session history for that account.
  - Codex /resume filters new sessions by account; resume-all lists them together.
  - Use only accounts you are authorized to use and follow your org/OpenAI limits.
"@
}

function Ensure-Dir($Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Ensure-Store {
    Ensure-Dir $ProfilesDir
    Ensure-Dir $ProfileHomesDir
}

function Read-JsonFile($Path, $Default) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return $Default
    }

    $raw = Get-Content -Raw -LiteralPath $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $Default
    }

    return $raw | ConvertFrom-Json
}

function Save-JsonFile($Path, $Value) {
    $json = $Value | ConvertTo-Json -Depth 12
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Normalize-Email($Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Email is required."
    }

    return $Value.Trim().ToLowerInvariant()
}

function Get-SafeProfileName($Value) {
    return ((Normalize-Email $Value) -replace '[^a-z0-9@._-]', '_')
}

function Get-ProfileHome($Value) {
    $safe = Get-SafeProfileName $Value
    $candidateHome = Join-Path $ProfileHomesDir $safe
    if (([Text.Encoding]::UTF8.GetByteCount((Join-Path $candidateHome "app-server-control\app-server-control.sock"))) -le 104) {
        return $candidateHome
    }

    # The app-server daemon uses a Unix-domain socket with a short path limit.
    $bytes = [Text.Encoding]::UTF8.GetBytes((Normalize-Email $Value))
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = [BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant().Substring(0, 12)
    }
    finally {
        $hash.Dispose()
    }
    return (Join-Path $ProfileHomesDir "p-$digest")
}

function Get-LegacyProfilePath($Value) {
    $safe = Get-SafeProfileName $Value
    return (Join-Path $ProfilesDir "$safe.auth.json")
}

function Get-RelativeHome($HomePath) {
    $fullRoot = [System.IO.Path]::GetFullPath($ProfilesDir)
    $fullHome = [System.IO.Path]::GetFullPath($HomePath)
    if (-not $fullHome.StartsWith($fullRoot + [System.IO.Path]::DirectorySeparatorChar)) {
        throw "Profile home is outside the profile store: $fullHome"
    }

    return $fullHome.Substring($fullRoot.Length + 1)
}

function Resolve-ProfileHomeFromMeta($Profile) {
    if ($Profile.home) {
        return [System.IO.Path]::GetFullPath((Join-Path $ProfilesDir $Profile.home))
    }

    return Get-ProfileHome $Profile.email
}

function Get-ProfileAuthFile($EmailValue) {
    return (Join-Path (Get-ProfileHome $EmailValue) "auth.json")
}

function Get-FileHashValue($Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Load-Meta {
    Ensure-Store
    $meta = Read-JsonFile $MetaFile ([pscustomobject]@{ profiles = @() })
    if ($null -eq $meta.profiles) {
        $meta | Add-Member -NotePropertyName profiles -NotePropertyValue @()
    }
    return $meta
}

function Save-Meta($Meta) {
    Ensure-Store
    Save-JsonFile $MetaFile $Meta
}

function Get-AuthSummary($Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{
            exists = $false
            sha256 = $null
        }
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            exists = $false
            sha256 = $null
        }
    }

    $auth = Read-JsonFile $Path $null
    $tokenFields = @()
    if ($auth -and $auth.tokens) {
        $tokenFields = @($auth.tokens.PSObject.Properties.Name)
    }
    $tokenEmail = $null
    if ($auth -and $auth.tokens -and $auth.tokens.id_token) {
        $tokenEmail = Get-EmailFromJwt $auth.tokens.id_token
    }

    return [pscustomobject]@{
        exists = $true
        auth_mode = $auth.auth_mode
        last_refresh = $auth.last_refresh
        account_id = if ($auth.tokens -and $auth.tokens.account_id) { $auth.tokens.account_id } else { $null }
        token_email = $tokenEmail
        has_api_key = [bool]$auth.OPENAI_API_KEY
        token_fields = ($tokenFields -join ",")
        sha256 = Get-FileHashValue $Path
    }
}

function ConvertFrom-Base64Url($Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $base64 = $Value.Replace("-", "+").Replace("_", "/")
    switch ($base64.Length % 4) {
        2 { $base64 += "==" }
        3 { $base64 += "=" }
        1 { return $null }
    }

    try {
        return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($base64))
    }
    catch {
        return $null
    }
}

function Get-EmailFromJwt($Jwt) {
    if ([string]::IsNullOrWhiteSpace($Jwt)) {
        return $null
    }

    $parts = $Jwt.Split(".")
    if ($parts.Count -lt 2) {
        return $null
    }

    $payload = ConvertFrom-Base64Url $parts[1]
    if ([string]::IsNullOrWhiteSpace($payload)) {
        return $null
    }

    try {
        $json = $payload | ConvertFrom-Json
        if ($json.email) {
            return ([string]$json.email).ToLowerInvariant()
        }
    }
    catch {
        return $null
    }

    return $null
}

function Copy-BaseConfigToProfileHome($HomePath) {
    Ensure-Dir $HomePath

    foreach ($name in @("config.toml", "AGENTS.md")) {
        $source = Join-Path $DefaultCodexHome $name
        $dest = Join-Path $HomePath $name
        if ((Test-Path -LiteralPath $source) -and -not (Test-Path -LiteralPath $dest)) {
            Copy-Item -LiteralPath $source -Destination $dest -Force
        }
    }
}

function Ensure-FileCredentialStore($HomePath) {
    $configPath = Join-Path $HomePath "config.toml"
    $raw = if (Test-Path -LiteralPath $configPath) { [IO.File]::ReadAllText($configPath) } else { "" }
    $section = [regex]::Match($raw, '(?m)^\s*\[')
    $head = if ($section.Success) { $raw.Substring(0, $section.Index) } else { $raw }
    $tail = if ($section.Success) { $raw.Substring($section.Index) } else { "" }
    $setting = 'cli_auth_credentials_store = "file"'
    $pattern = '(?m)^\s*cli_auth_credentials_store\s*=\s*[^\r\n]*(?:\r?\n|$)'

    if ([regex]::IsMatch($head, $pattern)) {
        $head = ([regex]::new($pattern)).Replace($head, ($setting + [Environment]::NewLine), 1)
    }
    else {
        $head = $setting + [Environment]::NewLine + $head
    }

    $updated = $head + $tail
    if ($updated -ne $raw) {
        [IO.File]::WriteAllText($configPath, $updated, [Text.UTF8Encoding]::new($false))
    }
}

function Ensure-ProfileHome($EmailValue) {
    Ensure-Store
    $profile = Find-Profile $EmailValue
    $profileHome = if ($profile) { Ensure-UsableProfileHome $profile } else { Get-ProfileHome $EmailValue }
    Copy-BaseConfigToProfileHome $profileHome
    Ensure-FileCredentialStore $profileHome
    return $profileHome
}

function Ensure-UsableProfileHome($Profile) {
    $profileHome = Resolve-ProfileHomeFromMeta $Profile
    $socket = Join-Path $profileHome "app-server-control\app-server-control.sock"
    if ([Text.Encoding]::UTF8.GetByteCount($socket) -le 104) {
        return $profileHome
    }

    $shortHome = Get-ProfileHome $Profile.email
    if ($shortHome -eq $profileHome) {
        throw "CODEX_HOME is too long for the app-server socket: $profileHome"
    }
    Ensure-Dir $shortHome
    foreach ($name in @("auth.json", "config.toml", "AGENTS.md")) {
        $source = Join-Path $profileHome $name
        $destination = Join-Path $shortHome $name
        if ((Test-Path -LiteralPath $source) -and -not (Test-Path -LiteralPath $destination)) {
            Copy-Item -LiteralPath $source -Destination $destination
        }
    }
    Upsert-ProfileMeta $Profile.email $shortHome
    Write-Host "Moved profile home reference to shorter path: $shortHome"
    return $shortHome
}

function Upsert-ProfileMeta($EmailValue, $HomePath) {
    $meta = Load-Meta
    $emailNorm = Normalize-Email $EmailValue
    $now = (Get-Date).ToUniversalTime().ToString("o")
    $authPath = Join-Path $HomePath "auth.json"
    $summary = Get-AuthSummary $authPath
    $nextProfiles = @()
    $found = $false

    foreach ($profile in @($meta.profiles)) {
        if ($profile.email -eq $emailNorm) {
            $nextProfiles += [pscustomobject]@{
                email = $emailNorm
                home = Get-RelativeHome $HomePath
                added_at = if ($profile.added_at) { $profile.added_at } else { $now }
                updated_at = $now
                auth_present = $summary.exists
                auth_mode = $summary.auth_mode
                last_refresh = $summary.last_refresh
                account_id = $summary.account_id
                token_email = $summary.token_email
                sha256 = $summary.sha256
            }
            $found = $true
        }
        else {
            $nextProfiles += $profile
        }
    }

    if (-not $found) {
        $nextProfiles += [pscustomobject]@{
            email = $emailNorm
            home = Get-RelativeHome $HomePath
            added_at = $now
            updated_at = $now
            auth_present = $summary.exists
            auth_mode = $summary.auth_mode
            last_refresh = $summary.last_refresh
            account_id = $summary.account_id
            token_email = $summary.token_email
            sha256 = $summary.sha256
        }
    }

    $meta.profiles = @($nextProfiles | Sort-Object @{ Expression = { if ($_.added_at) { $_.added_at } else { "" } } }, email)
    Save-Meta $meta
}

function Get-OrderedProfiles {
    $meta = Load-Meta
    return @($meta.profiles | Sort-Object @{ Expression = { if ($_.added_at) { $_.added_at } else { "" } } }, email)
}

function Find-Profile($EmailValue) {
    $emailNorm = Normalize-Email $EmailValue
    foreach ($profile in (Get-OrderedProfiles)) {
        if ($profile.email -eq $emailNorm) {
            return $profile
        }
    }

    return $null
}

function Resolve-ProfileSelector($Selector) {
    if ([string]::IsNullOrWhiteSpace($Selector)) {
        throw "Profile email or index is required."
    }

    $profiles = @(Get-OrderedProfiles)
    $indexValue = 0
    if ([int]::TryParse($Selector, [ref]$indexValue)) {
        if ($indexValue -lt 1 -or $indexValue -gt $profiles.Count) {
            throw "Profile index out of range: $Selector. Run codex-auth list."
        }

        return $profiles[$indexValue - 1]
    }

    $profile = Find-Profile $Selector
    if (-not $profile) {
        throw "Profile not found: $Selector"
    }

    return $profile
}

function Get-ActiveProfile($Profiles) {
    $activeSummary = Get-AuthSummary $ActiveAuthFile
    if (-not $activeSummary.exists) {
        return $null
    }

    foreach ($profile in @($Profiles)) {
        $source = Get-ProfileAuthSource $profile
        $profileSummary = Get-AuthSummary $source
        if (Test-SameAuthIdentity $activeSummary $profileSummary) {
            return $profile
        }
    }

    return $null
}

function Test-SameAuthIdentity($Left, $Right) {
    if (-not $Left.exists -or -not $Right.exists) {
        return $false
    }
    if ($Left.auth_mode -ne $Right.auth_mode) {
        return $false
    }

    # Access and refresh tokens change during normal use. Compare stable identity
    # fields instead, and use the file hash only when neither is available.
    $hasIdentity = $false
    if ($Left.account_id -and $Right.account_id) {
        if ($Left.account_id -ne $Right.account_id) {
            return $false
        }
        $hasIdentity = $true
    }
    if ($Left.token_email -and $Right.token_email) {
        if ($Left.token_email -ine $Right.token_email) {
            return $false
        }
        $hasIdentity = $true
    }

    if ($hasIdentity) {
        return $true
    }
    return [bool]($Left.sha256 -and $Left.sha256 -eq $Right.sha256)
}

function Save-ActiveAuthToProfile($Profile) {
    if (-not $Profile) {
        return
    }

    $source = Get-ProfileAuthSource $Profile
    $activeSummary = Get-AuthSummary $ActiveAuthFile
    $savedSummary = Get-AuthSummary $source
    if (-not (Test-SameAuthIdentity $activeSummary $savedSummary)) {
        return
    }
    if ($activeSummary.sha256 -eq $savedSummary.sha256) {
        return
    }

    # A fresh private login can be newer than the current default auth.
    $activeRefresh = [datetimeoffset]::MinValue
    $savedRefresh = [datetimeoffset]::MinValue
    [datetimeoffset]::TryParse($activeSummary.last_refresh, [ref]$activeRefresh) | Out-Null
    [datetimeoffset]::TryParse($savedSummary.last_refresh, [ref]$savedRefresh) | Out-Null
    if ($activeRefresh -lt $savedRefresh) {
        return
    }

    $profileHome = Resolve-ProfileHomeFromMeta $Profile
    Ensure-Dir $profileHome
    Copy-Item -LiteralPath $ActiveAuthFile -Destination (Join-Path $profileHome "auth.json") -Force
    Upsert-ProfileMeta $Profile.email $profileHome
    Write-Host "Saved refreshed auth for: $($Profile.email)"
}

function Find-CodexCommand {
    $cmd = Get-Command codex.cmd -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) {
        $cmd = Get-Command codex.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $cmd) {
        $cmd = Get-Command codex -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $cmd) {
        return $null
    }

    if ($cmd.Path) {
        return $cmd.Path
    }
    if ($cmd.Source) {
        return $cmd.Source
    }

    return $cmd.Name
}

function Find-CodexAuthCommand {
    foreach ($name in @("codex-auth.cmd", "codex-auth.ps1", "codex-auth")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) {
            if ($cmd.Path) {
                return $cmd.Path
            }
            if ($cmd.Source) {
                return $cmd.Source
            }

            return $cmd.Name
        }
    }

    return $null
}

function Invoke-CodexWithHome($HomePath, [string[]]$CodexArguments) {
    $codex = Find-CodexCommand
    if (-not $codex) {
        throw "Cannot find codex on PATH. Run prepare-login to print manual commands."
    }

    $hadOldHome = Test-Path Env:CODEX_HOME
    $oldHome = $env:CODEX_HOME
    $env:CODEX_HOME = $HomePath

    try {
        & $codex @CodexArguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        if ($hadOldHome) {
            $env:CODEX_HOME = $oldHome
        }
        else {
            Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
        }
    }

    $script:CodexExitCode = $exitCode
}

function Strip-Separator([string[]]$CodexArguments) {
    if ($CodexArguments -and $CodexArguments.Count -gt 0 -and $CodexArguments[0] -eq "--") {
        return @($CodexArguments | Select-Object -Skip 1)
    }

    return @($CodexArguments)
}

function Show-EnvHelp {
    Write-Host "Codex reads CODEX_HOME when it is set."
    Write-Host "If CODEX_HOME still points at a private login home, plain 'codex' will ignore the default .codex auth switched by codex-auth use."
    Write-Host ""
    Write-Host "Current CODEX_HOME:"
    if ($env:CODEX_HOME) {
        Write-Host ("  " + $env:CODEX_HOME)
    }
    else {
        Write-Host "  (not set)"
    }
    Write-Host ""
    Write-Host "Clear it in PowerShell:"
    Write-Host "  Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue"
    Write-Host ""
    Write-Host "Clear it in cmd.exe:"
    Write-Host "  set CODEX_HOME="
}

function Prepare-Login($EmailValue) {
    $emailNorm = Normalize-Email $EmailValue
    $profileHome = Ensure-ProfileHome $emailNorm
    Upsert-ProfileMeta $emailNorm $profileHome
    $escapedToolCmd = $ToolCmd.Replace("'", "''")

    Write-Host "Prepared private CODEX_HOME for: $emailNorm"
    Write-Host $profileHome
    Write-Host ""
    Write-Host "Manual login commands for PowerShell:"
    Write-Host ("  `$env:CODEX_HOME = '" + $profileHome.Replace("'", "''") + "'")
    Write-Host "  codex login"
    Write-Host ("  & '" + $escapedToolCmd + "' sync " + $emailNorm)
    Write-Host "  Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue"
    Write-Host ""
    Write-Host "Or in cmd.exe:"
    Write-Host ("  set CODEX_HOME=" + $profileHome)
    Write-Host "  codex login"
    Write-Host ("  """ + $ToolCmd + """ sync " + $emailNorm)
    Write-Host "  set CODEX_HOME="
}

function New-LoginScript($EmailValue) {
    $emailNorm = Normalize-Email $EmailValue
    $profileHome = Ensure-ProfileHome $emailNorm
    Upsert-ProfileMeta $emailNorm $profileHome

    $scriptPath = Join-Path $profileHome "codex-login.cmd"
    $content = @"
@echo off
setlocal
set "CODEX_HOME=$profileHome"
set "CODEX_AUTH_DEFAULT=$DefaultCodexHome"
set "CODEX_AUTH_DEFAULT_FILE=$ActiveAuthFile"
echo Logging in Codex profile: $emailNorm
echo CODEX_HOME=%CODEX_HOME%
echo.
call codex login
set "CODEX_LOGIN_EXIT=%ERRORLEVEL%"
echo.
call "$ToolCmd" finish-login $emailNorm
if errorlevel 1 (
  echo.
  echo codex-auth finish-login failed.
  pause
  exit /b %errorlevel%
)
if not "%CODEX_LOGIN_EXIT%"=="0" (
  echo.
  echo Warning: codex login exited with code %CODEX_LOGIN_EXIT%, but finish-login was attempted.
)
echo.
echo Login saved for $emailNorm and left as the active default Codex auth.
echo You can close this window.
pause
"@

    Set-Content -LiteralPath $scriptPath -Value $content -Encoding ASCII
    Write-Host "Created login script for: $emailNorm"
    Write-Host $scriptPath
    return $scriptPath
}

function Login-Profile($EmailValue) {
    $scriptPath = New-LoginScript $EmailValue
    Write-Host "Opening login terminal..."
    Start-Process -FilePath "cmd.exe" -ArgumentList @("/k", "`"$scriptPath`"")
}

function Sync-Profile($EmailValue) {
    $emailNorm = Normalize-Email $EmailValue
    $profileHome = Ensure-ProfileHome $emailNorm
    $authPath = Join-Path $profileHome "auth.json"
    if (-not (Test-Path -LiteralPath $authPath)) {
        throw "No auth.json found in profile home: $profileHome. If Codex wrote the login to the default home, run codex-auth sync-active $emailNorm."
    }

    Upsert-ProfileMeta $emailNorm $profileHome
    Write-Host "Synced profile metadata: $emailNorm"
}

function Sync-ActiveProfile($EmailValue) {
    $emailNorm = Normalize-Email $EmailValue
    if (-not (Test-Path -LiteralPath $ActiveAuthFile)) {
        throw "No active Codex auth file found at $ActiveAuthFile."
    }

    $profileHome = Ensure-ProfileHome $emailNorm
    Copy-Item -LiteralPath $ActiveAuthFile -Destination (Join-Path $profileHome "auth.json") -Force
    Upsert-ProfileMeta $emailNorm $profileHome
    Write-Host "Imported current default auth into private profile: $emailNorm"
}

function Finish-Login($EmailValue) {
    $emailNorm = Normalize-Email $EmailValue
    $profileHome = Ensure-ProfileHome $emailNorm
    $profileAuth = Join-Path $profileHome "auth.json"

    if (Test-Path -LiteralPath $profileAuth) {
        Upsert-ProfileMeta $emailNorm $profileHome
        $profile = Find-Profile $emailNorm
        Switch-ToProfile $profile
        Write-Host "Finished login from private profile auth: $emailNorm"
        return
    }

    if (Test-Path -LiteralPath $ActiveAuthFile) {
        Copy-Item -LiteralPath $ActiveAuthFile -Destination $profileAuth -Force
        Upsert-ProfileMeta $emailNorm $profileHome
        Write-Host "Finished login from default Codex auth: $emailNorm"
        Write-Host "Default Codex auth is still active for this login."
        return
    }

    throw "Login did not produce auth.json in either $profileHome or $DefaultCodexHome"
}

function Add-Login($EmailValue) {
    Sync-ActiveProfile $EmailValue
}

function Get-ProfileAuthSource($Profile) {
    $profileHome = Resolve-ProfileHomeFromMeta $Profile
    $homeAuth = Join-Path $profileHome "auth.json"
    if (Test-Path -LiteralPath $homeAuth) {
        return $homeAuth
    }

    $legacy = Get-LegacyProfilePath $Profile.email
    if (Test-Path -LiteralPath $legacy) {
        return $legacy
    }

    return $null
}

function List-Profiles {
    $activeProfile = Get-ActiveProfile (Get-OrderedProfiles)
    $rows = @()
    $index = 0

    foreach ($profile in (Get-OrderedProfiles)) {
        $index++
        $source = Get-ProfileAuthSource $profile
        $summary = Get-AuthSummary $source
        $profileHome = Resolve-ProfileHomeFromMeta $profile
        $rows += [pscustomobject]@{
            index = $index
            active = if ($activeProfile -and $activeProfile.email -eq $profile.email) { "*" } else { "" }
            email = $profile.email
            auth = if ($summary.exists) { "yes" } else { "no" }
            auth_mode = $summary.auth_mode
            token_email = $summary.token_email
            last_refresh = $summary.last_refresh
            home = $profileHome
        }
    }

    if ($rows.Count -eq 0) {
        Write-Host "No profiles saved."
        return
    }

    $rows | Format-Table -AutoSize
}

function Stop-DefaultDaemon {
    # The shared app-server keeps the previous login in memory after auth.json changes.
    Invoke-CodexWithHome $DefaultCodexHome @("app-server", "daemon", "stop")
    if ($script:CodexExitCode -ne 0) {
        throw "Could not stop the shared Codex daemon. The account was not switched."
    }
}

function Switch-ToProfile($Profile) {
    $profile = $Profile
    $source = Get-ProfileAuthSource $profile
    if (-not $source) {
        throw "No auth.json found for profile: $($profile.email). Run codex-auth login $($profile.email) first."
    }

    Ensure-Dir $DefaultCodexHome
    Save-ActiveAuthToProfile (Get-ActiveProfile (Get-OrderedProfiles))
    $source = Get-ProfileAuthSource $profile
    Ensure-FileCredentialStore $DefaultCodexHome
    Ensure-FileCredentialStore (Resolve-ProfileHomeFromMeta $profile)
    Stop-DefaultDaemon
    if (Test-Path -LiteralPath $ActiveAuthFile) {
        $backup = Join-Path $DefaultCodexHome ("auth.backup-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".json")
        Copy-Item -LiteralPath $ActiveAuthFile -Destination $backup -Force
    }

    Copy-Item -LiteralPath $source -Destination $ActiveAuthFile -Force
    Write-Host "Switched default Codex auth to: $($profile.email)"

    if ($env:CODEX_HOME -and ([System.IO.Path]::GetFullPath($env:CODEX_HOME) -ne [System.IO.Path]::GetFullPath($DefaultCodexHome))) {
        Write-Host ""
        Write-Host "Warning: CODEX_HOME is currently set, so plain 'codex' will use that folder instead of the switched default auth:"
        Write-Host ("  " + $env:CODEX_HOME)
        Write-Host ""
        Write-Host "Clear it in PowerShell:"
        Write-Host "  Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue"
        Write-Host "Or in cmd.exe:"
        Write-Host "  set CODEX_HOME="
    }
}

function Use-Profile($Selector) {
    $profile = Resolve-ProfileSelector $Selector
    Switch-ToProfile $profile
}

function Next-Profile {
    $profiles = @(Get-OrderedProfiles | Where-Object { Get-ProfileAuthSource $_ })
    if ($profiles.Count -eq 0) {
        throw "No profiles with auth found. Run codex-auth list."
    }

    $active = Get-ActiveProfile $profiles
    $nextIndex = 0
    if ($active) {
        for ($i = 0; $i -lt $profiles.Count; $i++) {
            if ($profiles[$i].email -eq $active.email) {
                $nextIndex = ($i + 1) % $profiles.Count
                break
            }
        }
    }

    $script:NextProfile = $profiles[$nextIndex]
    Switch-ToProfile $script:NextProfile
}

function Run-CodexProfile($Selector, [bool]$AlreadySelected = $false) {
    $profile = Resolve-ProfileSelector $Selector
    if (-not $AlreadySelected) {
        Switch-ToProfile $profile
    }

    $codexArguments = @(Strip-Separator $Rest)
    if ($codexArguments -notcontains "--no-daemon") {
        $codexArguments = @("--no-daemon") + $codexArguments
    }
    Invoke-CodexWithHome $DefaultCodexHome $codexArguments
    $exitCode = $script:CodexExitCode
    Save-ActiveAuthToProfile (Find-Profile $profile.email)
    if ($exitCode -ne 0) {
        exit $exitCode
    }
}

function Run-IsolatedCodexProfile($Selector) {
    $profile = Resolve-ProfileSelector $Selector
    $profileHome = Ensure-UsableProfileHome $profile
    $profile = Find-Profile $profile.email
    $source = Get-ProfileAuthSource $profile
    if (-not $source) {
        throw "No auth.json found for profile: $($profile.email). Run codex-auth login $($profile.email) first."
    }

    Ensure-Dir $profileHome
    $homeAuth = Join-Path $profileHome "auth.json"
    if (-not (Test-Path -LiteralPath $homeAuth)) {
        Copy-Item -LiteralPath $source -Destination $homeAuth -Force
    }
    Ensure-FileCredentialStore $profileHome

    # Flush a newer token from the shared home when this account is active there.
    $active = Get-ActiveProfile (Get-OrderedProfiles)
    if ($active -and $active.email -eq $profile.email) {
        Save-ActiveAuthToProfile $profile
    }

    $codexArguments = Strip-Separator $Rest
    Invoke-CodexWithHome $profileHome $codexArguments
    if ($script:CodexExitCode -ne 0) {
        exit $script:CodexExitCode
    }
}

function Get-SharedSessions([bool]$AllDirectories) {
    $codex = Find-CodexCommand
    if (-not $codex) {
        throw "Cannot find codex on PATH."
    }
    $helper = Join-Path $PSScriptRoot "codex-auth.sessions.mjs"
    if (-not (Test-Path -LiteralPath $helper)) {
        throw "Missing codex-auth.sessions.mjs next to codex-auth.ps1. Reinstall codex-auth."
    }
    $arguments = @($helper, "--codex=$codex", "--home=$DefaultCodexHome")
    if (-not $AllDirectories) {
        $arguments += "--cwd=$((Get-Location).Path)"
    }
    $json = & node @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Could not list local Codex sessions."
    }
    $parsed = $json | ConvertFrom-Json
    return $parsed
}

function Show-SharedSessions([bool]$AllDirectories) {
    $threads = @(Get-SharedSessions $AllDirectories)
    if ($threads.Count -eq 0) {
        Write-Host "No saved sessions found for this directory. Use codex-auth sessions --all to search all directories."
        return @()
    }
    $rows = for ($i = 0; $i -lt $threads.Count; $i++) {
        $thread = $threads[$i]
        $title = [regex]::Replace([string]$thread.title, '\s+', ' ').Trim()
        if ($title.Length -gt 65) { $title = $title.Substring(0, 62) + "..." }
        [pscustomobject]@{
            index = $i + 1
            updated = if ($thread.updatedAt) { [DateTimeOffset]::FromUnixTimeSeconds([long]$thread.updatedAt).ToLocalTime().ToString("yyyy-MM-dd HH:mm") } else { "" }
            title = $title
            id = $thread.id
        }
    }
    $rows | Format-Table -AutoSize | Out-Host
    return $threads
}

function Resume-SharedSession($Selection) {
    $allDirectories = $Selection -eq "--all"
    $threads = @(Show-SharedSessions $allDirectories)
    if ($threads.Count -eq 0) {
        throw "No saved sessions found. Run codex-auth sessions --all to inspect all directories."
    }
    $choice = if ($Selection -and -not $allDirectories) { $Selection } else { Read-Host "Session number or ID (blank to cancel)" }
    if ([string]::IsNullOrWhiteSpace($choice)) { return }
    $sessionId = $choice
    $index = 0
    if ([int]::TryParse($choice, [ref]$index)) {
        if ($index -lt 1 -or $index -gt $threads.Count) {
            throw "Session number out of range: $choice"
        }
        $sessionId = $threads[$index - 1].id
    }
    elseif ($choice -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$') {
        throw "Enter a session number or UUID."
    }
    Invoke-CodexWithHome $DefaultCodexHome @("--no-daemon", "resume", $sessionId)
    $exitCode = $script:CodexExitCode
    Save-ActiveAuthToProfile (Get-ActiveProfile (Get-OrderedProfiles))
    if ($exitCode -ne 0) { exit $exitCode }
}

function Remove-Profile($Selector) {
    $meta = Load-Meta
    $profile = Resolve-ProfileSelector $Selector
    $emailNorm = $profile.email

    $profileHome = Resolve-ProfileHomeFromMeta $profile
    $fullHome = [System.IO.Path]::GetFullPath($profileHome)
    $fullRoot = [System.IO.Path]::GetFullPath($ProfileHomesDir)
    if ($fullHome.StartsWith($fullRoot + [System.IO.Path]::DirectorySeparatorChar) -and (Test-Path -LiteralPath $fullHome)) {
        Remove-Item -LiteralPath $fullHome -Recurse -Force
    }

    $legacy = Get-LegacyProfilePath $emailNorm
    if (Test-Path -LiteralPath $legacy) {
        Remove-Item -LiteralPath $legacy -Force
    }

    $meta.profiles = @($meta.profiles | Where-Object { $_.email -ne $emailNorm })
    Save-Meta $meta
    Write-Host "Removed profile: $emailNorm"
}

function Get-CommandArgs {
    $args = @()
    if (-not [string]::IsNullOrWhiteSpace($Email)) {
        $args += $Email
    }
    if ($Rest) {
        $args += $Rest
    }
    return $args
}

function Test-LoginScriptCurrent($Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $content = Get-Content -Raw -LiteralPath $Path
    return ($content -match 'call\s+codex\s+login' -and $content -match 'finish-login')
}

function Get-PathContains($Directory) {
    $target = [System.IO.Path]::GetFullPath($Directory).TrimEnd('\')
    $paths = @()
    if ($env:PATH) {
        $paths += ($env:PATH -split ';')
    }

    foreach ($path in $paths) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }
        try {
            if ([System.IO.Path]::GetFullPath($path).TrimEnd('\') -ieq $target) {
                return $true
            }
        }
        catch {
        }
    }

    return $false
}

function Show-Doctor {
    $profiles = @(Get-OrderedProfiles)
    $activeSummary = Get-AuthSummary $ActiveAuthFile
    $activeProfile = Get-ActiveProfile $profiles
    $installBin = Join-Path $DefaultCodexHome "bin"
    $installBinOnPath = Get-PathContains $installBin
    $codexAuthCommand = Find-CodexAuthCommand
    $issues = @()
    $rows = @()
    $index = 0

    foreach ($profile in $profiles) {
        $index++
        $source = Get-ProfileAuthSource $profile
        $summary = Get-AuthSummary $source
        $profileHome = Resolve-ProfileHomeFromMeta $profile
        $scriptPath = Join-Path $profileHome "codex-login.cmd"
        $scriptOk = Test-LoginScriptCurrent $scriptPath
        $mismatch = $false
        if ($summary.token_email -and $summary.token_email -ne $profile.email) {
            $mismatch = $true
        }

        if (-not $summary.exists) {
            $issues += "Profile $index has no auth.json: $($profile.email)"
        }
        if ($mismatch) {
            $issues += "Profile $index token email mismatch: profile=$($profile.email), token=$($summary.token_email)"
        }
        if ((Test-Path -LiteralPath $scriptPath) -and -not $scriptOk) {
            $issues += "Profile $index has an old login script; run codex-auth login $($profile.email) to regenerate it"
        }

        $rows += [pscustomobject]@{
            index = $index
            active = if ($activeProfile -and $activeProfile.email -eq $profile.email) { "*" } else { "" }
            email = $profile.email
            auth = if ($summary.exists) { "yes" } else { "no" }
            token_email = $summary.token_email
            script = if ($scriptOk) { "ok" } elseif (Test-Path -LiteralPath $scriptPath) { "old" } else { "missing" }
            mismatch = if ($mismatch) { "yes" } else { "" }
        }
    }

    Write-Host "codex-auth doctor"
    Write-Host ""
    [pscustomobject]@{
        default_codex_home = $DefaultCodexHome
        active_profile = if ($activeProfile) { $activeProfile.email } elseif ($activeSummary.exists) { "(not saved or changed)" } else { "(no active auth)" }
        active_token_email = $activeSummary.token_email
        env_CODEX_HOME = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { "(not set)" }
        codex_auth_command = if ($codexAuthCommand) { $codexAuthCommand } else { "(not found on PATH)" }
        install_bin = $installBin
        install_bin_on_PATH = $installBinOnPath
    } | Format-List

    if ($rows.Count -gt 0) {
        $rows | Format-Table -AutoSize
    }
    else {
        Write-Host "No profiles saved."
    }

    Write-Host ""
    if ($env:CODEX_HOME -and ([System.IO.Path]::GetFullPath($env:CODEX_HOME) -ne [System.IO.Path]::GetFullPath($DefaultCodexHome))) {
        $issues += "CODEX_HOME is set; plain codex may ignore the default auth selected by codex-auth use."
    }
    if (-not $codexAuthCommand) {
        $issues += "codex-auth is not on current PATH. Run codex-auth install-user or add the install directory to PATH."
    }

    if ($issues.Count -eq 0) {
        Write-Host "OK: no issues found."
        return
    }

    Write-Host "Issues:"
    foreach ($issue in $issues) {
        Write-Host ("- " + $issue)
    }
}

function Invoke-Clean {
    $args = Get-CommandArgs
    $dryRun = $args -contains "--dry-run"
    $includeBackups = $args -contains "--backups"
    $days = 7
    for ($i = 0; $i -lt $args.Count; $i++) {
        if ($args[$i] -eq "--days" -and ($i + 1) -lt $args.Count) {
            $days = [int]$args[$i + 1]
        }
    }

    $targets = @()
    if (Test-Path -LiteralPath $ProfileHomesDir) {
        $targets += Get-ChildItem -LiteralPath $ProfileHomesDir -Recurse -File -Filter "auth.default-before-login.json" -ErrorAction SilentlyContinue
    }

    if ($includeBackups -and (Test-Path -LiteralPath $DefaultCodexHome)) {
        $cutoff = (Get-Date).AddDays(-1 * $days)
        $targets += Get-ChildItem -LiteralPath $DefaultCodexHome -File -Filter "auth.backup-*.json" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff }
    }

    if ($targets.Count -eq 0) {
        Write-Host "Nothing to clean."
        if (-not $includeBackups) {
            Write-Host "Tip: use codex-auth clean --backups --days 7 to remove old auth.backup-*.json files."
        }
        return
    }

    foreach ($target in $targets) {
        if ($dryRun) {
            Write-Host ("Would remove: " + $target.FullName)
        }
        else {
            Remove-Item -LiteralPath $target.FullName -Force
            Write-Host ("Removed: " + $target.FullName)
        }
    }
}

function Install-User {
    $args = Get-CommandArgs
    $noPath = $args -contains "--no-path"
    $installDir = Join-Path $DefaultCodexHome "bin"
    Ensure-Dir $installDir

    foreach ($name in @("codex-auth.ps1", "codex-auth.cmd", "codex-auth.probe.mjs", "codex-auth.sessions.mjs")) {
        $source = Join-Path $PSScriptRoot $name
        $destination = Join-Path $installDir $name
        if ([IO.Path]::GetFullPath($source) -ine [IO.Path]::GetFullPath($destination)) {
            Copy-Item -LiteralPath $source -Destination $destination -Force
        }
    }

    Write-Host "Installed codex-auth to:"
    Write-Host $installDir

    if ($noPath) {
        Write-Host "Skipped PATH update because --no-path was provided."
        return
    }

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @()
    if ($userPath) {
        $parts = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $alreadyInUserPath = $false
    foreach ($part in $parts) {
        try {
            if ([System.IO.Path]::GetFullPath($part).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($installDir).TrimEnd('\')) {
                $alreadyInUserPath = $true
                break
            }
        }
        catch {
        }
    }

    if (-not $alreadyInUserPath) {
        $newPath = (($parts + $installDir) -join ';')
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        $env:PATH = (($env:PATH -split ';') + $installDir | Select-Object -Unique) -join ';'
        Write-Host "Added install dir to user PATH. Open a new terminal to use codex-auth from anywhere."
    }
    else {
        Write-Host "Install dir is already in user PATH."
    }
}

function Show-Status {
    $summary = Get-AuthSummary $ActiveAuthFile
    if (-not $summary.exists) {
        Write-Host "No active auth file: $ActiveAuthFile"
        return
    }

    $profiles = @(Get-OrderedProfiles)
    $match = Get-ActiveProfile $profiles
    $activeIndex = ""
    if ($match) {
        for ($i = 0; $i -lt $profiles.Count; $i++) {
            if ($profiles[$i].email -eq $match.email) {
                $activeIndex = ($i + 1).ToString()
                break
            }
        }
    }

    [pscustomobject]@{
        default_codex_home = $DefaultCodexHome
        active_profile = if ($match) { $match.email } else { "(not saved or changed)" }
        active_index = if ($activeIndex) { $activeIndex } else { "(none)" }
        auth_mode = $summary.auth_mode
        last_refresh = $summary.last_refresh
        account_id = $summary.account_id
        token_email = $summary.token_email
        has_api_key = $summary.has_api_key
        token_fields = $summary.token_fields
        profiles_home = $ProfileHomesDir
        env_CODEX_HOME = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { "(not set)" }
    } | Format-List
}

function Show-Verify {
    $codex = Find-CodexCommand
    if (-not $codex) {
        throw "Cannot find codex on PATH."
    }
    $probe = Join-Path $PSScriptRoot "codex-auth.probe.mjs"
    if (-not (Test-Path -LiteralPath $probe)) {
        throw "Missing codex-auth.probe.mjs next to codex-auth.ps1. Reinstall codex-auth."
    }
    $summary = Get-AuthSummary $ActiveAuthFile
    $result = & node $probe "--codex=$codex" --refresh
    if ($LASTEXITCODE -ne 0) {
        throw "Could not verify the account loaded by a fresh Codex process."
    }
    $actual = $result | ConvertFrom-Json
    Write-Host "Saved auth account: $($summary.token_email)"
    Write-Host "Fresh Codex account: $($actual.email)"
    if ($summary.auth_mode -eq "chatgpt" -and ($actual.type -ne "chatgpt" -or $summary.token_email -ine $actual.email)) {
        throw "Codex loaded a different account. Check CODEX_HOME and Codex command on PATH."
    }
    if ($summary.auth_mode -eq "apikey" -and $actual.type -ne "apiKey") {
        throw "Codex loaded a different authentication mode. Check CODEX_HOME and Codex command on PATH."
    }
    Save-ActiveAuthToProfile (Get-ActiveProfile (Get-OrderedProfiles))
    Write-Host "OK: fresh Codex loaded the selected account."
}

try {
    switch ($Command.ToLowerInvariant()) {
        "login" { Login-Profile $Email; break }
        "login-script" { New-LoginScript $Email | Out-Null; break }
        "prepare-login" { Prepare-Login $Email; break }
        "prepare" { Prepare-Login $Email; break }
        "finish-login" { Finish-Login $Email; break }
        "sync" { Sync-Profile $Email; break }
        "sync-active" { Sync-ActiveProfile $Email; break }
        "add-login" { Add-Login $Email; break }
        "add" { Add-Login $Email; break }
        "list" { List-Profiles; break }
        "lists" { List-Profiles; break }
        "ls" { List-Profiles; break }
        "use" { Use-Profile $Email; break }
        "switch" { Use-Profile $Email; break }
        "next" { Next-Profile; break }
        "next-run" { Next-Profile; Run-CodexProfile $script:NextProfile.email $true; break }
        "run" { Run-CodexProfile $Email; break }
        "run-isolated" { Run-IsolatedCodexProfile $Email; break }
        "sessions" { Show-SharedSessions ($Email -eq "--all") | Out-Null; break }
        "resume-all" { Resume-SharedSession $Email; break }
        "remove" { Remove-Profile $Email; break }
        "rm" { Remove-Profile $Email; break }
        "status" { Show-Status; break }
        "verify" { Show-Verify; break }
        "doctor" { Show-Doctor; break }
        "clean" { Invoke-Clean; break }
        "install-user" { Install-User; break }
        "env" { Show-EnvHelp; break }
        "help" { Show-Help; break }
        "-h" { Show-Help; break }
        "--help" { Show-Help; break }
        default {
            Write-Error "Unknown command: $Command"
            Show-Help
            exit 2
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
