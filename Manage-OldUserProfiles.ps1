<# 
Notes:
- Merged file-based checks
- Use WMI LastUseDate attribute from WMI as well as calculated last use date from profile load times
- Amended to look for missing essential folders instead
- use two duplicated loops for WMI and Reg


Questions:
- Could profiles exist which don't match the username in LDAP check? Does this matter using the SID? If the SIDs don't match, do we delete (i.e., renamed domain account)? what is the local profile path in this instance?
- we could also check the username matches in AD, but will need to be calculated from the folderpath name

Closed:
-- Is defaultuser a thing? - Yes,it is created by windows but can be deleted. No need to exclude
-- Should missing folders be combined with minimum size? 
-- Check the domain account limitation - is the filtering SID correct - Yes, local users has a different SID stub
-- Are WMI profiles and reg profile the same? How will .BAK profiles be represented and what about non-BAK profiles for the same SID? Not the same - reg entries are duplicated, whereas wmi only reports the non.bak sid
-- Need to manually delete reg keys for both otherwise they recreate and cannot be removed via WMI
-- Shall we filter out loaded profiles? I don't think so, Switched users are flagged as loaded in WMI, but don't survive a reboot
-- Is the last write date meaningless in the function - should we remove to speed up processing?Plus it's usage is inconsistent as we don't retunr the date for one function - yes it is so have tidies the logic
-- should we use an array for the AD users instead? Yes - reduces the number of LDAP queries to one initial hit (albeith returns 11000 entries)
#>

param (
	$logfile,
    [bool]$LiveMode = $false
)

if ($logfile -ne $null){
	try {
		Start-Transcript -Path $logfile -Append -ErrorAction Stop
	} catch {
		Write-Host "Failed to start transcript logging:" -ForegroundColor Red
		$message = $_
		Write-Host "Error $message" -ForegroundColor Red
	}
}

# Check if the script is running with administrative privileges otherwise folders will be inaccessible and give false positives
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

if ($isAdmin) {
    Write-Host "The script is running with administrative privileges." -ForegroundColor Green
} else {
    Write-Host "The script is NOT running with administrative privileges. Ending process." -ForegroundColor Red
    Exit
}

# General variables
$excludeSIDS = @("S-1-5-18","S-1-5-19","S-1-5-20","S-1-5-5-0","S-1-5-5-1")
$domainsid = "S-1-5-21-xxxx-"
$LDAPdomain = "LDAP://DC=xxxx,DC=xxxx,DC=uk"
# We only return domain based accounts this way
$AllRegProfiles = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" 
$RegProfiles = $AllRegProfiles|Where-Object { $_.Name -match $domainsid -and ($excludeSIDS -notcontains $_.Name) }
$AllWMIProfiles = Get-CimInstance -ClassName Win32_UserProfile
$WMIProfiles= $AllWMIProfiles |Where-Object { $_.sid -match $domainsid -and ($excludeSIDS -notcontains $_.sid) }
$requiredFolders = @("AppData", "Desktop", "Documents")
$excludedFolders = @('Public', 'All Users', 'Default', 'Default User','Temp','Administrator')
$thresholdDays = 180
$thresholdDate = (Get-Date).AddDays(-$thresholdDays)
$FoldersToDelete = @()
$profilesToDelete = @()
$regkeystodelete = @()
$orphanedDirs = @()
$LDAPUnavailable = $false
$ldapArray = @()
$RegistryKeyPath = "HKLM:\SOFTWARE\BuildDetails"
$RegistryValueName = "ProfileCleanLastRun"
$DrivetoCheck = "C"
# Enter Minimum drive space required in GB
$MinDriveSpace = 25
$CacheDaysThreshold = 30
$CacheArraytoDelete = @()


# Change this if we decide to schedule at a different time in SCCM
$ScheduledTime = [datetime]::ParseExact("10:30 AM", "h:m tt",$null)

