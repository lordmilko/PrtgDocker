[CmdletBinding(DefaultParameterSetName="Build")]
param(
    [Parameter(Mandatory=$false, ParameterSetName="Build")]
    [switch]$Build,

    [Parameter(Mandatory=$true, ParameterSetName="Install")]
    [switch]$Install,

    [Parameter(Mandatory=$true, ParameterSetName="InstallProbe")]
    [switch]$InstallProbe,

    [Parameter(Mandatory=$true, ParameterSetName="Wait")]
    [switch]$Wait,

    [Parameter(Mandatory=$true, ParameterSetName="WaitProbe")]
    [switch]$WaitProbe
)

$ErrorActionPreference = "Stop"
$script:coreServiceName = "PRTGCoreService"
$script:dockerTemp = Join-Path ([IO.Path]::GetTempPath()) "dockerTemp"
$script:dockerTempServer = Join-Path ([IO.Path]::GetTempPath()) "dockerTempServer"
$script:imageContext = "C:\Installer"
$script:installerLog = Join-Path $script:imageContext "log.log"
$script:prtgProgramFiles = "C:\Program Files (x86)\PRTG Network Monitor"
$script:originalCustomSensors = "$script:prtgProgramFiles\Custom Sensors"
$script:customSensorsBackup = "$script:prtgProgramFiles\Custom Sensors (Backup)"
$script:prtgProgramData = "C:\ProgramData\Paessler\PRTG Network Monitor"

$script:probeServiceName = "PRTGProbeService"
$script:probeRegistryPath = "HKLM\SOFTWARE\WOW6432Node\Paessler\PRTG Network Monitor\Probe"
$script:probeConfig = "$script:prtgProgramData\config.reg"

#region Build
    #region New-PrtgBuild

<#
.SYNOPSIS
Creates new Docker images for PRTG Network Monitor.

.PARAMETER Name
A wildcard specifying the installers to process under the -Path.
.PARAMETER Path
The folder containing the installers to process. By default this is the folder containing this script.
.PARAMETER Force
Specifies to generate Docker images without using the build cache.
.PARAMETER HyperV
Specifies that Docker should use Hyper-V isolation when building the image.
.PARAMETER BaseImage
The Windows Server build that should be used as the Docker Image base. By default this is "ltsc2019".
.PARAMETER PrtgEmail
The email address that should be used for the PRTG Administrator account. By default a dummy email is used.
.PARAMETER LicenseName
The license name that should be used for PRTG. By default "prtgtrial" is used.
.PARAMETER LicenseKey
The license key that should be used for PRTG. By default PRTG Trial key is used.
.PARAMETER Credential
Credential that should be used for remotely connecting to the Docker server using WinRM for changing the time. Used when $env:DOCKER_HOST is specified.
.PARAMETER Repository
Repository that should be used for the build. By default this value is "prtg".
.PARAMETER Server
Specifies that the PRTG installer should not be included in the build context and instead should be sent to Docker via a local web server temporarily spun up by New-PrtgBuild.
.PARAMETER SkipExisting
Specifies that installers that already have images should be skipped.
.PARAMETER Probe
Specifies that a PRTG Remote Probe image should be built, rather than a PRTG Core Server image.
.PARAMETER AdditionalArgs
Specifies additional arguments that should be included in the call to docker build.

.EXAMPLE
C:\> New-PrtgBuild
Creates a new build for a PRTG Core Server

.EXAMPLE
C:\> New-PrtgBuild -Probe
Creates a new build for a PRTG Remote Probe
#>
function New-PrtgBuild
{
    [CmdletBinding(DefaultParameterSetName = "Server")]
    param(
        [ValidateNotNullorEmpty()]
        [Parameter(Mandatory=$false, Position = 0, ParameterSetName = "Server")]
        [string]$Name = "*",

        [ValidateNotNullorEmpty()]
        [Parameter(Mandatory=$false, Position = 1, ParameterSetName = "Server")]
        [string]$Path = $PSScriptRoot,

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [switch]$HyperV,

        [ValidateNotNullorEmpty()]
        [Parameter(Mandatory = $false)]
        [string]$BaseImage = "ltsc2019",

        [ValidateNotNullorEmpty()]
        [Parameter(Mandatory = $false, ParameterSetName = "Server")]
        [string]$PrtgEmail,

        [ValidateNotNullorEmpty()]
        [Parameter(Mandatory = $false, ParameterSetName = "Server")]
        [string]$LicenseName,

        [ValidateNotNullorEmpty()]
        [Parameter(Mandatory = $false, ParameterSetName = "Server")]
        [string]$LicenseKey,

        [Parameter(Mandatory = $false, ParameterSetName = "Server")]
        [PSCredential]$Credential,

        [ValidateNotNullorEmpty()]
        [Parameter(Mandatory = $false)]
        [string]$Repository = "prtg",

        [Parameter(Mandatory = $false)]
        [switch]$Server,

        [Parameter(Mandatory = $false, ParameterSetName = "Server")]
        [switch]$SkipExisting,

        [Parameter(Mandatory = $true, ParameterSetName = "Probe")]
        [switch]$Probe,

        [Parameter(Mandatory = $false)]
        [string[]]$AdditionalArgs
    )

    $settings = [PSCustomObject]@{
        Force = $Force
        HyperV = $HyperV
        BaseImage = $BaseImage
        PrtgEmail = $PrtgEmail
        LicenseName = $LicenseName
        LicenseKey = $LicenseName
        DockerHost = $null
        Repository = $Repository
        FileServer = $null
        SkipExisting = $SkipExisting
        Mode = $PSCmdlet.ParameterSetName
        DockerFile = "Dockerfile"
        ProductName = "PRTG Network Monitor"
        AdditionalArgs = $AdditionalArgs
    }

    if($Credential)
    {
        $global:dockerCreds = $Credential
    }

    if($Probe)
    {
        $settings.DockerFile = "Dockerfile.probe"
        $settings.ProductName = "PRTG Remote Probe"
        __VerifyRepo $settings.DockerFile

        if(!$PSBoundParameters.ContainsKey("Repository"))
        {
            $Repository = "prtgprobe"
            $settings.Repository = $Repository
        }
    }
    else
    {
        __VerifyRepo
    }

    __QualifyBaseImage $settings
    $installers = __GetInstallers $Name $Path $settings.ProductName $settings.Mode
    __GetDockerHost $settings

    try
    {
        $settings.FileServer = __PrepareDockerTemp $Server $settings.DockerFile

        $split = $settings.BaseImage -split ":"

        if(!(Get-PrtgImage -Repository $split[0] -Tag $split[1]))
        {
            __Exec @("pull",$settings.BaseImage)
        }

        if($settings.Mode -eq "Server")
        {
            foreach($installer in $installers)
            {
                __ExecuteBuild $installer $settings
            }
        }
        else
        {
            __CopyToDockerTemp $installers.FullName $settings
            __ExecuteBuildInternal $installers $settings
        }
        
    }
    finally
    {
        if($settings.FileServer -ne $null)
        {
            $settings.FileServer.Stop()
        }
    }

    Remove-Item $script:dockerTemp -Recurse -Force

    if(Test-Path $script:dockerTempServer)
    {
        Remove-Item $script:dockerTempServer -Recurse -Force
    }
}

