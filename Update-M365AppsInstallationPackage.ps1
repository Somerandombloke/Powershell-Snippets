<#
    .SYNOPSIS
    Update M365 Apps / Office 365 installation package to latest version.
    .DESCRIPTION
    Update M365 Apps / Office 365 installation package to latest version.

    .PARAMETER Siteserver
    Define the hostname of the Microsoft Endpoint Manager Configuration Manager site server.

    .PARAMETER Sitecode
    Define the sitecode of the Microsoft Endpoint Manager Configuration Manager site.

    .PARAMETER ApplicationName
    Define the application name of the Microsoft 365 Apps application in Microsoft Endpoint Manager Configuration Manager.

    .PARAMETER Path
    Define the path of the Microsoft 365 Apps application content source

    .EXAMPLE
    .\Update-M365AppsInstallationPackage.ps1 -Siteserver "MEMCM01.andersrodland.com" -Sitecode "AR1" -ApplicationName "M365 Apps for Enterprise" -Path "\\memcm01\source\Applications\Microsoft 365 Apps for Enterprise"

    .NOTES
    FileName:    Update-M365AppsInstallationPackage.ps1
    Author:      Anders Rødland
    Contact:     @AndersRodland
    Created:     2020-12-30
    Version history:
    1.0.0 - (2020-12-30) Script created
    2.0.0 - (2024-11-07) Updated to use Garytown logic to download latest ODT and detect/update version, changed detection method & hardcoded additional paramters
    2.0.1 - (2024-12-17) Added Deadline offset and associated logic to change deployment deadline if required (to reduce network traffic from enforced global deplyments if using MECM to update Office)
    2.0.2 - (2025-01-03) Changed ODT Download URL logic due to MS website changes
#>

#Set Office App Name & corresponding Deployment Type Name
Start-Transcript -Path "$PSScriptRoot\OfficeUpdPackage.log" -append
$ApplicationName = "Microsoft Office 365 ProPlus en-US Current Latest x64 - Global Live" # $OfficeContentAppName
$OfficeContentAppDTName = "Office 365 ProPlus"
$SiteCode = "xxx" 
$Siteserver = "xxx.xx.xx" # $ProviderMachineName 
$rulearray = @()
$TargetCollectionName = "Microsoft Office 365 ProPlus x64"
$DeadlineOffset = "27.00:00" #Format is Days.Hours:Minutes

