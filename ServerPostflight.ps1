<#
.SYNOPSIS
    Runs the checks configured in the Config folder.

.NOTES
    This script has no end-user command-line options. Edit the JSON files in
    Config, then launch Run Server Postflight.cmd.
#>

$ErrorActionPreference = 'Stop'
$script:ScriptDirectory = $PSScriptRoot
$script:ConfigDirectory = Join-Path $script:ScriptDirectory 'Config'
$script:CredentialCache = @{}
$script:RejectedCredentials = @{}
$script:LogFile = $null

function Get-RequiredValue {
    param($Object, [string]$Name, [string]$Location)
    $property = $Object.PSObject.Properties[$Name]
    if (-not $property -or $null -eq $property.Value) { throw "$Location.$Name is required." }
    $property.Value
}

function Get-IntegerSetting {
    param($Settings, [string]$Name, [int]$Minimum, [int]$Maximum)
    $raw = Get-RequiredValue $Settings $Name 'Settings'
    $value = 0
    if (-not [int]::TryParse("$raw", [ref]$value) -or $value -lt $Minimum -or $value -gt $Maximum) {
        throw "Settings.$Name must be a whole number from $Minimum through $Maximum."
    }
    $value
}

function Get-BooleanSetting {
    param($Settings, [string]$Name)
    $value = Get-RequiredValue $Settings $Name 'Settings'
    if ($value -isnot [bool]) { throw "Settings.$Name must be true or false (without quotes)." }
    $value
}

