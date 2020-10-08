. $PSScriptRoot\..\PrtgDocker.ps1

Describe "Wait-PrtgProbe" {

    Mock "Start-Sleep" {}

    It "recreates custom sensors in a volume" {

        Mock "__Reg" {}

        Mock "Test-Path" {

            $allowed = @(
                "C:\ProgramData\Paessler\PRTG Network Monitor\Custom Sensors"
                "C:\ProgramData\Paessler\PRTG Network Monitor\config.reg"
            )

            if($Path -notin $allowed)
            {
                throw "Didn't expect $Path"
            }

            return $false
        }

        Mock "Get-Item" {

            if($Path -eq "C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors")
            {
                return [PSCustomObject]@{
                    Target = "C:\ProgramData\Paessler\PRTG Network Monitor\Custom Sensors"
                }
            }

            if($Path -eq "C:\ProgramData\Paessler\PRTG Network Monitor\config.reg")
            {
                return $null
            }

            throw "Didn't expect $Path"
        }

        Mock "Get-Service" {

            [PSCustomObject]@{
                Status = "Stopped"
            }
        } -Verifiable

        Mock "Copy-Item" {

            $Path | Should Be "C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors (Backup)"
            $Destination | Should Be "C:\ProgramData\Paessler\PRTG Network Monitor\Custom Sensors"
        }

        Wait-PrtgProbe

        Assert-VerifiableMocks
    }

    It "utilizes an external custom sensors path" {

        Mock "__DeleteFolder" {} -Verifiable

        Mock "New-Item" {

            $ItemType | Should Be "SymbolicLink"
            $Path | Should Be "C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors"
            $Value | Should Be "\\fs-1\CustomSensors"

            
        } -Verifiable

        try
        {
            $env:PRTG_CUSTOM_SENSORS_PATH = "\\fs-1\CustomSensors"

            Wait-PrtgProbe
        }
        finally
        {
            $env:PRTG_CUSTOM_SENSORS_PATH = $null
        }

        Assert-VerifiableMocks
    }

    It "waits for the service to stop, waits to see if it restarts, and terminates if it doesn't" {

        Mock "__BeginWaiter" {}
        Mock "__Reg" {}

        $script:count = 0

        Mock "Get-Service" {

            $script:count++

            if($script:count -ge 3)
            {
                [PSCustomObject]@{
                    Status = "Stopped"
                }
            }
        } -Verifiable

        Wait-PrtgProbe

        Assert-VerifiableMocks

        $script:count | Should Be 4
    }

    It "waits for the service to stop, waits to see if it restarts, and resumes if it does" {

        Mock "__BeginWaiter" {}
        Mock "__Reg" {}

        $script:count = 0

        Mock "Get-Service" {

            $script:count++

            if($script:count -eq 3 -or $script:count -ge 7)
            {
                [PSCustomObject]@{
                    Status = "Stopped"
                }
            }
            elseif($script:count -eq 4)
            {
                [PSCustomObject]@{
                    Status = "Running"
                }
            }
        } -Verifiable

        Wait-PrtgProbe

        Assert-VerifiableMocks

        $script:count | Should Be 8
    }

    It "applies init settings" {

        $script:count = 0

        Mock "Get-Service" {

            $script:count++

            if($script:count -ge 3)
            {
                [PSCustomObject]@{
                    Status = "Stopped"
                }
            }
        } -Verifiable

        $regPath = "Registry::HKLM\SOFTWARE\WOW6432Node\Paessler\PRTG Network Monitor\Probe"

        Mock "Get-ItemProperty" {} -ParameterFilter {
            $Path -eq $regPath -and $Name -eq "Server"
        } -Verifiable

        Mock "Get-ItemProperty" {} -ParameterFilter {
            $Path -eq $regPath -and $Name -eq "Name"
        } -Verifiable

        Mock "Set-ItemProperty" {} -ParameterFilter {
            $Path -eq $regPath -and $Name -eq "Server" -and $Value -eq "prtg.example.com"
        } -Verifiable

        Mock "Set-ItemProperty" {} -ParameterFilter {
            $Path -eq $regPath -and $Name -eq "Name" -and $Value -eq "New York"
        } -Verifiable

        try
        {
            $env:INIT_PRTG_SERVER = "prtg.example.com"
            $env:INIT_PRTG_NAME = "New_York"

            Wait-PrtgProbe
        }
        finally
        {
            $env:INIT_PRTG_SERVER = $null
            $env:INIT_PRTG_NAME = $null
        }

        Assert-VerifiableMocks

        $script:count | Should Be 4
    }

    It "skips importing an init setting when a value already exists" {
        $script:count = 0

        Mock "Get-Service" {

            $script:count++

            if($script:count -ge 3)
            {
                [PSCustomObject]@{
                    Status = "Stopped"
                }
            }
        } -Verifiable

        $regPath = "Registry::HKLM\SOFTWARE\WOW6432Node\Paessler\PRTG Network Monitor\Probe"

        Mock "Get-ItemProperty" {
            [PSCustomObject]@{
                Server = "prtg.example.com"
            }
        } -ParameterFilter {
            $Path -eq $regPath -and $Name -eq "Server"
        } -Verifiable

        Mock "Get-ItemProperty" {} -ParameterFilter {
            $Path -eq $regPath -and $Name -eq "Name"
        } -Verifiable

        Mock "Set-ItemProperty" {
            throw "Server should not have been updated"
        } -ParameterFilter {
            $Path -eq $regPath -and $Name -eq "Server" -and $Value -eq "prtg.example.com"
        }

        Mock "Set-ItemProperty" {} -ParameterFilter {
            $Path -eq $regPath -and $Name -eq "Name" -and $Value -eq "New York"
        } -Verifiable

        try
        {
            $env:INIT_PRTG_SERVER = "prtg.example.com"
            $env:INIT_PRTG_NAME = "New_York"

            Wait-PrtgProbe
        }
        finally
        {
            $env:INIT_PRTG_SERVER = $null
            $env:INIT_PRTG_NAME = $null
        }

        Assert-VerifiableMocks

        $script:count | Should Be 4
    }

    It "overwrites the initial server if its value is localhost" {
        $script:count = 0

        Mock "Get-Service" {

            $script:count++

            if($script:count -ge 3)
            {
                [PSCustomObject]@{
                    Status = "Stopped"
                }
            }
        } -Verifiable

        $regPath = "Registry::HKLM\SOFTWARE\WOW6432Node\Paessler\PRTG Network Monitor\Probe"

        Mock "Get-ItemProperty" {
            [PSCustomObject]@{
                Server = "localhost"
            }
        } -ParameterFilter {
            $Path -eq $regPath -and $Name -eq "Server"
        } -Verifiable

        Mock "Get-ItemProperty" {} -ParameterFilter {
            $Path -eq $regPath -and $Name -eq "Name"
        } -Verifiable

        Mock "Set-ItemProperty" {} -ParameterFilter {
            $Path -eq $regPath -and $Name -eq "Server" -and $Value -eq "prtg.example.com"
        } -Verifiable

        Mock "Set-ItemProperty" {} -ParameterFilter {
            $Path -eq $regPath -and $Name -eq "Name" -and $Value -eq "New York"
        } -Verifiable

        try
        {
            $env:INIT_PRTG_SERVER = "prtg.example.com"
            $env:INIT_PRTG_NAME = "New_York"

            Wait-PrtgProbe
        }
        finally
        {
            $env:INIT_PRTG_SERVER = $null
            $env:INIT_PRTG_NAME = $null
        }

        Assert-VerifiableMocks

        $script:count | Should Be 4
    }

    It "imports the initial registry config if one exists" {
        
        Mock "Test-Path" {
            if($Path -eq "C:\ProgramData\Paessler\PRTG Network Monitor\config.reg")
            {
                return $true
            }

            return $false
        }

        Mock "Get-Process" {
            $Name | Should Be "PRTG Probe" | Out-Null
        } -Verifiable

        $script:count = 0

        Mock "Get-Service" {

            $script:count++

            if($script:count -ge 3)
            {
                [PSCustomObject]@{
                    Status = "Stopped"
                }
            }
        } -Verifiable

        Mock "__Reg" {

            $allowed = @(
                "import C:\ProgramData\Paessler\PRTG Network Monitor\config.reg"
                "export HKLM\SOFTWARE\WOW6432Node\Paessler\PRTG Network Monitor\Probe C:\ProgramData\Paessler\PRTG Network Monitor\config.reg /y"
            )

            $str = $Arguments -join " "

            if($str -notin $allowed)
            {
                throw "Didn't expect $str"
            }
        } -Verifiable

        Wait-PrtgProbe

        Assert-VerifiableMocks

        $script:count | Should Be 4
    }

    It "skips importing the initial registry config if one doesn't exist" {
        
        Mock "__Reg" {
            if($Arguments[0] -eq "import")
            {
                throw "import should not occur"
            }
        } -Verifiable

        Mock "Test-Path" {
            $false
        }
        
        $script:count = 0

        Mock "Get-Service" {

            $script:count++

            if($script:count -ge 3)
            {
                [PSCustomObject]@{
                    Status = "Stopped"
                }
            }
        } -Verifiable

        Wait-PrtgProbe

        Assert-VerifiableMocks

        $script:count | Should Be 4
    }

    It "exports the registry config upon exiting" {
        
        Mock "__Reg" {} -ParameterFilter {
            $Arguments -join " " -eq "export HKLM\SOFTWARE\WOW6432Node\Paessler\PRTG Network Monitor\Probe C:\ProgramData\Paessler\PRTG Network Monitor\config.reg /y"
        } -Verifiable
        
        $script:count = 0

        Mock "Get-Service" {

            $script:count++

            if($script:count -ge 3)
            {
                [PSCustomObject]@{
                    Status = "Stopped"
                }
            }
        } -Verifiable

        Wait-PrtgProbe

        Assert-VerifiableMocks

        $script:count | Should Be 4
    }

    It "stops the service, imports the config and then restarts the service when the config is modified" {
        Mock "__Reg" {}
        Mock "Stop-Service" {} -Verifiable
        Mock "Start-Service" {} -Verifiable

        Mock "Test-Path" {

            $allowed = @(
                "C:\ProgramData\Paessler\PRTG Network Monitor\Custom Sensors"
                "C:\ProgramData\Paessler\PRTG Network Monitor\config.reg"
            )

            if($Path -notin $allowed)
            {
                throw "Didn't expect $Path"
            }

            return $false
        }

        Mock "Get-Item" {

            if($Path -eq "C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors")
            {
                return [PSCustomObject]@{
                    Target = "C:\ProgramData\Paessler\PRTG Network Monitor\Custom Sensors"
                }
            }

            if($Path -eq "C:\ProgramData\Paessler\PRTG Network Monitor\config.reg")
            {
                return [PSCustomObject]@{
                    LastWriteTime = (Get-Date).AddHours(1)
                }
            }

            throw "Didn't expect $Path"
        }

        $script:count = 0

        Mock "Get-Service" {

            $script:count++

            [PSCustomObject]@{
                Status = "Stopped"
            }
        } -Verifiable

        Mock "Copy-Item" {

            $Path | Should Be "C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors (Backup)"
            $Destination | Should Be "C:\ProgramData\Paessler\PRTG Network Monitor\Custom Sensors"
        }

        Wait-PrtgProbe

        Assert-VerifiableMocks

        $script:count | Should Be 4
    }
}