Function Get-OrphanVMDK
{
<#
.SYNOPSIS
    This function will prompt for vCenter, Location, and what you would like to do with the identified Orphan VMDKs

.DESCRIPTION
    This function will gather an array of all VMDKs attached to VMs, then gather all VMDKs in all Datastores, then will 
    proceed to compare the two arrays for discrepencies. Those discrepencies will the be available for manipulation, the
    ways available for manipulation are: Report (Which will only gather a full summary of OrphanedVMDKs), Rename (Will 
    rename all Orphan VMDKs to **VMDK_NAME**_ToDelete_**Date+15**Days.vmdk), and Delete (Which will remove all VMDKs)

.NOTES
    File Name: Get-OrphanVMDK.ps1
    Author: Eric Stehlin - eric@technology-strategies.net
    Requires: Powershell 3.0 & PowerCLI Installed

.LINK
    None

.EXAMPLE
    Apply appropriate variables for your required envrionment. Accepts Variable input. 
    Report will only produce the report and summary of the space consumed.
    Get-OrphanVMDK -vCenter $vCenter -Location $Location -Orphan Report

.EXAMPLE
    Apply appropriate variables for your required envrionment. Accepts Variable input.
    Rename will append the file with a **ToDelete** and apply a date 15 days in future.
    Get-OrphanVMDK -vCenter $vCenter -Location $Location -Orphan Rename

.EXAMPLE
    Apply appropriate variables for your required envrionment. Accepts Variable input.
    Delete will remove the orphaned VMDKs in your environment. Will not report.
    Get-OrphanVMDK -vCenter $vCenter -Location $Location -Orphan Delete

.EXAMPLE
    Apply appropriate variables for your required envrionment. Accepts Variable input.
    You can also specify a save location. 
    Get-OrphanVMDK -vCenter $vCenter -Location $Location -Orphan Report -SaveLocation C:\xfer
    
#>

#region Parameters
[CmdletBinding()]
param
(
    [Parameter(Mandatory=$true,
    ValueFromPipeline=$true)]
    [System.String]
    $vCenter,
    [Parameter(Mandatory=$true,
    ValueFromPipeline=$true)]
    [ValidateNotNullOrEmpty()]
    [System.String]
    $Location,
    [Parameter(Mandatory=$true,
    ValueFromPipeline=$true)]
    [ValidateSet("Report","Rename","Delete", ignorecase=$True)]
    [System.String]
    $Orphan,
    [Parameter(Mandatory=$false,
    ValueFromPipeline=$true)]
    [ValidateScript({Test-Path $_ -PathType Container})]
    $SaveLocation
)

#Set save location if none specified
if ($SaveLocation -eq $null)
{
    Write-Verbose "Save Location not specified"
    $SaveLocation = "$($env:USERPROFILE)\Desktop"
}

$report = @()

#endregion Parameters

#region Connecting to vCenter Server

########################
## Connect to vCenter ##
########################

## Load PowerCLI Powershell Module
    #Prevent loading Module if already loaded
    if (([bool](Get-Module -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue)) -eq $false)
    {
        Write-Verbose "Loading VMware PowerCLI Plugin"
        Import-Module VMware.VimAutomation.Core
        Write-Verbose "Loading VMware PowerCLI Plugin Complete"
    }
    else
    {
        Write-Verbose "VMware PowerCLI Plugin already loaded"
    }

##############################################
## Prevent duplicate connections to vCenter ##
##############################################
if ([bool]($global:DefaultVIServers -ne $null))
{
    if ([bool]($global:DefaultVIServers.name.Contains($vCenter)))
    {
        Write-Verbose "Session with $vCenter already established"
    }
    else
    {
        try
        {
            #Attempt logging in as local user
            Write-Verbose "Logging in as local user to:$vCenter"
            Connect-VIServer -Server $vCenter | Out-Null
        }
        catch [System.Exception]
        {
            #Prompt for credentials to login if Local User fails
            Write-Verbose "Logging in as designated user to:$vCenter"
            Connect-VIServer -Server $vCenter -Credential (Get-Credential) | Out-Null
        }
    }
}
else
{
    Connect-VIServer -Server $vCenter | Out-Null
}
#endregion Connecting to vCenter Server


#Gather Disks Attached to VMs
    Write-Verbose "Gathering Disks Attached to VMs"
    Write-Host "Checking for Orphaned VMDKs, This will take a while"
    Write-Verbose "Can take up to 30 minutes or more..."
    $arrUsedDisks = Get-View -Server $vCenter -ViewType VirtualMachine | % {$_.Layout} | % {$_.Disk} | % {$_.DiskFile}
    $Datastores = Get-Datastore -Datacenter $Location | Sort-Object -property Name
    Write-Verbose "Gathering Disks Attached to VMs Complete"

#Gather Processing
    foreach ($Datastore in $Datastores) 
    {
        Write-Host "Checking" $Datastore.Name "..."
        Write-Verbose "Searching Datastore for *.vmdk"
        $ds = Get-Datastore -Name $Datastore.Name | % {Get-View $_.Id}
        $fileQueryFlags = New-Object VMware.Vim.FileQueryFlags
        $fileQueryFlags.FileSize = $true
        $fileQueryFlags.FileType = $true
        $fileQueryFlags.Modification = $true
        $searchSpec = New-Object VMware.Vim.HostDatastoreBrowserSearchSpec
        $searchSpec.details = $fileQueryFlags
        $searchSpec.matchPattern = "*.vmdk"
        $searchSpec.sortFoldersFirst = $true
        $dsBrowser = Get-View $ds.browser
        $rootPath = "[" + $ds.Name + "]"
        Write-Verbose "Beginning Search"
        $searchResult = $dsBrowser.SearchDatastoreSubFolders($rootPath, $searchSpec)
        Write-Verbose "Search Complete"
        Write-Verbose "Beginning to parse VMDKs"
        foreach ($folder in $searchResult)
        {
            foreach ($fileResult in $folder.File)
            {
                if ($fileResult.Path)
                {
                    #Remove Change Tracking Files
                    if (-not ($fileResult.Path.contains("ctk.vmdk")) -or (-not ($fileResult.Path.contains("rdmp")))) 
                    {
                        #Removes Console.vmdk
                        if (-not ($fileResult.Path.contains("console.vmdk")))
                        {
                        Write-Verbose "Compare Datastore VMDKs with VM VMDKs"
                            if (-not ($arrUsedDisks -contains ($folder.FolderPath + $fileResult.Path)))
                            {
                                if ($Orphan.ToLower() -eq "report")
                                {
                                    Write-Verbose "Running 'Report' on VMDKs"
                                    Write-Verbose "Generating Report"
                                    $row = "" | Select DS, Folder, File, Size, ModDate, FullPath, NewName
                                    $row.DS = $Datastore.Name
                                    $row.Folder = ($folder.FolderPath).Replace("[$($Datastore.Name)] ",'').Replace('/','\')
                                    $row.File = $fileResult.Path
                                    $row.Size = $fileResult.FileSize
                                    $row.ModDate = $fileResult.Modification
                                    $row.FullPath = "$($Datastore.DatastoreBrowserPath)\$($row.Folder)"
                                    $row.NewName = "$($fileResult.Path.Replace('.vmdk',''))_ToDelete_$((Get-Date).AddDays(15).ToString('MM-dd-yyyy')).vmdk"
                                    $report += $row
                                    $SizeTotal += $row.Size
                                }
                                elseif ($Orphan.ToLower() -eq "rename")
                                {
                                    Write-Verbose "Running 'Rename' on VMDKs"
                                    Write-Verbose "Generate New File Path Name"
                                    $row = "" | Select Folder, FullPath, File, NewName, Success
                                    $row.File = $fileResult.Path
                                    $row.Folder = ($folder.FolderPath).Replace("[$($Datastore.Name)] ",'').Replace('/','\')
                                    $row.FullPath = "$($Datastore.DatastoreBrowserPath)\$($row.Folder)"
                                    $row.NewName = "$($fileResult.Path.Replace('.vmdk',''))_ToDelete_$((Get-Date).AddDays(15).ToString('MM-dd-yyyy')).vmdk"
                                    $report += $row
                                    #Catches any files that weren't properly renamed
                                    try 
                                    {
                                        Write-Verbose "Renaming VMDKs"
                                        Rename-Item -LiteralPath "$($row.FullPath)$($row.File)" -NewName $row.NewName -Force:$true -Confirm:$false -ErrorAction Stop
                                        $row.Success = "Renamed Successfully"
                                    }
                                    catch 
                                    {
                                        $row.Success = "Failed to Rename"
                                        Write-Host "Failed to Rename $($row.File)"
                                    }

                                }
                                elseif ($Orphan.ToLower() -eq "delete")
                                {
                                    Write-Verbose "Running 'Delete' on Orphaned VMDKs"
                                    Write-Verbose "Generate New File Path Name"
                                    $row = "" | Select Folder, FullPath, File, Success
                                    $row.File = $fileResult.Path
                                    $row.Folder = ($folder.FolderPath).Replace("[$($Datastore.Name)] ",'').Replace('/','\')
                                    $row.FullPath = "$($Datastore.DatastoreBrowserPath)\$($row.Folder)"
                                    $report += $row
                                    Write-Verbose "Deleting Orphaned VMDKs"
                                    #Catches any files that weren't properly deleted
                                    try
                                    {
                                        Write-Verbose "Deleting VMDKs"
                                        Remove-Item "$($row.FullPath)$($fileResult.Path)" -Force:$true -Confirm:$false
                                        $row.Success = "Deleted Successfully"
                                    }
                                    catch
                                    {
                                        $row.Success = "Failed to Delete"
                                        Write-Host "Failed to Delete $($row.File)"
                                    }
                                }
                                else
                                {
                                    Write-Verbose "Error Processing $Orphan Variable"
                                }
                            }
                        }
                    }
                }
            }
        } 
    }
    Write-Verbose "Processing of Orphaned VMDKs Complete"
#endregion Processing

#region Post-Processing
# Print report to $SaveLocation
    Write-Verbose "Writing to Report"
    $report | Out-File "$SaveLocation\$($vCenter)-$($Location)-$($Orphan).txt" -Append
    "Total Size Consumed = $($SizeTotal/1GB) GB" | Out-File "$SaveLocation\$($vCenter)-$($Location).txt" -Append
    Write-Verbose "Report Complete"
#endregion Post-Processing
}