function Get-List {
    param($Object, [string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if (-not $property -or $null -eq $property.Value) { return @() }
    @($property.Value)
}

function Test-IsCommentProperty {
    param([string]$Name)
    $Name -match '^_comment(?:$|_)'
}

function Assert-AllowedProperties {
    param($Object, [string[]]$Allowed, [string]$Location)
    foreach ($property in $Object.PSObject.Properties.Name) {
        if ($property -notin $Allowed -and -not (Test-IsCommentProperty $property)) {
            throw "$Location has unknown property '$property'."
        }
    }
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path"
    }
    try {
        Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "$([IO.Path]::GetFileName($Path)) is not valid JSON: $($_.Exception.Message)"
    }
}

function Resolve-ConfiguredPath {
    param([string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([IO.Path]::IsPathRooted($expanded)) { return $expanded }
    Join-Path $script:ScriptDirectory $expanded
}

function Test-TargetConfiguration {
    param(
        $Target,
        [int]$Number,
        [ValidateSet('server', 'http')][string]$Type
    )
    $location = if ($Type -eq 'server') { "ServerChecks.json entry $Number" } else { "WebChecks.json entry $Number" }
    if ($null -eq $Target) { throw "$location cannot be null." }

    $name = [string](Get-RequiredValue $Target 'Name' $location)
    if ([string]::IsNullOrWhiteSpace($name)) { throw "$location.Name cannot be blank." }

    if ($Type -eq 'server') {
        Assert-AllowedProperties $Target @('Name', 'Host', 'Port', 'User', 'Info', 'Services', 'Processes') "$location ('$name')"
        $hostName = [string](Get-RequiredValue $Target 'Host' $location)
        if ([string]::IsNullOrWhiteSpace($hostName)) { throw "$location.Host cannot be blank." }
        foreach ($port in (Get-List $Target 'Port')) {
            $numberValue = 0
            if (-not [int]::TryParse("$port", [ref]$numberValue) -or $numberValue -lt 1 -or $numberValue -gt 65535) {
                throw "$location.Port contains '$port'; ports must be whole numbers from 1 through 65535."
            }
        }

        $validInfo = @('uptime', 'os', 'memory', 'cpu', 'disk', 'all')
        foreach ($info in (Get-List $Target 'Info')) {
            if ("$info".ToLowerInvariant() -notin $validInfo) {
                throw "$location.Info contains '$info'; use uptime, os, memory, cpu, disk, or all."
            }
        }

        foreach ($field in 'Services', 'Processes') {
            foreach ($entry in (Get-List $Target $field)) {
                if ([string]::IsNullOrWhiteSpace("$entry")) { throw "$location.$field cannot contain a blank value." }
            }
        }
    }
    else {
        Assert-AllowedProperties $Target @('Name', 'Url', 'ExpectedCode', 'MaxResponseMilliseconds', 'MustContain') "$location ('$name')"
        $url = [string](Get-RequiredValue $Target 'Url' $location)
        $uri = $null
        if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https')) {
            throw "$location.Url must be a complete http:// or https:// URL."
        }
        if ($uri.UserInfo) { throw "$location.Url cannot contain a user name or password." }

        $codes = Get-List $Target 'ExpectedCode'
        if ($codes.Count -eq 0) { $codes = @(200) }
        foreach ($code in $codes) {
            $numberValue = 0
            if (-not [int]::TryParse("$code", [ref]$numberValue) -or $numberValue -lt 100 -or $numberValue -gt 599) {
                throw "$location.ExpectedCode contains '$code'; HTTP codes must be from 100 through 599."
            }
        }
        if ($Target.PSObject.Properties['MustContain'] -and
            ($codes | Where-Object { [int]$_ -lt 200 -or [int]$_ -ge 300 })) {
            throw "$location.MustContain can only be used with 2xx ExpectedCode values."
        }

        $maximum = $Target.PSObject.Properties['MaxResponseMilliseconds']
        if ($maximum) {
            $numberValue = 0
            if (-not [int]::TryParse("$($maximum.Value)", [ref]$numberValue) -or $numberValue -lt 0) {
                throw "$location.MaxResponseMilliseconds must be zero or a positive whole number."
            }
        }
    }
}

function Read-Configuration {
    param([string]$Directory = $script:ConfigDirectory)

    $settingsInput = Read-JsonFile (Join-Path $Directory 'Settings.json')
    $serverInput = Read-JsonFile (Join-Path $Directory 'ServerChecks.json')
    $webInput = Read-JsonFile (Join-Path $Directory 'WebChecks.json')

    Assert-AllowedProperties $serverInput @('ServerChecks') 'ServerChecks.json'
    Assert-AllowedProperties $webInput @('WebChecks') 'WebChecks.json'
    $servers = @(Get-RequiredValue $serverInput 'ServerChecks' 'ServerChecks.json')
    $webChecks = @(Get-RequiredValue $webInput 'WebChecks' 'WebChecks.json')
    if ($servers.Count + $webChecks.Count -eq 0) {
        throw 'ServerChecks.json and WebChecks.json must contain at least one check between them.'
    }

    $allowedSettings = @(
        'LogFolder', 'ReportFolder', 'HttpTimeoutSeconds', 'TcpTimeoutSeconds', 'RemoteTimeoutSeconds',
        'PingCount', 'DefaultTcpPort', 'DefaultMaxResponseMilliseconds',
        'ExpectedRebootWithinHours', 'CertificateWarningDays', 'CpuWarningPercent',
        'MemoryWarningPercent', 'DiskWarningPercent', 'DiskFailurePercent',
        'SkipCertificateValidation', 'SkipRemoteChecks', 'UseCredentialDialog'
    )
    Assert-AllowedProperties $settingsInput $allowedSettings 'Settings.json'

    $logFolder = [string](Get-RequiredValue $settingsInput 'LogFolder' 'Settings')
    if ([string]::IsNullOrWhiteSpace($logFolder)) { throw 'Settings.LogFolder cannot be blank.' }
    $reportFolder = [string](Get-RequiredValue $settingsInput 'ReportFolder' 'Settings')
    if ([string]::IsNullOrWhiteSpace($reportFolder)) { throw 'Settings.ReportFolder cannot be blank.' }
    $settings = [pscustomobject]@{
        LogFolder                      = Resolve-ConfiguredPath $logFolder
        ReportFolder                   = Resolve-ConfiguredPath $reportFolder
        HttpTimeoutSeconds             = Get-IntegerSetting $settingsInput 'HttpTimeoutSeconds' 1 300
        TcpTimeoutSeconds              = Get-IntegerSetting $settingsInput 'TcpTimeoutSeconds' 1 60
        RemoteTimeoutSeconds           = Get-IntegerSetting $settingsInput 'RemoteTimeoutSeconds' 1 300
        PingCount                      = Get-IntegerSetting $settingsInput 'PingCount' 1 10
        DefaultTcpPort                 = Get-IntegerSetting $settingsInput 'DefaultTcpPort' 1 65535
        DefaultMaxResponseMilliseconds = Get-IntegerSetting $settingsInput 'DefaultMaxResponseMilliseconds' 0 3600000
        ExpectedRebootWithinHours      = Get-IntegerSetting $settingsInput 'ExpectedRebootWithinHours' 0 87600
        CertificateWarningDays         = Get-IntegerSetting $settingsInput 'CertificateWarningDays' 0 3650
        CpuWarningPercent              = Get-IntegerSetting $settingsInput 'CpuWarningPercent' 1 100
        MemoryWarningPercent           = Get-IntegerSetting $settingsInput 'MemoryWarningPercent' 1 100
        DiskWarningPercent             = Get-IntegerSetting $settingsInput 'DiskWarningPercent' 1 100
        DiskFailurePercent             = Get-IntegerSetting $settingsInput 'DiskFailurePercent' 0 100
        SkipCertificateValidation      = Get-BooleanSetting $settingsInput 'SkipCertificateValidation'
        SkipRemoteChecks               = Get-BooleanSetting $settingsInput 'SkipRemoteChecks'
        UseCredentialDialog            = Get-BooleanSetting $settingsInput 'UseCredentialDialog'
    }

    if ($settings.DiskFailurePercent -gt $settings.DiskWarningPercent) {
        throw 'Settings.DiskFailurePercent cannot be greater than Settings.DiskWarningPercent.'
    }
    $targets = New-Object Collections.ArrayList
    for ($index = 0; $index -lt $servers.Count; $index++) {
        Test-TargetConfiguration $servers[$index] ($index + 1) 'server'
        $servers[$index] | Add-Member -NotePropertyName Type -NotePropertyValue 'server'
        [void]$targets.Add($servers[$index])
    }
    for ($index = 0; $index -lt $webChecks.Count; $index++) {
        Test-TargetConfiguration $webChecks[$index] ($index + 1) 'http'
        $webChecks[$index] | Add-Member -NotePropertyName Type -NotePropertyValue 'http'
        [void]$targets.Add($webChecks[$index])
    }
    [pscustomobject]@{ Settings = $settings; Targets = $targets.ToArray() }
}

function Write-Log {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    Add-Content -LiteralPath $script:LogFile -Value $Text -Encoding UTF8
}

function Write-Section {
    param([string]$Text)
    Write-Log
    Write-Log ('=' * 74) 'DarkCyan'
    Write-Log $Text 'Cyan'
    Write-Log ('=' * 74) 'DarkCyan'
}

function Get-StatusColor {
    param([string]$Status)
    switch ($Status) {
        'PASS' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        'SKIP' { 'DarkGray' }
        default { 'Gray' }
    }
}

function Write-Check {
    param(
        [System.Collections.ArrayList]$Checks,
        [string]$Name,
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO', 'SKIP')][string]$Status,
        [string]$Detail
    )
    [void]$Checks.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
    $line = '  [ {0} ] {1} {2}' -f $Status.PadRight(4), $Name.PadRight(22, '.'), $Detail
    Write-Log $line (Get-StatusColor $Status)
}

function Get-WorstStatus {
    param([System.Collections.ArrayList]$Checks)
    if ($Checks.Status -contains 'FAIL') { return 'FAIL' }
    if ($Checks.Status -contains 'WARN') { return 'WARN' }
    if ($Checks.Status -contains 'PASS') { return 'PASS' }
    'INFO'
}

function Get-SummaryDetail {
    param($Result)
    if ($Result.Problems) { return [string]$Result.Problems }
    if ($Result.Type -eq 'server') {
        return "$($Result.Ports)$(if ($Result.Uptime) { "  uptime $($Result.Uptime)" })"
    }
    "HTTP $($Result.ActualCode) in $($Result.ResponseMs) ms"
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return '{0:N1} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    '{0:N0} B' -f $Bytes
}

function Format-Uptime {
    param([TimeSpan]$Uptime)
    '{0}d {1}h {2}m' -f $Uptime.Days, $Uptime.Hours, $Uptime.Minutes
}

function Get-InfoSet {
    param($Target)
    $wanted = @{}
    foreach ($entry in (Get-List $Target 'Info')) {
        $name = "$entry".ToLowerInvariant()
        if ($name -eq 'all') {
            foreach ($item in 'uptime', 'os', 'memory', 'cpu', 'disk') { $wanted[$item] = $true }
        }
        else {
            $wanted[$name] = $true
        }
    }
    $wanted
}

function Test-NeedsRemoteCheck {
    param($Target)
    if ($script:Settings.SkipRemoteChecks -or "$($Target.Type)".ToLowerInvariant() -ne 'server') { return $false }
    (Get-List $Target 'Info').Count -gt 0 -or
        (Get-List $Target 'Services').Count -gt 0 -or
        (Get-List $Target 'Processes').Count -gt 0
}

function Test-IsLocalMachine {
    param([string]$ComputerName)
    $shortName = ($ComputerName -split '\.')[0]
    $ComputerName -in @('.', 'localhost', '127.0.0.1', '::1') -or $shortName -eq $env:COMPUTERNAME
}

function Get-CredentialFor {
    param([string]$UserName)
    if ($script:CredentialCache.ContainsKey($UserName)) { return $script:CredentialCache[$UserName] }

    Write-Host
    Write-Host "Password needed for $UserName" -ForegroundColor Yellow
    if ($script:Settings.UseCredentialDialog) {
        $credential = Get-Credential -UserName $UserName -Message "Password for $UserName"
    }
    else {
        $password = Read-Host 'Password (typing is hidden; press Enter to skip)' -AsSecureString
        if ($password -and $password.Length -gt 0) {
            $credential = New-Object System.Management.Automation.PSCredential($UserName, $password)
        }
        else {
            $credential = $null
        }
    }
    $script:CredentialCache[$UserName] = $credential
    $credential
}

function Test-TcpPort {
    param([string]$ComputerName, [int]$Port)
    $client = New-Object Net.Sockets.TcpClient
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $async = $null
    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($script:Settings.TcpTimeoutSeconds * 1000, $false)) {
            return [pscustomobject]@{ Open = $false; Milliseconds = $watch.ElapsedMilliseconds; Detail = 'timed out' }
        }
        $client.EndConnect($async)
        [pscustomobject]@{ Open = $true; Milliseconds = $watch.ElapsedMilliseconds; Detail = 'open' }
    }
    catch {
        [pscustomobject]@{ Open = $false; Milliseconds = $watch.ElapsedMilliseconds; Detail = $_.Exception.Message }
    }
    finally {
        $watch.Stop()
        if ($async) { $async.AsyncWaitHandle.Close() }
        $client.Close()
    }
}

