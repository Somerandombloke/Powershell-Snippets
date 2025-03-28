<# 
Notes:
- Merged file-based checks
- Use WMI LastUseDate attribute from WMI as well as file date plus calculated last use date from profile load times
- Amended to look for missing essential folders instead


Questions:

- Could profiles exist which don't match the username in LDAP check? Does this matter using the SID? If the SIDs don't match, do we delete (i.e., renamed domain account)?



Closed:
-- Is defaultuser a thing? - Yes,it is created by windows but can be deleted. No need to exclude
-- Should missing folders be combined with minimum size? 
-- Check the domain account limitation - is the filtering SID correct - Yes, local users has a different SID stub
-- Are WMI profiles and reg profile the same? How will .BAK profiles be represented and what about non-BAK profiles for the same SID? Not the same - reg entries are duplicated, whereas wmi only reports the non.bak sid
-- Need to manually delete reg keys for both otherwise they recreate and cannot be removed via WMI
-- Shall we filter out loaded profiles? I don't think so, Switched users are flagged as loaded in WMI, but don't survive a reboot
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
# We only return domain based accounts this way
$RegProfiles = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" |Where-Object { $_.Name -match "S-1-5-21-xxxx-" -and ($excludeSIDS -notcontains $_.Name) }
$WMIProfiles = Get-CimInstance -ClassName Win32_UserProfile |where-object { $excludeSIDS -notcontains $_.sid }
$requiredFolders = @("AppData", "Desktop", "Documents")
$excludedFolders = @('Public', 'All Users', 'Default', 'Default User')
$LDAPdomain = "LDAP://DC=xxxx,DC=xx,DC=xx"
$thresholdDays = 180
$thresholdDate = (Get-Date).AddDays(-$thresholdDays)
$sizeLimitMB = 3
$MinFileCount = 25
$FoldersToDelete = @()
$profilesToDelete = @()
$regkeystodelete = @()
$LDAPUnavailable = $false
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


function Remove-RegistryKey {
    param (
        [string]$KeyPath
    )
    
    if (Test-Path $KeyPath) {
        try {
            Remove-Item -Path $KeyPath -Force -Recurse
            Write-Host "Registry key $KeyPath successfully deleted."
        } catch {
		    $message = $_.Exception.Message
		    Write-Host "An error occurred deleting the registry key: $Message" -ForegroundColor Red
	    }
    }
    else {
        Write-Host "Registry key $KeyPath does not exist."
    }
}

function Is-InactiveorCorruptProfile {
    param (
        [string]$profilePath
    )

    $items = Get-ChildItem -Path $profilePath -Recurse -Force -ErrorAction SilentlyContinue
    $latestFile = $items | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    #$profileSize = ($items | Measure-Object -Property Length -Sum).Sum
    #$profileSizeMB = [math]::Round($profileSize / 1MB, 2)
    $missingFolders = $requiredFolders | Where-Object { -Not (Test-Path (Join-Path -Path $profilePath -ChildPath $_)) }

    Write-Host "Checking profile at: $profilePath"

    if (-not $latestFile) {
        Write-Host "Profile at '$profilePath' is empty. Marking as inactive."
        return $true
    }
    if ($missingFolders.Count -gt 0) {
        Write-Host "Profile at '$profilePath' is incomplete"
		Write-Host "Missing folders: $($missingFolders -join ', ')"
        return $true
    }	
    #if ($profileSizeMB -le $sizeLimitMB -and $missingFolders.Count -gt 0) {	#I feel that any missing folders should indicate a boned profile..
    #    Write-Host "Profile at '$profilePath' is incomplete"
	#	Write-Host "Size: $profileSizeMB MB"
	#	Write-Host "Missing folders: $($missingFolders -join ', ')"
    #    return $true
    #}
	#if ($items.Count -lt $MinFileCount) {
    #    Write-Host "Profile at '$profilePath' is too small"
	#	Write-Host "File count: $($items.count)"
	#    return $true
    #}
    if ($latestFile.LastWriteTime -lt $thresholdDate) {
        Write-Host "Profile at '$profilePath' is inactive."
		Write-Host "Last modified: $($latestFile.LastWriteTime)"
        return $true
    }
    Write-Host "Profile at '$profilePath' is healthy."
    return $false
}