# Use the script running at 10.30am as a proxy to detect manual invocation
$currentTime = Get-Date
if ($currenttime.Hour -eq $ScheduledTime.Hour -and $currentTime.Minute -eq $ScheduledTime.Minute) {
    # Generate a random delay between 1 and 60 minutes
    $delay = (Get-Random -Minimum 1 -Maximum 61)*60
    # Pause the script for the random delay
    Start-Sleep -Seconds $delay
}

# Function to check the amount of free space on a specified drive
function Get-DriveFreeSpace {
    param (
        [Parameter(Mandatory = $true)]
        [string]$DriveLetter
    )

    try {
        # Get drive information
        $VolumeInfo = Get-Volume -DriveLetter $DriveLetter

        # Calculate free space in GB
        $FreeSpaceGB = [math]::Round($VolumeInfo.SizeRemaining / 1GB, 2)

        # Return free space in GB
        return $FreeSpaceGB
    } catch {
        Write-Error "Failed to retrieve information for drive '$DriveLetter'. Ensure the drive exists and is accessible."
    }
}

# Function to detect if the script has run today
function HasRunToday {
    if (Test-Path $RegistryKeyPath) {
        try {
            # Attempt to retrieve the registry value
            $lastRunDateString = (Get-ItemProperty -Path $RegistryKeyPath -Name $RegistryValueName -ErrorAction SilentlyContinue).$RegistryValueName
            Write-Host "Last run time is: $lastRunDateString"
			if ($lastRunDateString) {
                [datetime]$lastRunDate = [datetime]::Parse($lastRunDateString)
                if ($lastRunDate.Date -eq (Get-Date).Date) {
                    return $true
                }
            }
        } catch {
            Write-Warning "Unable to retrieve or parse last run date from registry."
        }
    }
    # Return false if key or value does not exist
    return $false
}

# Function to update the registry with the run date and time
function UpdateLastRunLog {
    $currentDateTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
	if (-not (Test-Path $RegistryKeyPath)) {
        New-Item -Path $RegistryKeyPath -Force | Out-Null
    }
    try {
        Set-ItemProperty -Path $RegistryKeyPath -Name $RegistryValueName -Value $currentDateTime
    } catch {
        Write-Warning "Unable to update last run date in registry."
    }
}

# Delete passed registry keys
function Remove-RegistryKey {
    param (
        [string]$KeyPath
    )
    
    if (Test-Path $KeyPath) {
        try {
            Remove-Item -Path $KeyPath -Force -Recurse
        } catch {
		    $message = $_.Exception.Message
		    Write-Host "An error occurred deleting the registry key: $Message" -ForegroundColor Red
	    }
    }
    else {
        Write-Host "Registry key $KeyPath does not exist."
    }
}

# Detect impomplete profiles
function Is-IncompleteProfile {
    param (
        [string]$profilePath
    )
    
    if (-not (Test-Path -Path $profilePath)) {
        Write-Host "Profile path '$profilePath' is missing. Marking as incomplete."
        return $true
    }
    if ($profilePath -like "TEMP*") {
        Write-Host "Profile path '$profilePath' starts with 'TEMP'. Marking as incomplete."
        return $true
    }
        
    $items = Get-ChildItem -Path $profilePath -Force -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer }
    $missingFolders = $requiredFolders | Where-Object { -Not (Test-Path (Join-Path -Path $profilePath -ChildPath $_)) }
    if (-not $items) {
        Write-Host "Profile at '$profilePath' is empty. Marking as imcomplete."
        return $true
    }
    if ($missingFolders.Count -gt 0) {
        Write-Host "Profile at '$profilePath' is incomplete"
		Write-Host "Missing folders: $($missingFolders -join ', ')"
        return $true
    }	
    #Write-Host "Finished checking healthy profile at '$profilePath'."
    return $false
}

