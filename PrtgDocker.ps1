[CmdletBinding(DefaultParameterSetName="Build")]
param(
    [Parameter(Mandatory=$false, ParameterSetName="Build")]
    [switch]$Build,

    [Parameter(Mandatory=$true, ParameterSetName ="Install")]
    [switch]$Install,

    [Parameter(Mandatory=$true, ParameterSetName ="Wait")]
    [switch]$Wait
)

$ErrorActionPreference = "Stop"
$script:coreServiceName = "PRTGCoreService"
$script:dockerTemp = Join-Path ([IO.Path]::GetTempPath()) "dockerTemp"
$script:dockerTempServer = Join-Path ([IO.Path]::GetTempPath()) "dockerTempServer"
$script:imageContext = "C:\Installer"
$script:installerLog = Join-Path $script:imageContext "log.log"

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
#>
function New-PrtgBuild
{
    [CmdletBinding()]
    param(
        [ValidateNotNullorEmpty()]
        [Parameter(Mandatory=$false, Position = 0)]
        [string]$Name = "*",

        [ValidateNotNullorEmpty()]
        [Parameter(Mandatory=$false, Position = 1)]
        [string]$Path = $PSScriptRoot,

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [switch]$HyperV,

        [ValidateNotNullorEmpty()]
        [Parameter(Mandatory = $false)]
        [string]$BaseImage = "ltsc2019",

        [ValidateNotNullorEmpty()]
        [Parameter(Mandatory = $false)]
        [string]$PrtgEmail,

        [ValidateNotNullorEmpty()]
        [Parameter(Mandatory = $false)]
        [string]$LicenseName,

        [ValidateNotNullorEmpty()]
        [Parameter(Mandatory = $false)]
        [string]$LicenseKey,

        [Parameter(Mandatory = $false)]
        [PSCredential]$Credential,

        [ValidateNotNullorEmpty()]
        [Parameter(Mandatory = $false)]
        [string]$Repository = "prtg",

        [Parameter(Mandatory = $false)]
        [switch]$Server,

        [Parameter(Mandatory = $false)]
        [switch]$SkipExisting
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
    }

    if($Credential)
    {
        $global:dockerCreds = $Credential
    }

    __VerifyRepo
    __QualifyBaseImage $settings
    $installers = __GetInstallers $Name $Path
    __GetDockerHost $settings
    
    $fileServer = $null

    try
    {
        $settings.FileServer = __PrepareDockerTemp $Server

        $split = $settings.BaseImage -split ":"

        if(!(Get-PrtgImage -Repository $split[0] -Tag $split[1]))
        {
            __Exec @("pull",$settings.BaseImage)
        }

        foreach($installer in $installers)
        {
            __ExecuteBuild $installer $settings
        }
    }
    finally
    {
        if($fileServer -ne $null)
        {
            $fileServer.Stop()
        }
    }

    Remove-Item $script:dockerTemp -Recurse -Force

    if(Test-Path $script:dockerTempServer)
    {
        Remove-Item $script:dockerTempServer -Recurse -Force
    }
}

