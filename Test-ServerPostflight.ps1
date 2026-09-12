$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$scriptPath = Join-Path $root 'ServerPostflight.ps1'

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$errors
)
if ($errors.Count -gt 0) {
    throw "ServerPostflight.ps1 has syntax errors: $($errors -join '; ')"
}

$functions = $ast.FindAll(
    { param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] },
    $true
)
foreach ($function in $functions) {
    . ([scriptblock]::Create($function.Extent.Text))
}

$script:ScriptDirectory = $root
$script:ConfigDirectory = Join-Path $root 'Config'
$configuration = Read-Configuration $script:ConfigDirectory
$exampleConfiguration = Read-Configuration (Join-Path $script:ConfigDirectory 'Examples')
if ($configuration.Targets.Count -eq 0 -or $exampleConfiguration.Targets.Count -eq 0) {
    throw 'The live or example configuration has no targets.'
}
if (@($configuration.Targets | Where-Object Type -eq 'server').Count -ne 5 -or
    @($configuration.Targets | Where-Object Type -eq 'http').Count -ne 4) {
    throw 'The split configuration did not preserve all five server and four web checks.'
}
if (-not (Test-IsCommentProperty '_comment') -or
    -not (Test-IsCommentProperty '_comment_ports') -or
    (Test-IsCommentProperty '_commentary')) {
    throw 'Comment-property recognition is too broad or too narrow.'
}

$exampleServers = @($exampleConfiguration.Targets | Where-Object Type -eq 'server')
$exampleWebChecks = @($exampleConfiguration.Targets | Where-Object Type -eq 'http')
$serverProperties = @($exampleServers | ForEach-Object { $_.PSObject.Properties.Name } | Select-Object -Unique)
$webProperties = @($exampleWebChecks | ForEach-Object { $_.PSObject.Properties.Name } | Select-Object -Unique)
foreach ($property in 'Name', 'Host', 'Port', 'User', 'Info', 'Services', 'Processes') {
    if ($serverProperties -notcontains $property) { throw "Servers example does not demonstrate '$property'." }
}
foreach ($property in 'Name', 'Url', 'ExpectedCode', 'MaxResponseMilliseconds', 'MustContain') {
    if ($webProperties -notcontains $property) { throw "Web-check example does not demonstrate '$property'." }
}
if (-not ($exampleServers | Where-Object { $_.Info -eq 'all' }) -or
    -not ($exampleServers | Where-Object { $_.Port -is [array] }) -or
    -not ($exampleWebChecks | Where-Object { $_.ExpectedCode -is [array] }) -or
    -not ($exampleWebChecks | Where-Object { $_.MaxResponseMilliseconds -eq 0 })) {
    throw 'The examples do not demonstrate all supported single, list, shortcut, and disabled-limit forms.'
}

$badTarget = [pscustomobject]@{
    Name = 'Bad target'
    Host = 'localhost'
    MisspelledSetting = $true
}
try {
    Test-TargetConfiguration $badTarget 1 'server'
    throw 'Unknown target properties were not rejected.'
}
catch {
    if ($_.Exception.Message -notmatch "unknown property 'MisspelledSetting'") { throw }
}

$commentedTarget = [pscustomobject]@{
    _comment = 'Ignored note'
    _comment_ports = 'Another ignored note'
    Name = 'Comment test'
    Host = 'localhost'
}
Test-TargetConfiguration $commentedTarget 1 'server'

$checks = New-Object Collections.ArrayList
[void]$checks.Add([pscustomobject]@{ Status = 'PASS' })
[void]$checks.Add([pscustomobject]@{ Status = 'WARN' })
if ((Get-WorstStatus $checks) -ne 'WARN') { throw 'Status priority is incorrect.' }

try {
    throw [UnauthorizedAccessException]'Access is denied'
}
catch {
    if (-not (Test-AuthenticationError $_)) { throw 'Access-denied authentication errors are not recognized.' }
}
try {
    throw 'The authentication mechanism is not supported'
}
catch {
    if (Test-AuthenticationError $_) { throw 'A transport capability error was mistaken for rejected credentials.' }
}

$script:Settings = $configuration.Settings
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
try {
    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    if (-not (Test-TcpPort '127.0.0.1' $port).Open) { throw 'The TCP check missed an open loopback port.' }
}
finally {
    $listener.Stop()
}
if ((Test-TcpPort '127.0.0.1' $port).Open) { throw 'The TCP check reported a closed loopback port as open.' }