# Obsolete profiles based on sid
Function Is-UserInAD {
    param (
        [string]$sidstring
    )

    # Check if the SID exists in the hash table
    $result = $ldapArray | Where-Object { $_.SID -eq $sidstring }
    
    if ($result) {
        return $true
    } else {
        return $false
    }
    
}

# Generic add-to-array function to ensure unique values only added
function Add-ValueToArray {
    param (
        [array]$array,
        $valueToAdd
    )
    # Check if the value is not null and not already in the array
    if ($null -ne $valueToAdd -and $array -notcontains $valueToAdd) {
        $array += $valueToAdd
    }
    return $array
}

# Evaluate the last load time of a profile from the registry entries by SID
function Get-LastProfileLoadTime {
    param (
        [string]$SID
    )

    $profileListSIDKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$SID"
    $neverLoggedIn = [datetime]::MinValue

	try {
		$localProfileLoadTimeLow = Get-ItemProperty -Path $profileListSIDKey -Name LocalProfileLoadTimeLow -ErrorAction SilentlyContinue
		$localProfileLoadTimeHigh = Get-ItemProperty -Path $profileListSIDKey -Name LocalProfileLoadTimeHigh -ErrorAction SilentlyContinue

		if ($null -eq $localProfileLoadTimeLow.LocalProfileLoadTimeLow -or $null -eq $localProfileLoadTimeHigh.LocalProfileLoadTimeHigh) {
			return $neverLoggedIn
		}

		$localProfileLoadTime = ([long]$localProfileLoadTimeHigh.LocalProfileLoadTimeHigh -shl 32) + [long]$localProfileLoadTimeLow.LocalProfileLoadTimeLow
		$loadDate = [datetime]::FromFileTime($localProfileLoadTime)

		return $loadDate
	} catch {
		$message = $_.Exception.Message
		Write-Host "An unexpected error occurred while retrieving profile load time for SID: $SID. Error: $message"
		return $neverLoggedIn
	}
}

# Check for first run of the day and exit if not
if (HasRunToday) {
	Write-host "Script has already run today. Exiting"
	exit
}

#Get AD User hash table
try {
	$searcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]$LDAPdomain)
	$searcher.Filter = "(&(objectCategory=person)(objectClass=user))"
	$searcher.PropertiesToLoad.Add("sAMAccountName") | Out-Null
	$searcher.PropertiesToLoad.Add("objectSid") | Out-Null
	$searcher.PropertiesToLoad.Add("useraccountcontrol") | Out-Null
	$searcher.PageSize = 1000
	$LDAPHash = $searcher.FindAll()

	foreach ($user in $LDAPHash) {
		# Retrieve the SID, username, and account status from the LDAP object
		$sid = [System.Security.Principal.SecurityIdentifier]::new($user.Properties["objectSid"][0], 0).Value
		$username = $user.Properties["sAMAccountName"][0]
		$accountstatus = $user.Properties["useraccountcontrol"][0]

		# Add a new object to the array with SID, username, and account status
		$ldapArray += [PSCustomObject]@{
			SID               = $sid
			Username          = $username
			UserAccountControl = $accountstatus
		}
	}
} catch {
	$message = $_.Exception.Message
	Write-Host "An error occurred while querying LDAP: $Message" -ForegroundColor Red
    # Set the LDAP status flag to true to prevent repeated failed attempts
    $LDAPUnavailable = $true
}

