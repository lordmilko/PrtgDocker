. $PSScriptRoot\..\PrtgDocker.ps1

class MockKey
{
    [string[]]GetValueNames()
    {
        return @(
            "Id"
            "GId"
            "Name"
        )
    }
}

Describe "Install-PrtgProbe" {

    Mock "Test-Path" {
        return $true
    } -ParameterFilter { $Path -eq "C:\Installer" -or $Path -like "C:\ProgramData*" }

    Mock "__ExecInstall" {
        $installer | Should Be "C:\Installer\notepad.exe" | Out-Null
        $installerArgs -join " " | Should Be "/verysilent /SUPPRESSMSGBOXES /norestart /log=`"C:\Installer\log.log`"" | Out-Null
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
                Name = "PRTGProbeService"
                Status = "Running"
            }
        }

        Mock "Get-WmiObject" {
            [PSCustomObject]@{
                PathName = "C:\Program Files (x86)\PRTG Network Monitor\PRTG Probe.exe"
            }
        }
    }

    function MockFonts
    {
        Mock "Get-ChildItem" {

            [PSCustomObject]@{
                FullName = "C:\Windows\arial.ttf"
                Name = "arial.ttf"
            }
        } -ParameterFilter { $Filter -eq "*.ttf" }
    }

    function MockInstaller($version)
    {
        $global:versionVar = $version

        MockFonts

        Mock "Get-ChildItem" {

            [PSCustomObject]@{
                FullName = "C:\Installer\notepad.exe"
                Name = "notepad.exe"
                VersionInfo = [PSCustomObject]@{
                    ProductName = "PRTG Remote Probe"
                    FileVersion = $global:versionVar
                }
            }
        } -ParameterFilter { $Filter -ne "*.ttf" }
    }

    function MockRemove($script:includeConfig = $false)
    {
        Mock "Remove-Item" {
            $allowed = @(
                "C:\ProgramData\Paessler"
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

        Mock "Get-Item" {

            $Path | Should Be "Registry::HKLM\SOFTWARE\WOW6432Node\Paessler\PRTG Network Monitor\Probe" | Out-Null

            [MockKey]::new()
        }

        Mock "Remove-ItemProperty" {

            $allowed = @(
                "Id"
                "GId"
                "Name"
            )

            if($Name -notin $allowed)
            {
                throw "Remove-ItemProperty was called with '$Name'"
            }
        } -Verifiable
    }

    It "installs a PRTG Probe" {

        MockInstaller "17.1.2.3"
        MockService
        MockRemove

        Install-PrtgProbe

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

        MockInstaller "17.1.2.3"
        MockService
        MockRemove

        try
        {
            $env:PRTG_INSTALLER_URL = "http://192.168.1.1:1234/notepad+2006.exe"

            Install-PrtgProbe
        }
        finally
        {
            $env:PRTG_INSTALLER_URL = $null
        }

        Assert-VerifiableMocks
    }

    It "changes the server address in the executable to localhost" {

        MockFonts

        Mock "Get-ChildItem" {

            [PSCustomObject]@{
                FullName = "C:\Installer\PRTG_Remote_Probe_Installer_for_prtg.example.com_12345678.exe"
                Name = "PRTG_Remote_Probe_Installer_for_prtg.example.com_12345678.exe"
                VersionInfo = [PSCustomObject]@{
                    ProductName = "PRTG Remote Probe"
                    FileVersion = "14.1.2.3"
                }
            }
        } -ParameterFilter { $Filter -ne "*.ttf" }

        MockInstaller "17.1.2.3"
        MockService
        MockRemove

        Install-PrtgProbe

        Assert-VerifiableMocks
    }
}