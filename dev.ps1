<#
.SYNOPSIS
    Windows development script for CodeLoom (PowerShell equivalent of dev.sh).

.PARAMETER Command
    local   (default)  Start backend (:5033) + frontend (:5034)
    stop               Stop all running services
    status             Show service status
    build              Build frontend + sync deps + run migrations

.EXAMPLE
    .\dev.ps1
    .\dev.ps1 local
    .\dev.ps1 stop
    .\dev.ps1 status
    .\dev.ps1 build
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet("local", "l", "stop", "s", "status", "st", "build", "b", "setup-age", "sa")]
    [string]$Command = "local"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Portable tool paths -- no global Python or Node used
# ---------------------------------------------------------------------------
$PYTHON_EXE = "D:\soft\python-3.11.9-embed-amd64\python.exe"
$NODE_DIR   = "D:\soft\node-v24.14.0-win-x64"
$NPM_CMD    = "$NODE_DIR\npm.cmd"

# Inject portable Node into PATH for this session only
$env:PATH = "$NODE_DIR;$env:PATH"

# ---------------------------------------------------------------------------
# Derived paths
# ---------------------------------------------------------------------------
$SCRIPT_DIR    = $PSScriptRoot
$BACKEND_PORT  = 5033
$FRONTEND_PORT = 5034