function __VerifyRepo($required = $null)
{
    if(!$required)
    {
        $required = @(
            "config.dat"
            "Dockerfile"
            "PrtgDocker.ps1"
        )
    }

    foreach($file in @($required))
    {
        $path = Join-Path $PSScriptRoot $file

        if(!(Test-Path $path))
        {
            throw "Cannot continue as mandatory file '$path' is missing"
        }
    }
}

function __QualifyBaseImage($settings)
{
    if(!$settings.BaseImage.Contains(":"))
    {
        $settings.BaseImage = "mcr.microsoft.com/windows/servercore:$($settings.BaseImage)"
    }
}

function __GetInstallers($name, $installerFolder, $productName = "PRTG Network Monitor", $mode)
{
    Write-Host "Enumerating installers in '$installerFolder'"

    if(!(Test-Path $installerFolder))
    {
        throw "Installer Path '$installerFolder' is not a valid folder"
    }

    $exe = gci $installerFolder -Filter "*.exe"

    if(!$exe)
    {
        $str = "No executable files exist in '$installerFolder'. Please place a PRTG installer in this folder and try again"

        if($mode -eq "Server")
        {
            $str += ", or specify an alternate -Path"
        }

        throw $str
    }

    $installers = $exe|where { $_.VersionInfo.ProductName.Trim() -eq $productName }

    if(!$installers)
    {
        $str = "Couldn't find any $productName installers under the specified folder. Please place a valid PRTG installer in this folder and try again"

        if($mode -eq "Server")
        {
            $str += ", or specify an alternate -Path"
        }

        throw $str
    }

    $candidates = $installers|where Name -Like $name

    if(!$candidates)
    {
        throw "Installer filter '$name' did not match any candidates"
    }

    $candidates | foreach { $_ | Add-Member Version ([Version]$_.VersionInfo.FileVersion) }
    $candidates = $candidates | sort version

    if($mode -eq "Probe")
    {
        if(@($candidates).Count -gt 1)
        {
            $str = ($candidates | foreach { "'$($_.FullName) ($($_.Version))'" }) -join ", "

            throw "Found multiple probe installers under '$installerFolder' ($str). Please specify only a single installer"
        }

        return $candidates
    }

    $grouped = $candidates | group { $_.Version.ToString(3) }

    Write-Host "Identified the following installers for processing" -ForegroundColor Cyan

    $ignored = @()

    foreach($group in $grouped)
    {
        if($group.Count -eq 1)
        {
            Write-Host "    $($group.Group.Name)"
        }
        else
        {
            $ignored += $group.Group | select -SkipLast 1
            $last = $group.Group | select -Last 1
            Write-Host "    $($last.Name)"
        }
    }

    if($ignored)
    {
        Write-Host "Ignoring the following installers as they are superseded by a later revision"

        foreach($ignore in $ignored)
        {
            Write-Host "    $($ignore.Name)"
        }
    }

    return $candidates
}

function __GetDockerHost($settings)
{
    if($settings.Mode -ne "Server")
    {
        return
    }

    if($env:DOCKER_HOST)
    {
        $settings.DockerHost = ([Uri]$env:DOCKER_HOST).Host

        Write-Host "`$env:DOCKER_HOST is defined. Will remotely connect to '$($settings.DockerHost)' to manipulate time"

        if(!($global:dockerCreds))
        {
            $global:dockerCreds = Get-Credential -Message "Please enter your Windows credentials to connect to '$($settings.DockerHost)'"
        }
    }
    else
    {
        Write-Host "`$env:DOCKER_HOST is not defined. Assuming running from Docker server"
    }
}

function __PrepareDockerTemp($server, $dockerFile = "Dockerfile")
{
    if(!(Test-Path $script:dockerTemp))
    {
        New-Item $script:dockerTemp -ItemType Directory | Out-Null
    }

    if($server)
    {
        if(!(Test-Path $script:dockerTempServer))
        {
            New-Item $script:dockerTempServer -ItemType Directory | Out-Null
        }
    }

    $contextFiles = @(
        $dockerFile      # Dockerfile is always required
        "PrtgDocker.ps1" # PrtgDocker.ps1 is needed after the build, and is also our single "guaranteed" file that exists in our COPY directive
    )

    foreach($file in $contextFiles)
    {
        $source = Join-Path $PSScriptRoot $file
        $destination = Join-Path $script:dockerTemp $file

        if($file -like "Dockerfile*")
        {
            $destination = Join-Path $script:dockerTemp "Dockerfile"
        }

        Copy-Item $source $destination -Force
    }

    # Server 2019 doesn't have fonts, so include these as well
    $fonts = gci C:\Windows\Fonts | where {$_.Name -like "*arial*" -or $_.Name -like "*tahoma*" }

    if(!$fonts)
    {
        throw "Cannot find any fonts for Arial and Tahoma under C:\Windows\Fonts. Chart Director requires Arial and Tahoma to function which are not present in Server 2019+ images"
    }

    foreach($font in $fonts)
    {
        $destination = Join-Path $script:dockerTemp $font.Name

        Copy-Item $font.FullName $destination -Force
    }

    if($server)
    {
        $fileServer = New-Object SimpleHTTPServer $script:dockerTempServer

        return $fileServer
    }
    else
    {
        return $null
    }
}

function __ExecuteBuild($installer, $settings)
{
    Write-Host "Processing version '$($installer.Version)'" -Foreground Magenta

    if($settings.SkipExisting)
    {
        if(Get-PrtgImage -Repository $settings.Repository -Tag $installer.Version.ToString("3"))
        {
            Write-Host "    Skipping installer as image already exists"
            return
        }
    }

    __CopyToDockerTemp $installer.FullName $settings

    if(__NeedLicenseHelp $installer)
    {
        __CopyToDockerTemp (Join-Path $PSScriptRoot "config.dat") $settings
    }

    $job = $null

    try
    {
        $job = __AdjustServerTime $settings.DockerHost $installer

        __ExecuteBuildInternal $installer $settings
    }
    finally
    {
        $job | Remove-Job -Force

        __RemoveFromDockerTemp $installer.Name $settings
        __RemoveFromDockerTemp "config.dat" $settings
    }
}