# First, get all profile dirs on disk to check for orphaned directories against both WMI and registry
$profileDirs = Get-ChildItem "C:\Users" -Directory | Where-Object { $ExcludedFolders -notcontains $_.Name }
# Get all profile paths from WMI ProfileList
$WMIProfilePaths = $AllWMIProfiles | ForEach-Object {
    if (-not [string]::IsNullOrEmpty($_.LocalPath)) {
        $_.LocalPath.TrimEnd('\')
    }
}

$RegProfilePaths = $AllRegProfiles | ForEach-Object {
    (Get-ItemProperty $_.PSPath).ProfileImagePath
}

# Then check for orphan CCMCache folders
$CCMCacheLocation = Get-CimInstance -Namespace ROOT\CCM\SoftMgmtAgent -Query 'Select Location from CacheConfig' | Select-Object -ExpandProperty Location
$CacheWMIList = Get-CimInstance -Namespace "ROOT\ccm\SoftMgmtAgent" -ClassName CacheInfoEx | Select-Object -ExpandProperty Location | Sort-Object
$CacheFolderList = Get-ChildItem -Path $CCMCacheLocation -Directory

if ($CacheWMIList -eq $null) {$CacheWMIList = ""}
if ($CacheFolderList -eq $null) {$CacheFolderList = ""}

$orphanedDirs = @($profileDirs | Where-Object { $WMIProfilePaths -notcontains $_.FullName })
$orphanedDirs += @($profileDirs | Where-Object { $RegProfilePaths -notcontains $_.FullName })
$orphanedDirs += @($CacheFolderList | Where-Object { $CacheWMIList -notcontains $_.FullName })
$orphanedDirs = $orphanedDirs | Select-Object -Unique

foreach ($orphanedDir in $orphanedDirs) {
    $OrphanPath = $orphanedDir.FullName
    Write-host "Orphaned folder discovered: $OrphanPath" -ForegroundColor Gray
    $FoldersToDelete = Add-ValueToArray -array $FoldersToDelete -valueToAdd $OrphanPath
}

# Check each profile for deletion - note.bak profiles will be listed twice
foreach ($WMIProfile in $WMIProfiles) {
    $ProfileSID = $WMIProfile.SID
    $LastLoadDate = $WMIProfile.LastUseTime
    $ProfileFolder = $WMIProfile.LocalPath
    # Get the total size for info
    #$folderSizeBytes = (Get-ChildItem -Path $ProfileFolder -File -Force -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    #$folderSizeGB = [math]::Round($folderSizeBytes / 1GB, 2)
    
    #Write-Host "Checking WMI Profile '$ProfileSID' Last modified: $LastLoadDate Folder: $ProfileFolder FolderSize:  $folderSizeGB GB" -ForegroundColor White
	Write-Host "Checking WMI Profile '$ProfileSID' Last modified: $LastLoadDate Folder: $ProfileFolder" -ForegroundColor White
    
    # Check if the profile folder value is missing first to avoid issues later on
    if ($null -eq $ProfileFolder) {
        # Add the profile SID only to the list for deletion - folders are null so can't be deleted
        $profilesToDelete = Add-ValueToArray -array $profilesToDelete -valueToAdd $ProfileSID
        Write-Host "Profile at '$ProfileSID' is missing the profile folder, adding for removal" -ForegroundColor Cyan
        continue
    }
    
     # Check for aged profiles - will default to remval if no value found
    if ($LastLoadDate -lt $thresholdDate) {
        # Add the profile to the list for deletion
        $profilesToDelete = Add-ValueToArray -array $profilesToDelete -valueToAdd $ProfileSID
        $FoldersToDelete = Add-ValueToArray -array $FoldersToDelete -valueToAdd $ProfileFolder
        Write-Host "User $ProfileSid is WMI Aged, adding for removal" -ForegroundColor Cyan
        continue
    }

    # Check if the profile folder is invalid
    if (Is-IncompleteProfile -profilePath $ProfileFolder) {
        # Add the profile to the list for deletion
        $profilesToDelete = Add-ValueToArray -array $profilesToDelete -valueToAdd $ProfileSID
        $FoldersToDelete = Add-ValueToArray -array $FoldersToDelete -valueToAdd $ProfileFolder
        Write-Host "Corrupted profile $ProfileSID added for removal." -ForegroundColor Cyan
		continue
     }
    # Check if the username exists in AD - bypass if failed
    if ($LDAPUnavailable) {
        Write-Host "Skipping LDAP check because it has previously failed." -ForegroundColor Yellow
    } elseif (-not (Is-UserInAD -sidstring $sid)) {
        $profilesToDelete = Add-ValueToArray -array $profilesToDelete -valueToAdd $ProfileSID
        $FoldersToDelete = Add-ValueToArray -array $FoldersToDelete -valueToAdd $ProfileFolder
        Write-Host "User $ProfileSID does not exist in AD, adding for removal" -ForegroundColor Cyan
        continue
    }
}

# Now repeat through the profiles defined in the registry
foreach ($regprofile in $RegProfiles) {
    $sid = $regprofile.PSChildName
	$profilePath = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -Name "ProfileImagePath" -ErrorAction SilentlyContinue |select-object -ExpandProperty "ProfileImagePath"
    $LastRegLoadDate = (Get-LastProfileLoadTime -SID $sid)

    Write-Host "Checking registry Profile '$sid' Last modified: $LastRegLoadDate Folder: $profilePath" -ForegroundColor White

    # Check if the profile folder value is missing first to avoid issues later on
    if ($null -eq $profilePath) {
        Write-Host "Profile at '$sid' is missing the profile folder value" -ForegroundColor DarkMagenta
        # Add the profile SID to the list for deletion, again we cannot add a null folder for deletion
        $profilesToDelete = Add-ValueToArray -array $profilesToDelete -valueToAdd $sid
        continue
    }

    # Clear out profiles ending in .bak
    if ($sid -like "*.bak") {
        $nonBakSid = $sid -replace '\.bak$', ''
        $regkeystodelete = Add-ValueToArray -array $regkeystodelete -valueToAdd "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
        $regkeystodelete = Add-ValueToArray -array $regkeystodelete -valueToAdd "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$nonBakSid"
        $profilesToDelete = Add-ValueToArray -array $profilesToDelete -valueToAdd $sid
        $FoldersToDelete = Add-ValueToArray -array $FoldersToDelete -valueToAdd $profilePath
		Write-Host ".BAK profile added to deletion list: $sid" -ForegroundColor DarkMagenta
        Write-Host "Corresponding profile added to deletion list: $nonBakSid" -ForegroundColor DarkMagenta
		continue
    }

    # Check the registry last load dates for aged profiles
    if ($LastRegLoadDate -lt $thresholdDate) {
        # Add the profile to the list for later deletion
        $profilesToDelete = Add-ValueToArray -array $profilesToDelete -valueToAdd $sid
        $FoldersToDelete = Add-ValueToArray -array $FoldersToDelete -valueToAdd $profilePath
        Write-Host "User $sid is Reg Aged - last used: $LastRegLoadDate, adding for removal" -ForegroundColor DarkMagenta
        continue
    }

    # Check if the profile folder is invalid
    if (Is-IncompleteProfile -profilePath $profilePath) {
        # Add the profile and folder to the list for later deletion
        $profilesToDelete = Add-ValueToArray -array $profilesToDelete -valueToAdd $sid
        $FoldersToDelete = Add-ValueToArray -array $FoldersToDelete -valueToAdd $profilePath
        Write-Host "Corrupted profile $sid added for removal." -ForegroundColor DarkMagenta
		continue
     }

    # Check if the username exists in AD - bypass if failed
    if ($LDAPUnavailable) {
        Write-Host "Skipping LDAP check because it has previously failed." -ForegroundColor Yellow
    } elseif (-not (Is-UserInAD -sidstring $sid)) {
        $profilesToDelete = Add-ValueToArray -array $profilesToDelete -valueToAdd $sid
        $FoldersToDelete = Add-ValueToArray -array $FoldersToDelete -valueToAdd $profilePath
        Write-Host "User $sid does not exist in AD, adding for removal" -ForegroundColor DarkMagenta
        continue
    }
}

# Check if free space is less than the minimum required space if so scan for cache entries to remove
$DriveFreeSpace = Get-DriveFreeSpace -DriveLetter $DrivetoCheck
if ($DriveFreeSpace -lt $MinDriveSpace) {
    Write-Host "Free space on $DrivetoCheck is $DriveFreeSpace GB. Checking for expired cache folders"
    try {
        $CacheTargetDate = (Get-Date).AddDays(-$CacheDaysThreshold)
        $CCM = New-Object -ComObject UIResource.UIResourceMgr
        $CCMCache = $CCM.GetCacheInfo()
        $CCMCacheElements = $CCMCache.GetCacheElements()

        ForEach ($CacheElement in $CCMCacheElements) {
            [datetime]$LastRefTime = $CacheElement.LastReferenceTime
            $CacheLocation = $CacheElement.Location
            $CacheElementID = $CacheElement.CacheElementID

            if ($LastRefTime -lt $CacheTargetDate) {
                $CacheArraytoDelete = Add-ValueToArray -array $CacheArraytoDelete -valueToAdd $CacheElementID
                $FoldersToDelete = Add-ValueToArray -array $FoldersToDelete -valueToAdd $CacheLocation
            }
        }
    } catch {
        $message = $_.Exception.Message
		Write-Host "Failed during SCCM cache cleanup Error: $message"
    }
} else {
    Write-Host "Drive '$DrivetoCheck' has sufficient free space: $DriveFreeSpace"
}

# Profile removal - act on the arrays for deletion
foreach ($regkey in $regkeystodelete) {
    try {
		if (-not $LiveMode) {
            Write-Host "Test Mode: Would remove registry key : $regkey" -ForegroundColor Red
        } else {
		    Remove-RegistryKey -KeyPath $regkey
			Write-Host "Registry key $regkey successfully deleted."
        }
	} catch {
		$message = $_.Exception.Message
		Write-Host "Failed to remove registry key: $regkey Error: $message"
    }
}	

foreach ($sid in $profilesToDelete) {
    try {
		if (-not $LiveMode) {
            Write-Host "Test Mode: Would remove profile: $sid" -ForegroundColor Red
        } else {
		    try {
                Get-CimInstance -ClassName Win32_UserProfile | Where-Object { $_.SID -eq $sid } | Remove-CimInstance -ErrorAction Stop
                Write-Host "Successfully removed profile: $sid"
            } catch {
                Remove-RegistryKey -KeyPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
                Write-Host "Successfully removed registry profile instead: $sid"
            }
        }
	} catch {
		$message = $_.Exception.Message
		Write-Host "Failed to remove profile : $sid Error: $message"
    }
}

foreach ($folder in $FoldersToDelete) {
    if (-not $LiveMode) {
        Write-Host "Test Mode: Would remove profile directory: $folder" -ForegroundColor Red
    } else {
        if (Test-Path -Path $folder) {
            try {
                Remove-Item -Path $folder -Recurse -Force
                Write-Host "Removed profile directory: $folder" -ForegroundColor Green
            } catch {
                $message = $_.Exception.Message
                Write-Host "Failed to remove profile directory: $folder Error: $message" -ForegroundColor Red
            }
        } else {
            Write-Host "Profile directory does not exist: $folder" -ForegroundColor Yellow
        }
    }
}

foreach ($CacheElement in $CacheArraytoDelete) {
    if (-not $LiveMode) {
        Write-Host "Test Mode: Would remove CCM Cache: $CacheElement" -ForegroundColor Red
    } else {
        try {
            $CCMClient = New-Object -ComObject 'UIResource.UIResourceMgr'
            $CacheInfo = $CCMClient.GetCacheInfo()
            $CacheInfo.DeleteCacheElement($CacheElement)
            Write-Host "Removed CCM Cache directory: $CacheElement" -ForegroundColor Green
        } catch {
            $message = $_.Exception.Message
            Write-Host "Failed to remove CCM Cache: $CacheElement Error: $message" -ForegroundColor Red
        }
    }
}

UpdateLastRunLog

if ($logfile -ne $null){
    stop-Transcript
}
