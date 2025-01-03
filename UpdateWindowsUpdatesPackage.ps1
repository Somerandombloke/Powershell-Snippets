<#
    .SYNOPSIS
    Update Windows Latest update package to latest version.
    .DESCRIPTION
    This script downloads the latest Windows and .net updates for multiple versions of Windows and updates a corresponding package in MECM for use during imaging.

    .PARAMETER Siteserver
    Define the hostname of the Microsoft Endpoint Manager Configuration Manager site server.

    .PARAMETER Sitecode
    Define the sitecode of the Microsoft Endpoint Manager Configuration Manager site.

    .PARAMETER Foldername
    Define the shared folder where the package source files reside

    .PARAMETER Days
    Define how far back Windows updates should be searched - default is 30 days

    .PARAMETER SearchArray
    Define the search parameters to limit which updates are returned for each operating system

    .NOTES
    FileName:    UpdateWindowsUpdatesPackage.ps1
    Author:      Tristan David
    Created:     2023-12-17
    Version history:
    1.0.0 - (2023-12-17) Script created
    2.0.0 - (2025-01-03) Updated to ensure most recent .Net updates are included even if over 30 days and to accomodate changes in MSCatalogLTS - Product parameter no longer supported
#>



Start-Transcript -Path "$PSScriptRoot\WinUpdPackage.log" -append

#Firstoff - check that Config Manager powershell modules are installed and install if missing
Write-Host "Loading Microsoft Endpoint Configuration Manager PowerShell module."
if((Get-Module ConfigurationManager) -eq $null) { Import-Module "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1" }

#Check for MSCatalogLTS module. We use the LTS module as the current module causes the script to fail with an error regarding multiple files available
Write-Output "Checking if MSCatalogLTS PS Module is Installed"
if (!(Get-InstalledModule -Name MSCatalogLTS)){
 Verify Running as Admin
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
    If (!( $isAdmin )) {
        Write-Host "-- Restarting as Administrator to install Modules" -ForegroundColor Cyan ; Start-Sleep -Seconds 1
        Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs 
        exit
    }
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    Install-Module -Name MSCatalogLTS -Force
}

#Configure SCCM details
$siteserver = "xxxxxx"
$sitecode = "xxxxx"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

#This is the home folder where the updates will be saed to - note the need for the trailing \
$folderpath = "\\fileshare\SCCM\SourceFiles\OSD\"

#how far back the search should look for patches
$days = "30"
#Search array - elemnts are: Search Terms, Product Name, Sub Folder where Package sources are, Package ID
$SearchArray = @(
    ("22H2, x64","Windows 10*","WindowsUpdatesWin1022H2","xxx007EA"),
    ("23H2, x64","Windows 11","WindowsUpdatesWin1123H2","xxx007EB"),
    ("24H2, x64","Windows 11","WindowsUpdatesWin1124H2","xxx007EC")
)
#Set to a local drive in case SCCM drive still active, otherwise file actions will fail
Set-Location "C:"

#Loop through each search parameter
foreach($search in $SearchArray) {
  
#Set the variables for the muultidimensional array
  $Sstr = $search[0]
  $Product = $search[1]
  $folder =  $folderpath+$search[2]
  $PackageID = $search[3]

#Assign available updates to the variable array
 # $Updatelist = Get-MSCatalogUpdate -Search `"$Sstr`" -allpages |sort-object -Descending -Property LastUpdated | where-object { $_.Products -like $Product -and $_.Title -notlike "*Dynamic*" -and $_.Title -notlike "*Preview*" -and ($_.LastUpdated -ge ((Get-Date).AddDays(-$days))) }

#Assign available updates to the variable array
 $Allupdates = Get-MSCatalogUpdate -Search `"$Sstr`" -allpages | 
    Sort-Object -Descending -Property LastUpdated

$WinUpdates = $Allupdates | Where-Object {
    ($_.Products -like $Product -and 
    $_.Title -like "*Cumulative Update for Windows*" -and 
    $_.Title -notlike "*Dynamic*" -and 
    $_.Title -notlike "*Preview*" -and 
    ($_.LastUpdated -ge ((Get-Date).AddDays(-$days)))) 
}

# As .net is not release monnthly they need to be searched separately
$mostRecentDotNet = $Allupdates | Where-Object {
    $_.Products -like $Product -and
    $_.Title -like "*.NET*"
} | Sort-Object -Descending -Property LastUpdated | Select-Object -First 1

# Combine results into an array
$Updatelist = @()
if ($WinUpdates) {
    $Updatelist += $WinUpdates
}
if ($mostRecentDotNet) {
    $Updatelist += $mostRecentDotNet
}


#Check Updates are available, otherwise no action will be taken
    if ($Updatelist.Count -gt 0) {

#We'll backup the existing folder in case of problems, and so we don't need to worry about deleting old updates
       If(!(test-path -PathType container $folder)){
         New-Item -ItemType Directory -Path $folder
         } else {
         $backup = "$folder.bak"
         Write-Host "Renaming old folder temporarly in case we need rollback."
         Move-Item -Path $folder -Destination $backup
         New-Item -ItemType Directory -Path $folder
         }
#Spool through the updates list and download each one individually        
        Foreach ($Update in $Updatelist){
            $title= ($update).Title
            $Guid= ($update).Guid
            Save-MSCatalogUpdate -guid $Guid -Destination $folder
# Assume failure unless download process created new folder structure.
           $success = $false
        }

# Verify that files downloaded
         if (((Get-ChildItem $folder | Measure-Object ).Count) -gt 0) {
# Update successful
                write-host "Files found"
                $success = $true
                }
                else {
                # Update failed. Rollback
                Write-Host "Something went wrong. Performing rollback."
                Remove-Item -Path $folder -Recurse
                Move-Item -Path $backup -Destination $folder
                $success = $false
                }

          # We only update distribution points in MEMCM if update of files was successful
          if ($success -eq $true) {
                #We need to retain the installer script so copy this over
         copy-item -Path $backup\installupdates.ps1 -Destination $folder -Force
                Write-Host "Removing temporary backup folder."
                Remove-Item -Path $backup -Force -Recurse
                Set-Location "$($SiteCode):\"
                Update-CMDistributionPoint -PackageId $PackageID
                $PackageInfo = Get-CMPackage -id $PackageID -Fast
                Write-Host "Updated Package: $($PackageInfo.Name), ID: $PackageID"
                Set-Location "C:"
           }





     }
}
stop-Transcript
