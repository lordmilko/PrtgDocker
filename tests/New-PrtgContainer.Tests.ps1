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

    It "runs the specified tag" {

        MockExec "14.1.2.3" "run -m 4G -d -p 8080:80 prtg:14.1.2.3"

        New-PrtgContainer 14.1.2.3
    }

    It "runs interactively" {
        MockExec "14.1.2.3" "run -m 4G -it -p 8080:80 prtg:14.1.2.3"

        New-PrtgContainer 14.1.2.3 -Interactive
    }

    It "runs with Hyper-V isolation" {
        MockExec "14.1.2.3" "run -m 4G -d -p 8080:80 prtg:14.1.2.3 --isolation=hyperv"

        New-PrtgContainer 14.1.2.3 -HyperV
    }

    It "specifies a name" {
        MockExec "14.1.2.3" "run -m 4G -d --name prtg14 -p 8080:80 prtg:14.1.2.3"

        New-PrtgContainer 14.1.2.3 prtg14
    }

    It "specifies multiple ports" {
        MockExec "14.1.2.3" "run -m 4G -d -p 8000:80 -p 8443:443 prtg:14.1.2.3"

        New-PrtgContainer 14.1.2.3 -Port "8000:80","8443:443"
    }

    It "uses a volume" {
        MockExec "14.1.2.3" "run -m 4G -d -p 8080:80 -v prtg14_1_2_3:`"C:\ProgramData\Paessler\PRTG Network Monitor`" prtg:14.1.2.3"

        New-PrtgContainer 14.1.2.3 -Volume
    }

    It "specifies a repository" {
        MockExec "14.1.2.3" "run -m 4G -d -p 8080:80 lordmilko/prtg:14.1.2.3" "lordmilko/prtg"

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

        { New-PrtgContainer 14* } | Should Throw "Please specify one of the following candidates: 14.1.2.3, 14.4.5.6"
    }
}