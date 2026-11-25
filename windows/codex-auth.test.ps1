$ErrorActionPreference = 'Stop'
$tool = Join-Path $PSScriptRoot 'codex-auth.ps1'
$testRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testHome = Join-Path $testRoot ('t' + [guid]::NewGuid().ToString('N').Substring(0, 4))
$profiles = Join-Path $testHome 'auth-profiles\homes'
$originalPath = $env:PATH

function New-FakeAuth($Email, $AccountId, $Refresh, $Marker) {
    $payload = @{ email = $Email } | ConvertTo-Json -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return @{ auth_mode = 'chatgpt'; last_refresh = $Refresh; tokens = @{ id_token = "header.$encoded.signature"; account_id = $AccountId; refresh_token = $Marker } }
}

function Write-Auth($Path, $Value) {
    $Value | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-Tool([string[]]$Arguments) {
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "codex-auth $($Arguments -join ' ') failed: $output"
    }
    return $output
}

try {
    New-Item -ItemType Directory -Path $profiles -Force | Out-Null
    $a = 'a@example.com'
    $b = 'b@example.com'
    $aHome = Join-Path $profiles $a
    $bHome = Join-Path $profiles $b
    New-Item -ItemType Directory -Path $aHome, $bHome -Force | Out-Null
    $oldA = New-FakeAuth $a 'account-a' '2026-09-01T00:00:00Z' 'old-a'
    $freshA = New-FakeAuth $a 'account-a' '2026-09-02T00:00:00Z' 'fresh-a'
    $authB = New-FakeAuth $b 'account-b' '2026-09-01T00:00:00Z' 'b'
    Write-Auth (Join-Path $aHome 'auth.json') $oldA
    Write-Auth (Join-Path $bHome 'auth.json') $authB
    Write-Auth (Join-Path $testHome 'auth.json') $freshA
    Set-Content (Join-Path $testHome 'config.toml') "cli_auth_credentials_store = 'keyring'`n[features]`napps = false" -Encoding UTF8
    Set-Content (Join-Path $bHome 'config.toml') "[features]`napps = false" -Encoding UTF8
    @{ profiles = @(@{ email = $a; home = "homes\$a"; added_at = '1' }, @{ email = $b; home = "homes\$b"; added_at = '2' }) } |
        ConvertTo-Json -Depth 4 | Set-Content (Join-Path $testHome 'auth-profiles\profiles.json') -Encoding UTF8
    Set-Content (Join-Path $testHome 'state_5.sqlite-wal') 'untouched' -Encoding ASCII
    $env:CODEX_AUTH_HOME = $testHome
    $fakeBin = Join-Path $testHome 'fakebin'
    New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
    Set-Content (Join-Path $fakeBin 'codex.cmd') '@echo off', 'echo HOME=%CODEX_HOME% ARGS=%*' -Encoding ASCII
    $env:PATH = "$fakeBin;$originalPath"

    Invoke-Tool @('install-user', '--no-path') | Out-Null
    foreach ($name in @('codex-auth.ps1', 'codex-auth.cmd', 'codex-auth.probe.mjs', 'codex-auth.sessions.mjs')) {
        if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $testHome 'bin') $name))) {
            throw "Installer did not copy $name."
        }
    }

    $status = Invoke-Tool @('status')
    if ($status -notmatch 'active_profile\s+: a@example.com') { throw 'Refreshed auth was not recognized as active.' }

    $nextOutput = Invoke-Tool @('next')
    if ($nextOutput -notmatch [regex]::Escape("HOME=$testHome ARGS=app-server daemon stop")) {
        throw 'Switch did not stop the shared daemon before selecting a new account.'
    }
    $savedA = Get-Content -Raw (Join-Path $aHome 'auth.json') | ConvertFrom-Json
    $activeB = Get-Content -Raw (Join-Path $testHome 'auth.json') | ConvertFrom-Json
    if ($savedA.tokens.refresh_token -ne 'fresh-a') { throw 'Refreshed token was not saved before switching.' }
    if ($activeB.tokens.account_id -ne 'account-b') { throw 'Next did not select the following account.' }
    if ((Get-Content -Raw (Join-Path $testHome 'state_5.sqlite-wal')).Trim() -ne 'untouched') { throw 'Runtime SQLite WAL was modified.' }
    $defaultConfig = Get-Content -Raw (Join-Path $testHome 'config.toml')
    $profileConfig = Get-Content -Raw (Join-Path $bHome 'config.toml')
    if ($defaultConfig -notmatch 'cli_auth_credentials_store = "file"' -or $profileConfig -notmatch 'cli_auth_credentials_store = "file"' -or
        $defaultConfig -notmatch '\[features\]' -or $profileConfig -notmatch '\[features\]') {
        throw 'File credential storage was not configured for both Codex homes.'
    }

    Invoke-Tool @('use', $a) | Out-Null
    $restoredA = Get-Content -Raw (Join-Path $testHome 'auth.json') | ConvertFrom-Json
    if ($restoredA.tokens.refresh_token -ne 'fresh-a') { throw 'Switching back lost the refreshed token.' }

    $newerA = New-FakeAuth $a 'account-a' '2026-09-03T00:00:00Z' 'newer-a'
    Write-Auth (Join-Path $aHome 'auth.json') $newerA
    Invoke-Tool @('use', $a) | Out-Null
    $activeA = Get-Content -Raw (Join-Path $testHome 'auth.json') | ConvertFrom-Json
    if ($activeA.tokens.refresh_token -ne 'newer-a') { throw 'An older active token replaced a newer private login.' }

    $runOutput = Invoke-Tool @('run', $b, 'login', 'status')
    if ($runOutput -notmatch [regex]::Escape("HOME=$testHome ARGS=--no-daemon login status")) {
        throw "Shared-history run did not use the default home and bypass the cached daemon: $runOutput"
    }
    $nextRunOutput = Invoke-Tool @('next-run')
    if ($nextRunOutput -notmatch [regex]::Escape("HOME=$testHome ARGS=--no-daemon")) {
        throw "Next-run did not launch with shared history and a fresh account: $nextRunOutput"
    }
    $longEmail = '10397189+matrixupdates@utc2eduvn.onmicrosoft.com'
    $longHome = Join-Path $profiles ($longEmail -replace '[^a-z0-9@._-]', '_')
    New-Item -ItemType Directory -Path $longHome -Force | Out-Null
    Write-Auth (Join-Path $longHome 'auth.json') (New-FakeAuth $longEmail 'account-long' '2026-09-01T00:00:00Z' 'long')
    $metaPath = Join-Path $testHome 'auth-profiles\profiles.json'
    $meta = Get-Content -Raw -LiteralPath $metaPath | ConvertFrom-Json
    $meta.profiles = @($meta.profiles) + [pscustomobject]@{ email = $longEmail; home = "homes\$($longEmail -replace '[^a-z0-9@._-]', '_')"; added_at = '3' }
    $meta | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metaPath -Encoding UTF8
    $longRunOutput = Invoke-Tool @('run-isolated', $longEmail, 'login', 'status')
    $migrated = Get-Content -Raw -LiteralPath $metaPath | ConvertFrom-Json
    $newHome = Join-Path (Join-Path $testHome 'auth-profiles') (@($migrated.profiles | Where-Object email -eq $longEmail)[0].home)
    if ($newHome -eq $longHome -or $longRunOutput -notmatch [regex]::Escape("HOME=$newHome ARGS=login status")) {
        throw "Long profile home was not shortened before launch: $longRunOutput"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $newHome 'auth.json')) -or -not (Test-Path -LiteralPath (Join-Path $longHome 'auth.json'))) {
        throw 'Migrating a long profile home lost its saved auth or original backup.'
    }
    Write-Output 'codex-auth account switch and shared-history tests passed.'
}
finally {
    $env:PATH = $originalPath
    Remove-Item Env:CODEX_AUTH_HOME -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($testHome)
    $root = $testRoot.TrimEnd('\') + '\'
    if ($resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