function Resolve-Target {
    param([string]$HostName, [System.Collections.ArrayList]$Checks, $Row)
    try {
        $addresses = @([Net.Dns]::GetHostAddresses($HostName) | ForEach-Object { $_.IPAddressToString })
        if ($addresses.Count -eq 0) { throw 'no addresses returned' }
        $Row.IPAddress = $addresses -join ';'
        Write-Check $Checks 'DNS' 'PASS' ($addresses -join ', ')
        $true
    }
    catch {
        Write-Check $Checks 'DNS' 'FAIL' "cannot resolve '$HostName' - $($_.Exception.Message)"
        $false
    }
}

function Test-AuthenticationError {
    param($ErrorRecord)
    $message = $ErrorRecord.Exception.Message
    $nativeCode = "$($ErrorRecord.Exception.NativeErrorCode)"
    $hresult = $ErrorRecord.Exception.HResult
    $nativeCode -eq 'AccessDenied' -or
        $hresult -eq -2147024891 -or
        $message -match '(?i)access is denied|unauthorized|logon failure|user name or password is incorrect'
}

function Reject-Credential {
    param([System.Management.Automation.PSCredential]$Credential)
    $script:RejectedCredentials[$Credential.UserName] = $true
    [void]$script:CredentialCache.Remove($Credential.UserName)
}

function New-RemoteSession {
    param([string]$ComputerName, [System.Management.Automation.PSCredential]$Credential, [System.Collections.ArrayList]$Checks)

    if ($Credential -and $script:RejectedCredentials.ContainsKey($Credential.UserName)) {
        Write-Check $Checks 'WMI / CIM' 'FAIL' "credential for $($Credential.UserName) was rejected earlier and was not retried"
        return $null
    }

    $parameters = @{
        ComputerName = $ComputerName
        OperationTimeoutSec = $script:Settings.RemoteTimeoutSeconds
        ErrorAction = 'Stop'
    }
    if ($Credential) { $parameters.Credential = $Credential }
    try {
        return New-CimSession @parameters
    }
    catch {
        if ($Credential -and (Test-AuthenticationError $_)) {
            Reject-Credential $Credential
            Write-Check $Checks 'WMI / CIM' 'FAIL' "WinRM rejected the credential; it will not be retried through DCOM or on later targets"
            return $null
        }
        $wsmanError = $_.Exception.Message
    }
    try {
        $parameters.SessionOption = New-CimSessionOption -Protocol Dcom
        return New-CimSession @parameters
    }
    catch {
        if ($Credential -and (Test-AuthenticationError $_)) { Reject-Credential $Credential }
        Write-Check $Checks 'WMI / CIM' 'FAIL' "remote checks unavailable; WinRM: $wsmanError; DCOM: $($_.Exception.Message)"
        $null
    }
}

