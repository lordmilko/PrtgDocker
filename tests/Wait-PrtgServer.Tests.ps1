. $PSScriptRoot\..\PrtgDocker.ps1

Describe "Wait-PrtgServer" {

    Mock "Start-Sleep" {}

    It "recreates custom sensors in a volume" {

        Mock "Test-Path" {
            $Path | Should Be "C:\ProgramData\Paessler\PRTG Network Monitor\Custom Sensors" | Out-Null

            return $false
        } -ParameterFilter { $Path -notlike "*config.reg" } -Verifiable

        Mock "Test-Path" {
            return $true
        } -ParameterFilter { $Path -like "*config.reg" }

        Mock "Get-Item" {

            $Path | Should Be "C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors" | Out-Null

            return [PSCustomObject]@{
                Target = "C:\ProgramData\Paessler\PRTG Network Monitor\Custom Sensors"
            }
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

        Wait-PrtgServer

        Assert-VerifiableMocks
    }

    It "utilizes an external custom sensors path" {

        Mock "__DeleteFolder" {} -Verifiable

        Mock "New-Item" {
            $ItemType | Should Be "SymbolicLink"
            $Path | Should Be "C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors"
            $Value | Should Be "\\fs-1\CustomSensors"            
        } -Verifiable

        Mock "Test-Path" {
            return $true
        } -ParameterFilter { $Path -like "*config.reg" }

        Mock "Get-Service" {

            [PSCustomObject]@{
                Status = "Stopped"
            }
        } -Verifiable

        try
        {
            $env:PRTG_CUSTOM_SENSORS_PATH = "\\fs-1\CustomSensors"

            Wait-PrtgServer
        }
        finally
        {
            $env:PRTG_CUSTOM_SENSORS_PATH = $null
        }

        Assert-VerifiableMocks
    }

    It "waits for the service to stop, waits to see if it restarts, and terminates if it doesn't" {

        Mock "__BeginWaiter" {}

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

        Wait-PrtgServer

        Assert-VerifiableMocks

        $script:count | Should Be 4
    }

    It "waits for the service to stop, waits to see if it restarts, and resumes if it does" {
        
        Mock "__BeginWaiter" {}

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

        Wait-PrtgServer

        Assert-VerifiableMocks

        $script:count | Should Be 8
    }
}