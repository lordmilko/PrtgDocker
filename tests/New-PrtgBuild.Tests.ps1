. $PSScriptRoot\..\PrtgDocker.ps1

Describe "New-PrtgBuild" {

    $original = $env:DOCKER_HOST
    $env:DOCKER_HOST = $null

    Mock "__ExecInternal" {
        throw "__ExecInternal was called with '$commands'. A Mock on __Exec is either missing or not working properly"
    }

    Mock "Set-Date" {}
    Mock "Start-Job" {}

    Mock Invoke-Command {}

    Context "Image" {
        It "qualifies a tag" {

            $settings = ([PSCustomObject]@{ BaseImage = "ltsc2016" })

            __QualifyBaseImage $settings

            $settings.BaseImage | Should Be "mcr.microsoft.com/windows/servercore:ltsc2016"
        }

        it "doesn't qualify a full image path" {

            $input = "mcr.microsoft.com/windows/servercore:ltsc2016"
            $settings = ([PSCustomObject]@{ BaseImage = $input })

            __QualifyBaseImage $settings

            $settings.BaseImage | Should Be $input
        }
    }

    Context "Path" {
        It "throws when an invalid folder is specified" {
            Mock "Test-Path" {
                return $false
            } -ParameterFilter { $Path -eq "C:\Archives" }
            
            { New-PrtgBuild -Path "C:\Archives" } | Should Throw "Installer Path 'C:\Archives' is not a valid folder"
        }

        It "throws when no executables are found" {
            Mock "Test-Path" {
                return $true
            } -ParameterFilter { $Path -eq "C:\Archives" }

            Mock "Get-ChildItem" {}

            { New-PrtgBuild -Path "C:\Archives" } | Should Throw "No executable files exist"
        }

        It "throws when no PRTG installers are found" {
            Mock "Test-Path" {
                return $true
            } -ParameterFilter { $Path -eq "C:\Archives" }

            Mock "Get-ChildItem" {
                [PSCustomObject]@{
                    Name = "notepad"
                    VersionInfo = [PSCustomObject]@{
                        ProductName = "notepad"
                    }
                }
            }

            { New-PrtgBuild -Path "C:\Archives" } | Should Throw "Couldn't find any PRTG Network Monitor installers"
        }

        It "throws when all installers are filtered out" {

            Mock "Test-Path" {
                return $true
            } -ParameterFilter { $Path -eq "C:\Archives" }

            Mock "Get-ChildItem" {
                [PSCustomObject]@{
                    Name = "notepad"
                    VersionInfo = [PSCustomObject]@{
                        ProductName = "PRTG Network Monitor"
                    }
                }
            }

            { New-PrtgBuild *potato* -Path "C:\Archives" } | Should Throw "Installer filter '*potato*' did not match any candidates"
        }
    }

    Context "Build" {

        function MockInstaller($version)
        {
            Mock "Test-Path" {
                return $true
            } -ParameterFilter { $Path -eq "C:\Archives" -or $Path -like "*dockerTemp" }

            Mock "Test-Path" {
                return $false
            } -ParameterFilter { $Path -like "*dockerTempServer*" -or $Path -like "*dockerTemp\config.dat" }

            Mock "Get-ChildItem" {
                [PSCustomObject]@{
                    FullName = "C:\Archives\notepad 2006.exe"
                    Name = "notepad 2006.exe"
                    VersionInfo = [PSCustomObject]@{
                        ProductName = "PRTG Network Monitor"
                        FileVersion = $version
                    }
                }
            }.GetNewClosure()
        }

        function MockExec($version, $script:pullStr, $script:buildStr)
        {
            MockInstaller $version

            Mock "__Exec" {} -ParameterFilter {
                return $commands -join " " -eq $script:pullStr
            } -Verifiable

            Mock "__Exec" {} -ParameterFilter {
                $temp = Join-Path ([IO.Path]::GetTempPath()) "dockerTemp"
                $b = "build $temp -t $script:buildStr"

                if($b.Contains("<wildcard>"))
                {
                    $b = [regex]::Escape($b) -replace "<wildcard>",".+?"

                    return $commands -join " " -match $b
                }
                else
                {
                    return $commands -join " " -eq $b
                }
            } -Verifiable
        }

        function MockCopy($script:includeConfig = $false)
        {
            Mock "Copy-Item" {

                $temp = [IO.Path]::GetTempPath()
                $dockerTemp = Join-Path $temp "dockerTemp"
                $dockerFile = Join-Path $dockerTemp "Dockerfile"
                $scriptFile = Join-path $dockerTemp "PrtgDocker.ps1"

                $allowed = @(
                    $dockerFile
                    $scriptFile
                )

                if($Destination -in $allowed)
                {
                    return
                }

                if($Path -eq "C:\Archives\notepad 2006.exe" -and $Destination -eq $dockerTemp)
                {
                    return
                }

                if($script:includeConfig)
                {
                    if($Path -like "*config.dat")
                    {
                        return
                    }
                }

                throw "Copy-Item should not have been called with Path '$Path', Destination '$Destination'"
            }
        }

        function MockRemove($script:includeConfig = $false)
        {
            Mock "Remove-Item" {
                $temp = [IO.Path]::GetTempPath()
                $dockerTemp = Join-Path $temp "dockerTemp"

                $allowed = @(
                    Join-Path $dockerTemp "notepad 2006.exe"
                    $dockerTemp
                )

                if($Path -in $allowed)
                {
                    return
                }

                if($script:includeConfig -and $Path -eq (Join-Path $dockerTemp "config.dat"))
                {
                    return
                }

                throw "Remove-Item should not have been called with Path '$Path'"
            }
        }

        It "installs a legacy version" {

            MockExec `
                "14.1.2.3" `
                "pull mcr.microsoft.com/windows/servercore:ltsc2016" `
                "prtg:14.1.2 --build-arg BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2016"

            MockCopy
            MockRemove

            New-PrtgBuild -Path "C:\Archives"

            Assert-VerifiableMocks
        }

        It "installs a 32-bit Themida version" {

            MockExec `
                "17.1.2.3" `
                "pull mcr.microsoft.com/windows/servercore:ltsc2016" `
                "prtg:17.1.2 --build-arg BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2016"

            MockCopy $true
            MockRemove $true

            Mock "Test-Path" {
                return $true
            } -ParameterFilter { $Path -like "*dockerTemp\config.dat" }

            New-PrtgBuild -Path "C:\Archives"

            Assert-VerifiableMocks
        }

        It "builds without a cache" {

            MockExec `
                "14.1.2.3" `
                "pull mcr.microsoft.com/windows/servercore:ltsc2016" `
                "prtg:14.1.2 --build-arg BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2016 --no-cache"

            MockCopy
            MockRemove

            New-PrtgBuild -Path "C:\Archives" -Force

            Assert-VerifiableMocks
        }

        It "builds with Hyper-V isolation" {

            MockExec `
                "14.1.2.3" `
                "pull mcr.microsoft.com/windows/servercore:ltsc2016" `
                "prtg:14.1.2 --build-arg BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2016 --isolation=hyperv"

            MockCopy
            MockRemove

            New-PrtgBuild -Path "C:\Archives" -HyperV

            Assert-VerifiableMocks
        }

        It "specifies a custom base image" {
            MockExec `
                "14.1.2.3" `
                "pull mcr.microsoft.com/windows/servercore:1803" `
                "prtg:14.1.2 --build-arg BASE_IMAGE=mcr.microsoft.com/windows/servercore:1803"

            MockCopy
            MockRemove

            New-PrtgBuild -Path "C:\Archives" -BaseImage 1803

            Assert-VerifiableMocks
        }

        It "specifies installer overrides" {

            MockExec `
                "14.1.2.3" `
                "pull mcr.microsoft.com/windows/servercore:ltsc2016" `
                "prtg:14.1.2 --build-arg BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2016 --build-arg PRTG_LICENSEKEY=testName --build-arg PRTG_LICENSENAME=testName --build-arg PRTG_EMAIL=potato@example.com"

            MockCopy
            MockRemove

            New-PrtgBuild -Path "C:\Archives" -PrtgEmail "potato@example.com" -LicenseName "testName" -LicenseKey "testKey"

            Assert-VerifiableMocks
        }

        It "specifies a repository" {
            MockExec `
                "14.1.2.3" `
                "pull mcr.microsoft.com/windows/servercore:ltsc2016" `
                "lordmilko/prtg:14.1.2 --build-arg BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2016"

            MockCopy
            MockRemove

            New-PrtgBuild -Path "C:\Archives" -Repository "lordmilko/prtg"

            Assert-VerifiableMocks
        }

        It "uses a local web server" {

            MockExec `
                "14.1.2.3" `
                "pull mcr.microsoft.com/windows/servercore:ltsc2016" `
                "prtg:14.1.2 --build-arg BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2016 --build-arg PRTG_INSTALLER_URL=http://<wildcard>:<wildcard>/notepad+2006.exe"
            
            Mock "Test-Path" {
                return $true
            } -ParameterFilter { $Path -like "*dockerTempServer*" }

            Mock "Copy-Item" {

                $temp = [IO.Path]::GetTempPath()
                $dockerTemp = Join-Path $temp "dockerTemp"
                $dockerTempServer = Join-Path $temp "dockerTempServer"
                $dockerFile = Join-Path $dockerTemp "Dockerfile"
                $scriptFile = Join-path $dockerTemp "PrtgDocker.ps1"

                if($Destination -eq $dockerFile -or $Destination -eq $scriptFile)
                {
                    return
                }

                if($Path -eq "C:\Archives\notepad 2006.exe" -and $Destination -eq $dockerTempServer)
                {
                    return
                }

                throw "Copy-Item should not have been called with Path '$Path', Destination '$Destination'"
            }

            Mock "Remove-Item" {
                $temp = [IO.Path]::GetTempPath()
                $dockerTemp = Join-Path $temp "dockerTemp"
                $dockerTempServer = Join-Path $temp "dockerTempServer"
                $config = Join-Path $dockerTempServer "config.dat"
                $installer = Join-Path $dockerTempServer "notepad 2006.exe"

                $allowed = @(
                    $config
                    $installer
                    $dockerTemp
                    $dockerTempServer
                )

                if($Path -in $allowed)
                {
                    return
                }

                throw "Remove-Item should not have been called with Path '$Path'"
            }

            New-PrtgBuild -Path "C:\Archives" -Server

            Assert-VerifiableMocks
        }
    }

    $env:DOCKER_HOST = $original
}