function Test-ServerTarget {
    param($Target, [System.Collections.ArrayList]$Checks, $Row)
    $hostName = [string]$Target.Host
    if ($hostName -eq '.') { $hostName = 'localhost' }
    $Row.Target = $hostName
    Write-Log "  Host: $hostName" 'DarkGray'
    if (-not (Resolve-Target $hostName $Checks $Row)) { return }

    try {
        $replies = @(Test-Connection -ComputerName $hostName -Count $script:Settings.PingCount -ErrorAction Stop)
        $average = [math]::Round(($replies | Measure-Object ResponseTime -Average).Average)
        $Row.PingMs = $average
        Write-Check $Checks 'Ping (ICMP)' 'PASS' "$($replies.Count)/$($script:Settings.PingCount) replies, average $average ms"
    }
    catch {
        Write-Check $Checks 'Ping (ICMP)' 'WARN' 'no reply (ICMP may be blocked)'
    }

    $ports = Get-List $Target 'Port'
    if ($ports.Count -eq 0) { $ports = @($script:Settings.DefaultTcpPort) }
    $portResults = @()
    foreach ($portValue in $ports) {
        $port = [int]$portValue
        $result = Test-TcpPort $hostName $port
        if ($result.Open) {
            Write-Check $Checks "TCP $port" 'PASS' "open in $($result.Milliseconds) ms"
            $portResults += "$port=open"
        }
        else {
            Write-Check $Checks "TCP $port" 'FAIL' "$($result.Detail) after $($result.Milliseconds) ms"
            $portResults += "$port=closed"
        }
    }
    $Row.Ports = $portResults -join ';'

    $info = Get-InfoSet $Target
    $services = Get-List $Target 'Services'
    $processes = Get-List $Target 'Processes'
    if ($info.Count -eq 0 -and $services.Count -eq 0 -and $processes.Count -eq 0) {
        Write-Check $Checks 'Remote checks' 'SKIP' 'none configured'
        return
    }
    if ($script:Settings.SkipRemoteChecks) {
        Write-Check $Checks 'Remote checks' 'SKIP' 'disabled in Settings'
        return
    }

    $credential = $null
    if (-not (Test-IsLocalMachine $hostName) -and
        $Target.PSObject.Properties['User'] -and
        -not [string]::IsNullOrWhiteSpace("$($Target.User)")) {
        if ($script:RejectedCredentials.ContainsKey([string]$Target.User)) {
            Write-Check $Checks 'WMI / CIM' 'FAIL' "credential for $($Target.User) was rejected earlier and was not retried"
            return
        }
        $credential = Get-CredentialFor ([string]$Target.User)
    }
    $session = New-RemoteSession $hostName $credential $Checks
    if (-not $session) { return }

    try {
        $os = $null
        if ($info['uptime'] -or $info['os'] -or $info['memory']) {
            try { $os = Get-CimInstance -CimSession $session -ClassName Win32_OperatingSystem -ErrorAction Stop }
            catch { Write-Check $Checks 'Operating system' 'FAIL' $_.Exception.Message }
        }

        if ($os -and $info['uptime']) {
            try {
                if ($null -eq $os.LastBootUpTime) { throw 'server returned no last-boot time' }
                $uptime = (Get-Date) - $os.LastBootUpTime
                $text = "up $(Format-Uptime $uptime), booted $($os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm'))"
                if ($script:Settings.ExpectedRebootWithinHours -gt 0 -and $uptime.TotalHours -gt $script:Settings.ExpectedRebootWithinHours) {
                    Write-Check $Checks 'Uptime' 'WARN' "$text; no reboot within $($script:Settings.ExpectedRebootWithinHours) hours"
                }
                else {
                    Write-Check $Checks 'Uptime' 'PASS' $text
                }
                $Row.Uptime = Format-Uptime $uptime
                $Row.LastBoot = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss')
            }
            catch {
                Write-Check $Checks 'Uptime' 'FAIL' $_.Exception.Message
            }
        }
        if ($os -and $info['os']) { Write-Check $Checks 'OS' 'INFO' "$($os.Caption) build $($os.BuildNumber)" }
        if ($os -and $info['memory']) {
            if ($null -eq $os.TotalVisibleMemorySize -or $null -eq $os.FreePhysicalMemory) {
                Write-Check $Checks 'Memory' 'FAIL' 'server returned incomplete memory data'
            }
            else {
                $total = [double]$os.TotalVisibleMemorySize
                $free = [double]$os.FreePhysicalMemory
                if ($total -le 0) {
                    Write-Check $Checks 'Memory' 'FAIL' 'server returned an invalid total-memory value'
                }
                else {
                    $percent = [math]::Round(($free / $total) * 100, 1)
                    $text = '{0} free of {1} ({2}% free)' -f (Format-Bytes ($free * 1KB)), (Format-Bytes ($total * 1KB)), $percent
                    $status = if ($percent -lt $script:Settings.MemoryWarningPercent) { 'WARN' } else { 'PASS' }
                    Write-Check $Checks 'Memory' $status $text
                    $Row.MemFreePct = $percent
                }
            }
        }

        if ($info['cpu']) {
            try {
                $processors = @(Get-CimInstance -CimSession $session -ClassName Win32_Processor -ErrorAction Stop)
                $loads = @($processors | Where-Object { $null -ne $_.LoadPercentage } | ForEach-Object { [double]$_.LoadPercentage })
                if ($loads.Count -eq 0) { throw 'server returned no CPU load data' }
                $load = [math]::Round(($loads | Measure-Object -Average).Average)
                $status = if ($load -ge $script:Settings.CpuWarningPercent) { 'WARN' } else { 'PASS' }
                Write-Check $Checks 'CPU load' $status "$load% busy"
                $Row.CpuPct = $load
            }
            catch { Write-Check $Checks 'CPU load' 'FAIL' $_.Exception.Message }
        }

        if ($info['disk']) {
            try {
                $disks = @(Get-CimInstance -CimSession $session -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop |
                    Where-Object { [double]$_.Size -gt 0 })
                if ($disks.Count -eq 0) { throw 'server returned no usable fixed-disk data' }
                foreach ($disk in $disks) {
                    $percent = [math]::Round(([double]$disk.FreeSpace / [double]$disk.Size) * 100, 1)
                    $text = '{0} free of {1} ({2}% free)' -f (Format-Bytes $disk.FreeSpace), (Format-Bytes $disk.Size), $percent
                    $status = if ($percent -lt $script:Settings.DiskFailurePercent) {
                        'FAIL'
                    }
                    elseif ($percent -lt $script:Settings.DiskWarningPercent) {
                        'WARN'
                    }
                    else {
                        'PASS'
                    }
                    Write-Check $Checks "Disk $($disk.DeviceID)" $status $text
                }
            }
            catch { Write-Check $Checks 'Disk' 'FAIL' $_.Exception.Message }
        }

        if ($services.Count -gt 0) {
            try {
                $installedServices = @(Get-CimInstance -CimSession $session -ClassName Win32_Service -ErrorAction Stop)
                foreach ($serviceName in $services) {
                    $service = $installedServices | Where-Object {
                        $_.Name -eq $serviceName -or $_.DisplayName -eq $serviceName
                    } | Select-Object -First 1
                    if (-not $service) {
                        Write-Check $Checks "Svc $serviceName" 'FAIL' 'not found; configure the service Name or exact DisplayName, not its .exe'
                    }
                    elseif ($service.State -eq 'Running') {
                        Write-Check $Checks "Svc $serviceName" 'PASS' "Running (start mode: $($service.StartMode))"
                    }
                    else {
                        Write-Check $Checks "Svc $serviceName" 'FAIL' "$($service.State) (start mode: $($service.StartMode))"
                    }
                }
            }
            catch { Write-Check $Checks 'Services' 'FAIL' $_.Exception.Message }
        }

        if ($processes.Count -gt 0) {
            try {
                $runningProcesses = @(Get-CimInstance -CimSession $session -ClassName Win32_Process -ErrorAction Stop)
                foreach ($processName in $processes) {
                    $bareName = "$processName" -replace '\.exe$', ''
                    $matches = @($runningProcesses | Where-Object { ($_.Name -replace '\.exe$', '') -eq $bareName })
                    if ($matches.Count -eq 0) {
                        Write-Check $Checks "Proc $processName" 'FAIL' 'not running'
                    }
                    else {
                        $ids = ($matches | Select-Object -First 5 | ForEach-Object { $_.ProcessId }) -join ', '
                        if ($matches.Count -gt 5) { $ids += ', ...' }
                        $memory = ($matches | Measure-Object WorkingSetSize -Sum).Sum
                        Write-Check $Checks "Proc $processName" 'PASS' "$($matches.Count) running (PID $ids), $(Format-Bytes $memory) memory"
                    }
                }
            }
            catch { Write-Check $Checks 'Processes' 'FAIL' $_.Exception.Message }
        }
    }
    finally {
        Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue
    }
}