function __NeedLicenseHelp($installer)
{
    return $installer.Version -gt [Version]"16.4.27" -and $installer.Version -lt [Version]"19.3.52"
}

function __CopyToDockerTemp($file, $settings)
{
    $destination = $script:dockerTemp

    if($settings.FileServer -ne $null)
    {
        $destination = $script:dockerTempServer
    }

    Copy-Item $file $destination -Force
}

function __RemoveFromDockerTemp($file, $settings)
{
    $root = $script:dockerTemp

    if($settings.FileServer -ne $null)
    {
        $root = $script:dockerTempServer
    }

    $path = Join-Path $root $file

    if(Test-Path $path)
    {
        Remove-item $path -Force
    }
}

function __ExecuteBuildInternal($installer, $settings)
{
    $version = $installer.Version.ToString(3)

    $buildArgs = @(
        "build"
        $script:dockerTemp
        "-t"
        "$($settings.Repository):$version"
        "--build-arg"
        "BASE_IMAGE=$($settings.BaseImage)"
    )

    if($settings.Mode -eq "Server")
    {
        $installerSettings = @{
            # <Setting> = <ARG>
            PrtgEmail = "PRTG_EMAIL"
            LicenseName = "PRTG_LICENSENAME"
            LicenseKey = "PRTG_LICENSEKEY"
        }
    }

    if($installerSettings -ne $null)
    {
        foreach($item in $installerSettings.GetEnumerator())
        {
            $v = $settings."$($item.Name)"

            if(!([string]::IsNullOrEmpty($v)))
            {
                $buildArgs += @(
                    "--build-arg"
                    "$($item.Value)=$v"
                )
            }
        }
    }

    if($settings.FileServer -ne $null)
    {
        $installerName = [Net.WebUtility]::UrlEncode($installer.Name)

        $ipv4 = (Test-Connection -ComputerName ($env:COMPUTERNAME) -Count 1  | Select -Expand IPV4Address).IPAddressToString

        Write-Host "Advertising web server on $ipv4"

        $buildArgs += @(
            "--build-arg"
            "PRTG_INSTALLER_URL=http://$($ipv4):$($settings.FileServer.Port)/$installerName"
        )
    }

    if($settings.HyperV)
    {
        $buildArgs += "--isolation=hyperv"
    }

    if($settings.Force)
    {
        $buildArgs += "--no-cache"
    }

    if($settings.AdditionalArgs)
    {
        $buildArgs += $settings.AdditionalArgs
    }

    $stopwatch =  [System.Diagnostics.Stopwatch]::StartNew()

    __Exec $buildArgs

    $stopwatch.Stop()

    $duration = [math]::round($stopwatch.Elapsed.TotalMinutes, 2)

    if($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0)
    {
        throw "docker build did not complete successfully. Please check for any errors reported above. For PRTG Server Core most failures relate to subtle timing issues during build; please try running build again" 
    }
    else
    {
        Write-Host "Build completed in $duration minutes" -Foreground Green
    }
}

function __AdjustServerTime($dockerHost, $installer)
{
    $yearHack = __GetYearHack $installer

    if($dockerHost)
    {
        __TestTimeConnectivity $dockerHost $yearHack
        return __StartRemoteTimeWatcher $dockerHost $yearHack
    }
    else
    {
        return __StartLocalTimeWatcher $yearHack
    }
}

function __GetYearHack($installer)
{
    $version = $installer.Version.ToString("3")

    $year = 2000 + $installer.Version.Major
    $month = (12/4 * $installer.Version.Minor).ToString('00')
    $versionStr ="15/$month/$year"

    return $versionStr
}

function __TestTimeConnectivity($dockerHost, $yearHack)
{
    for($i = 0; $i -lt 5; $i++)
    {
        try
        {
            Invoke-Command $dockerHost -Credential $global:dockerCreds {

                $newDate = [DateTime]::ParseExact($using:yearHack, 'dd/MM/yyyy', $null)

                $result = Set-Date $newDate

                Write-Host "Successfully set date on Docker server to to '$result'"
            } -ErrorAction Stop

            break
        }
        catch
        {
            if($i -eq 4)
            {
                throw
            }

            if($_.Exception.Message -like "*There is a time and/or date difference*")
            {
                Write-Warning "Could not adjust time on Docker server; time and date is still incorrect from a previous attempt. Manually fix time with 'W32tm /resync /force' or 'net time /set /y'; Sleeping for 10 seconds and trying again..."
                Sleep 5
            }
        }
    }
}

function __StartRemoteTimeWatcher($dockerHost, $yearHack)
{
    $job = Start-Job {
        param($dockerHost, $dockerCreds, $yearHack)

        Invoke-Command $dockerHost -Credential $dockerCreds {
            param($yearHack)

            $newDate = [DateTime]::ParseExact($using:yearHack, 'dd/MM/yyyy', $null)

            for($i = 0; $i -lt 60; $i++)
            {
                Set-Date $newDate
                sleep 1
            }
        } -ArgumentList $yearHack -ErrorAction Stop
    } -ArgumentList ($dockerHost, $global:dockerCreds, $yearHack) -ErrorAction Stop

    return $job
}

function __StartLocalTimeWatcher($yearHack)
{
    $job = Start-Job {
        param($yearHack)

        $newDate = [DateTime]::ParseExact($yearHack, 'dd/MM/yyyy', $null)

        for($i = 0; $i -lt 60; $i++)
        {
            Set-Date $newDate
            sleep 1
        }
    } -ArgumentList ($yearHack) -ErrorAction Stop

    return $job
}

    #endregion
    #region New-PrtgContainer

<#
.SYNOPSIS
Creates a new Docker container from an image previously produced by New-PrtgBuild or 'docker build'.

