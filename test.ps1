# Servy Full Automated Deployment Script
# Run this in PowerShell as Administrator
# .\deploy.ps1

# ===========================================
# CONFIG
# ===========================================
$logFile = "C:\Ess_Mo\logs\setup.log"
$global:ErrorActionPreference = "Continue"  # Don't crash on single failure

# ===========================================
# PREREQ CHECK
# ===========================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Servy Automated Deployment" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Start logging
Start-Transcript -Path $logFile -Append

# Track overall success
$exitCode = 0

# Check prerequisites first
Write-Host "[Step 0/8] Checking prerequisites..." -ForegroundColor Yellow
$missingTools = @()

# Git
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $missingTools += "Git (install from https://git-scm.com)"
} else {
    Write-Host "  Git: OK" -ForegroundColor Green
}

# Node.js
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    $missingTools += "Node.js 22+ (install from https://nodejs.org)"
} else {
    Write-Host "  Node.js: OK" -ForegroundColor Green
}

# Python
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    $missingTools += "Python 3.13+ (install from https://python.org)"
} else {
    Write-Host "  Python: OK" -ForegroundColor Green
}

# Servy - auto-install if missing
if (-not (Get-Command servy-cli -ErrorAction SilentlyContinue)) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "  Servy: not found, installing via winget..." -ForegroundColor Yellow
        try {
            winget install servy --accept-package-agreements --silent 2>&1 | Out-Null
            # Refresh PATH so servy-cli is available in this session
            $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
            if (Get-Command servy-cli -ErrorAction SilentlyContinue) {
                Write-Host "  Servy: installed OK" -ForegroundColor Green
            } else {
                $missingTools += "Servy - installed but not in PATH. RESTART PowerShell and re-run."
            }
        } catch {
            $missingTools += "Servy CLI - winget install failed: $_"
        }
    } else {
        $missingTools += "Servy CLI (winget not available - install manually from https://github.com/servy-community/servy)"
    }
} else {
    Write-Host "  Servy: OK" -ForegroundColor Green
}

if ($missingTools.Count -gt 0) {
    Write-Host "`n  MISSING PREREQUISITES:" -ForegroundColor Red
    $missingTools | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    Write-Host "`n  Install these first, then re-run this script." -ForegroundColor Yellow
    Stop-Transcript
    exit 1
}
Write-Host "  All prerequisites found.`n" -ForegroundColor Green

# ===========================================
# Step 1: Create Directories
# ===========================================
Write-Host "[Step 1/8] Creating directories..." -ForegroundColor Yellow
@(
    "C:\Ess_Mo",
    "C:\Ess_Mo\backend",
    "C:\Ess_Mo\frontend",
    "C:\Ess_Mo\caddy",
    "C:\Ess_Mo\cloudflare",
    "C:\Ess_Mo\logs"
) | ForEach-Object {
    New-Item -Path $_ -ItemType Directory -Force | Out-Null
    Write-Host "  Created: $_"
}
Write-Host "  Done.`n"

# ===========================================
# Step 2: Setup Frontend
# ===========================================
Write-Host "[Step 2/8] Setting up Frontend..." -ForegroundColor Yellow
try {
    Set-Location "C:\"
    if (Test-Path "C:\temp_frontend") { Remove-Item -Path "C:\temp_frontend" -Recurse -Force }

    Write-Host "  Cloning frontend repo..." -ForegroundColor Gray
    git clone https://github.com/Posuza/ESS_MO_Fronend.git temp_frontend 2>&1 | Out-Null
    Copy-Item -Path "C:\temp_frontend\*" -Destination "C:\Ess_Mo\frontend" -Recurse -Force

    Set-Location "C:\Ess_Mo\frontend"
    Write-Host "  Installing npm dependencies..." -ForegroundColor Gray
    npm install 2>&1 | Out-Null
    npm install serve 2>&1 | Out-Null

    Write-Host "  Building frontend..." -ForegroundColor Gray
    $env:VITE_API_URL = "/api/v1"
    npm run build 2>&1 | Out-Null

    Remove-Item -Path "C:\temp_frontend" -Recurse -Force

    Write-Host "  Installing Frontend Service..." -ForegroundColor Gray
    # Use --wait so servy-cli finishes before we move on
    servy-cli install --name="ess-mo-frontend" --path="C:\Windows\System32\cmd.exe" --params="/c C:\Ess_Mo\frontend\node_modules\.bin\serve.cmd -s dist -l 3000" --startupDir="C:\Ess_Mo\frontend" --startupType="Automatic" --wait 2>&1 | Out-Null

    # Verify service was installed
    if (-not (Get-Service -Name ess-mo-frontend -ErrorAction SilentlyContinue)) {
        throw "Service 'ess-mo-frontend' was not created by servy-cli"
    }
    Write-Host "  Frontend service installed.`n" -ForegroundColor Green
} catch {
    Write-Host "  FRONTEND SETUP FAILED: $_" -ForegroundColor Red
    $exitCode = 1
}