function New-CertificateProbeStream {
    param([IO.Stream]$Stream)
    if (-not ('ServerPostflight.TlsCertificateProbe' -as [type])) {
        Add-Type -TypeDefinition @'
using System.IO;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

namespace ServerPostflight
{
    public static class TlsCertificateProbe
    {
        public static SslStream CreateStream(Stream stream)
        {
            return new SslStream(stream, false, AcceptAnyCertificate);
        }

        private static bool AcceptAnyCertificate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors)
        {
            return true;
        }
    }
}
'@
    }
    [ServerPostflight.TlsCertificateProbe]::CreateStream($Stream)
}

function Test-Certificate {
    param([Uri]$Uri, [System.Collections.ArrayList]$Checks, $Row)
    $client = New-Object Net.Sockets.TcpClient
    $stream = $null
    $async = $null
    $authentication = $null
    try {
        $async = $client.BeginConnect($Uri.Host, $Uri.Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($script:Settings.TcpTimeoutSeconds * 1000, $false)) {
            throw "connection to $($Uri.Host):$($Uri.Port) timed out"
        }
        $client.EndConnect($async)
        $stream = New-CertificateProbeStream $client.GetStream()
        $authentication = $stream.BeginAuthenticateAsClient($Uri.Host, $null, $null)
        if (-not $authentication.AsyncWaitHandle.WaitOne($script:Settings.TcpTimeoutSeconds * 1000, $false)) {
            throw "TLS negotiation with $($Uri.Host) timed out"
        }
        $stream.EndAuthenticateAsClient($authentication)
        $certificate = New-Object Security.Cryptography.X509Certificates.X509Certificate2($stream.RemoteCertificate)
        $days = [math]::Floor(($certificate.NotAfter - (Get-Date)).TotalDays)
        $text = "$($certificate.GetNameInfo('SimpleName', $false)); expires $($certificate.NotAfter.ToString('yyyy-MM-dd')) ($days days)"
        if ($days -lt 0) {
            Write-Check $Checks 'TLS expiry' 'FAIL' "expired; $text"
        }
        elseif ($days -le $script:Settings.CertificateWarningDays) {
            Write-Check $Checks 'TLS expiry' 'WARN' $text
        }
        else {
            Write-Check $Checks 'TLS expiry' 'PASS' $text
        }
        $Row.CertExpires = $certificate.NotAfter.ToString('yyyy-MM-dd')
        $Row.CertDaysLeft = $days
    }
    catch {
        Write-Check $Checks 'TLS expiry' 'WARN' "could not read certificate: $($_.Exception.Message)"
    }
    finally {
        if ($authentication) { $authentication.AsyncWaitHandle.Close() }
        if ($async) { $async.AsyncWaitHandle.Close() }
        if ($stream) { $stream.Dispose() }
        $client.Close()
    }
}

