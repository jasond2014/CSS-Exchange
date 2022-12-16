﻿# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

. $PSScriptRoot\..\Helpers\PerformanceCountersFunctions.ps1
. $PSScriptRoot\..\..\..\Shared\Invoke-CatchActionErrorLoop.ps1
function Get-LoadBalancingReport {
    Write-Verbose "Calling: $($MyInvocation.MyCommand)"
    $CASServers = @()
    $MBXServers = @()

    if ($SiteName -ne [string]::Empty) {
        Write-Grey("Site filtering ON.  Only Exchange 2013+ CAS servers in {0} will be used in the report." -f $SiteName)
        $CASServers = Get-ExchangeServer | Where-Object {
            ($_.IsClientAccessServer -eq $true) -and
            ($_.AdminDisplayVersion -Match "^Version 15") -and
            ([System.Convert]::ToString($_.Site).Split("/")[-1] -eq $SiteName) } | Sort-Object Name
        Write-Grey("Site filtering ON.  Only Exchange 2013+ MBX servers in {0} will be used in the report." -f $SiteName)
        $MBXServers = Get-ExchangeServer | Where-Object {
                ($_.IsMailboxServer -eq $true) -and
                ($_.AdminDisplayVersion -Match "^Version 15") -and
                ([System.Convert]::ToString($_.Site).Split("/")[-1] -eq $SiteName) } | Sort-Object Name
    } else {
        if ( ($null -eq $CasServerList) ) {
            Write-Grey("Filtering OFF.  All Exchange 2013+ CAS servers will be used in the report.")
            $CASServers = Get-ExchangeServer | Where-Object { ($_.IsClientAccessServer -eq $true) -and ($_.AdminDisplayVersion -Match "^Version 15") } | Sort-Object Name
        } else {
            Write-Grey("Custom CAS server list is being used.  Only servers specified after the -CasServerList parameter will be used in the report.")
            $CASServers = Get-ExchangeServer | Where-Object { ($_.IsClientAccessServer -eq $true) -and ( ($_.Name -in $CasServerList) -or ($_.FQDN -in $CasServerList) ) } | Sort-Object Name
        }

        if ($null -eq $MbxServerList) {
            Write-Grey("All Exchange 2013+ servers will be used in the report.")
            $MBXServers = Get-ExchangeServer | Where-Object { ($_.IsMailboxServer -eq $true) -and ($_.AdminDisplayVersion -Match "^Version 15") } | Sort-Object Name
        } else {
            Write-Grey("Custom MBX server list is being used.  Only servers specified after the -MbxServerList parameter will be used in the report.")
            $MBXServers = Get-ExchangeServer | Where-Object { ($_.IsMailboxServer -eq $true) -and ( ($_.Name -in $MbxServerList) -or ($_.FQDN -in $MbxServerList) ) } | Sort-Object Name
        }
    }

    if ($CASServers.Count -eq 0) {
        Write-Red("Error: No CAS servers found using the specified search criteria.")
        exit
    }

    if ($MBXServers.Count -eq 0) {
        Write-Red("Error: No MBX servers found using the specified search criteria.")
        exit
    }

    function DisplayKeyMatching {
        param(
            [string]$CounterValue,
            [string]$DisplayValue
        )
        return [PSCustomObject]@{
            Counter = $CounterValue
            Display = $DisplayValue
        }
    }

    #Request stats from perfmon for all CAS
    $displayKeys = @{
        1  = DisplayKeyMatching "_LM_W3SVC_1_Total" "Load Distribution"
        2  = DisplayKeyMatching "_LM_W3SVC_1_ROOT" "root"
        3  = DisplayKeyMatching "_LM_W3SVC_1_ROOT_API" "API"
        4  = DisplayKeyMatching "_LM_W3SVC_1_ROOT_Autodiscover" "AutoDiscover"
        5  = DisplayKeyMatching "_LM_W3SVC_1_ROOT_ecp" "ECP"
        6  = DisplayKeyMatching "_LM_W3SVC_1_ROOT_EWS" "EWS"
        7  = DisplayKeyMatching "_LM_W3SVC_1_ROOT_mapi" "MapiHttp"
        8  = DisplayKeyMatching "_LM_W3SVC_1_ROOT_Microsoft-Server-ActiveSync" "EAS"
        9  = DisplayKeyMatching "_LM_W3SVC_1_ROOT_OAB" "OAB"
        10 = DisplayKeyMatching "_LM_W3SVC_1_ROOT_owa" "OWA"
        11 = DisplayKeyMatching "_LM_W3SVC_1_ROOT_owa_Calendar" "OWA-Calendar"
        12 = DisplayKeyMatching "_LM_W3SVC_1_ROOT_PowerShell" "PowerShell"
        13 = DisplayKeyMatching "_LM_W3SVC_1_ROOT_Rpc" "RpcHttp"
    }

    #Request stats from perfmon for all MBX
    $displayKeysBackend = @{
        1  = DisplayKeyMatching "_LM_W3SVC_2_Total" "Load Distribution-BackEnd"
        2  = DisplayKeyMatching "_LM_W3SVC_2_ROOT_API" "API-BackEnd"
        3  = DisplayKeyMatching "_LM_W3SVC_2_ROOT_Autodiscover" "AutoDiscover-BackEnd"
        4  = DisplayKeyMatching "_LM_W3SVC_2_ROOT_ecp" "ECP-BackEnd"
        5  = DisplayKeyMatching "_LM_W3SVC_2_ROOT_EWS" "EWS-BackEnd"
        6  = DisplayKeyMatching "_LM_W3SVC_2_ROOT_mapi_emsmdb" "MapiHttp_emsmdb-BackEnd"
        7  = DisplayKeyMatching "_LM_W3SVC_2_ROOT_mapi_nspi" "MapiHttp_nspi-BackEnd"
        8  = DisplayKeyMatching "_LM_W3SVC_2_ROOT_Microsoft-Server-ActiveSync" "EAS-BackEnd"
        9  = DisplayKeyMatching "_LM_W3SVC_2_ROOT_owa" "OWA-BackEnd"
        10 = DisplayKeyMatching "_LM_W3SVC_2_ROOT_PowerShell" "PowerShell-BackEnd"
        11 = DisplayKeyMatching "_LM_W3SVC_2_ROOT_Rpc" "RpcHttp-BackEnd"
    }

    $perServerStats = [ordered]@{}
    $perServerBackendStats = [ordered]@{}
    $totalStats = [ordered]@{}
    $totalBackendStats = [ordered]@{}

    $currentErrors = $Error.Count
    $counterSamples = Get-LocalizedCounterSamples -MachineName $CASServers -Counter @(
        "\ASP.NET Apps v4.0.30319(_lm_w3svc_1_*)\Requests Executing"
    ) `
        -CustomErrorAction "SilentlyContinue"

    Invoke-CatchActionErrorLoop $currentErrors ${Function:Invoke-CatchActions}

    foreach ($counterSample in $counterSamples) {
        $counterObject = Get-CounterFullNameToCounterObject -FullCounterName $counterSample.Path

        if (-not ($perServerStats.Contains($counterObject.ServerName))) {
            $perServerStats.Add($counterObject.ServerName, @{})
        }
        if (-not ($perServerStats[$counterObject.ServerName].Contains($counterObject.InstanceName))) {
            $perServerStats[$counterObject.ServerName].Add($counterObject.InstanceName, $counterSample.CookedValue)
        } else {
            Write-Verbose "This shouldn't occur...."
            $perServerStats[$counterObject.ServerName][$counterObject.InstanceName] += $counterSample.CookedValue
        }
        if (-not ($totalStats.Contains($counterObject.InstanceName))) {
            $totalStats.Add($counterObject.InstanceName, 0)
        }
        $totalStats[$counterObject.InstanceName] += $counterSample.CookedValue
    }

    $totalStats.Add('_lm_w3svc_1_total', ($totalStats.Values | Measure-Object -Sum).Sum)

    for ($i = 0; $i -lt $perServerStats.count; $i++) {
        $perServerStats[$i].Add('_lm_w3svc_1_total', ($perServerStats[$i].Values | Measure-Object -Sum).Sum)
    }
    $keyOrders = $displayKeys.Keys | Sort-Object

    $counterBackendSamples = Get-LocalizedCounterSamples -MachineName $MBXServers -Counter @(
        "\ASP.NET Apps v4.0.30319(_lm_w3svc_2_*)\Requests Executing"
    ) `
        -CustomErrorAction "SilentlyContinue"

    foreach ($counterSample in $counterBackendSamples) {
        $counterObject = Get-CounterFullNameToCounterObject -FullCounterName $counterSample.Path

        if (-not ($perServerBackendStats.Contains($counterObject.ServerName))) {
            $perServerBackendStats.Add($counterObject.ServerName, @{})
        }
        if (-not ($perServerBackendStats[$counterObject.ServerName].Contains($counterObject.InstanceName))) {
            $perServerBackendStats[$counterObject.ServerName].Add($counterObject.InstanceName, $counterSample.CookedValue)
        } else {
            Write-Verbose "This shouldn't occur...."
            $perServerBackendStats[$counterObject.ServerName][$counterObject.InstanceName] += $counterSample.CookedValue
        }
        if (-not ($totalBackendStats.Contains($counterObject.InstanceName))) {
            $totalBackendStats.Add($counterObject.InstanceName, 0)
        }
        $totalBackendStats[$counterObject.InstanceName] += $counterSample.CookedValue
    }
    $totalBackendStats.Add('_lm_w3svc_2_total', ($totalBackendStats.Values | Measure-Object -Sum).Sum)
    for ($i = 0; $i -lt $perServerBackendStats.count; $i++) {
        $perServerBackendStats[$i].Add('_lm_w3svc_2_total', ($perServerBackendStats[$i].Values | Measure-Object -Sum).Sum)
    }
    $keyOrdersBackend = $displayKeysBackend.Keys | Sort-Object

    $htmlHeader = "<html>
    <style>
    BODY{font-family: Arial; font-size: 8pt;}
    H1{font-size: 16px;}
    H2{font-size: 14px;}
    H3{font-size: 12px;}
    TABLE{border: 1px solid black; border-collapse: collapse; font-size: 8pt;}
    TH{border: 1px solid black; background: #dddddd; padding: 5px; color: #000000;}
    TD{border: 1px solid black; padding: 5px; }
    td.Green{background: #7FFF00;}
    td.Yellow{background: #FFE600;}
    td.Red{background: #FF0000; color: #ffffff;}
    td.Info{background: #85D4FF;}
    </style>
    <body>
    <h1 align=""center"">Exchange Health Checker v$($BuildVersion)</h1>
    <h1 align=""center"">Domain : $(($(Get-ADDomain).DNSRoot).toUpper())</h1>
    <h2 align=""center"">Load balancer run finished : $((Get-Date).ToString("yyyy-MM-dd HH:mm"))</h2><br>"

    [array]$htmlLoadDetails += "<table>
    <tr><th>Server</th>
    <th>Site</th>
    "
    #Load the key Headers
    $keyOrders | ForEach-Object {
        $htmlLoadDetails += "$([System.Environment]::NewLine)<th><center>$($displayKeys[$_].Display) Requests</center></th>
        <th><center>$($displayKeys[$_].Display) %</center></th>"
    }
    $htmlLoadDetails += "$([System.Environment]::NewLine)</tr>$([System.Environment]::NewLine)"

    foreach ($server in $CASServers) {
        $serverKey = $server.Name.ToString()
        Write-Verbose "Working Server for HTML report $serverKey"
        $htmlLoadDetails += "<tr>
        <td>$($serverKey)</td>
        <td><center>$($server.Site)</center></td>"

        foreach ($key in $keyOrders) {
            $currentDisplayKey = $displayKeys[$key]
            $totalRequests = $totalStats[$currentDisplayKey.Counter]

            if ($perServerStats.Contains($serverKey)) {
                $serverValue = $perServerStats[$serverKey][$currentDisplayKey.Counter]
                if ($null -eq $serverValue) { $serverValue = 0 }
            } else {
                $serverValue = 0
            }
            if ( $totalRequests -eq 0 -or $null -eq $totalRequests) {
                $percentageLoad = 100
            } else {
                $percentageLoad = [math]::Round((($serverValue / $totalRequests) * 100))
            }
            Write-Verbose "$($currentDisplayKey.Display) Server Value $serverValue Percentage usage $percentageLoad"

            $htmlLoadDetails += "$([System.Environment]::NewLine)<td><center>$($serverValue)</center></td>
            <td><center>$percentageLoad</center></td>"
        }
        $htmlLoadDetails += "$([System.Environment]::NewLine)</tr>"
    }

    # Totals
    $htmlLoadDetails += "$([System.Environment]::NewLine)<tr>
        <td><center>Totals</center></td>
        <td></td>"
    $keyOrders | ForEach-Object {
        $htmlLoadDetails += "$([System.Environment]::NewLine)<td><center>$($totalStats[(($displayKeys[$_]).Counter)])</center></td>
        <td></td>"
    }

    $htmlLoadDetails += "$([System.Environment]::NewLine)</table></p>"

    $htmlHeaderBackend = "<h2 align=""center"">BackEnd - Mailbox Role</h2><br>"

    [array]$htmlLoadDetailsBackend = "<table>
        <tr><th>Server</th>
        <th>Site</th>
        "
    #Load the key Headers
    $keyOrdersBackend | ForEach-Object {
        $htmlLoadDetailsBackend += "$([System.Environment]::NewLine)<th><center>$($displayKeysBackend[$_].Display) Requests</center></th>
            <th><center>$($displayKeysBackend[$_].Display) %</center></th>"
    }
    $htmlLoadDetailsBackend += "$([System.Environment]::NewLine)</tr>$([System.Environment]::NewLine)"

    foreach ($server in $MBXServers) {
        $serverKey = $server.Name.ToString()
        Write-Verbose "Working Server for HTML report $serverKey"
        $htmlLoadDetailsBackend += "<tr>
            <td>$($serverKey)</td>
            <td><center>$($server.Site)</center></td>"

        foreach ($key in $keyOrdersBackend) {
            $currentDisplayKey = $displayKeysBackend[$key]
            $totalRequests = $totalBackendStats[$currentDisplayKey.Counter]

            if ($perServerBackendStats.Contains($serverKey)) {
                $serverValue = $perServerBackendStats[$serverKey][$currentDisplayKey.Counter]
                if ($null -eq $serverValue) { $serverValue = 0 }
            } else {
                $serverValue = 0
            }
            if ( $totalRequests -eq 0 -or $null -eq $totalRequests) {
                $percentageLoad = 100
            } else {
                $percentageLoad = [math]::Round((($serverValue / $totalRequests) * 100))
            }
            Write-Verbose "$($currentDisplayKey.Display) Server Value $serverValue Percentage usage $percentageLoad"
            $htmlLoadDetailsBackend += "$([System.Environment]::NewLine)<td><center>$($serverValue)</center></td>
                <td><center>$percentageLoad</center></td>"
        }
        $htmlLoadDetailsBackend += "$([System.Environment]::NewLine)</tr>"
    }

    # Totals
    $htmlLoadDetailsBackend += "$([System.Environment]::NewLine)<tr>
            <td><center>Totals</center></td>
            <td></td>"
    $keyOrdersBackend | ForEach-Object {
        $htmlLoadDetailsBackend += "$([System.Environment]::NewLine)<td><center>$($totalBackendStats[(($displayKeysBackend[$_]).Counter)])</center></td>
            <td></td>"
    }
    $htmlLoadDetailsBackend += "$([System.Environment]::NewLine)</table></p>"

    $htmlReport = $htmlHeader + $htmlLoadDetails
    $htmlReport = $htmlReport + $htmlHeaderBackend + $htmlLoadDetailsBackend
    $htmlReport = $htmlReport + "</body></html>"

    $htmlFile = "$Script:OutputFilePath\HtmlLoadBalancerReport-$((Get-Date).ToString("yyyyMMddhhmmss")).html"
    $htmlReport | Out-File $htmlFile

    Write-Grey ""
    Write-Green "Client Access - FrontEnd information"
    foreach ($key in $keyOrders) {
        $currentDisplayKey = $displayKeys[$key]
        $totalRequests = $totalStats[$currentDisplayKey.Counter]

        if ($totalRequests -le 0) { continue }

        Write-Grey ""
        Write-Grey "Current $($currentDisplayKey.Display) Per Server"
        Write-Grey "Total Requests: $totalRequests"

        foreach ($serverKey in $perServerStats.Keys) {
            if ($perServerStats.Contains($serverKey)) {
                $serverValue = $perServerStats[$serverKey][$currentDisplayKey.Counter]
                Write-Grey "$serverKey : $serverValue Connections = $([math]::Round((([int]$serverValue / $totalRequests) * 100)))% Distribution"
            }
        }
    }

    Write-Grey ""
    Write-Green "Mailbox - BackEnd information"
    foreach ($key in $keyOrdersBackend) {
        $currentDisplayKey = $displayKeysBackend[$key]
        $totalRequests = $totalBackendStats[$currentDisplayKey.Counter]

        if ($totalRequests -le 0) { continue }

        Write-Grey ""
        Write-Grey "Current $($currentDisplayKey.Display) Per Server on Backend"
        Write-Grey "Total Requests: $totalRequests on Backend"

        foreach ($serverKey in $perServerBackendStats.Keys) {
            if ($perServerBackendStats.Contains($serverKey)) {
                $serverValue = $perServerBackendStats[$serverKey][$currentDisplayKey.Counter]
                Write-Grey "$serverKey : $serverValue Connections = $([math]::Round((([int]$serverValue / $totalRequests) * 100)))% Distribution on Backend"
            }
        }
    }
    Write-Grey ""
    Write-Grey "HTML File Report Written to $htmlFile"
}
