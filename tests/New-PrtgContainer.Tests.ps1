. $PSScriptRoot\..\PrtgDocker.ps1

Describe "New-PrtgContainer" {

    Mock "__ExecInternal" {
        throw "__ExecInternal was called with '$commands'. A Mock on __Exec is either missing or not working properly"
    }

    function MockExec($versions, $script:runStr, $repository = "prtg")
    {
        $available = NewObj $versions $repository

        Mock "__Exec" {
            return "[]"
        } -ParameterFilter { $commands -join " " -eq "image ls --format `"{{json . }}`"" } -Verifiable

        Mock "ConvertFrom-Json" {
            $available
        }.GetNewClosure()

        Mock "__Exec" {} -ParameterFilter { $commands -join " " -eq $script:runStr }
    }

    function NewObj($versions, $repository)
    {
        if($versions)
        {
            foreach($v in @($versions))
            {
                [PSCustomObject]@{
                    Tag = $v
                    Repository = $repository
                }
            }
        }
    }

    Context "Server" {
        It "runs the specified tag" {

            MockExec "14.1.2.3" "run -m 4G -d -p 8080:80 --restart always prtg:14.1.2.3"

            New-PrtgContainer 14.1.2.3
        }

        It "runs interactively" {
            MockExec "14.1.2.3" "run -m 4G -it -p 8080:80 --restart always prtg:14.1.2.3"

            New-PrtgContainer 14.1.2.3 -Interactive
        }

        It "runs with Hyper-V isolation" {
            MockExec "14.1.2.3" "run -m 4G -d -p 8080:80 --isolation=hyperv --restart always prtg:14.1.2.3"

            New-PrtgContainer 14.1.2.3 -HyperV
        }

        It "specifies a name" {
            MockExec "14.1.2.3" "run -m 4G -d --name prtg14 -p 8080:80 --restart always prtg:14.1.2.3"

            New-PrtgContainer 14.1.2.3 prtg14
        }

        It "specifies multiple ports" {
            MockExec "14.1.2.3" "run -m 4G -d -p 8000:80 -p 8443:443 --restart always prtg:14.1.2.3"

            New-PrtgContainer 14.1.2.3 -Port "8000:80","8443:443"
        }

        It "uses a volume" {
            MockExec "14.1.2.3" "run -m 4G -d -p 8080:80 -v prtg14_1_2_3:`"C:\ProgramData\Paessler\PRTG Network Monitor`" --restart always prtg:14.1.2.3"

            New-PrtgContainer 14.1.2.3 -Volume
        }

        It "specifies a repository" {
            MockExec "14.1.2.3" "run -m 4G -d -p 8080:80 --restart always lordmilko/prtg:14.1.2.3" "lordmilko/prtg"

            New-PrtgContainer 14.1.2.3 -Repository "lordmilko/prtg"
        }

        It "throws when no images are found" {
            MockExec $null

            { New-PrtgContainer } | Should Throw "No PRTG images have been built"
        }

        It "throws when no images match a specified tag" {
            MockExec $null

            { New-PrtgContainer 14.1.2.3 } | Should Throw "No PRTG images match the specified wildcard '14.1.2.3'"
        }

        It "throws when an ambiguous tag is specified" {
            MockExec "14.1.2.3","14.4.5.6"

            { New-PrtgContainer 14* } | Should Throw "Please specify one of the following -Tag candidates: 14.1.2.3, 14.4.5.6"
        }

        It "specifies additional args" {
            MockExec "14.1.2.3" "run -m 4G -d -p 8080:80 --restart always -p 8081:81 prtg:14.1.2.3"

            New-PrtgContainer 14.1.2.3 -AdditionalArgs "-p","8081:81"
        }

        It "specifies a different restart policy" {
            MockExec "14.1.2.3" "run -m 4G -d -p 8080:80 --restart unless-stopped prtg:14.1.2.3"

            New-PrtgContainer 14.1.2.3 -RestartPolicy UnlessStopped
        }

        It "disables the restart policy" {
            MockExec "14.1.2.3" "run -m 4G -d -p 8080:80 prtg:14.1.2.3"

            New-PrtgContainer 14.1.2.3 -RestartPolicy None
        }
    }

    Context "Probe" {
        It "creates a probe container without a name" {
            MockExec "14.1.2.3" "run -m 4G -d --restart always prtgprobe:14.1.2.3" "prtgprobe"

            New-PrtgContainer 14.1.2.3 -Probe
        }

        It "specifies a server, name and volume" {
            MockExec "14.1.2.3" "run -m 4G -d --name newyork_1 --env INIT_PRTG_NAME=NewYork_1 -v newyork_1:`"C:\ProgramData\Paessler\PRTG Network Monitor`" --env INIT_PRTG_SERVER=prtg.example.com --restart always prtgprobe:14.1.2.3" "prtgprobe"

            New-PrtgContainer 14.1.2.3 -Probe -Name "NewYork_1" -ServerUrl "prtg.example.com" -Volume
        }

        It "specifies a name with a space" {
            MockExec "14.1.2.3" "run -m 4G -d --name new_york --env INIT_PRTG_NAME=New_York --restart always prtgprobe:14.1.2.3" "prtgprobe"

            New-PrtgContainer 14.1.2.3 -Probe -Name "New York"
        }

        It "specifies a custom sensors path" {
            MockExec "14.1.2.3" "run -m 4G -d --env PRTG_CUSTOM_SENSORS_PATH=\\fs-1\CustomSensors --restart always prtgprobe:14.1.2.3" "prtgprobe"

            New-PrtgContainer 14.1.2.3 -Probe -CustomSensorsPath "\\fs-1\CustomSensors"
        }
    }

    Context "CredentialSpec" {

        It "installs the CredentialSpec module if it doesn't exist" {

            MockExec "14.1.2.3" "run -m 4G -d --name new_york --env INIT_PRTG_NAME=New_York --security-opt credentialspec=file://New_York.json --restart always prtgprobe:14.1.2.3" "prtgprobe"

            Mock "__GetModule" {}

            Mock "__InstallPackage" {
                $Name | Should Be CredentialSpec
            } -Verifiable

            Mock "Get-CredentialSpec" {
                [PSCustomObject]@{
                    Name = "New_York.json"
                    Path = "C:\ProgramData\docker\CredentialSpecs\New_York.json"
                }
            }

            New-PrtgContainer -Probe -CredentialSpec -Name "New York"

            Assert-VerifiableMocks
        }

        It "specifies an existing credential spec" {
            MockExec "14.1.2.3" "run -m 4G -d --name new_york --env INIT_PRTG_NAME=New_York --security-opt credentialspec=file://New_York.json --restart always prtgprobe:14.1.2.3" "prtgprobe"

            Mock "__GetModule" {
                return $true
            }

            Mock "__InstallPackage" {
                throw "Package should not be reinstalled"
            }

            Mock "Get-CredentialSpec" {
                [PSCustomObject]@{
                    Name = "New_York.json"
                    Path = "C:\ProgramData\docker\CredentialSpecs\New_York.json"
                }
            }

            New-PrtgContainer -Probe -CredentialSpec -Name "New York"
        }

        It "creates a new credential spec" {

            MockExec "14.1.2.3" "run -m 4G -d --name new_york --env INIT_PRTG_NAME=New_York --security-opt credentialspec=file://New_York.json --restart always prtgprobe:14.1.2.3" "prtgprobe"

            Mock "__GetModule" {
                return $true
            }

            Mock "__InstallPackage" {
                throw "Package should not be reinstalled"
            }

            Mock "Get-CredentialSpec" {}

            Mock "New-CredentialSpec" {
                [PSCustomObject]@{
                    Name = "New_York.json"
                    Path = "C:\ProgramData\docker\CredentialSpecs\New_York.json"
                }
            }

            New-PrtgContainer -Probe -CredentialSpec -Name "New York" -CredentialSpecAccount container_gmsa

            Assert-VerifiableMocks
        }

        It "throws when -CredentialSpec is specified but -Name is not specified" {
            MockExec "14.1.2.3" $null "prtgprobe"

            { New-PrtgContainer -Probe -CredentialSpec } | Should Throw "-Name must be specified when -CredentialSpec is specified"
        }

        It "throws when -CredentialSpec is specified but -CredentialSpecAccount is not specified and the credential doesn't exist" {
            Mock "__GetModule" {
                return $true
            }

            Mock "__InstallPackage" {
                throw "Package should not be reinstalled"
            }

            Mock "Get-CredentialSpec" {}

            { New-PrtgContainer -Probe -CredentialSpec -Name "New York" } | Should Throw "Cannot create CredentialSpec New_York as -CredentialSpecAccount was not specified. Please specify -CredentialSpecAccount or create credential spec manually first"
        }
    }
}