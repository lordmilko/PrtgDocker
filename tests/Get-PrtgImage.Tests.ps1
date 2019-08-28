. $PSScriptRoot\..\PrtgDocker.ps1

Describe "Get-PrtgImage" {

    Mock "__ExecInternal" {
        throw "__ExecInternal was called with '$commands'. A Mock on __Exec is either missing or not working properly"
    }

    function MockGet($repository = "prtg")
    {
        Mock "__Exec" {
            return "[]"
        } -ParameterFilter { $commands -join " " -eq "image ls --format `"{{json . }}`"" } -Verifiable

        Mock "ConvertFrom-Json" {
            [PSCustomObject]@{
                Tag = "14.1.2.3"
                Repository = $repository
            }

            [PSCustomObject]@{
                Tag = "17.1.2.3"
                Repository = $repository
            }
        }.GetNewClosure()
    }

    It "lists all images" {

        MockGet

        $result = Get-PrtgImage
        $result.Count | Should Be 2
    }

    It "filters images by tag" {
        MockGet

        $result = @(Get-PrtgImage 17*)
        $result.Count | Should Be 1
        $result.Tag | Should Be "17.1.2.3"
    }

    It "specifies a repository" {
        MockGet "lordmilko/prtg"

        $result = @(Get-PrtgImage 17* "lordmilko/prtg")
        $result.Count | Should Be 1
        $result.Tag | Should Be "17.1.2.3"
    }
}