function __VerifyRepo
{
    $required = @(
        "config.dat"
        "Dockerfile"
        "PrtgDocker.ps1"
    )

    foreach($file in $required)
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

function __GetInstallers($name, $installerFolder)
{
    Write-Host "Enumerating installers in '$installerFolder'"

    if(!(Test-Path $installerFolder))
    {
        throw "Installer Path '$installerFolder' is not a valid folder"
    }

    $exe = gci $installerFolder -Filter "*.exe"

    if(!$exe)
    {
        throw "No executable files exist in '$installerFolder'. Please place a PRTG installer in this folder and try again, or specify an alternate -Path"
    }

    $installers = $exe|where { $_.VersionInfo.ProductName.Trim() -eq "PRTG Network Monitor" }

    if(!$installers)
    {
        throw "Couldn't find any PRTG Network Monitor installers under the specified folder. Please place a valid PRTG installer in this folder and try again, or specify an alternate -Path"
    }

    $candidates = $installers|where Name -Like $name

    if(!$candidates)
    {
        throw "Installer filter '$name' did not match any candidates"
    }

    $candidates | foreach { $_ | Add-Member Version ([Version]$_.VersionInfo.FileVersion) }
    $candidates = $candidates | sort version

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

function __PrepareDockerTemp($server)
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
        "Dockerfile"     # Dockerfile is always required
        "PrtgDocker.ps1" # PrtgDocker.ps1 is needed after the build, and is also our single "guaranteed" file that exists in our COPY directive
    )

    foreach($file in $contextFiles)
    {
        $source = Join-Path $PSScriptRoot $file
        $destination = Join-Path $script:dockerTemp $file

        Copy-Item $source $destination -Force
    }

    # Server 2019 doesn't have fonts, so include these as well
    $fonts = gci C:\Windows\Fonts | where {$_.Name -like "*arial*" -or $_.Name -like "*tahoma*" }

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

    $installerSettings = @{
        PrtgEmail = "PRTG_EMAIL"
        LicenseName = "PRTG_LICENSENAME"
        LicenseKey = "PRTG_LICENSEKEY"
    }

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

    $stopwatch =  [System.Diagnostics.Stopwatch]::StartNew()

    __Exec $buildArgs

    $stopwatch.Stop()

    $duration = [math]::round($stopwatch.Elapsed.TotalMinutes, 2)

    if($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0)
    {
        throw "docker build did not complete successfully. Most failures relate to subtle timing issues during build; please try running build again"
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
#>
function New-PrtgContainer
{
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Tag = "*",

        [ValidateNotNullOrEmpty()]
        [Parameter(Mandatory = $false, Position = 1)]
        [string]$Name,

        [ValidateNotNullOrEmpty()]
        [Parameter(Mandatory = $false, Position = 2)]
        [string[]]$Port = "8080:80",

        [ValidateNotNullOrEmpty()]
        [Parameter(Mandatory = $false)]
        [string[]]$Repository = "prtg",

        [Parameter(Mandatory = $false)]
        [switch]$Interactive,

        [Parameter(Mandatory = $false)]
        [switch]$Volume,

        [Parameter(Mandatory = $false)]
        [switch]$HyperV
    )

    $settings = [PSCustomObject]@{
        Name = $Name
        Port = $Port
        Repository = $Repository
        Interactive = $Interactive
        Volume = $Volume
        HyperV = $HyperV
        Version = $null
    }

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

        throw "Please specify one of the following candidates: $str"
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

    if($settings.HyperV)
    {
        $runArgs += "--isolation=hyperv"
    }

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
            $settings.Name
        )
    }

    foreach($port in $settings.Port)
    {
        $otherArgs += @(
            "-p"
            $port
        )
    }

    if($settings.Volume)
    {
        $otherArgs += @(
            "-v"
            "prtg$($settings.Version -replace '\.','_'):`"C:\ProgramData\Paessler\PRTG Network Monitor`""
        )
    }

    return $otherArgs
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

<#
.SYNOPSIS
Installs PRTG from within a Docker container. This cmdlet supports the build infrastructure and should not be used directly.
#>
function Install-PrtgServer
{
    if(![string]::IsNullOrWhiteSpace(($env:PRTG_INSTALLER_URL)))
    {
        Write-Host "`$env:PRTG_INSTALLER_URL. Was specified. Downloading installer from '$env:PRTG_INSTALLER_URL'"

        $file = [Net.WebUtility]::UrlDecode((Split-Path $env:PRTG_INSTALLER_URL -Leaf))

        Invoke-WebRequest $env:PRTG_INSTALLER_URL -OutFile (Join-Path $script:imageContext $file)
    }

    $installer = @(__GetInstallers "*" $script:imageContext)

    if((__NeedLicenseHelp $installer) -and ![string]::IsNullOrWhiteSpace(($env:PRTG_INSTALLER_URL)))
    {
        $server = $env:PRTG_INSTALLER_URL.substring(0, $env:PRTG_INSTALLER_URL.LastIndexOf("/"))

        $serverFile = "$server/config.dat"

        Write-Host "Downloading config.dat from '$serverFile'"
        Invoke-WebRequest $serverFile -OutFile (Join-Path $script:imageContext "config.dat")
    }

    if(!$installer)
    {
        throw "Could not install PRTG: no PRTG installers were copied over during build context. Please ensure a PRTG installer is in the same folder as your Dockerfile, or an -Path was properly specified to New-PrtgBuild"
    }

    if($installer.Count -gt 1)
    {
        $str = ($installer | select -expand name) -join ", "

        throw "Multiple PRTG installers were passed to build context. Please ensure only one of the following installers is in build context and build again: $str"
    }
    
    $installerArgs = @(
        "/verysilent"
        "/adminemail=`"$env:PRTG_EMAIL`""
        "/SUPPRESSMSGBOXES"
        "/log=`"$installerLog`""
        "/licensekey=`"$env:PRTG_LICENSEKEY`""
        "/licensekeyname=`"$env:PRTG_LICENSENAME`""
    )

    $job = __StartLicenseFixer $installer

    __ExecInstall $installer.FullName $installerArgs

    if($job)
    {
        $job | Remove-Job -Force
    }

    __InstallFonts

    __VerifyBuild $installerLog
    __CleanupBuild

    Write-Host "Installation completed successfully. Finalizing image..."
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

function __ExecInstall($installer, $installerArgs)
{
    Write-Host "Executing '$installer $installerArgs'"
    & $installer @installerArgs | Out-Null
    Write-Host "    Installer completed with exit code $LASTEXITCODE"
}

function __InstallFonts
{
    Write-Host "Checking required fonts are installed"

    $fonts = gci $script:imageContext *.ttf
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
        __FailInstall "!!! ERROR: 32-bit version of PRTG appears to be installed. 64-bit version is required to due issues with Themida when running as 32-bit process under Docker. Please make sure Docker server has at least 6gb RAM $script:coreServiceName path was '$path'" $logFile
    }

    if($prtgCore.Status -ne "Running")
    {
        __FailInstall "!!! ERROR: $script:coreServiceName wasn't able to start" $logFile
    }
}