.PARAMETER Tag
Tag that a container should be created from. If no tag is specified New-PrtgContainer will retrieve all images that exist under the specified Repository. If multiple tags exist, an exception will be thrown.
.PARAMETER Name
Name that should be assigned to the new container. If no value is specified Docker will generate a random name for you.
.PARAMETER Port
One or more ports that should be mapped to the container. By default port this value is 8080:80, which will map port 8080 on the host to port 80 in the container.
.PARAMETER Repository
Repository to create a container from. By default this value is "prtg".
.PARAMETER Interactive
Specifies whether to run this container in interactive mode with console access.
.PARAMETER Volume
Specifies that a volume should be created and mounted alongside this image for persisting data under the C:\ProgramData\Paessler\PRTG Network Monitor folder of the container. Volume name will be unique based on the tag of the image.
.PARAMETER HyperV
Specifies that the container should be run using Hyper-V isolation.
.PARAMETER Probe
Specifies that the container should be built from a PRTG Remote Probe image.
.PARAMETER ServerUrl
Specifies the server the PRTG Probe should connect to.
.PARAMETER CustomSensorsPath
Fully qualified UNC path of a network share to redirect the Custom Sensors folder to.
.PARAMETER CredentialSpec
Specifies that the container should be launched using a credential spec. If -Name is not specified, specifying this parameter will throw an exception. If a credential spec with the specified -Name does not exist, -CredentialSpecAccount must also be specified.
.PARAMETER CredentialSpecAccount
Specifies the gMSA account to use for creating the CredentialSpec (if one doesn't exist).
.PARAMETER RestartPolicy
Specifies the conditions under which the container should automatically start itself when stopped. By default this value is "Always"
.PARAMETER AdditionalArgs
Specifies additional arguments that should be included in the call to docker run.

.EXAMPLE
C:\> New-PrtgContainer 20* -Name "New York 1" -Volume
Creates a new container for the PRTG Core Server whose tag starts with "20", naming the container "New York 1" and attaching a volume to the folder "C:\ProgramData\Paessler\PRTG Network Monitor" within the container

.EXAMPLE
C:\> New-PrtgContainer -Probe -Name "New York 2" -Volume -ServerUrl prtg.example.com -CredentialSpec -CredentialSpecAccount container_gmsa -CustomSensorsPath \\fs-1\CustomSensors
Creates a new container for a PRTG Remote Probe:
* whose container and probe name is "New York 2",
* that connects to the PRTG Core Server prtg.example.com,
* that redirects the "Custom Sensors" folder under Program Files to a common network location,
* attaches a volume to the folder "C:\ProgramData\Paessler\PRTG Network Monitor" within the container,
* and configures the container to use a credential spec for using Active Directory authentication against network resources.
#>
function New-PrtgContainer
{
    [CmdletBinding(DefaultParameterSetName = "Server")]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Tag = "*",

        [ValidateNotNullOrEmpty()]
        [Parameter(Mandatory = $false, Position = 1)]
        [string]$Name,

        [ValidateNotNullOrEmpty()]
        [Parameter(Mandatory = $false, Position = 2, ParameterSetName = "Server")]
        [string[]]$Port = "8080:80",

        [ValidateNotNullOrEmpty()]
        [Parameter(Mandatory = $false)]
        [string[]]$Repository = "prtg",

        [Parameter(Mandatory = $false)]
        [switch]$Interactive,

        [Parameter(Mandatory = $false)]
        [switch]$Volume,

        [Parameter(Mandatory = $false)]
        [switch]$HyperV,

        [Parameter(Mandatory = $true, ParameterSetName = "Probe")]
        [switch]$Probe,

        [ValidateNotNullOrEmpty()]
        [Parameter(Mandatory = $false, ParameterSetName = "Probe")]
        [string]$ServerUrl,

        [Parameter(Mandatory = $false)]
        [string]$CustomSensorsPath,

        [Parameter(Mandatory = $false)]
        [switch]$CredentialSpec,

        [Parameter(Mandatory = $false)]
        [string]$CredentialSpecAccount,

        [ValidateSet("Always", "OnFailure", "UnlessStopped", "None")]
        [Parameter(Mandatory = $false)]
        [string]$RestartPolicy = "Always",

        [ValidateNotNullOrEmpty()]
        [Parameter(Mandatory = $false)]
        [string[]]$AdditionalArgs        
    )

    if($Name)
    {
        $Name = $Name -replace ' ','_'
    }

    $settings = @{
        Name = $Name
        Repository = $Repository
        Interactive = $Interactive
        Volume = $Volume
        HyperV = $HyperV
        Version = $null
        Probe = $Probe
        ServerUrl = $ServerUrl
        CustomSensorsPath = $CustomSensorsPath
        CredentialSpec = $CredentialSpec
        CredentialSpecAccount = $CredentialSpecAccount
        RestartPolicy = $RestartPolicy
        AdditionalArgs = $AdditionalArgs
    }

    if($Probe)
    {
        if(!$PSBoundParameters.ContainsKey("Repository"))
        {
            $Repository = "prtgprobe"
            $settings.Repository = $Repository
        }
    }
    else
    {
        $settings.Port = $Port
    }

    $settings = [PSCustomObject]$settings

    $settings.Version = __ResolveRunVersion $Tag $Repository

    $runArgs = __GetRunArgs $settings

    __Exec $runArgs
}

function __ResolveRunVersion($version, $repository)
{
    $candidates = @(Get-PrtgImage $version -Repository $repository)

    if(!$candidates)
    {
        if($version -eq "*")
        {
            throw "No PRTG images have been built. Please build an image first with New-PrtgImage"
        }
        else
        {
            throw "No PRTG images match the specified wildcard '$version'. Please check available images manually with 'docker container ls -a'"
        }
    }
    if($candidates.Count -eq 1)
    {
        return $candidates.Tag
    }
    else
    {
        $str = ($candidates|select -expand Tag) -join ", "

        throw "More than one image was found. Please specify one of the following -Tag candidates: $str"
    }
}

function __GetRunArgs($settings)
{
    $runArgs = @(
        "run"
        "-m"
        "4G"
        __RunMode $settings
        __OtherArgs $settings
        "$($settings.Repository):$($settings.Version)"
    )

    return $runArgs
}

function __RunMode($settings)
{
    $runMode = "-d"

    if($settings.Interactive)
    {
        $runMode = "-it"
    }

    return $runMode
}

