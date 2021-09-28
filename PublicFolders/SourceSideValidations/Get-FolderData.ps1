﻿# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

. $PSScriptRoot\Get-IpmSubtree.ps1
. $PSScriptRoot\Get-NonIpmSubtree.ps1
. $PSScriptRoot\Get-ItemCount.ps1

function Get-FolderData {
    [CmdletBinding()]
    param (
        [Parameter()]
        [bool]
        $StartFresh = $true,

        [Parameter()]
        [bool]
        $SlowTraversal = $false
    )

    begin {
        Write-Verbose "$($MyInvocation.MyCommand) called."
        $startTime = Get-Date
        $serverName = (Get-Mailbox -PublicFolder (Get-OrganizationConfig).RootPublicFolderMailbox.HierarchyMailboxGuid.ToString()).ServerName
        $folderData = [PSCustomObject]@{
            IpmSubtree              = $null
            IpmSubtreeByMailbox     = $null
            ParentEntryIdCounts     = @{}
            EntryIdDictionary       = @{}
            NonIpmSubtree           = $null
            NonIpmEntryIdDictionary = @{}
            MailboxToServerMap      = @{}
            ItemCounts              = @()
            ItemCountDictionary     = @{}
            Errors                  = New-Object System.Collections.ArrayList
        }
    }

    process {
        if (-not $StartFresh -and (Test-Path $PSScriptRoot\IpmSubtree.csv)) {
            $folderData.IpmSubtree = Import-Csv $PSScriptRoot\IpmSubtree.csv
        } else {
            Add-JobQueueJob @{
                ArgumentList = $serverName, $SlowTraversal
                Name         = "Get-IpmSubtree"
                ScriptBlock  = ${Function:Get-IpmSubtree}
            }
        }

        if (-not $StartFresh -and (Test-Path $PSScriptRoot\NonIpmSubtree.csv)) {
            $folderData.NonIpmSubtree = Import-Csv $PSScriptRoot\NonIpmSubtree.csv
        } else {
            Add-JobQueueJob @{
                ArgumentList = $serverName, $SlowTraversal
                Name         = "Get-NonIpmSubtree"
                ScriptBlock  = ${Function:Get-NonIpmSubtree}
            }
        }

        # If we're not doing slow traversal, we can get the stats concurrently with the other jobs
        if (-not $SlowTraversal) {
            if (-not $StartFresh -and (Test-Path $PSScriptRoot\ItemCounts.csv)) {
                $folderData.ItemCounts = Import-Csv $PSScriptRoot\ItemCounts.csv
            } else {
                Add-JobQueueJob @{
                    ArgumentList = $serverName
                    Name         = "Get-ItemCount"
                    ScriptBlock  = ${Function:Get-ItemCount}
                }
            }
        }

        $completedJobs = Wait-QueuedJob

        foreach ($job in $completedJobs) {
            if ($null -ne $job.IpmSubtree) {
                $folderData.IpmSubtree = $job.IpmSubtree
                $folderData.IpmSubtree | Export-Csv $PSScriptRoot\IpmSubtree.csv
            }

            if ($null -ne $job.NonIpmSubtree) {
                $folderData.NonIpmSubtree = $job.NonIpmSubtree
                $folderData.NonIpmSubtree | Export-Csv $PSScriptRoot\NonIpmSubtree.csv
            }

            if ($null -ne $job.ItemCounts) {
                $folderData.ItemCounts = $job.ItemCounts
                $folderData.ItemCounts | Export-Csv $PSScriptRoot\ItemCounts.csv
            }
        }

        $folderData.IpmSubtreeByMailbox = $folderData.IpmSubtree | Group-Object ContentMailbox
        $folderData.IpmSubtree | ForEach-Object { $folderData.ParentEntryIdCounts[$_.ParentEntryId] += 1 }
        $folderData.IpmSubtree | ForEach-Object { $folderData.EntryIdDictionary[$_.EntryId] = $_ }
        # We can't count on $folder.Path.Depth being available in remote powershell,
        # so we calculate the depth by walking the parent entry IDs.
        $folderData.IpmSubtree | ForEach-Object {
            $pathDepth = 0
            $parent = $folderData.EntryIdDictionary[$_.ParentEntryId]
            while ($null -ne $parent) {
                $pathDepth++
                $parent = $folderData.EntryIdDictionary[$parent.ParentEntryId]
            }

            Add-Member -InputObject $_ -MemberType NoteProperty -Name FolderPathDepth -Value $pathDepth
        }
        $folderData.NonIpmSubtree | ForEach-Object { $folderData.NonIpmEntryIdDictionary[$_.EntryId] = $_ }

        # If we're doing slow traversal, we have to get the stats after we have the hierarchy
        # grouped by mailbox.
        if ($SlowTraversal) {
            if (-not $StartFresh -and (Test-Path $PSScriptRoot\ItemCounts.csv)) {
                $folderData.ItemCounts = Import-Csv $PSScriptRoot\ItemCounts.csv
            } else {
                Write-Verbose "Starting slow traversal item count."
                $itemCountResult = Get-ItemCount $serverName $folderData
                $folderData.ItemCounts = $itemCountResult.ItemCounts
                $folderData.ItemCounts | Export-Csv $PSScriptRoot\ItemCounts.csv
                foreach ($errorParam in $itemCountResult.Errors) {
                    $errorResult = New-TestResult @errorParam
                    $folderData.Errors.Add($errorResult)
                }
            }
        }

        $folderData.ItemCounts | ForEach-Object { $folderData.ItemCountDictionary[$_.EntryId] = $_.ItemCount }
    }

    end {
        Write-Host "Get-FolderData duration $((Get-Date) - $startTime)"
        Write-Host "    IPM_SUBTREE folder count: $($folderData.IpmSubtree.Count)"
        Write-Host "    NON_IPM_SUBTREE folder count: $($folderData.NonIpmSubtree.Count)"

        return $folderData
    }
}