$probeStream = New-Object IO.MemoryStream
try {
    $sslStream = New-CertificateProbeStream $probeStream
    if ($sslStream -isnot [Net.Security.SslStream]) { throw 'The certificate probe did not create an SSL stream.' }
}
finally {
    if ($sslStream) { $sslStream.Dispose() }
    $probeStream.Dispose()
}

$portProbe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$portProbe.Start()
$httpPort = ([Net.IPEndPoint]$portProbe.LocalEndpoint).Port
$portProbe.Stop()

$httpJob = Start-Job -ArgumentList $httpPort -ScriptBlock {
    param($Port)
    $server = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
    try {
        $server.Start()
        Write-Output 'READY'
        $client = $server.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $newline = [char]13 + [char]10
            $response = 'HTTP/1.1 302 Found' + $newline +
                'Location: /destination' + $newline +
                'Content-Length: 0' + $newline +
                'Connection: close' + $newline + $newline
            $bytes = [Text.Encoding]::ASCII.GetBytes($response)
            $stream.Write($bytes, 0, $bytes.Length)
        }
        finally {
            $client.Close()
        }
    }
    finally {
        $server.Stop()
    }
}

$ready = $false
for ($attempt = 0; $attempt -lt 50; $attempt++) {
    if (@(Receive-Job $httpJob -Keep) -contains 'READY') {
        $ready = $true
        break
    }
    Start-Sleep -Milliseconds 100
}
if (-not $ready) { throw 'The local redirect test server did not start.' }

$script:LogFile = [IO.Path]::GetTempFileName()
try {
    $redirectChecks = New-Object Collections.ArrayList
    $redirectRow = [ordered]@{
        Target = ''
        IPAddress = ''
        Expected = ''
        ActualCode = ''
        ResponseMs = ''
        MaxResponseMs = ''
        CertExpires = ''
        CertDaysLeft = ''
    }
    $redirectTarget = [pscustomobject]@{
        Name = 'Local redirect'
        Type = 'http'
        Url = "http://127.0.0.1:$httpPort/"
        ExpectedCode = 302
    }
    Test-HttpTarget $redirectTarget $redirectChecks $redirectRow
    if ($redirectRow.ActualCode -ne 302 -or
        -not ($redirectChecks | Where-Object { $_.Name -eq 'HTTP status' -and $_.Status -eq 'PASS' })) {
        throw 'An expected HTTP redirect did not pass.'
    }
}
finally {
    Remove-Item -LiteralPath $script:LogFile -Force -ErrorAction SilentlyContinue
    Stop-Job $httpJob -ErrorAction SilentlyContinue
    Remove-Job $httpJob -Force -ErrorAction SilentlyContinue
}

$reportPath = [IO.Path]::GetTempFileName()
try {
    $reportStarted = [datetime]'2026-09-12 09:30:15'
    $reportSummary = @([pscustomobject]@{
        Name = 'Test <server>'
        Type = 'server'
        Status = 'WARN'
        Problems = 'WARN:Memory'
        Ports = '443=open'
        Uptime = '1d 2h 3m'
        ActualCode = ''
        ResponseMs = ''
    })
    $reportTargets = @([pscustomobject]@{
        Name = 'Test <server>'
        Type = 'server'
        Target = 'localhost'
        Status = 'WARN'
        Checks = @([pscustomobject]@{ Name = 'Memory'; Status = 'WARN'; Detail = '9% free & falling' })
    })
    New-HtmlReport -Path $reportPath -Started $reportStarted -Completed $reportStarted.AddSeconds(2.5) `
        -Targets $reportTargets -Summary $reportSummary -LogFile 'test.log' -CsvFile 'test.csv'
    $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8
    if ($report -notmatch '<title>Server Postflight Report - 2026-09-12 09:30:15</title>' -or
        $report -notmatch 'Test &lt;server&gt;' -or
        $report -notmatch '9% free &amp; falling' -or
        $report -notmatch 'class="status warn"') {
        throw 'The HTML report is incomplete or does not safely encode check details.'
    }
}
finally {
    Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue
}

$launcher = Get-Content -LiteralPath (Join-Path $root 'Run Server Postflight.cmd') -Raw
if ($launcher -notmatch 'ServerPostflight\.ps1' -or $launcher -notmatch 'exit /b %RESULT%') {
    throw 'The launcher is not wired to the script and its exit code.'
}

Write-Host 'PASS: Server Postflight syntax, split configuration, comprehensive examples, comments, HTML report, auth classification, TCP and redirect checks, status priority, and launcher wiring.' -ForegroundColor Green
