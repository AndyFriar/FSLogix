<#
    .SYNOPSIS
        Create a container and copy in target OST/PST file

    .NOTES
        https://github.com/FSLogix/Fslogix.Powershell.Disk/tree/master/Dave%20Young/Ost%20Migration/Release
#>

[CmdletBinding(SupportsShouldProcess = $False)]
Param (
    [Parameter(Mandatory = $False)]
    # AD group name for target users for migration
    [string] $Group = "FSLogix-Office365Container-Migrate",

    [Parameter(Mandatory = $False)]
    # Location of the target OST / PST file
    [string] $DataFilePath = "\\ad1\Home\%username%",

    [Parameter(Mandatory = $False)]
    # Network location of the FSLogix Containers
    [string] $VHDLocation = "\\ad1\FSLogixContainers\RDS",

    [Parameter(Mandatory = $False)]
    [string[]] $FileType = ("*.ost", "*.pst"),

    [Parameter(Mandatory = $False)]
    # Target location in the new ODFC container
    [string] $ODFCPath = "ODFC",

    [Parameter(Mandatory = $False)]
    # Flip flip SID and username in folder name
    [switch] $FlipFlop,

    [Parameter(Mandatory = $False)]
    # Maximum VHD size in MB
    [string] $VHDSize = 30000,

    [Parameter(Mandatory = $False)]
    # Maximum VHD size in MB
    [ValidateSet('0', '1')]
    [int] $VhdIsDynamic = 1,

    [Parameter(Mandatory = $False)]
    # True to initialize driveletter, false to mount to path
    [switch] $AssignDriveLetter,

    [Parameter(Mandatory = $False)]
    # Remove user account from target AD group after migration
    [switch] $RemoveFromGroup,

    [Parameter(Mandatory = $False)]
    # Rename old Outlook data file/s
    [switch] $RenameOldDataFile,

    [Parameter(Mandatory = $False)]
    # Rename directory containing Outlook data file/s
    [switch] $RenameOldDirectory
)

Set-StrictMode -Version Latest
#Requires -RunAsAdministrator
#Requires -Modules "ActiveDirectory"
#Requires -Modules "Hyper-V"
#Requires -Modules "FsLogix.PowerShell.Disk"

#region Functions
Function Get-LineNumber() {
    $MyInvocation.ScriptLineNumber
}

Function Invoke-Process {
    <#PSScriptInfo 
    .VERSION 1.4 
    .GUID b787dc5d-8d11-45e9-aeef-5cf3a1f690de 
    .AUTHOR Adam Bertram 
    .COMPANYNAME Adam the Automator, LLC 
    .TAGS Processes 
    #>

    <# 
    .DESCRIPTION 
    Invoke-Process is a simple wrapper function that aims to "PowerShellyify" launching typical external processes. There 
    are lots of ways to invoke processes in PowerShell with Start-Process, Invoke-Expression, & and others but none account 
    well for the various streams and exit codes that an external process returns. Also, it's hard to write good tests 
    when launching external proceses. 
 
    This function ensures any errors are sent to the error stream, standard output is sent via the Output stream and any 
    time the process returns an exit code other than 0, treat it as an error. 
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FilePath,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ArgumentList
    )

    $ErrorActionPreference = 'Stop'

    try {
        $stdOutTempFile = "$env:TEMP\$((New-Guid).Guid)"
        $stdErrTempFile = "$env:TEMP\$((New-Guid).Guid)"

        $startProcessParams = @{
            FilePath               = $FilePath
            ArgumentList           = $ArgumentList
            RedirectStandardError  = $stdErrTempFile
            RedirectStandardOutput = $stdOutTempFile
            Wait                   = $true;
            PassThru               = $true;
            NoNewWindow            = $true;
        }
        if ($PSCmdlet.ShouldProcess("Process [$($FilePath)]", "Run with args: [$($ArgumentList)]")) {
            $cmd = Start-Process @startProcessParams
            $cmdOutput = Get-Content -Path $stdOutTempFile -Raw
            $cmdError = Get-Content -Path $stdErrTempFile -Raw
            if ($cmd.ExitCode -ne 0) {
                if ($cmdError) {
                    throw $cmdError.Trim()
                }
                if ($cmdOutput) {
                    throw $cmdOutput.Trim()
                }
            }
            else {
                if ([string]::IsNullOrEmpty($cmdOutput) -eq $false) {
                    Write-Output -InputObject $cmdOutput
                }
            }
        }
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
    finally {
        Remove-Item -Path $stdOutTempFile, $stdErrTempFile -Force -ErrorAction Ignore
    }
}
#endregion

# Script
# Validate Frx.exe is installed.
Try {
    $FrxPath = Confirm-Frx -Passthru -ErrorAction Stop
}
Catch {
    Write-Warning -Message "Error on line: $(Get-LineNumber)"
    Write-Error $Error[0]
    Exit
}