function __FailInstall($msg, $logFile)
{
    $msg = "$msg. Please see log above for details"

    gc $logFile

    Write-Host $msg

    throw $msg
}

function __CleanupBuild($installer)
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
        "C:\Program Files (x86)\PRTG Network Monitor\download"
        "C:\Program Files (x86)\PRTG Network Monitor\PRTG Installer Archive"
        "C:\Program Files (x86)\PRTG Network Monitor\prtg-installer-for-distribution"
        Join-Path $script:imageContext "config.dat"
    )

    $badItems += (gci $script:imageContext -Filter *.exe).FullName

    foreach($item in $badItems)
    {
        if(Test-Path $item)
        {
            Write-Host "    Removing '$item'"

            Remove-Item $item -Recurse -Force
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
#region Wait

<#
.SYNOPSIS
Waits for the PRTG Server process to end within a Docker container. This cmdlet supports the build infrastructure and should not be used directly.

.DESCRIPTION
The Wait-PrtgServer cmdlet waits for the PRTG Server process to end within a Docker container. The container will automatically be terminated if the PRTG Server process is stopped for longer than 10 seconds.
#>
function Wait-PrtgServer
{
    __Log "Waiting 10 seconds for $script:coreServiceName to start..."
    sleep 10

    __Log "$script:coreServiceName should now be started! Container will automatically close when service is stopped"

    while($true)
    {
        do
        {
            $service = Get-Service $script:coreServiceName
            sleep 1
        } while($service.Status -ne 'Stopped');

        __Log "Waiting for 10 seconds to see if service restarted..."
        sleep 10

        $service = Get-Service $script:coreServiceName

        if($service.Status -eq "Stopped")
        {
            break
        }
        else
        {
            __Log "Resuming as $script:coreServiceName status changed to '$($service.Status)'"
        }
    }

    __Log "Exiting as $script:coreServiceName status was '$($service.Status)"
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

    "Wait" {
        Wait-PrtgServer
    }

    default {
        throw "Don't know how to handle parameter set '$_'"
    }
}