function Test-HttpTarget {
    param($Target, [System.Collections.ArrayList]$Checks, $Row)
    $url = [string]$Target.Url
    $uri = [Uri]$url
    $safeUrl = $uri.GetLeftPart([UriPartial]::Path)
    $Row.Target = $safeUrl
    Write-Log "  URL: $safeUrl" 'DarkGray'
    if (-not (Resolve-Target $uri.Host $Checks $Row)) { return }
    if ($uri.Scheme -eq 'https') { Test-Certificate $uri $Checks $Row }

    $expected = Get-List $Target 'ExpectedCode'
    if ($expected.Count -eq 0) { $expected = @(200) }
    $expected = @($expected | ForEach-Object { [int]$_ })
    $Row.Expected = $expected -join '/'
    $maximumRedirects = 10
    if ($expected | Where-Object { $_ -ge 300 -and $_ -lt 400 }) { $maximumRedirects = 0 }

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $response = $null
    $statusCode = $null
    $errorMessage = $null
    $location = $null
    $requestParameters = @{
        Uri = $url
        Method = 'Get'
        TimeoutSec = $script:Settings.HttpTimeoutSeconds
        UseBasicParsing = $true
        MaximumRedirection = $maximumRedirects
    }
    try {
        if ($maximumRedirects -eq 0) {
            $requestErrors = @()
            $response = Invoke-WebRequest @requestParameters -ErrorAction SilentlyContinue -ErrorVariable requestErrors
            if ($response) {
                $statusCode = [int]$response.StatusCode
                $location = $response.Headers['Location']
            }
            elseif ($requestErrors.Count -gt 0) {
                $errorMessage = $requestErrors[0].Exception.Message
            }
        }
        else {
            $response = Invoke-WebRequest @requestParameters
            $statusCode = [int]$response.StatusCode
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        $errorResponse = $_.Exception.Response
        if ($errorResponse) {
            try { $statusCode = [int]$errorResponse.StatusCode } catch { $statusCode = $null }
            try { $location = $errorResponse.Headers['Location'] } catch { $location = $null }
        }
    }
    $watch.Stop()

    $milliseconds = $watch.ElapsedMilliseconds
    $Row.ResponseMs = $milliseconds
    if ($null -eq $statusCode) {
        $Row.ActualCode = 'none'
        Write-Check $Checks 'HTTP request' 'FAIL' "no response after $milliseconds ms - $errorMessage"
        return
    }

    $Row.ActualCode = $statusCode
    if ($expected -contains $statusCode) {
        Write-Check $Checks 'HTTP status' 'PASS' "got $statusCode, expected $($expected -join ' or ') ($milliseconds ms)"
    }
    else {
        Write-Check $Checks 'HTTP status' 'FAIL' "got $statusCode, expected $($expected -join ' or ') ($milliseconds ms)"
    }

    $limit = $script:Settings.DefaultMaxResponseMilliseconds
    if ($Target.PSObject.Properties['MaxResponseMilliseconds']) { $limit = [int]$Target.MaxResponseMilliseconds }
    $Row.MaxResponseMs = $limit
    if ($limit -gt 0) {
        $status = if ($milliseconds -gt $limit) { 'WARN' } else { 'PASS' }
        Write-Check $Checks 'Response time' $status "$milliseconds ms (limit $limit ms)"
    }

    if ($response) {
        if ($response.BaseResponse -and $response.BaseResponse.ResponseUri -and
            $response.BaseResponse.ResponseUri.AbsoluteUri -ne $url) {
            Write-Check $Checks 'Redirected to' 'INFO' $response.BaseResponse.ResponseUri.GetLeftPart([UriPartial]::Path)
        }
        $body = [string]$response.Content
        Write-Check $Checks 'Body size' 'INFO' "$($body.Length) characters"
        if ($Target.PSObject.Properties['MustContain'] -and -not [string]::IsNullOrWhiteSpace("$($Target.MustContain)")) {
            if ($body.IndexOf([string]$Target.MustContain, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                Write-Check $Checks 'Content match' 'PASS' "found '$($Target.MustContain)'"
            }
            else {
                Write-Check $Checks 'Content match' 'FAIL' "'$($Target.MustContain)' was not found"
            }
        }
    }
    elseif ($location) {
        try {
            $safeLocation = (New-Object Uri($uri, $location)).GetLeftPart([UriPartial]::Path)
            Write-Check $Checks 'Redirect location' 'INFO' $safeLocation
        }
        catch {
            Write-Check $Checks 'Redirect location' 'INFO' '(invalid Location header)'
        }
    }
}

function ConvertTo-HtmlEncoded {
    param($Value)
    [Net.WebUtility]::HtmlEncode([string]$Value)
}

function New-HtmlReport {
    param(
        [string]$Path,
        [datetime]$Started,
        [datetime]$Completed,
        [object[]]$Targets,
        [object[]]$Summary,
        [string]$LogFile,
        [string]$CsvFile
    )

    $passed = @($Summary | Where-Object Status -eq 'PASS').Count
    $warnings = @($Summary | Where-Object Status -eq 'WARN').Count
    $failed = @($Summary | Where-Object Status -eq 'FAIL').Count
    $overallStatus = if ($failed -gt 0) { 'FAIL' } elseif ($warnings -gt 0) { 'WARN' } else { 'PASS' }
    $overallClass = $overallStatus.ToLowerInvariant()
    $overallMessage = if ($failed -gt 0) {
        'Attention required: review the failed checks below.'
    }
    elseif ($warnings -gt 0) {
        'All targets responded; review the warnings below.'
    }
    else {
        'All checks passed.'
    }
    $elapsed = [math]::Round(($Completed - $Started).TotalSeconds, 1)
    $displayTime = $Started.ToString('yyyy-MM-dd HH:mm:ss')

    $summaryRows = foreach ($result in $Summary) {
        $status = "$($result.Status)".ToLowerInvariant()
        $name = ConvertTo-HtmlEncoded $result.Name
        $type = ConvertTo-HtmlEncoded "$($result.Type)".ToUpperInvariant()
        $detail = ConvertTo-HtmlEncoded (Get-SummaryDetail $result)
        '<tr><td><span class="status {0}">{1}</span></td><td class="strong">{2}</td><td>{3}</td><td>{4}</td></tr>' -f `
            $status, $result.Status, $name, $type, $detail
    }

    $targetCards = foreach ($target in $Targets) {
        $status = "$($target.Status)".ToLowerInvariant()
        $name = ConvertTo-HtmlEncoded $target.Name
        $type = ConvertTo-HtmlEncoded "$($target.Type)".ToUpperInvariant()
        $destination = ConvertTo-HtmlEncoded $target.Target
        $checkRows = foreach ($check in $target.Checks) {
            $checkStatus = "$($check.Status)".ToLowerInvariant()
            $checkName = ConvertTo-HtmlEncoded $check.Name
            $checkDetail = ConvertTo-HtmlEncoded $check.Detail
            '<tr><td><span class="status {0}">{1}</span></td><td class="strong">{2}</td><td>{3}</td></tr>' -f `
                $checkStatus, $check.Status, $checkName, $checkDetail
        }
        @"
<section class="target-card $status">
  <header><div><p class="eyebrow">$type</p><h2>$name</h2><p class="destination">$destination</p></div><span class="status large $status">$($target.Status)</span></header>
  <div class="table-wrap"><table><thead><tr><th>Status</th><th>Check</th><th>Detail</th></tr></thead><tbody>$($checkRows -join [Environment]::NewLine)</tbody></table></div>
</section>
"@
    }

    $title = ConvertTo-HtmlEncoded "Server Postflight Report - $displayTime"
    $operator = ConvertTo-HtmlEncoded "$env:USERDOMAIN\$env:USERNAME"
    $computer = ConvertTo-HtmlEncoded $env:COMPUTERNAME
    $config = ConvertTo-HtmlEncoded $script:ConfigDirectory
    $logName = ConvertTo-HtmlEncoded ([IO.Path]::GetFileName($LogFile))
    $csvName = ConvertTo-HtmlEncoded ([IO.Path]::GetFileName($CsvFile))
    $html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
  <title>$title</title>
  <style>
    :root { color-scheme: light; --ink:#172033; --muted:#667085; --line:#dfe4ec; --panel:#fff; --page:#f3f6fa; --pass:#087f5b; --pass-bg:#e8f7f1; --warn:#9a6700; --warn-bg:#fff5d6; --fail:#c92a2a; --fail-bg:#fff0f0; --info:#1864ab; --info-bg:#eaf4ff; --skip:#667085; --skip-bg:#f2f4f7; }
    * { box-sizing:border-box; }
    body { margin:0; background:var(--page); color:var(--ink); font:15px/1.5 "Segoe UI", Arial, sans-serif; }
    .shell { width:min(1180px, calc(100% - 32px)); margin:32px auto 48px; }
    .hero { color:#fff; padding:30px; border-radius:18px; background:linear-gradient(135deg,#14213d,#21466f); box-shadow:0 12px 32px rgba(20,33,61,.18); }
    .hero-top { display:flex; justify-content:space-between; align-items:flex-start; gap:24px; }
    h1 { margin:3px 0 5px; font-size:clamp(26px,4vw,38px); letter-spacing:-.03em; }
    h2 { margin:2px 0; font-size:20px; }
    .eyebrow { margin:0; color:#8ed8ff; font-size:12px; font-weight:700; letter-spacing:.12em; text-transform:uppercase; }
    .hero .sub { margin:0; color:#c8d5e6; }
    .overall { max-width:360px; padding:14px 16px; border:1px solid rgba(255,255,255,.25); border-radius:12px; background:rgba(255,255,255,.09); }
    .overall.pass { border-color:#5bd0a3; background:rgba(8,127,91,.28); } .overall.warn { border-color:#f6c453; background:rgba(154,103,0,.28); } .overall.fail { border-color:#ff8787; background:rgba(201,42,42,.3); }
    .overall strong { display:block; margin-bottom:3px; font-size:17px; }
    .overall p { margin:0; color:#e8eef7; }
    .stats { display:grid; grid-template-columns:repeat(4,1fr); gap:12px; margin-top:25px; }
    .stat { padding:14px 16px; border-radius:11px; background:rgba(255,255,255,.1); }
    .stat span { display:block; color:#c8d5e6; font-size:12px; text-transform:uppercase; letter-spacing:.08em; }
    .stat strong { font-size:25px; }
    .meta { display:grid; grid-template-columns:repeat(3,1fr); gap:16px; margin:18px 0 28px; padding:16px 20px; border:1px solid var(--line); border-radius:12px; background:var(--panel); color:var(--muted); }
    .meta b { display:block; color:var(--ink); }
    .section-title { margin:30px 0 12px; font-size:21px; }
    .target-card { overflow:hidden; margin:14px 0; border:1px solid var(--line); border-left:5px solid var(--skip); border-radius:14px; background:var(--panel); box-shadow:0 4px 14px rgba(16,24,40,.05); }
    .target-card.pass { border-left-color:var(--pass); } .target-card.warn { border-left-color:var(--warn); } .target-card.fail { border-left-color:var(--fail); }
    .target-card header { display:flex; align-items:center; justify-content:space-between; gap:16px; padding:18px 20px 15px; }
    .target-card .eyebrow { color:var(--info); }
    .destination { overflow-wrap:anywhere; margin:2px 0 0; color:var(--muted); }
    .table-wrap { overflow-x:auto; }
    table { width:100%; border-collapse:collapse; }
    th,td { padding:12px 16px; border-top:1px solid var(--line); text-align:left; vertical-align:top; }
    th { background:#f8fafc; color:var(--muted); font-size:11px; letter-spacing:.08em; text-transform:uppercase; }
    .strong { font-weight:600; }
    .status { display:inline-block; min-width:52px; padding:3px 8px; border-radius:999px; background:var(--skip-bg); color:var(--skip); font-size:11px; font-weight:800; letter-spacing:.05em; text-align:center; }
    .status.pass { color:var(--pass); background:var(--pass-bg); } .status.warn { color:var(--warn); background:var(--warn-bg); } .status.fail { color:var(--fail); background:var(--fail-bg); } .status.info { color:var(--info); background:var(--info-bg); }
    .status.large { min-width:64px; padding:6px 11px; font-size:12px; }
    .summary { overflow:hidden; border:1px solid var(--line); border-radius:14px; background:var(--panel); box-shadow:0 4px 14px rgba(16,24,40,.05); }
    footer { margin-top:25px; color:var(--muted); font-size:13px; text-align:center; }
    @media (max-width:700px) { .hero-top { display:block; } .overall { max-width:none; margin-top:18px; } .stats { grid-template-columns:repeat(2,1fr); } .meta { grid-template-columns:1fr; } .shell { width:min(100% - 18px,1180px); margin-top:9px; } .hero { padding:22px; border-radius:13px; } }
    @media print { body { background:#fff; } .shell { width:100%; margin:0; } .hero,.target-card,.summary { box-shadow:none; } .target-card { break-inside:avoid; } }
  </style>
</head>
<body>
<main class="shell">
  <section class="hero">
    <div class="hero-top"><div><p class="eyebrow">Post-Maintenance Verification</p><h1>Server Postflight Report</h1><p class="sub">Run started $displayTime</p></div><div class="overall $overallClass"><strong>$overallStatus</strong><p>$overallMessage</p></div></div>
    <div class="stats"><div class="stat"><span>Total targets</span><strong>$($Summary.Count)</strong></div><div class="stat"><span>Passed</span><strong>$passed</strong></div><div class="stat"><span>Warnings</span><strong>$warnings</strong></div><div class="stat"><span>Failed</span><strong>$failed</strong></div></div>
  </section>
  <section class="meta"><div>Operator<b>$operator</b></div><div>Computer<b>$computer</b></div><div>Elapsed<b>$elapsed seconds</b></div><div>Configuration<b>$config</b></div><div>Text log<b>$logName</b></div><div>CSV data<b>$csvName</b></div></section>
  <h2 class="section-title">Summary</h2>
  <div class="summary table-wrap"><table><thead><tr><th>Status</th><th>Name</th><th>Type</th><th>Detail</th></tr></thead><tbody>$($summaryRows -join [Environment]::NewLine)</tbody></table></div>
  <h2 class="section-title">Detailed checks</h2>
  $($targetCards -join [Environment]::NewLine)
  <footer>Generated locally by Server Postflight at $($Completed.ToString('yyyy-MM-dd HH:mm:ss')).</footer>
</main>
</body>
</html>
"@
    Set-Content -LiteralPath $Path -Value $html -Encoding UTF8
}

try {
    $configuration = Read-Configuration
}
catch {
    Write-Host
    Write-Host "CONFIGURATION ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Fix the named JSON file in Config and run the launcher again.' -ForegroundColor Yellow
    exit 1
}

$script:Settings = $configuration.Settings
$targets = $configuration.Targets
try {
    foreach ($folder in $script:Settings.LogFolder, $script:Settings.ReportFolder) {
        if (-not (Test-Path -LiteralPath $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
        }
    }
    $started = Get-Date
    $stamp = $started.ToString('yyyy-MM-dd_HHmmss_fff')
    $script:LogFile = Join-Path $script:Settings.LogFolder "ServerPostflight_$stamp.log"
    $csvFile = Join-Path $script:Settings.LogFolder "ServerPostflight_$stamp.csv"
    $reportFile = Join-Path $script:Settings.ReportFolder "ServerPostflightReport_$stamp.html"
    Set-Content -LiteralPath $script:LogFile -Value $null -Encoding UTF8
}
catch {
    Write-Host "Cannot create the output folders or log file: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$oldCertificateCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
$exitCode = 1

try {
    if ($script:Settings.SkipCertificateValidation) {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }

    Write-Section "SERVER POSTFLIGHT   $($started.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Log "Run by   : $env:USERDOMAIN\$env:USERNAME from $env:COMPUTERNAME"
    Write-Log "Config   : $($script:ConfigDirectory)"
    Write-Log "Log file : $($script:LogFile)"
    Write-Log "Report   : $reportFile"
    Write-Log "Targets  : $($targets.Count)"
    if ($script:Settings.SkipCertificateValidation) {
        Write-Log 'WARNING: TLS certificate trust validation is disabled in Settings.' 'Yellow'
    }
    $namedUsers = @()
    foreach ($target in $targets) {
        if (-not (Test-NeedsRemoteCheck $target)) { continue }
        if (-not (Test-IsLocalMachine ([string]$target.Host)) -and
            $target.PSObject.Properties['User'] -and
            -not [string]::IsNullOrWhiteSpace("$($target.User)")) {
            if ($namedUsers -notcontains [string]$target.User) { $namedUsers += [string]$target.User }
        }
    }

    foreach ($userName in $namedUsers) {
        $credential = Get-CredentialFor $userName
        if ($credential) {
            Write-Log "Credential: supplied for $userName"
        }
        else {
            Write-Log "Credential: not supplied for $userName; Windows will try the current account." 'Yellow'
        }
    }

    $summary = New-Object Collections.ArrayList
    $reportTargets = New-Object Collections.ArrayList
    foreach ($target in $targets) {
        $type = "$($target.Type)".ToLowerInvariant()
        Write-Section "$($target.Name)   [$($type.ToUpperInvariant())]"
        $checks = New-Object Collections.ArrayList
        $row = [ordered]@{
            CheckTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Name = [string]$target.Name
            Type = $type
            Target = ''
            Status = ''
            IPAddress = ''
            PingMs = ''
            Ports = ''
            Uptime = ''
            LastBoot = ''
            CpuPct = ''
            MemFreePct = ''
            Expected = ''
            ActualCode = ''
            ResponseMs = ''
            MaxResponseMs = ''
            CertExpires = ''
            CertDaysLeft = ''
            Problems = ''
        }

        try {
            if ($type -eq 'server') { Test-ServerTarget $target $checks $row }
            else { Test-HttpTarget $target $checks $row }
        }
        catch {
            Write-Check $checks 'Unhandled error' 'FAIL' $_.Exception.Message
        }

        $row.Status = Get-WorstStatus $checks
        $row.Problems = @($checks | Where-Object { $_.Status -in @('FAIL', 'WARN') } |
            ForEach-Object { "$($_.Status):$($_.Name)" }) -join '; '
        Write-Log
        Write-Log "  RESULT: $($row.Status)" (Get-StatusColor $row.Status)
        [void]$summary.Add([pscustomobject]$row)
        [void]$reportTargets.Add([pscustomobject]@{
            Name = [string]$target.Name
            Type = $type
            Target = [string]$row.Target
            Status = [string]$row.Status
            Checks = @($checks)
        })
    }

    $passed = @($summary | Where-Object Status -eq 'PASS').Count
    $warnings = @($summary | Where-Object Status -eq 'WARN').Count
    $failed = @($summary | Where-Object Status -eq 'FAIL').Count
    Write-Section 'SUMMARY'

    $nameWidth = 4
    foreach ($result in $summary) {
        if ("$($result.Name)".Length -gt $nameWidth) { $nameWidth = "$($result.Name)".Length }
    }
    $nameWidth = [math]::Min(45, $nameWidth)
    Write-Log ('  {0} {1} {2} {3}' -f 'STATUS'.PadRight(7), 'NAME'.PadRight($nameWidth), 'TYPE'.PadRight(7), 'DETAIL')
    Write-Log ('  ' + ('-' * ($nameWidth + 40)))
    foreach ($result in $summary) {
        $detail = Get-SummaryDetail $result
        $displayName = "$($result.Name)"
        if ($displayName.Length -gt $nameWidth) { $displayName = $displayName.Substring(0, $nameWidth - 1) + '~' }
        Write-Log ('  {0} {1} {2} {3}' -f "$($result.Status)".PadRight(7), $displayName.PadRight($nameWidth), "$($result.Type)".PadRight(7), $detail) (Get-StatusColor $result.Status)
    }

    Write-Log
    Write-Log "  Passed   : $passed" 'Green'
    Write-Log "  Warnings : $warnings" 'Yellow'
    Write-Log "  Failed   : $failed" 'Red'
    Write-Log "  Elapsed  : $([math]::Round(((Get-Date) - $started).TotalSeconds, 1)) seconds"
    Write-Log
    if ($failed -gt 0) {
        Write-Log '  ATTENTION REQUIRED: review the FAIL lines above.' 'Red'
    }
    elseif ($warnings -gt 0) {
        Write-Log '  All targets responded; review the warnings above.' 'Yellow'
    }
    else {
        Write-Log '  All checks passed.' 'Green'
    }

    $summary | Export-Csv -LiteralPath $csvFile -NoTypeInformation -Encoding UTF8
    $completed = Get-Date
    New-HtmlReport -Path $reportFile -Started $started -Completed $completed `
        -Targets $reportTargets.ToArray() -Summary $summary.ToArray() -LogFile $script:LogFile -CsvFile $csvFile
    Write-Host
    Write-Host "Log : $($script:LogFile)" -ForegroundColor Cyan
    Write-Host "CSV : $csvFile" -ForegroundColor Cyan
    Write-Host "HTML: $reportFile" -ForegroundColor Cyan
    $exitCode = if ($failed -gt 0) { 1 } else { 0 }
}
catch {
    Write-Host
    Write-Host "FATAL: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}
finally {
    [Net.ServicePointManager]::ServerCertificateValidationCallback = $oldCertificateCallback
}

exit $exitCode