function __OtherArgs($settings)
{
    $otherArgs = @()

    if(![string]::IsNullOrEmpty($settings.Name))
    {
        $otherArgs += @(
            "--name"
            $settings.Name.ToLower()
        )

        if($settings.Probe)
        {
            $otherArgs += @(
                "--env"
                "INIT_PRTG_NAME=$($settings.Name)"
            )
        }
    }

    if($settings.Port)
    {
        foreach($port in $settings.Port)
        {
            $otherArgs += @(
                "-p"
                $port
            )
        }
    }    

    if($settings.Volume)
    {
        $volumeName = "prtg$($settings.Version -replace '\.','_')"

        if($settings.Probe -and ![string]::IsNullOrWhiteSpace($settings.Name))
        {
            $volumeName = $settings.Name.ToLower()
        }

        $otherArgs += @(
            "-v"
            "$($volumeName):`"$script:prtgProgramData`""
        )
    }

    if($settings.ServerUrl)
    {
        $otherArgs += @(
            "--env"
            "INIT_PRTG_SERVER=$($settings.ServerUrl)"
        )
    }

    if($settings.HyperV)
    {
        $otherArgs += "--isolation=hyperv"
    }

    if($settings.CustomSensorsPath)
    {
        $otherArgs += @(
            "--env"
            "PRTG_CUSTOM_SENSORS_PATH=$($settings.CustomSensorsPath)"
        )
    }

    if($settings.CredentialSpec)
    {
        $spec = __GetCredentialSpec

        $otherArgs += @(
            "--security-opt"
            "credentialspec=file://$($spec.Name)"
        )
    }

    if($settings.RestartPolicy -ne "None")
    {
        $map = @{
            "Always" = "always"
            "OnFailure" = "on-failure"
            "UnlessStopped" = "unless-stopped"
        }

        $value = $map.$($settings.RestartPolicy)

        $otherArgs += @(
            "--restart"
            $value
        )
    }

    if($settings.AdditionalArgs)
    {
        $otherArgs += $settings.AdditionalArgs
    }

    return $otherArgs
}

function __GetCredentialSpec
{
    if(!$settings.Name)
    {
        throw "-Name must be specified when -CredentialSpec is specified"
    }

    if(!(__GetModule CredentialSpec))
    {
        Write-Host "Installing CredentialSpec PowerShell Module"

        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        __InstallPackage CredentialSpec
    }

    $name = $settings.Name -replace " ","_"

    $spec = Get-CredentialSpec|where Name -eq "$name.json"

    if(!$spec)
    {
        if(!$settings.CredentialSpecAccount)
        {
            throw "Cannot create CredentialSpec $name as -CredentialSpecAccount was not specified. Please specify -CredentialSpecAccount or create credential spec manually first"
        }

        $spec = New-CredentialSpec -Name $name -AccountName $settings.CredentialSpecAccount
    }

    return $spec
}

function __GetModule($name)
{
    # Mocking Get-Module fails due to conflict with PSEdition parameter with read-only $PSEdition varible,
    # so wrap it in a function we can mock instead

    Get-Module -ListAvailable $name
}

function __InstallPackage($name)
{
    # Mocking cmdldets in PackageManagement is slow, so wrap it in a function

    Install-Package $name -ForceBootstrap -Force | Out-Null
}

    #endregion
    #region Get-PrtgImage

<#
.SYNOPSIS
Lists all images produced by New-PrtgBuild or 'docker build'.

.PARAMETER Tag
A wildcard specifying the tags to filter for.
.PARAMETER Repository
The repository to retrieve images from. By default this value is "prtg".

.EXAMPLE
C:\> Get-PrtgImage 20*
Lists all images whose tag starts with "20" in the "prtg" repository

.EXAMPLE
C:\> Get-PrtgImage -Repository prtgprobe
Lists all PRTG Probe images in the prtgprobe repository
#>
function Get-PrtgImage
{
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        $Tag = "*",

        [Parameter(Mandatory = $false, Position = 1)]
        $Repository = "prtg"
    )

    $imageArgs = @(
        "image"
        "ls"
        "--format"
        "`"{{json . }}`""
    )

    $images = __Exec $imageArgs -Quiet | ConvertFrom-Json | where Repository -eq $Repository

    return $images | where Tag -like $Tag
}

    #endregion
#endregion
#region Install
    #region Server

<#
.SYNOPSIS
Installs PRTG from within a Docker container. This cmdlet supports the build infrastructure and should not be used directly.
#>
function Install-PrtgServer
{
    __DownloadInstaller

    $installer = __GetContextInstaller

    if((__NeedLicenseHelp $installer) -and ![string]::IsNullOrWhiteSpace(($env:PRTG_INSTALLER_URL)))
    {
        $server = $env:PRTG_INSTALLER_URL.substring(0, $env:PRTG_INSTALLER_URL.LastIndexOf("/"))

        $serverFile = "$server/config.dat"

        Write-Host "Downloading config.dat from '$serverFile'"
        Invoke-WebRequest $serverFile -OutFile (Join-Path $script:imageContext "config.dat")
    }

    $installerArgs = @(
        "/verysilent"
        "/adminemail=`"$env:PRTG_EMAIL`""
        "/SUPPRESSMSGBOXES"
        "/log=`"$installerLog`""
        "/licensekey=`"$env:PRTG_LICENSEKEY`""
        "/licensekeyname=`"$env:PRTG_LICENSENAME`""
        "/NoInitialAutoDisco=1"
    )

    $job = __StartLicenseFixer $installer

    __ExecInstall $installer.FullName $installerArgs $installerLog

    if($job)
    {
        $job | Remove-Job -Force
    }

    __InstallFonts
    __DisableNags
    __MoveCustomSensors

    __VerifyBuild $installerLog
    __CleanupBuild
    __RemoveHelp

    Write-Host "Installation completed successfully. Finalizing image..."
}

function __DownloadInstaller
{
    if(![string]::IsNullOrWhiteSpace(($env:PRTG_INSTALLER_URL)))
    {
        Write-Host "`$env:PRTG_INSTALLER_URL. Was specified. Downloading installer from '$env:PRTG_INSTALLER_URL'"

        $file = [Net.WebUtility]::UrlDecode((Split-Path $env:PRTG_INSTALLER_URL -Leaf))

        Invoke-WebRequest $env:PRTG_INSTALLER_URL -OutFile (Join-Path $script:imageContext $file)
    }
}

function __GetContextInstaller($productName)
{
    $getInstallerArgs = @{
        name = "*"
        installerFolder = $script:imageContext
    }

    if($productName)
    {
        $getInstallerArgs.productName = $productName
    }

    $installer = @(__GetInstallers @getInstallerArgs)

    if(!$installer)
    {
        throw "Could not install PRTG: no PRTG installers were copied over during build context. Please ensure a PRTG installer is in the same folder as your Dockerfile, or an -Path was properly specified to New-PrtgBuild"
    }

    if($installer.Count -gt 1)
    {
        $str = ($installer | select -expand name) -join ", "

        throw "Multiple PRTG installers were passed to build context. Please ensure only one of the following installers is in build context and build again: $str"
    }

    return $installer
}

function __StartLicenseFixer($installer)
{
    if(__NeedLicenseHelp $installer)
    {
        # We need to use a 64-bit version of prtglicensecheck.exe under Docker. Aggressively scan our %temp% folder
        # for when PRTG extracts the 32-bit version so we can do a bait and switch before PRTG executes it
        $job = Start-Job {
            while($true)
            {
                $result = gci $env:temp -Recurse -Filter "*prtglicensecheck*"

                if($result)
                {
                    while($true)
                    {
                        if(Test-Path $result.FullName)
                        {
                            Rename-Item $result.FullName "old.exe" -ErrorAction SilentlyContinue
                        }
                        else
                        {
                            break
                        }
                    }

                    while($true)
                    {
                        Move-Item "C:\Installer\config.dat" $result.FullName -ErrorAction SilentlyContinue

                        if(Test-Path $result.FullName)
                        {
                            break
                        }
                    }

                    break
                }
            }
        }

        return $job
    }

    return $null
}

function __ExecInstall($installer, $installerArgs, $logFile)
{
    Write-Host "Executing '$installer $installerArgs'"
    & $installer @installerArgs | Out-Null
    Write-Host "    Installer completed with exit code $LASTEXITCODE"

    if($LASTEXITCODE -ne 0)
    {
        if($LASTEXITCODE -eq -1073741511)
        {
            throw "!!! ERROR: installer did not complete successfully. Please check that your Docker host AND/OR container image are up to date. For more information please see https://github.com/lordmilko/PrtgDocker/wiki/Advanced#windows-updates"
        }

        __FailInstall "!!! ERROR: installer did not complete successfully" $logFile
    }
}

function __InstallFonts
{
    Write-Host "Checking required fonts are installed"

    $fonts = gci $script:imageContext *.ttf

    if(!$fonts)
    {
        throw "Couldn't find any fonts in Docker Context. PrtgDocker should have automatically copied over Arial and Tahoma"
    }

    $fontsFolder = "C:\Windows\Fonts"

    foreach($font in $fonts)
    {
        $destination = Join-Path $fontsFolder $font.Name

        if(!(Test-Path $destination))
        {
            Write-Host "    Installing font '$($font.Name)'"

            $fontName = __GetFontName $font.Name

            Move-Item $font.FullName $destination

            New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts" -Name "$fontName (TypeType)" -Value $font.Name -PropertyType String -Force | Out-Null
        }
        else
        {
            Write-Host "    Font '$($font.Name)' is already installed"
        }
    }
}

function __DisableNags
{
    Write-Host "Disabling UI nags"

    $str = @"

.prtg_growl_important {
    display: none;
}
"@

    $stylesPath = "$script:prtgProgramFiles\webroot\css\styles_custom_v2.css"

    if(Test-Path $stylesPath)
    {
        Add-Content $stylesPath $str
    }
    else
    {
        Set-Content $stylesPath $str
    }

    $path = "HKLM:\SOFTWARE\WOW6432Node\Paessler\PRTG Network Monitor\Server"

    New-ItemProperty -Path $path -Name DoInitialAutoDiscover -Value 0 -PropertyType dword -Force | Out-Null

    New-ItemProperty -Path "$path\Webserver" -Name showsslnagscreen -Value 0 -PropertyType dword -Force | Out-Null
    New-ItemProperty -Path "$path\Webserver" -Name ShowHomeNagScreen -Value 0 -PropertyType dword -Force | Out-Null
}

function __RemoveHelp
{
    Write-Host "    Removing built-in help to improve startup/search performance"

    $helpPath = "$script:prtgProgramFiles\webroot\help"

    if(Test-Path $helpPath)
    {
        Remove-Item $helpPath -Recurse -Force
    }
}

function __MoveCustomSensors
{
    # Create a symlink from the normal Custom Sensors folder to ProgramData so we can manage custom sensors from our config volume.
    # We will recreate this symlink as required when the container starts up in case a -Volume has been specified and C:\ProgramData\Paessler\PRTG Network Monitor has been replaced

    Write-Host "Moving Custom Sensors"

    $newCustomSensors = "$script:prtgProgramData\Custom Sensors"

    # If the container startup script detects the ProgramData Custom Sensors folder is missing, we will recreate it
    Copy-Item $script:originalCustomSensors $script:customSensorsBackup -Recurse

    Move-Item $script:originalCustomSensors $newCustomSensors

    New-Item -ItemType SymbolicLink -Path $script:originalCustomSensors -Target $newCustomSensors | Out-Null
}

function __GetFontName($fileName)
{
    switch($fileName)
    {
        "arial.ttf" { "Arial" }
        "arialbd.ttf" { "Arial Bold" }
        "arialbi.ttf" { "Arial Bold Italic" }
        "ariali.ttf" { "Arial Italic" }
        "ariblk.ttf" { "Arial Black" }
        "tahoma.ttf" { "Tahoma" }
        "tahomabd.ttf" { "Tahoma Bold" }
        default {
            throw "Don't know what the font name of '$fileName' is"
        }
    }
}

function __VerifyBuild($logFile)
{
    $prtgCore = Get-Service $script:coreServiceName -ErrorAction SilentlyContinue

    if(!$prtgCore)
    {
        __FailInstall "!!! ERROR: $script:coreServiceName wasn't even installed" $logFile
    }

    $path = gwmi win32_service -Filter "name = '$script:coreServiceName'"|select -expand pathname

    if($path -notlike "*64 bit\PRTG Server.exe*")
    {
        __FailInstall "!!! ERROR: 32-bit version of PRTG appears to be installed. 64-bit version is required to due issues with Themida when running as 32-bit process under Docker. Please make sure Docker server has at least 6gb RAM. $script:coreServiceName path was $path" $logFile
    }

    if($prtgCore.Status -ne "Running")
    {
        __FailInstall "!!! ERROR: $script:coreServiceName wasn't able to start" $logFile
    }
}

function __FailInstall($msg, $logFile)
{
    if(Test-Path $logFile)
    {
        $msg = "$msg. Please see log above for details"

        gc $logFile

        Write-Host $msg
    }
    else
    {
        Write-Host "$msg. Installer did not generate a log file"
    }

    throw $msg
}

function __CleanupBuild
{
    Write-Host "Finalizing build"

    Get-Service *prtg* | Stop-Service -Force -NoWait

    while($true)
    {
        $process = Get-Process *prtg* -ErrorAction SilentlyContinue

        if($process)
        {
            $str = ($process | select -expand name | foreach { "'$_.exe'" }) -join ", "

            Write-Host "    Terminating $str"

            $process | Stop-Process -Force -ErrorAction SilentlyContinue

            Sleep 1
        }
        else
        {
            break
        }
    }

    $badItems = @(
        "C:\ProgramData\Paessler"
        "$script:prtgProgramFiles\download"
        "$script:prtgProgramFiles\PRTG Installer Archive"
        "$script:prtgProgramFiles\prtg-installer-for-distribution"
        Join-Path $script:imageContext "config.dat"
        (gci $script:imageContext -Filter *.exe).FullName
    )

    $fonts = (gci $script:imageContext -Filter *.ttf).FullName

    if($fonts)
    {
        $badItems += $fonts
    }

    foreach($item in $badItems)
    {
        if(Test-Path $item)
        {
            Write-Host "    Removing '$item'"

            Remove-Item -LiteralPath $item -Recurse -Force
        }
    }

    $remaining = @(gci $script:imageContext)

    if($remaining.Count -gt 2)
    {
        $str = $remaining|select -ExpandProperty name

        throw "Expected C:\Installer to only contain 'PrtgDocker.ps1' and 'log.log', but it still contains $str"
    }
}

    #endregion
    #region Probe

function Install-PrtgProbe
{
    __DownloadInstaller

    $installer = __GetContextInstaller "PRTG Remote Probe"
    $installer = __RenameProbeInstaller $installer

    $installerArgs = @(
        "/verysilent"
        "/SUPPRESSMSGBOXES"
        "/norestart"
        "/log=`"$installerLog`""
    )

    __ExecInstall $installer.FullName $installerArgs $installerLog
    __InstallFonts
    __MoveCustomSensors
    __VerifyProbeBuild $installerLog
    __CleanupProbeBuild

    Write-Host "Installation completed successfully. Finalizing image..."
}

function __RenameProbeInstaller($installer)
{
    $newName = $installer.Name -replace "(PRTG_Remote_Probe_Installer_for_).+?(_.+)","`$1localhost`$2"

    if($newName -ne $installer.Name)
    {
        Write-Host "Renaming installer '$($installer.Name)' to '$newName'"

        Rename-Item -LiteralPath $installer.FullName $newName -PassThru
    }
    else
    {
        $installer
    }
}

function __VerifyProbeBuild($logFile)
{
    $prtgProbe = Get-Service $script:probeServiceName -ErrorAction SilentlyContinue

    if(!$prtgProbe)
    {
        __FailInstall "!!! ERROR: $script:probeServiceName wasn't even installed" $logFile
    }

    if($prtgProbe.Status -ne "Running")
    {
        __FailInstall "!!! ERROR: $script:probeServiceName wasn't able to start" $logFile
    }
}

function __CleanupProbeBuild
{
    __CleanupBuild

    $regPath = "Registry::$script:probeRegistryPath"

    $key = Get-Item $regPath

    $values = $key.GetValueNames()

    $toRemove = @($values | where { $_ -like "*Id" })
    $toRemove += @(
        "Name"
    )

    foreach($item in $toRemove)
    {
        Write-Host "    Removing registry value '$item'"

        Remove-ItemProperty $regPath $item
    }
}

    #endregion
#endregion
#region Wait

<#
.SYNOPSIS
Waits for the PRTG Server process to end within a Docker container. This cmdlet supports the build infrastructure and should not be used directly.

.DESCRIPTION
The Wait-PrtgServer cmdlet waits for the PRTG Server process to end within a Docker container. The container will automatically be terminated if the PRTG Server process is stopped for longer than 10 seconds.
#>
function Wait-PrtgServer
{
    __BeginWaiter $script:coreServiceName

    while($true)
    {
        do
        {
            $service = Get-Service $script:coreServiceName
            sleep 1
        } while($service.Status -ne 'Stopped');

        if(!(__RepairWait $script:coreServiceName))
        {
            break
        }
    }

    __Log "Exiting as $script:coreServiceName status was '$($service.Status)'"
}

function Wait-PrtgProbe
{
    $init = @{
        Server = $env:INIT_PRTG_SERVER
        Name = $env:INIT_PRTG_NAME -replace '_',' '
    }

    if((Test-Path $script:probeConfig) -or (__HasInitSettings $init))
    {
        Get-Process "PRTG Probe" -ErrorAction SilentlyContinue | Stop-Process -Force

        if(Test-Path $script:probeConfig)
        {
            __Log "Importing initial registry config"
            __Reg import $script:probeConfig | Write-Host
        }

        __InitProbeSettings $init

        $lastImportTime = Get-Date

        __Log "Starting $script:probeServiceName"
        Get-Service $script:probeServiceName | Start-Service -ErrorAction SilentlyContinue
    }

    $date = __BeginWaiter $script:probeServiceName

    if($date)
    {
        $lastImportTime = $date
    }

    while($true)
    {
        do
        {
            $service = Get-Service $script:probeServiceName
            sleep 1

            $newConfig = Get-Item $script:probeConfig -ErrorAction SilentlyContinue

            if($newConfig -ne $null -and $newConfig.LastWriteTime -gt $lastImportTime)
            {
                __Log "Probe config has changed. Stopping service to apply changes"

                Get-Service *prtg* | Stop-Service

                __Log "    Importing registry config"
                __Reg import $script:probeConfig | Write-Host

                $lastImportTime = Get-Date

                Get-Service *prtg* | Start-Service

                __Log "    Waiting 10 seconds for $script:probeServiceName to start..."
                sleep 10
                __Log "Service successfully restarted. Continuing to monitor for state changes"
            }

        } while($service.Status -ne 'Stopped');

        if(!(__RepairWait $script:probeServiceName))
        {
            break
        }
    }

    __Log "Backing up registry config"
    __Reg export $script:probeRegistryPath $script:probeConfig /y | Write-Host
}

function __Reg
{
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    $old = $ErrorActionPreference

    $ErrorActionPreference = "SilentlyContinue"

    try
    {
        reg @Arguments
    }
    finally
    {
        $ErrorActionPreference = $old
    }
}

function __HasInitSettings($settings)
{
    foreach($item in $settings.GetEnumerator())
    {
        if(![string]::IsNullOrWhiteSpace($item.Value))
        {
            return $true
        }
    }

    return $false
}

function __InitProbeSettings($settings)
{
    foreach($item in $settings.GetEnumerator())
    {
        __Log "Processing registry property $($item.Name)"

        if($item.Value)
        {
            $currentValue = (Get-ItemProperty "Registry::$script:probeRegistryPath" $item.Name -ErrorAction SilentlyContinue).$($item.Name)

            if($currentValue)
            {
                if($item.Name -eq "Server")
                {
                    if($currentValue -ne "localhost")
                    {
                        __Log "    Using existing value $currentValue"

                        continue
                    }
                }
                else
                {
                    __Log "    Using existing value $currentValue"

                    continue
                }
            }

            __Log "Setting '$script:probeRegistryPath\$($item.Name)' to $($item.Value)"
            Set-ItemProperty "Registry::$script:probeRegistryPath" $item.Name $item.Value
        }
    }
}

function __BeginWaiter($serviceName)
{
    $newCustomSensors = "$script:prtgProgramData\Custom Sensors"

    if($env:PRTG_CUSTOM_SENSORS_PATH)
    {
        __Log "Replacing '$script:originalCustomSensors' with symlink to $env:PRTG_CUSTOM_SENSORS_PATH"

        __DeleteFolder $script:originalCustomSensors

        New-Item -ItemType SymbolicLink -Path $script:originalCustomSensors -Target $env:PRTG_CUSTOM_SENSORS_PATH | Out-Null
    }
    else
    {
        if(!(Test-Path $newCustomSensors))
        {
            if(((Get-Item $script:originalCustomSensors).Target -ne $newCustomSensors))
            {
                __DeleteFolder $script:originalCustomSensors

                New-Item -ItemType SymbolicLink -Path $script:originalCustomSensors -Target $newCustomSensors | Out-Null
            }

            __Log "Restoring missing Custom Sensors"
            Copy-Item $script:customSensorsBackup $newCustomSensors -Recurse -Force
        }
    }    

    __Log "Waiting 10 seconds for $serviceName to start..."
    sleep 10

    if(!(Test-Path $script:probeConfig))
    {
        __Log "Exporting initial registry config"
        __Reg export $script:probeRegistryPath $script:probeConfig /y | Write-Host

        Get-Date
    }

    __Log "$serviceName should now be started! Container will automatically close when service is stopped"
}

function __DeleteFolder($path)
{
    # Remove-Item attempts to delete the target of the symlink rather than the symbolic link itself.
    # Use Directory.Delete instead, and wrap it in a function so that we can mock it as required

    [System.IO.Directory]::Delete($path, $true)
}

function __RepairWait($serviceName)
{
    __Log "Waiting for 10 seconds to see if service restarted..."
    sleep 10

    $service = Get-Service $serviceName

    if($service.Status -eq "Stopped")
    {
        return $false
    }
    else
    {
        __Log "Resuming as $serviceName status changed to '$($service.Status)'"
        return $true
    }
}

function __Log($msg)
{
    Write-Host "$(Get-Date): $msg"
}

#endregion
#region Common

function __Exec
{
    param(
        $Commands,

        [switch]$Quiet
    )

    if(!$Quiet)
    {
        Write-Host "Executing 'docker $Commands'" -ForegroundColor Yellow
    }

    __ExecInternal $Commands
}

function __ExecInternal($commands)
{
    docker @commands
}

#endregion
#region Server

Add-Type -Language CSharp @"
// MIT License - Copyright (c) 2016 Can Güney Aksakalli
// https://aksakalli.github.io/2014/02/24/simple-http-server-with-csparp.html

using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Net.Sockets;
using System.Net;
using System.IO;
using System.Threading;
using System.Diagnostics;

public class SimpleHTTPServer
{
    private static IDictionary<string, string> _mimeTypeMappings = new Dictionary<string, string>(StringComparer.InvariantCultureIgnoreCase) {
        {".exe", "application/octet-stream"}
    };
    private Thread _serverThread;
    private string _rootDirectory;
    private HttpListener _listener;

    public int Port { get; private set; }

    public SimpleHTTPServer(string path)
    {
        //get an empty port
        TcpListener l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        Port = ((IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();

        _rootDirectory = path;
        _serverThread = new Thread(this.Listen);
        _serverThread.Start();
    }

    public void Stop()
    {
        _serverThread.Abort();
        _listener.Stop();
    }

    private void Listen()
    {
        _listener = new HttpListener();
        _listener.Prefixes.Add("http://*:" + Port.ToString() + "/");
        _listener.Start();

        while (true)
        {
            try
            {
                HttpListenerContext context = _listener.GetContext();
                Process(context);
            }
            catch (Exception)
            {
            }
        }
    }

    private void Process(HttpListenerContext context)
    {
        string fileName = WebUtility.UrlDecode(context.Request.Url.AbsolutePath);
        fileName = fileName.Substring(1);
        fileName = Path.Combine(_rootDirectory, fileName);

        Console.WriteLine("Serving request for file '" + fileName + "'");

        if (File.Exists(fileName))
        {
            try
            {
                Stream input = new FileStream(fileName, FileMode.Open);

                //Adding permanent http response headers
                string mime;
                context.Response.ContentType = _mimeTypeMappings.TryGetValue(Path.GetExtension(fileName), out mime) ? mime : "application/octet-stream";
                context.Response.ContentLength64 = input.Length;
                context.Response.AddHeader("Date", DateTime.Now.ToString("r"));
                context.Response.AddHeader("Last-Modified", System.IO.File.GetLastWriteTime(fileName).ToString("r"));

                byte[] buffer = new byte[1024 * 16];
                int nbytes;
                while ((nbytes = input.Read(buffer, 0, buffer.Length)) > 0)
                    context.Response.OutputStream.Write(buffer, 0, nbytes);
                input.Close();

                context.Response.StatusCode = (int)HttpStatusCode.OK;
                context.Response.OutputStream.Flush();
            }
            catch (Exception)
            {
                context.Response.StatusCode = (int)HttpStatusCode.InternalServerError;
            }
        }
        else
        {
            context.Response.StatusCode = (int)HttpStatusCode.NotFound;
        }

        context.Response.OutputStream.Close();
    }
}
"@

#endregion

switch($PSCmdlet.ParameterSetName)
{
    "Build" {
        # Do nothing, the script is simply being dot sourced
    }

    "Install" {
        Install-PrtgServer
    }

    "InstallProbe" {
        Install-PrtgProbe
    }

    "Wait" {
        Wait-PrtgServer
    }

    "WaitProbe" {
        Wait-PrtgProbe
    }

    default {
        throw "Don't know how to handle parameter set '$_'"
    }
}