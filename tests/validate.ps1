<#
.SYNOPSIS
    End-to-end validation: confirms embeddings are stored and chat returns real content.

.PARAMETER BaseUrl
    Root URL of the deployment, e.g. https://idea.htcindia.com/codeloom

.PARAMETER Username / Password
    Credentials. Defaults: admin / admin123

.EXAMPLE
    .\tests\validate.ps1
    .\tests\validate.ps1 -BaseUrl https://idea.htcindia.com/codeloom
#>

param(
    [string]$BaseUrl  = "",
    [string]$Username = "",
    [string]$Password = ""
)

if (-not $BaseUrl)  { $BaseUrl  = if ($env:BASE_URL)   { $env:BASE_URL }   else { "http://localhost:7007/codeloom" } }
if (-not $Username) { $Username = if ($env:ADMIN_USER) { $env:ADMIN_USER } else { "admin" } }
if (-not $Password) { $Password = if ($env:ADMIN_PASS) { $env:ADMIN_PASS } else { "admin123" } }

$ErrorActionPreference = "Stop"
$ApiBase = "$BaseUrl/api"

function Write-Pass($msg) { Write-Host "[PASS] $msg" -ForegroundColor Green }
function Write-Fail($msg) { Write-Host "[FAIL] $msg" -ForegroundColor Red; exit 1 }
function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }

Write-Info "Validating against: $ApiBase"

# ── 1. Health check ──────────────────────────────────────────────────────────
Write-Info "Step 1: Health check"
try {
    $health = Invoke-RestMethod -Uri "$ApiBase/health" -Method GET -TimeoutSec 10
    $status = if ($health.status) { $health.status } else { "ok" }
    Write-Pass "Health OK - status=$status"
} catch {
    Write-Fail "Health check failed: $_"
}