# Move to the frx install path and grab the path to frx.exe
Try {
    Push-Location -Path (Split-Path -Path $FrxPath -Parent)
    $cmd = Resolve-Path -Path ".\frx.exe"
    Pop-Location
}
Catch {
    Write-Warning -Message "Error on line: $(Get-LineNumber)"
    Write-Error $Error[0]
    Exit
}
Write-Verbose -Message "Frx.exe path is: $cmd."

#region Get group members from target migration AD group
# Modify to open a CSV list of usernames + OST/PST paths
Try {
    $groupMembers = Get-AdGroupMember -Identity $Group -Recursive -ErrorAction Stop
}
Catch {
    Write-Warning -Message "Error on line: $(Get-LineNumber)"
    Write-Error $Error[0]
}
#endregion

#region Step through each group member to create the container
ForEach ($User in $groupMembers) {
    Write-Verbose -Message "Generate container: $($User.SamAccountName)."

    #region Determine target container folder for the user's container
    Try {
        If ($FlipFlop.IsPresent) {
            Write-Verbose -Message "FlipFlip is present."
            $Directory = New-FslDirectory -SamAccountName $User.SamAccountName -SID $User.SID -Destination $VHDLocation `
                -FlipFlop -Passthru -ErrorAction Stop
        }
        Else {
            Write-Verbose -Message "FlipFlip is not present."
            $Directory = New-FslDirectory -SamAccountName $User.SamAccountName -SID $User.SID -Destination $VHDLocation `
                -Passthru -ErrorAction Stop
        }
        Write-Verbose -Message "Container directory: $Directory."
    }
    Catch {
        Write-Warning -Message "Error on line: $(Get-LineNumber)"
        Write-Error $Error[0]
        Exit
    }
    # Construct full VHD path 
    $vhdName = "ODFC_" + $User.SamAccountName + ".vhdx"
    $vhdPath = Join-Path $Directory $vhdName
    Write-Verbose -Message "VHDLocation: $vhdPath."
    #endregion

    #region Remove the VHD if it exists
    # Modify this to open an existing container
    If (Test-Path -Path $vhdPath) {
        If ($pscmdlet.ShouldProcess($vhdPath, "Remove")) {
            Remove-Item -Path $vhdPath -Force -ErrorAction SilentlyContinue
        }
    }
    #endregion

    #region Generate the container
    Try {
        $arguments = "create-vhd -filename $vhdPath -size-mbs=$VHDSize -dynamic=$vhdIsDynamic -label $($User.SamAccountName)"
        If ($pscmdlet.ShouldProcess($vhdPath, "Create VHD")) {
            Invoke-Process -FilePath $cmd -ArgumentList $arguments
        }
    }
    Catch {
        Write-Warning -Message "Error on line: $(Get-LineNumber)"
        Write-Error $Error[0]
        Exit
    }
    Write-Verbose -Message "Generated new VHD at: $vhdPath"
    #endregion

    #region Confirm the container is good
    Write-Verbose -Message "Validating Outlook container."
    $FslPath = $VHDLocation.TrimEnd('\%username%')
    Write-Verbose -Message "FslPath is $FslPath."
    If ($FlipFlop.IsPresent) {
        $IsFslProfile = Confirm-FslProfile -Path $FslPath -SamAccountName $User.samAccountName -SID $User.SID -FlipFlop
    }
    Else {
        $IsFslProfile = Confirm-FslProfile -Path $FslPath -SamAccountName $User.samAccountName -SID $User.SID
    }
    If ($IsFslProfile) {
        Write-Verbose -Message "Validated Outlook container."
    }
    Else {
        Write-Error $Error "Could not validate Outlook containers."
    }
    #endregion

    #region Apply permissions to the container
    Write-Verbose -Message "Applying security permissions for $($User.samAccountName)."
    Try {
        If ($pscmdlet.ShouldProcess($User.samAccountName, "Add permissions")) {
            Add-FslPermissions -User $User.samAccountName -folder $Directory
        }
        Write-Verbose -Message "Successfully applied security permissions for $($User.samAccountName)."
    }
    Catch {
        Write-Warning -Message "Error on line: $(Get-LineNumber)"
        Write-Error $Error[0]
        Exit
    }
    #endregion

    #region Get the OST/PST file path
    Write-Verbose -Message "Gather Outlook data file path."
    If ($DataFilePath.ToLower().Contains("%username%")) {
        $userDataFilePath = $DataFilePath -replace "%username%", $User.samAccountName
    }
    Else {
        $userDataFilePath = Join-Path $DataFilePath $User.samAccountName
    }
    If (-not(Test-Path -Path $userDataFilePath)) {
        Write-Warning -Message "Invalid Outlook data file path: $userDataFilePath"
        Write-Warning -Message "Error on line: $(Get-LineNumber)"
        Write-Warning "Could not locate Outlook data file path for $($User.samAccountName)."
    }
    Else {
        $dataFiles = Get-ChildItem -Path $userDataFilePath -Include $FileType -Recurse
    }
    If ($Null -eq $dataFiles) {
        Write-Warning -Message "No Outlook data files returned in $userDataFilePath"
        Write-Warning -Message "Error on line: $(Get-LineNumber)"
        Write-Warning "Could not locate Outlook data files for $($User.samAccountName)."
    }
    Else {
        Write-Verbose -Message "Successfully obtained Outlook data file/s."
    }
    ForEach ($dataFile in $dataFiles) {
        Write-Verbose -Message "Data file: $dataFile."
    }
    #endregion

    #region Mount the container
    Write-Verbose -Message "Mounting FSLogix Container."
    Try {
        If ($AssignDriveLetter.IsPresent) {
            If ($pscmdlet.ShouldProcess($vhdPath, "Mount")) {
                $MountPath = Add-FslDriveLetter -Path $vhdPath -Passthru
                Write-Verbose -Message "Container mounted at: $MountPath"
            }
        }
        Else {
            If ($pscmdlet.ShouldProcess($vhdPath, "Mount")) {
                $Mount = Mount-FslDisk -Path $vhdPath -ErrorAction Stop -PassThru
                $MountPath = $Mount.Path
                Write-Verbose -Message "Container mounted at: $MountPath"
            }
        }
    }
    Catch {
        Write-Warning -Message "Error on line: $(Get-LineNumber)"
        Write-Error $Error[0]
        Exit
    }
    #endregion

    #region Copy the data files
    Write-Verbose -Message "Copy Outlook data file/s"
    $dataFileDestination = Join-Path $MountPath $ODFCPath
    If (-not (Test-Path -Path $dataFileDestination)) {
        If ($pscmdlet.ShouldProcess($dataFileDestination, "Create")) {
            New-Item -ItemType Directory -Path $dataFileDestination -Force | Out-Null
        }
    }
    ForEach ($dataFile in $dataFiles) {
        Try {
            Write-Verbose -Message "Copy file $($dataFile.FullName) to $ODFCPath."
            If ($pscmdlet.ShouldProcess($dataFile.FullName, "Copy to disk")) {
                Copy-FslToDisk -VHD $vhdPath -Path $dataFile.FullName -Destination $ODFCPath -ErrorAction Stop
            }
        }
        Catch {
            Dismount-FslDisk -Path $vhdPath
            Write-Warning -Message "Error on line: $(Get-LineNumber)"
            Write-Error $Error[0]
            Exit
        }
    }
    #endregion

    #region Rename the old Outlook data file/s; rename folders; remove user from group
    If ($RenameOldDataFile.IsPresent) {
        ForEach ($dataFile in $dataFiles) {
            Try {
                If ($pscmdlet.ShouldProcess($dataFile.FullName, "Rename")) {
                    Write-Verbose -Message "Rename [$($dataFile.FullName)] to [$($dataFile.BaseName).old]."
                    Rename-Item -Path $dataFile.FullName -NewName "$($dataFile.BaseName).old" -Force -ErrorAction Stop
                }
            }
            Catch {
                Write-Warning -Message "Error on line: $(Get-LineNumber)"
                Write-Error $Error[0]
            }
        }
    }
    If ($RenameOldDirectory.IsPresent) {
        If ($Null -ne $userDataFilePath) {
            Try {
                Write-Verbose -Message "Renaming old Outlook data file directory"
                If ($pscmdlet.ShouldProcess($userDataFilePath, "Rename")) {
                    Rename-Item -Path $userDataFilePath -NewName "$($userDataFilePath)_Old" -Force -ErrorAction Stop
                }
            }
            Catch {
                Write-Warning -Message "Error on line: $(Get-LineNumber)"
                Write-Error $Error[0]
            }
            Write-Verbose -Message "Successfully renamed old Outlook data file directory"
        }
        Else {
            Write-Verbose "Skipping rename directory for user: $User."
        }
    }
    If ($RemoveFromGroup.IsPresent) {
        Try {
            Write-Verbose -Message "Removing $($User.samAccountName) from AD group: $Group."
            If ($pscmdlet.ShouldProcess($User.samAccountName, "Remove from group")) {
                Remove-ADGroupMember -Identity $Group -Members $User.samAccountName -ErrorAction Stop
            }
        }
        Catch {
            Write-Warning -Message "Error on line: $(Get-LineNumber)"
            Write-Error $Error[0]
        }
        Write-Verbose -Message "Successfully removed $($User.samAccountName) from AdGroup: $Group."
    }
    #endregion

    Write-Verbose -Message "Successfully migrated Outlook data file for $($User.samAccountName)."
    Write-Verbose -Message "Dismounting container."
    Try {
        If ($pscmdlet.ShouldProcess($vhdPath, "Dismount")) {
            Dismount-FslDisk -Path $vhdPath -ErrorAction Stop
            Write-Verbose -Message "Dismounted container."
        }
    }
    Catch {
        Write-Warning -Message "Error on line: $(Get-LineNumber)"
        Write-Error $Error[0]
        Exit
    }
}
#endregion
