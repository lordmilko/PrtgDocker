. $PSScriptRoot\..\PrtgDocker.ps1

Describe "Install-PrtgServer" {

    $env:PRTG_EMAIL = "prtg@example.com"
    $env:PRTG_LICENSENAME = "prtguser"
    $env:PRTG_LICENSEKEY = "topSecret"
    $env:BASE_IMAGE = "baseImage"

    Mock "Test-Path" {
        return $true
    } -ParameterFilter { $Path -eq "C:\Installer" -or $Path -like "C:\ProgramData*" -or $Path -like "C:\Program Files (x86)\*" }

    Mock "__ExecInstall" {
        $installer | Should Be "C:\Installer\notepad.exe" | Out-Null
        $installerArgs -join " " | Should Be "/verysilent /adminemail=`"prtg@example.com`" /SUPPRESSMSGBOXES /log=`"C:\Installer\log.log`" /licensekey=`"topSecret`" /licensekeyname=`"prtguser`" /NoInitialAutoDisco=1" | Out-Null
    } -Verifiable

    Mock "Get-Content" {}
    Mock "Get-Process" {}
    Mock "Stop-Service" {}
    Mock "Add-Content" {}
    Mock "New-Item" {}
    Mock "Move-Item" {}
    Mock "Copy-Item" {}

    function MockService
    {
        Mock "Get-Service" {
            [PSCustomObject]@{
                Name = "PRTGCoreService"
                Status = "Running"
            }
        }

        Mock "Get-WmiObject" {
            [PSCustomObject]@{
                PathName = "C:\Program Files (x86)\PRTG Network Monitor\64 bit\PRTG Server.exe"
            }
        }
    }

    function MockInstaller($version)
    {
        $global:versionVar = $version

        Mock "Get-ChildItem" {

            [PSCustomObject]@{
                FullName = "C:\Windows\arial.ttf"
                Name = "arial.ttf"
            }
        } -ParameterFilter { $Filter -eq "*.ttf" }

        Mock "Get-ChildItem" {

            [PSCustomObject]@{
                FullName = "C:\Installer\notepad.exe"
                Name = "notepad.exe"
                VersionInfo = [PSCustomObject]@{
                    ProductName = "PRTG Network Monitor"
                    FileVersion = $global:versionVar
                }
            }
        } -ParameterFilter { $Filter -ne "*.ttf" }
    }

    function MockCopy($script:includeConfig = $false)
    {
        Mock "Test-Path" {
            return $script:includeConfig
        } -ParameterFilter { $Path -like "*config.dat" }
    }

    function MockRemove($script:includeConfig = $false)
    {
        Mock "Remove-Item" {
            $allowed = @(
                "C:\ProgramData\Paessler"
                "C:\Program Files (x86)\PRTG Network Monitor\download"
                "C:\Program Files (x86)\PRTG Network Monitor\PRTG Installer Archive"
                "C:\Program Files (x86)\PRTG Network Monitor\prtg-installer-for-distribution"
                "C:\Program Files (x86)\PRTG Network Monitor\webroot\help"
            )

            if($script:includeConfig)
            {
                $allowed += "C:\Installer\config.dat"
            }

            if($Path -in $allowed -or $LiteralPath -in $allowed)
            {
                return
            }

            if(!$Path)
            {
                $Path = $LiteralPath
            }

            throw "Remove-Item was called with '$Path'"
        } -Verifiable
    }

    It "installs a legacy version" {

        MockInstaller "14.1.2.3"
        MockService
        MockCopy
        MockRemove

        Install-PrtgServer

        Assert-VerifiableMocks
    }

    It "installs a 32-bit Themida version" {

        MockInstaller "17.1.2.3"
        MockService
        MockCopy $true
        MockRemove $true

        Install-PrtgServer

        Assert-VerifiableMocks
    }

    It "installs with a web server" {

        Mock "Invoke-WebRequest" {

            if($Uri -eq "http://192.168.1.1:1234/notepad+2006.exe" -and $OutFile -eq "C:\Installer\notepad 2006.exe")
            {
                return
            }

            throw "Uri was '$Uri', OutFile was '$OutFile'"
        } -Verifiable

        MockInstaller "14.1.2.3"
        MockService
        MockCopy
        MockRemove

        try
        {
            $env:PRTG_INSTALLER_URL = "http://192.168.1.1:1234/notepad+2006.exe"

            Install-PrtgServer
        }
        finally
        {
            $env:PRTG_INSTALLER_URL = $null
        }

        Assert-VerifiableMocks
    }

    It "installs with a web server and a 32-bit Themida version" {
        Mock "Invoke-WebRequest" {

            if($Uri -eq "http://192.168.1.1:1234/notepad+2006.exe" -and $OutFile -eq "C:\Installer\notepad 2006.exe")
            {
                return
            }

            if($Uri -eq "http://192.168.1.1:1234/config.dat" -and $OutFile -eq "C:\Installer\config.dat")
            {
                return
            }

            throw "Uri was '$Uri', OutFile was '$OutFile'"
        } -Verifiable

        MockInstaller "17.1.2.3"
        MockService
        MockCopy
        MockRemove

        try
        {
            $env:PRTG_INSTALLER_URL = "http://192.168.1.1:1234/notepad+2006.exe"

            Install-PrtgServer
        }
        finally
        {
            $env:PRTG_INSTALLER_URL = $null
        }

        Assert-VerifiableMocks
    }

    It "throws when no installers in build context" {
        Mock "Get-ChildItem" {} -ParameterFilter { $Filter -ne "*.ttf" }

        { Install-PrtgServer } | Should Throw "No executable files exist in 'C:\Installer'"
    }

    It "throws when multiple installers in build context" {
        Mock "Get-ChildItem" {
            [PSCustomObject]@{
                FullName = "C:\Installer\notepad.exe"
                Name = "notepad1.exe"
                VersionInfo = [PSCustomObject]@{
                    ProductName = "PRTG Network Monitor"
                    FileVersion = "14.1.2.3"
                }
            }

            [PSCustomObject]@{
                FullName = "C:\Installer\notepad.exe"
                Name = "notepad2.exe"
                VersionInfo = [PSCustomObject]@{
                    ProductName = "PRTG Network Monitor"
                    FileVersion = "17.1.2.3"
                }
            }
        } -ParameterFilter { $Filter -ne "*.ttf" }

        { Install-PrtgServer } | Should Throw "Multiple PRTG installers were passed to build context"
    }

    It "throws when PRTGCoreService was not installed" {
        MockInstaller "14.1.2.3"
        Mock "Get-Service" {}
        Mock "Test-Path" { $true} -ParameterFilter { $Path -eq "C:\Installer\log.log" }

        { Install-PrtgServer } | Should Throw "PRTGCoreService wasn't even installed. Please see log above for details"
    }

    It "throws when PRTGCoreService didn't start" {
        MockInstaller "14.1.2.3"
        Mock "Get-Service" {
            [PSCustomObject]@{
                Name = "PRTGCoreService"
                Status = "Stopped"
            }
        }
        Mock "Test-Path" { $true} -ParameterFilter { $Path -eq "C:\Installer\log.log" }

        { Install-PrtgServer } | Should Throw "PRTGCoreService wasn't able to start. Please see log above for details"
    }

    It "throws when 32-bit version of PRTGCoreService was installed" {
        MockInstaller "14.1.2.3"
        Mock "Get-Service" {
            [PSCustomObject]@{
                Name = "PRTGCoreService"
                Status = "Running"
            }
        }

        Mock "Get-WmiObject" {
            [PSCustomObject]@{
                PathName = "C:\Program Files (x86)\PRTG Network Monitor\PRTG Server.exe"
            }
        }

        { Install-PrtgServer } | Should Throw "32-bit version of PRTG appears to be installed"
    }

    $env:PRTG_EMAIL = $null
    $env:PRTG_LICENSENAME = $null
    $env:PRTG_LICENSEKEY = $null
    $env:BASE_IMAGE = $null
}