# ── 2. Login ─────────────────────────────────────────────────────────────────
Write-Info "Step 2: Login as $Username"
$sessionVar = $null
try {
    $loginBody = "{`"username`": `"$Username`", `"password`": `"$Password`"}"
    $loginResp = Invoke-RestMethod `
        -Uri         "$ApiBase/auth/login" `
        -Method      POST `
        -Body        $loginBody `
        -ContentType "application/json" `
        -SessionVariable sessionVar `
        -TimeoutSec  15
    $uname = if ($loginResp.username) { $loginResp.username } else { $Username }
    Write-Pass "Login OK - user=$uname"
} catch {
    Write-Fail "Login failed: $_"
}

# ── 3. List projects ──────────────────────────────────────────────────────────
Write-Info "Step 3: Fetch project list"
try {
    $projects = Invoke-RestMethod `
        -Uri        "$ApiBase/projects" `
        -Method     GET `
        -WebSession $sessionVar `
        -TimeoutSec 15
    if ($projects.Count -eq 0) {
        Write-Fail "No projects found - upload a project first, then re-run"
    }
    Write-Info "All projects:"
    foreach ($p in $projects) {
        Write-Info "  $($p.project_id) | $($p.name) | type=$($p.project_type)"
    }
    # Pick the first non-knowledge project (source code project)
    $project = $projects | Where-Object { $_.project_type -ne 'knowledge' } | Select-Object -First 1
    if (-not $project) { $project = $projects[0] }
    Write-Pass "Testing project: '$($project.name)' ($($project.project_id))"
} catch {
    Write-Fail "Failed to fetch projects: $_"
}

# ── 4. Check node_count ───────────────────────────────────────────────────────
Write-Info "Step 4: Check project node_count (embedding count)"
$nodeCount = 0
$projectId = $project.project_id
try {
    $detail = Invoke-RestMethod `
        -Uri        "$ApiBase/projects/$projectId" `
        -Method     GET `
        -WebSession $sessionVar `
        -TimeoutSec 15
    $nodeCount = if ($detail.node_count) { $detail.node_count } else { 0 }
    Write-Info "node_count = $nodeCount"
    if ($nodeCount -eq 0) {
        Write-Host "[WARN] node_count=0 - embeddings not yet stored. Chat will return an error unless re-uploaded." -ForegroundColor Yellow
    } else {
        Write-Pass "node_count=$nodeCount > 0"
    }
} catch {
    Write-Host "[WARN] Could not fetch project detail: $_" -ForegroundColor Yellow
}

# ── 5. Chat SSE validation ────────────────────────────────────────────────────
Write-Info "Step 5: Sending chat message and validating SSE response"

$chatQuestion = "What programming language is this project written in?"
$chatBody     = "{`"message`": `"$chatQuestion`", `"conversation_id`": null}"
$chatUrl      = "$ApiBase/projects/$projectId/chat/stream"
Write-Info "POST $chatUrl"

$contentChunks = New-Object System.Collections.Generic.List[string]
$errorChunks   = New-Object System.Collections.Generic.List[string]
$rawLines      = New-Object System.Collections.Generic.List[string]

try {
    $req = [System.Net.HttpWebRequest]::Create($chatUrl)
    $req.Method      = "POST"
    $req.ContentType = "application/json"
    $req.Timeout     = 90000
    $req.Accept      = "text/event-stream"

    # Copy session cookies (PS 5.1 compatible - GetCookies takes a Uri)
    $req.CookieContainer = New-Object System.Net.CookieContainer
    $cookieUri = New-Object System.Uri($BaseUrl)
    $cookies = $sessionVar.Cookies.GetCookies($cookieUri)
    foreach ($cookie in $cookies) {
        $req.CookieContainer.Add($cookie)
    }

    # Write body
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($chatBody)
    $req.ContentLength = $bodyBytes.Length
    $reqStream = $req.GetRequestStream()
    $reqStream.Write($bodyBytes, 0, $bodyBytes.Length)
    $reqStream.Close()

    # Read SSE stream
    try {
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        $webEx = $_.Exception
        $statusCode = [int]$webEx.Response.StatusCode
        $body = ""
        if ($webEx.Response) {
            $reader2 = New-Object System.IO.StreamReader($webEx.Response.GetResponseStream())
            $body = $reader2.ReadToEnd()
            $reader2.Close()
        }
        if ($statusCode -eq 422 -and ($body -match "No embeddings" -or $nodeCount -eq 0)) {
            Write-Host "[WARN] Chat returned HTTP 422 - No embeddings found for this project." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "ACTION REQUIRED:" -ForegroundColor Yellow
            Write-Host "  pgvector is now installed and the backend is running correctly." -ForegroundColor Yellow
            Write-Host "  The project was uploaded before pgvector was available." -ForegroundColor Yellow
            Write-Host "  Please re-upload the project zip via the UI to generate embeddings:" -ForegroundColor Yellow
            Write-Host "  $BaseUrl/project/$projectId" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  After re-upload, run this script again to confirm embeddings are stored." -ForegroundColor Yellow
            exit 2
        }
        Write-Fail "Chat request failed (HTTP $statusCode): $body"
    }

    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())

    $timeout = [System.DateTime]::UtcNow.AddSeconds(60)
    $done    = $false

    while (-not $reader.EndOfStream -and [System.DateTime]::UtcNow -lt $timeout -and -not $done) {
        $line = $reader.ReadLine()
        if ($line -and $line.StartsWith("data: ")) {
            $json = $line.Substring(6)
            $rawLines.Add($json)
            try {
                $obj = $json | ConvertFrom-Json
                switch ($obj.type) {
                    "content" { $contentChunks.Add($(if ($obj.content) { $obj.content } else { "" })) }
                    "error"   { $errorChunks.Add($(if ($obj.error) { $obj.error } else { $json })) }
                    "done"    { $done = $true }
                }
            } catch { }
        }
    }

    $reader.Close()
    $resp.Close()

} catch {
    Write-Fail "Chat request failed: $_"
}

# ── 6. Assert results ─────────────────────────────────────────────────────────
Write-Info "Step 6: Asserting chat response"

if ($errorChunks.Count -gt 0) {
    $errText = $errorChunks -join " "
    Write-Info "SSE error chunks: $errText"
    if ($errText -match "No embeddings found") {
        Write-Fail "ASSERTION FAILED: 'No embeddings found' - re-upload the project zip to generate embeddings."
    }
    Write-Fail "ASSERTION FAILED: Chat error: $errText"
}

if ($contentChunks.Count -eq 0) {
    Write-Host "[WARN] No content chunks. Raw SSE lines:" -ForegroundColor Yellow
    $rawLines | ForEach-Object { Write-Host "  $_" }
    Write-Fail "ASSERTION FAILED: Chat returned no content."
}

$fullResponse = $contentChunks -join ""
$len = $fullResponse.Length
$preview = $fullResponse.Substring(0, [Math]::Min(300, $len))
Write-Info "Response preview: $preview"

if ($fullResponse -match "I cannot answer this question because") {
    Write-Fail "ASSERTION FAILED: LLM refusal - embeddings exist but context retrieval failed."
}

Write-Pass "Chat returned $($contentChunks.Count) content chunks ($len chars)"
Write-Pass ""
Write-Pass "=== All validations passed! ==="
Write-Pass "  Login:       OK"
Write-Pass "  Projects:    $($projects.Count) found"
Write-Pass "  node_count:  $nodeCount"
Write-Pass "  Chat SSE:    $($contentChunks.Count) chunks, no errors"