# ===========================================
# Step 3: Setup Backend
# ===========================================
Write-Host "[Step 3/8] Setting up Backend..." -ForegroundColor Yellow
try {
    Set-Location "C:\"
    if (Test-Path "C:\temp_backend") { Remove-Item -Path "C:\temp_backend" -Recurse -Force }

    Write-Host "  Cloning backend repo..." -ForegroundColor Gray
    git clone https://github.com/Posuza/ESS_MO_Backend.git temp_backend 2>&1 | Out-Null
    Copy-Item -Path "C:\temp_backend\*" -Destination "C:\Ess_Mo\backend" -Recurse -Force

    Set-Location "C:\Ess_Mo\backend"

    Write-Host "  Creating virtual environment..." -ForegroundColor Gray
    python -m venv venv
    if (-not (Test-Path "C:\Ess_Mo\backend\venv\Scripts\python.exe")) {
        throw "Virtual environment was not created"
    }

    Write-Host "  Installing Python dependencies..." -ForegroundColor Gray
    # FIXED: Use full path to venv pip instead of relying on activation
    & "C:\Ess_Mo\backend\venv\Scripts\pip" install -r requirements.txt 2>&1 | Out-Null

    Remove-Item -Path "C:\temp_backend" -Recurse -Force

    Write-Host "  Creating .env file..." -ForegroundColor Gray
    $generated_key = & "C:\Ess_Mo\backend\venv\Scripts\python" -c "import secrets; print(secrets.token_hex(32))"
    $env_content = @"
DB_ENGINE=mysql
DB_HOST=123.1234.1.123
DB_PORT=3306
DB_USER=yourdb
DB_PASSWORD=yourpass
DB_NAME=db name

# JWT Security
SECRET_KEY=$generated_key
ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=30

# Email settings (used by password reset)
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=your_email@gmail.com
SMTP_PASS=your_app_password
EMAIL_FROM=your_email@gmail.com
# FIXED: Use the production URL behind Caddy, not Vite dev port
FRONTEND_URL=http://localhost:80
"@
    Set-Content -Path "C:\Ess_Mo\backend\.env" -Value $env_content -Force

    Write-Host "  Installing Backend Service..." -ForegroundColor Gray
    servy-cli install --name="ess-mo-backend" --path="C:\Ess_Mo\backend\venv\Scripts\python.exe" --params="-m uvicorn app.main:app --host 0.0.0.0 --port 8001" --startupDir="C:\Ess_Mo\backend" --startupType="Automatic" --wait 2>&1 | Out-Null

    if (-not (Get-Service -Name ess-mo-backend -ErrorAction SilentlyContinue)) {
        throw "Service 'ess-mo-backend' was not created by servy-cli"
    }
    Write-Host "  Backend service installed.`n" -ForegroundColor Green
} catch {
    Write-Host "  BACKEND SETUP FAILED: $_" -ForegroundColor Red
    $exitCode = 1
}