# Obsolete profiles based on username from WMI or REG
function Is-UserNotInAD {
	param (
		[string]$sidstring,
        [ref]$LDAPUnavailable
    )
    try {
		$sidValue = (New-Object System.Security.Principal.SecurityIdentifier($sidString)).Value
		$searcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]$LDAPdomain)
		$searcher.Filter = "(&(objectCategory=person)(objectClass=user)(objectsid=$sidValue))"
		$result = $searcher.FindOne()

		if ($result -ne $null) {
			$userAccountControl = $result.Properties["useraccountcontrol"][0]
			if (($userAccountControl -band 2) -eq 2) {
				Write-Host "The account $sidstring is disabled in AD" -ForegroundColor Yellow
				return $false
			} else {
				Write-Host "The account $sidstring is enabled in AD" -ForegroundColor Green
				return $false
			}
		} else {
			Write-Host "User $sidstring not found in AD" -ForegroundColor Red
			return $true
		}
	} catch {
		$message = $_.Exception.Message
		Write-Host "An error occurred while querying LDAP: $Message" -ForegroundColor Red
        # Set the LDAP status flag to true
        $LDAPUnavailable.Value = $true
        return $false
	}
}

# Generic add-to-array function
function Add-ProfileforRemoval {
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

function Get-LastProfileLoadTime {
    param (
        [Parameter(Mandatory=$true)]
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


# Write out the paths and SIDS as a record of what's present
$WMIProfiles |select-object "LocalPath","SID"|ft

# First, get all profile dirs on disk to check both the Temp.* directories and orphaned directories
$profileDirs = Get-ChildItem "C:\Users" -Directory | Where-Object { $ExcludedFolders -notcontains $_.Name }
# Get all profile paths from WMI ProfileList
$WMIProfilePaths = $WMIProfiles | ForEach-Object {
    if (-not [string]::IsNullOrEmpty($_.LocalPath)) {
        $_.LocalPath.TrimEnd('\')
    }
}
# Loop through each folder in C:\Users
foreach ($dir in $profileDirs) {
    # If the folder name starts with "Temp." and is not "C:\Users\Temp", consider it for deletion
    if ($dir.Name -like "Temp*" -and $dir.FullName -ne "C:\Users\Temp") {
        # Add the profile to the list for later deletion
        $FoldersToDelete = Add-ProfileforRemoval -array $FoldersToDelete -valueToAdd $($dir.FullName)
        Write-Host "Temp folder added to deletion list: $($dir.FullName)" -ForegroundColor Red
    }
    # If the folder is orphaned (not in the WMI profiles), consider it for deletion
    elseif ($WMIProfilePaths -notcontains $dir.FullName) {
        # Add the folder to the list for later deletion
        $FoldersToDelete = Add-ProfileforRemoval -array $FoldersToDelete -valueToAdd $($dir.FullName)
        Write-Host "Orphan folder added to deletion list: $($dir.FullName)" -ForegroundColor Red
    } else {
        Write-Host "Profile folder $($dir.FullName) is listed in the registry. Skipping."
    }
}

# Belt and braces using WMI LastUsed date for unused profiles - removed due to errors if date missing and load date being more reliable
#foreach ($WMIProfile in $WMIProfiles) {
#    $WMILastUseDate = $WMIProfile.ConvertToDateTime($WMIProfile.LastUseTime)
#    if ($WMILastUseDate -lt $thresholdDate) {
#        Write-Host "Profile at '$($WMIProfile.SID)' is WMI Inactive. Last modified: $WMILastUseDate Folder: $($WMIProfile.LocalPath) " -ForegroundColor Cyan
#        # Add the profile to the list for later deletion
#		$profilesToDelete = Add-ProfileforRemoval -array $profilesToDelete -valueToAdd $($WMIProfile.SID)
#        $FoldersToDelete = Add-ProfileforRemoval -array $FoldersToDelete -valueToAdd $($WMIProfile.LocalPath)
#    }
#}

# Actual Belt and braces using registry to ID unused profiles
foreach ($WMIProfile in $WMIProfiles) {
    $LastLoadDate = (Get-LastProfileLoadTime -SID $($WMIProfile).SID)
    if ($LastLoadDate -lt $thresholdDate) {
        Write-Host "Profile at '$($WMIProfile.SID)' is WMI Inactive. Last modified: $LastLoadDate Folder: $($WMIProfile.LocalPath) " -ForegroundColor Cyan
        # Add the profile to the list for later deletion
		$profilesToDelete = Add-ProfileforRemoval -array $profilesToDelete -valueToAdd $($WMIProfile.SID)
        $FoldersToDelete = Add-ProfileforRemoval -array $FoldersToDelete -valueToAdd $($WMIProfile.LocalPath)
    }
}


# Loop through again to filter out SIDs without a local profile folder
foreach ($WMIProfile in $WMIProfiles) {
    $ProfileFolder = $WMIProfile.LocalPath
    if ($null -eq $ProfileFolder) {
        Write-Host "Profile at '$($WMIProfile.SID)' has a missing folder" -ForegroundColor Cyan
        # Add the profile to the list for later deletion
        $profilesToDelete = Add-ProfileforRemoval -array $profilesToDelete -valueToAdd $WMIProfile.SID
    }
}

# Now run through the profiles defined in the registry and remove old or corrupt profiles, as well as .BAK - this should leave the registry and file system matching
foreach ($profile in $RegProfiles) {
    $sid = $profile.PSChildName
    $profileKey = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
    $profilePath = $profileKey.ProfileImagePath
	
    # First things first - clear out profiles ending in .bak
    if ($profile.PSChildName -like "*.bak") {
        Write-Host "Found profile: $($profile.PSChildName) for removal"
        $nonBakSid = $sid -replace '\.bak$', ''
        Write-Host "Also deleting non-backup profiles : $nonBaksid for removal"
        #Pass the keys for deletion as the profile removal by SID fails on these
        
        # Add the profile to the list for later deletion
    	$regkeystodelete = Add-ProfileforRemoval -array $regkeystodelete -valueToAdd "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
        $regkeystodelete = Add-ProfileforRemoval -array $regkeystodelete -valueToAdd "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$nonBakSid"
        $profilesToDelete = Add-ProfileforRemoval -array $profilesToDelete -valueToAdd $SID
        $FoldersToDelete = Add-ProfileforRemoval -array $FoldersToDelete -valueToAdd $profilePath
		Write-Host ".BAK profile added to deletion list: $($profile.PSChildName)"
    } else {
        Write-Host "User $($profile.PSChildName) is not a .bak version. Moving on..."
    }
    
    # Now check for slam dunk removals - exclude existing folders set for deletion as they get done later
    if ([string]::IsNullOrEmpty($profilePath)) {
        # Profile path is null or empty
        $profilesToDelete = Add-ProfileforRemoval -array $profilesToDelete -valueToAdd $SID
        Write-Host "Profile $sid has a null or empty path, added for removal."
    } else {
      if ((Test-Path $profilePath) -and ($FoldersToDelete -notcontains $profilePath)) {
           # Check if the username exists in AD - bypass if previously failed
           if ($LDAPUnavailable -eq $false) {
               if (Is-UserNotInAD -sidstring $sid -LDAPUnavailable ([ref]$LDAPUnavailable)) {
                    # Add the profile and folder to the list for later deletion
                    $profilesToDelete = Add-ProfileforRemoval -array $profilesToDelete -valueToAdd $SID
                    $FoldersToDelete = Add-ProfileforRemoval -array $FoldersToDelete -valueToAdd $profilePath
                    Write-Host "User $sid does not exist in AD, adding for removal"
               } else {
                    if ($LDAPUnavailable -eq $true) {
                        Write-Host "LDAP Connection Failed Will not retry" -ForegroundColor Yellow
                    } else {
                     Write-Host "User $sid exists in AD. Moving on..."
                    }
               }
            } else {
                Write-Host "Skipping LDAP check because it has previously failed." -ForegroundColor Yellow
            }

            # Check if the profile is inactive or corrupt
            if (Is-InactiveorCorruptProfile -profilePath $profilePath) {
                # Add the profile and folder to the list for later deletion
                $profilesToDelete = Add-ProfileforRemoval -array $profilesToDelete -valueToAdd $SID
                $FoldersToDelete = Add-ProfileforRemoval -array $FoldersToDelete -valueToAdd $profilePath
                Write-Host "Corrupted profile $sid added for removal."
            } else {
                Write-Host "Profile $sid is healthy. Skipping."
            }
        } else {
            # Profile path doesn't exist, indicating orphaned profile or is already flagged
            # Add the profile to the list for later deletion
            $profilesToDelete = Add-ProfileforRemoval -array $profilesToDelete -valueToAdd $SID
            $FoldersToDelete = Add-ProfileforRemoval -array $FoldersToDelete -valueToAdd $profilePath
            Write-Host "Orphaned profile $sid added for removal."
        }
    }
}


# Profile removal

foreach ($regkey in $regkeystodelete) {
    try {
		if (-not $LiveMode) {
            Write-Host "Test Mode: Would remove registry key : $regkey" -ForegroundColor Red
        } else {
		    Remove-RegistryKey -RegistryKey $regkey
            Write-Host "Successfully removed registry key: $regkey"
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
		    Get-CimInstance -ClassName Win32_UserProfile | Where-Object { $_.SID -eq $sid } | Remove-CimInstance
            Write-Host "Successfully removed profile: $sid"
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




if ($logfile -ne $null){
    stop-Transcript
}