$Path = "\\xxxx\SCCM\SourceFiles\Applications\Microsoft\Microsoft_Office_365_Current_Latestx64" #$SetupPath replace with source folder on network
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
#First check that download.xml exists as this is a fatal error
if (Test-Path $path\Download.XML) {

    $ODTDownloadURL =((Invoke-WebRequest -Uri https://www.microsoft.com/en-us/download/details.aspx?id=49117 -UseBasicParsing).Links | where href -like *officedeploymenttool*.exe).href
    $ODTDownloadFile = "$env:temp\ODT.exe"
    $ODTExtractPath = "$env:temp\ODTExtract"
    if (Test-Path $ODTExtractPath) { 
        Remove-Item -Path $ODTExtractPath -Force -Recurse
    }
    $NewFolder = New-Item -Path $ODTExtractPath -ItemType Directory -Force

    Invoke-WebRequest -UseBasicParsing -Uri $ODTDownloadURL -OutFile $ODTDownloadFile
    Start-Process -FilePath $ODTDownloadFile -ArgumentList "/extract:$ODTExtractPath /log:$env:temp\ODT.log /quiet" -wait

    $SetupEXEVersion = (Get-Item -Path "$ODTExtractPath\setup.exe").VersionInfo.FileVersion

    if (Test-Path $Path) {
        $CurrentSetupEXEVersion = (Get-Item -Path $Path\setup.exe -ErrorAction SilentlyContinue).VersionInfo.FileVersion 
        if ($CurrentSetupEXEVersion -lt $SetupEXEVersion) {
            Set-Location -Path "c:"
            Copy-Item "$ODTExtractPath\setup.exe" -Destination $Path -Force
            Unblock-File -Path $Path\setup.exe
        }
    }
    else {
        Set-Location -Path "c:"
        Copy-Item "$ODTExtractPath\setup.exe" -Destination $Path -Force
        Unblock-File -Path $Path\setup.exe
    }

    # Define folder variables
    $folder = "$path\Office"
    $backup = "$folder.bak"

    # Download files
    Set-Location $path

    #Backup existing folder if it exists
    if (Test-Path $folder) {
        Write-Host "Renaming old Office folder temporarly in case we need rollback."
        Move-Item -Path $folder -Destination $backup
    }
    Write-Host "Downloading latest Office files."

    #Start the Office Download
    $DownloadArgs = "/Download $path\download.xml"
    Start-Process "$Path\setup.exe" -ArgumentList $DownloadArgs -Wait -NoNewWindow

    # Assume failure unless setup process created new folder structure.
    $success = $false

    # Verify that files downloaded
    if (Test-Path $folder) {
        # Update successful
        $PreviousCabName = (Get-ChildItem -Path "$backup\Data\v64_*.cab" -ErrorAction SilentlyContinue).Name
        $NewCabName = (Get-ChildItem -Path "$folder\Data\v64_*.cab").Name
        $success = $true
    }
    else {
        # Update failed. Rollback
        Write-Host "Something went wrong. Performing rollback."
        Move-Item -Path $backup -Destination $folder
        $success = $false
    }

    # We only update distribution points in MEMCM if update of files was successful and are new versions
    if ($success -eq $true -And $NewCabName -ne $PreviousCabName) {
        Write-Host "Removing temporary backup folder."
        Remove-Item -Path $backup -Force -Recurse -ErrorAction SilentlyContinue
        $VersionNumber = (($NewCabName).replace("v64_","")).replace(".cab","")
     
 
    # Connect to MEMCM
    Write-Host "Loading Microsoft Endpoint Configuration Manager PowerShell module."
    if((Get-Module ConfigurationManager) -eq $null) { Import-Module "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1" }
    
    # Connect to the site's drive if it is not already present
    Write-Host "Connecting to siteserver $siteserver with sitecode $sitecode"
    if((Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue) -eq $null) { New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer }
    Set-Location "$($SiteCode):\"

    #Update Application version number
    
    $CMApplication = Get-CMApplication -Name $ApplicationName
    Set-CMApplication -InputObject $CMApplication -SoftwareVersion $VersionNumber

    #Create the new Detection Method (Registry key value)
    $DetectionRegistryKeyName = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\O365ProPlusRetail - en-us'
    $DetectionRegistryPropertyName = "DisplayVersion"
 
    $newDetectionclause = New-CMDetectionClauseRegistryKeyValue -Hive LocalMachine -KeyName $DetectionRegistryKeyName -PropertyType Version -ValueName $DetectionRegistryPropertyName -ExpressionOperator GreaterEquals -ExpectedValue $versionnumber -Value -Is64Bit
    Write-Host "Setting Detection Method $DetectionRegistryKeyName to $versionnumber"

    #Add New Detection Method to AppDT
    Get-CMDeploymentType -ApplicationName $ApplicationName -DeploymentTypeName $OfficeContentAppDTName | Set-CMScriptDeploymentType -AddDetectionClause $newDetectionclause

    #Get App Info after updating, then Remove the old Detection


    $CMDeploymentType = get-CMDeploymentType -ApplicationName $ApplicationName -DeploymentTypeName $OfficeContentAppDTName
    [XML]$AppDTXML = $CMDeploymentType.SDMPackageXML
    [XML]$AppDTDXML = $AppDTXML.AppMgmtDigest.DeploymentType.Installer.DetectAction.args.Arg[1].'#text'
    $RuleVersions = $AppDTDXML.EnhancedDetectionMethod.Rule.Expression.Operands
    foreach ($rules in $RuleVersions.Expression) {
        $LogicalName = (($rules.Operands.SettingReference).SettingLogicalName)
        $oldversion = (($rules.Operands.ConstantValue).Value)
        $rulearray += ,@("$oldversion", "$LogicalName")
    }
                       
    foreach ($ruleset in $rulearray){
        if ($ruleset[0] -ne $versionnumber) {
            $LogicalName = $ruleset[1]
        }
    }

    foreach ($Detection in $LogicalName){$CMDeploymentType | Set-CMScriptDeploymentType -RemoveDetectionClause $Detection}

    Write-Host "Updated Detection Method for M365 AppDT, now changing deplyment scudule for $DeadlineOffset days" -ForegroundColor Green

	# Retrieve the Deployment object to change the schedule
	$Deployment = Get-CMDeployment -CollectionName "$TargetCollectionName" -SoftwareName "$ApplicationName"

	Write-Host " Current Deadline is" $deployment.EnforcementDeadline

	# Update the deployment schedule
	$deadlinedate = (Get-Date) + $DeadlineOffset
	Set-CMApplicationDeployment -ApplicationName $ApplicationName -DeadlineDateTime $deadlinedate -CollectionName $TargetCollectionName

    Write-Host "Updated enforcement deadline for M365 AppDT, now Triggering Content Update" -ForegroundColor Green
    # Update distribution points
    Write-Host "Updating distribution points for $ApplicationName."
    $DeploymentTypeName = (Get-CMDeploymentType -ApplicationName $ApplicationName).LocalizedDisplayName
    Update-CMDistributionPoint -ApplicationName $ApplicationName -DeploymentTypeName $DeploymentTypeName

    }
    elseif ($success -eq $true -And $NewCabName -eq $PreviousCabName) {
        Write-Host "Removing downloaded folder as no updated files detected."
        Remove-Item -Path $folder -Force -Recurse
        Move-Item -Path $backup -Destination $folder
    }
}
else {
    Write-Host "Download XML Missing - script aborted"
}


stop-Transcript