# ===========================================
# Step 4: Setup Caddy
# ===========================================
Write-Host "[Step 4/8] Setting up Caddy..." -ForegroundColor Yellow
try {
    New-Item -Path "C:\Ess_Mo\caddy" -ItemType Directory -Force | Out-Null

    if (-not (Test-Path "C:\Ess_Mo\caddy\caddy.exe")) {
        Write-Host "  Downloading Caddy..." -ForegroundColor Gray
        # FIXED: Enable TLS 1.2 so Invoke-WebRequest doesn't fail on older Windows
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri "https://caddyserver.com/api/download?os=windows&arch=amd64" -OutFile "C:\Ess_Mo\caddy\caddy.exe" -UseBasicParsing
        if (-not (Test-Path "C:\Ess_Mo\caddy\caddy.exe")) {
            throw "Caddy download failed"
        }
    } else {
        Write-Host "  Caddy already downloaded, skipping." -ForegroundColor Gray
    }

    Write-Host "  Creating Caddyfile..." -ForegroundColor Gray
    $caddy_content = @"
:80 {
    # Backend API requests
    handle /api/v1/* {
        reverse_proxy 127.0.0.1:8001
    }

    # Frontend requests
    handle /* {
        reverse_proxy 127.0.0.1:3000
    }

    # Headers
    header {
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
    }
}
"@
    Set-Content -Path "C:\Ess_Mo\caddy\Caddyfile" -Value $caddy_content -Force

    Write-Host "  Installing Caddy Service..." -ForegroundColor Gray
    # FIXED: Removed --adapter caddyfile (auto-detected from .caddyfile extension)
    servy-cli install --name="ess-mo-caddy" --path="C:\Ess_Mo\caddy\caddy.exe" --params="run --config C:\Ess_Mo\caddy\Caddyfile" --startupDir="C:\Ess_Mo\caddy" --startupType="Automatic" --wait 2>&1 | Out-Null

    if (-not (Get-Service -Name ess-mo-caddy -ErrorAction SilentlyContinue)) {
        throw "Service 'ess-mo-caddy' was not created by servy-cli"
    }
    Write-Host "  Caddy service installed.`n" -ForegroundColor Green
} catch {
    Write-Host "  CADDY SETUP FAILED: $_" -ForegroundColor Red
    $exitCode = 1
}

# ===========================================
# Step 5: Setup Cloudflare Tunnel (Optional)
# ===========================================
Write-Host "[Step 5/8] Setting up Cloudflare Tunnel..." -ForegroundColor Yellow
try {
    if (-not (Get-Command cloudflared -ErrorAction SilentlyContinue)) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host "  cloudflared not found, installing via winget..." -ForegroundColor Yellow
            winget install Cloudflare.cloudflared --accept-package-agreements --silent 2>&1 | Out-Null
            $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
        }
    }
    if (-not (Get-Command cloudflared -ErrorAction SilentlyContinue)) {
        Write-Host "  WARNING: cloudflared not available. Install manually: winget install Cloudflare.cloudflared" -ForegroundColor Red
        Write-Host "  Skipping Cloudflare tunnel setup.`n" -ForegroundColor Red
    } else {
        New-Item -Path "C:\Ess_Mo\cloudflare" -ItemType Directory -Force | Out-Null
        $cf_path = (Get-Command cloudflared).Source
        servy-cli install --name="ess-mo-cloudflare" --path="$cf_path" --params="tunnel --url http://localhost:80 --logfile C:\Ess_Mo\cloudflare\cloudflare.log" --startupDir="C:\Ess_Mo\cloudflare" --startupType="Automatic" --wait 2>&1 | Out-Null

        if (-not (Get-Service -Name ess-mo-cloudflare -ErrorAction SilentlyContinue)) {
            throw "Service 'ess-mo-cloudflare' was not created by servy-cli"
        }
        Write-Host "  Cloudflare service installed.`n" -ForegroundColor Green
    }
} catch {
    Write-Host "  CLOUDFLARE SETUP FAILED: $_" -ForegroundColor Red
    $exitCode = 1
}

# ===========================================
# Step 6: Stop IIS (frees Port 80)
# ===========================================
Write-Host "[Step 6/8] Releasing Port 80..." -ForegroundColor Yellow
try {
    Stop-Service -Name W3SVC -ErrorAction SilentlyContinue
    Set-Service -Name W3SVC -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Host "  IIS (W3SVC) stopped and disabled.`n" -ForegroundColor Green
} catch {
    Write-Host "  Note: Could not stop IIS: $_" -ForegroundColor Yellow
}

# ===========================================
# Step 7: Start All Services
# ===========================================
Write-Host "[Step 7/8] Starting all services..." -ForegroundColor Yellow
$services = @("ess-mo-backend", "ess-mo-frontend", "ess-mo-caddy", "ess-mo-cloudflare")
$startedAny = $false

foreach ($svc in $services) {
    $svcExists = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $svcExists) {
        Write-Host "  Skipping $svc (not installed)" -ForegroundColor Gray
        continue
    }
    try {
        Start-Service -Name $svc -ErrorAction Stop
        Write-Host "  Started: $svc" -ForegroundColor Green
        $startedAny = $true
    } catch {
        Write-Host "  FAILED to start $svc : $_" -ForegroundColor Red
        $exitCode = 1
    }
}

if (-not $startedAny) {
    Write-Host "  WARNING: No services were started. Something went wrong above.`n" -ForegroundColor Red
} else {
    Write-Host "`n  Waiting for services to initialize..." -ForegroundColor Gray
}

# FIXED: Wait smarter for Cloudflare tunnel URL instead of fixed 3 seconds
$cloudflareTimeout = 15  # seconds
$tunnel_url = $null
$waited = 0
while ($waited -lt $cloudflareTimeout) {
    $tunnel_url = Get-ChildItem -Path "C:\Ess_Mo\cloudflare\*.log" -ErrorAction SilentlyContinue `
        | Get-Content -ErrorAction SilentlyContinue `
        | Select-String -Pattern "https://[a-zA-Z0-9-]+\.trycloudflare\.com" `
        | ForEach-Object { $_.Matches.Value } `
        | Select-Object -First 1
    if ($tunnel_url) { break }
    Start-Sleep -Seconds 1
    $waited++
}
Write-Host "  Services initialized.`n"

# ===========================================
# Step 8: Verify & Display Results
# ===========================================
Write-Host "[Step 8/8] Verifying services..." -ForegroundColor Yellow

# Test backend
try {
    $backendTest = Invoke-RestMethod -Uri "http://localhost:8001/api/v1/health" -ErrorAction Stop -TimeoutSec 5
    Write-Host "  Backend API (8001): OK" -ForegroundColor Green
} catch {
    Write-Host "  Backend API (8001): FAILED - $_" -ForegroundColor Red
    $exitCode = 1
}

# Test frontend
try {
    $frontendTest = Invoke-RestMethod -Uri "http://localhost:3000" -ErrorAction Stop -TimeoutSec 5
    Write-Host "  Frontend (3000):    OK" -ForegroundColor Green
} catch {
    Write-Host "  Frontend (3000):    FAILED - $_" -ForegroundColor Red
    $exitCode = 1
}

# Test Caddy proxy
try {
    $caddyTest = Invoke-RestMethod -Uri "http://localhost/api/v1/health" -ErrorAction Stop -TimeoutSec 5
    Write-Host "  Caddy Proxy (80):   OK" -ForegroundColor Green
} catch {
    Write-Host "  Caddy Proxy (80):   FAILED - $_" -ForegroundColor Red
    $exitCode = 1
}

# Output summary
Write-Host ""
Write-Host "===================================================" -ForegroundColor Green
Write-Host "  DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host "===================================================" -ForegroundColor Green
Write-Host "  Backend:  http://localhost:8001"
Write-Host "  Frontend: http://localhost:3000"
Write-Host "  Caddy:    http://localhost:80"
if ($tunnel_url) {
    Write-Host "  Cloudflare Tunnel URL: $tunnel_url" -ForegroundColor Cyan
} else {
    Write-Host "  Cloudflare Tunnel: Started, URL not yet available." -ForegroundColor Yellow
    Write-Host "    Check later: Get-ChildItem 'C:\Ess_Mo\cloudflare\*.log' | Get-Content | Select-String 'trycloudflare.com'" -ForegroundColor Yellow
}
if ($exitCode -ne 0) {
    Write-Host "  ⚠ Some steps had errors (see above)." -ForegroundColor Red
}
Write-Host "===================================================" -ForegroundColor Green

Stop-Transcript
Write-Host "`nFull log saved to: $logFile" -ForegroundColor Gray
exit $exitCode