# ---------------------------------------------------------------------------
# Console helpers
# ---------------------------------------------------------------------------
function Write-Step { param($msg) Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok   { param($msg) Write-Host "    OK   $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "    WARN $msg" -ForegroundColor Yellow }
function Write-Fail { param($msg) Write-Host "    FAIL $msg" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
# Port helpers
# ---------------------------------------------------------------------------
function Test-PortListening {
    param([int]$port)
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    return ($null -ne $conn)
}

function Stop-PortProcess {
    param([int]$port)
    $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    foreach ($c in $conns) {
        Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
        Write-Ok "Stopped PID $($c.OwningProcess) on port $port"
    }
}

function Test-PostgresReachable {
    # Parse host and port from DATABASE_URL so this works for both native PG (5432)
    # and the AGE Docker container (5035) without hardcoding.
    $url  = if ($env:DATABASE_URL) { $env:DATABASE_URL } else { "" }
    $pgHost = "localhost"
    $pgPort = 5432
    if ($url -match '@([^:]+):(\d+)/') { $pgHost = $Matches[1]; $pgPort = [int]$Matches[2] }
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($pgHost, $pgPort)
        $tcp.Close()
        return $true
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Load .env into the current process environment
# ---------------------------------------------------------------------------
function Load-DotEnv {
    $envFile = "$SCRIPT_DIR\.env"
    if (!(Test-Path $envFile)) {
        Write-Warn ".env not found -- copy .env.example to .env and fill in your API keys"
        return
    }
    Get-Content $envFile |
        Where-Object { $_ -notmatch '^\s*#' -and $_ -match '=' } |
        ForEach-Object {
            $parts = $_ -split '=', 2
            $name  = $parts[0].Trim()
            $value = if ($parts.Length -gt 1) { $parts[1].Trim() } else { "" }
            [System.Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    # Local mode: swap Docker hostname back to localhost
    if ($env:DATABASE_URL) {
        $env:DATABASE_URL = $env:DATABASE_URL -replace 'host\.docker\.internal', 'localhost'
    }
}

# ---------------------------------------------------------------------------
# Bootstrap pip into embedded Python if not already present, then install deps
# Embedded Python has no venv module -- install directly to its site-packages
# ---------------------------------------------------------------------------
function Ensure-Deps {
    if (!(Test-Path $PYTHON_EXE)) {
        Write-Fail "Python not found at $PYTHON_EXE"
    }

    # Enable site-packages if the ._pth file still has it commented out
    $pythonDir = Split-Path $PYTHON_EXE
    $pthFiles  = Get-ChildItem $pythonDir -Filter "*.pth" -ErrorAction SilentlyContinue
    foreach ($pth in $pthFiles) {
        $content = Get-Content $pth.FullName -Raw
        if ($content -match '#import site') {
            Write-Step "Enabling site-packages in $($pth.Name)..."
            $content = $content -replace '#import site', 'import site'
            Set-Content $pth.FullName $content -NoNewline
            Write-Ok "site-packages enabled -- re-run the script now"
            exit 0
        }
    }

    # Ensure the project root is in the ._pth search path so `python -m codeloom` works.
    # The embedded distribution ignores PYTHONPATH when a ._pth file exists; we patch it once.
    $dotPth = "$pythonDir\python311._pth"
    if (Test-Path $dotPth) {
        $pthText = Get-Content $dotPth -Raw
        if ($pthText -notmatch [regex]::Escape($SCRIPT_DIR)) {
            Add-Content -Path $dotPth -Value "`r`n$SCRIPT_DIR"
        }
    }

    # Bootstrap pip if missing
    $hasPip = $false
    try { $null = & $PYTHON_EXE -m pip --version 2>&1; $hasPip = ($LASTEXITCODE -eq 0) } catch {}
    if (!$hasPip) {
        Write-Step "Bootstrapping pip (one-time download)..."
        $getPip = "$env:TEMP\get-pip.py"
        Invoke-WebRequest -Uri "https://bootstrap.pypa.io/get-pip.py" -OutFile $getPip -UseBasicParsing
        & $PYTHON_EXE $getPip --quiet
        if ($LASTEXITCODE -ne 0) { Write-Fail "pip bootstrap failed" }
        Write-Ok "pip installed"
    }

    Write-Step "Syncing Python dependencies..."
    & $PYTHON_EXE -m pip install -r "$SCRIPT_DIR\requirements.txt" -q
    if ($LASTEXITCODE -ne 0) { Write-Fail "pip install failed" }
    Write-Ok "Dependencies up to date"
}

# ---------------------------------------------------------------------------
# Alembic migrations
# ---------------------------------------------------------------------------
function Run-Migrations {
    Write-Step "Running Alembic migrations..."
    $env:PYTHONPATH = $SCRIPT_DIR
    & $PYTHON_EXE -m alembic upgrade head
    if ($LASTEXITCODE -ne 0) { Write-Fail "Alembic upgrade failed" }
    Write-Ok "Schema up to date"
}

# ---------------------------------------------------------------------------
# Frontend node_modules
# ---------------------------------------------------------------------------
function Ensure-NodeModules {
    Push-Location "$SCRIPT_DIR\frontend"
    try {
        & $NPM_CMD install --silent
        if ($LASTEXITCODE -ne 0) { Write-Fail "npm install failed" }
    } finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# Apache AGE via Docker (LCOW)
# ---------------------------------------------------------------------------
$AGE_CONTAINER  = "codeloom-age"
$AGE_IMAGE      = "codeloom-age-pg17"
$AGE_HOST_PORT  = 5035

function Find-Psql {
    try { return (Get-Command psql -ErrorAction Stop).Source } catch {}
    foreach ($d in @(
        "C:\Program Files\PostgreSQL\17",
        "C:\Program Files\PostgreSQL\16",
        "C:\Program Files\PostgreSQL\15"
    )) {
        $p = "$d\bin\psql.exe"
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Switch-DatabaseUrlPort {
    param([int]$NewPort)
    # Update in-process env
    if ($env:DATABASE_URL) {
        $env:DATABASE_URL = $env:DATABASE_URL -replace '@([^:]+):\d+/', "@`$1:${NewPort}/"
    }
    # Persist to .env file
    $envFile = "$SCRIPT_DIR\.env"
    if (Test-Path $envFile) {
        $content = Get-Content $envFile -Raw
        $content = $content -replace '(DATABASE_URL=postgresql://[^@]+@[^:]+):\d+/', "`$1:${NewPort}/"
        Set-Content $envFile $content -NoNewline
    }
}

function Enable-DockerLCOW {
    $daemonJson = "C:\ProgramData\docker\config\daemon.json"
    $cfg = if (Test-Path $daemonJson) {
        Get-Content $daemonJson -Raw | ConvertFrom-Json
    } else {
        [PSCustomObject]@{}
    }
    $alreadyEnabled = $false
    try { $alreadyEnabled = ($cfg.experimental -eq $true) } catch {}
    if ($alreadyEnabled) { return }   # already enabled

    Write-Step "Enabling Docker experimental mode (LCOW) -- requires Docker restart..."
    $cfg | Add-Member -NotePropertyName "experimental" -NotePropertyValue $true -Force
    $cfg | ConvertTo-Json -Depth 5 | Set-Content $daemonJson
    Restart-Service docker
    # Wait for Docker daemon to come back (up to 30s)
    for ($i = 0; $i -lt 30; $i++) {
        $ready = $false
        try { $null = docker info 2>&1; $ready = ($LASTEXITCODE -eq 0) } catch {}
        if ($ready) { Write-Ok "Docker restarted with experimental mode"; return }
        Start-Sleep -Seconds 1
    }
    Write-Fail "Docker did not come back after restart. Check 'docker info' manually."
}

function Setup-AGE {
    Write-Step "Setting up Apache AGE (Docker container)..."

    # ---- Fast path: container already running ----
    $running = $false
    try { $running = ((docker inspect $AGE_CONTAINER --format '{{.State.Running}}' 2>&1) -eq "true") } catch {}
    if ($running) {
        Write-Ok "Container '$AGE_CONTAINER' is running"
        Switch-DatabaseUrlPort $AGE_HOST_PORT
        return
    }

    # ---- Enable LCOW so Docker can run Linux images ----
    Enable-DockerLCOW

    # ---- Verify LCOW actually works ----
    Write-Step "Verifying Linux container support (LCOW)..."
    $lcowOk = $false
    try {
        $null = docker run --platform linux --rm hello-world 2>&1
        $lcowOk = ($LASTEXITCODE -eq 0)
    } catch {}
    if (!$lcowOk) {
        Write-Warn "Docker cannot run Linux containers on this host."
        Write-Warn "LCOW requires Hyper-V / nested virtualisation."
        Write-Warn "Check that the Azure VM size supports nested virtualisation,"
        Write-Warn "or use WSL2 to run PostgreSQL+AGE inside Ubuntu."
        return
    }
    Write-Ok "LCOW is working"

    # ---- Build custom image (AGE + pgvector) if not already built ----
    $imageExists = $false
    try { $null = docker image inspect $AGE_IMAGE 2>&1; $imageExists = ($LASTEXITCODE -eq 0) } catch {}
    if (!$imageExists) {
        Write-Step "Building $AGE_IMAGE (AGE + pgvector) -- this takes a few minutes on first run..."
        docker build --platform linux -f "$SCRIPT_DIR\docker\Dockerfile.age" -t $AGE_IMAGE "$SCRIPT_DIR"
        if ($LASTEXITCODE -ne 0) { Write-Fail "docker build failed" }
        Write-Ok "Image $AGE_IMAGE built"
    }

    # ---- Remove any stopped container with the same name ----
    $exists = $false
    try { $null = docker inspect $AGE_CONTAINER 2>&1; $exists = ($LASTEXITCODE -eq 0) } catch {}
    if ($exists) { docker rm -f $AGE_CONTAINER | Out-Null }

    # ---- Start the container ----
    Write-Step "Starting container '$AGE_CONTAINER' on port $AGE_HOST_PORT..."
    docker run -d --platform linux --name $AGE_CONTAINER `
        -p "${AGE_HOST_PORT}:5432" `
        -e POSTGRES_USER=codeloom `
        -e POSTGRES_PASSWORD=codeloom `
        -e POSTGRES_DB=codeloom_dev `
        -v codeloom-age-data:/var/lib/postgresql/data `
        -v "${SCRIPT_DIR}\docker\init-age.sql:/docker-entrypoint-initdb.d/init-age.sql" `
        $AGE_IMAGE | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Fail "docker run failed" }

    # ---- Wait for the database to be ready (up to 60s) ----
    Write-Step "Waiting for container database to be ready..."
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("localhost", $AGE_HOST_PORT)
            $tcp.Close()
            $ready = $true; break
        } catch { Start-Sleep -Seconds 1 }
    }
    if (!$ready) { Write-Fail "Container database did not become ready within 60s" }
    # Extra wait for PostgreSQL init scripts to complete
    Start-Sleep -Seconds 3
    Write-Ok "Container database is ready"

    # ---- Update DATABASE_URL to point at the container ----
    Switch-DatabaseUrlPort $AGE_HOST_PORT
    Write-Ok "DATABASE_URL updated to port $AGE_HOST_PORT in process env and .env"
    Write-Ok "AGE + pgvector are pre-enabled via docker/init-age.sql"
}

# ===========================================================================
# Commands
# ===========================================================================

function Invoke-Local {
    Load-DotEnv

    # Setup-AGE runs first -- it may update DATABASE_URL to port 5035 (AGE container).
    # Test-PostgresReachable then reads the correct port from the updated DATABASE_URL.
    Setup-AGE

    Write-Step "Checking PostgreSQL..."
    if (!(Test-PostgresReachable)) {
        Write-Fail "PostgreSQL is not reachable. Check that native PG or the AGE container is running."
    }
    Write-Ok "PostgreSQL is up"
    Ensure-Deps
    Run-Migrations
    Ensure-NodeModules

    # Start backend -- redirect output to backend.log so errors are visible on failure
    Write-Step "Starting backend on port $BACKEND_PORT..."
    $backendLog = "$SCRIPT_DIR\backend.log"
    $backendCmd = "& '$PYTHON_EXE' -m codeloom --host 0.0.0.0 --port $BACKEND_PORT *> '$backendLog'"
    $backend = Start-Process powershell `
        -ArgumentList "-NoProfile", "-NonInteractive", "-Command", $backendCmd `
        -WorkingDirectory $SCRIPT_DIR `
        -PassThru -WindowStyle Hidden

    # Poll until port is open (up to 60 s).
    # Note: on Windows the wrapper PowerShell process may exit after Python/uvicorn
    # detaches into its own console group — HasExited on the wrapper is not a reliable
    # crash signal. We rely solely on the TCP port check.
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 1
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("localhost", $BACKEND_PORT)
            $tcp.Close()
            $ready = $true
            break
        } catch {}
    }
    if (-not $ready) {
        Write-Fail "Backend did not bind to port $BACKEND_PORT within 60 s. Last log lines:`n$(Get-Content $backendLog -Tail 30 -ErrorAction SilentlyContinue | Out-String)"
    }
    # Resolve actual backend PID from the port (the wrapper PID may differ)
    $backendPid = (Get-NetTCPConnection -LocalPort $BACKEND_PORT -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1).OwningProcess
    Write-Ok "Backend started (PID $backendPid)"

    Write-Host ""
    Write-Host "  Backend  -> http://localhost:$BACKEND_PORT" -ForegroundColor Green
    Write-Host "  Frontend -> http://localhost:$FRONTEND_PORT" -ForegroundColor Green
    Write-Host "  API docs -> http://localhost:$BACKEND_PORT/docs" -ForegroundColor Green
    Write-Host "  Log      -> $backendLog" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Ctrl+C stops the frontend. Backend keeps running; use '.\dev.ps1 stop' to kill it." -ForegroundColor Yellow
    Write-Host ""

    # Start frontend in foreground (blocking)
    Push-Location "$SCRIPT_DIR\frontend"
    try {
        & $NPM_CMD run dev
    } finally {
        Pop-Location
        # Stop backend by port (wrapper process PID is unreliable on Windows)
        Stop-PortProcess $BACKEND_PORT
    }
}

function Invoke-Stop {
    Write-Step "Stopping services..."
    Stop-PortProcess $BACKEND_PORT
    Stop-PortProcess $FRONTEND_PORT
    Write-Ok "Done"
}

function Invoke-Status {
    Write-Host ""
    Write-Host "  Service       Endpoint         Status" -ForegroundColor Cyan
    Write-Host "  -------       --------         ------"

    $pgStatus = if (Test-PostgresReachable)           { "running"       } else { "not reachable" }
    $pgColor  = if ($pgStatus -eq "running")          { "Green"         } else { "Red" }
    $beStatus = if (Test-PortListening $BACKEND_PORT)  { "running"       } else { "stopped" }
    $beColor  = if ($beStatus -eq "running")          { "Green"         } else { "Yellow" }
    $feStatus = if (Test-PortListening $FRONTEND_PORT) { "running"       } else { "stopped" }
    $feColor  = if ($feStatus -eq "running")          { "Green"         } else { "Yellow" }
    $ageRunning = $false
    try { $ageRunning = ((docker inspect $AGE_CONTAINER --format '{{.State.Running}}' 2>&1) -eq "true") } catch {}
    $ageStatus = if ($ageRunning)                     { "running :$AGE_HOST_PORT" } else { "stopped" }
    $ageColor  = if ($ageRunning)                     { "Green"         } else { "Yellow" }

    Write-Host "  PostgreSQL    localhost:5432    " -NoNewline; Write-Host $pgStatus -ForegroundColor $pgColor
    Write-Host "  AGE container :$AGE_HOST_PORT           " -NoNewline; Write-Host $ageStatus -ForegroundColor $ageColor
    Write-Host "  Backend       :$BACKEND_PORT           " -NoNewline; Write-Host $beStatus -ForegroundColor $beColor
    Write-Host "  Frontend      :$FRONTEND_PORT           " -NoNewline; Write-Host $feStatus -ForegroundColor $feColor
    Write-Host ""
}

function Invoke-Build {
    Load-DotEnv
    Ensure-Deps
    Run-Migrations
    Write-Step "Building frontend..."
    Push-Location "$SCRIPT_DIR\frontend"
    try {
        & $NPM_CMD install --silent
        & $NPM_CMD run build
        if ($LASTEXITCODE -ne 0) { Write-Fail "npm run build failed" }
        Write-Ok "Frontend built to frontend/dist/"
    } finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
switch ($Command) {
    { $_ -in "local",     "l"  } { Invoke-Local  }
    { $_ -in "stop",      "s"  } { Invoke-Stop   }
    { $_ -in "status",    "st" } { Invoke-Status }
    { $_ -in "build",     "b"  } { Invoke-Build  }
    { $_ -in "setup-age", "sa" } { Load-DotEnv; Setup-AGE }
}
