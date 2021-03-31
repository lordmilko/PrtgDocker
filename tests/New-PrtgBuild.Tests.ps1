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

    #region Build Helpers

    function MockInstaller($version, [switch]$Probe)
    {
        Mock "Test-Path" {
            return $true
        } -ParameterFilter { $Path -eq "C:\Archives" -or $Path -like "*dockerTemp" }

        Mock "Test-Path" {
            return $false
        } -ParameterFilter { $Path -like "*dockerTempServer*" -or $Path -like "*dockerTemp\config.dat" }

        Mock "Get-ChildItem" {

            $productName = "PRTG Network Monitor"

            if($Probe)
            {
                $productName = "PRTG Remote Probe"
            }

            [PSCustomObject]@{
                FullName = "C:\Archives\notepad 2006.exe"
                Name = "notepad 2006.exe"
                VersionInfo = [PSCustomObject]@{
                    ProductName = $productName
                    FileVersion = $version
                }
            }
        }.GetNewClosure()
    }

    function MockExec($version, $script:imageStr, $script:pullStr, $script:buildStr, [switch]$Probe)
    {
        MockInstaller $version -Probe:$Probe

        Mock "__Exec" {} -ParameterFilter {
            return $commands -join " " -eq $script:pullStr
        } -Verifiable

        Mock "__Exec" {} -ParameterFilter {
            return $commands -join " " -eq $script:imageStr
        } -Verifiable

        MockBuild $script:buildStr
    }

    function MockBuild($script:buildStr)
    {
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

            if($Path -like "C:\Windows\Fonts*")
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

    function MockFonts
    {
        Mock "Get-ChildItem" {
            [PSCustomObject]@{
                Name = "arial.ttf"
                FullName = "C:\Windows\Fonts\arial.ttf"
            }
        } -ParameterFilter { $Path -eq "C:\Windows\Fonts" }
    }

    #endregion

    Context "Image" {
        It "qualifies a tag" {

            $settings = ([PSCustomObject]@{ BaseImage = "ltsc2019" })

            __QualifyBaseImage $settings

            $settings.BaseImage | Should Be "mcr.microsoft.com/windows/servercore:ltsc2019"
        }

        it "doesn't qualify a full image path" {

            $input = "mcr.microsoft.com/windows/servercore:ltsc2019"
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

        It "installs a legacy version" {

            MockExec `
                "14.1.2.3" `
                "image ls --format `"{{json . }}`"" `
                "pull mcr.microsoft.com/windows/servercore:ltsc2019" `
                "prtg:14.1.2 --build-arg BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2019"

            MockCopy
            MockRemove
            MockFonts

            New-PrtgBuild -Path "C:\Archives"

            Assert-VerifiableMocks
        }

        It "installs a 32-bit Themida version" {

            MockExec `
                "17.1.2.3" `
                "image ls --format `"{{json . }}`"" `
                "pull mcr.microsoft.com/windows/servercore:ltsc2019" `
                "prtg:17.1.2 --build-arg BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2019"

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
                "image ls --format `"{{json . }}`"" `
                "pull mcr.microsoft.com/windows/servercore:ltsc2019" `
                "prtg:14.1.2 --build-arg BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2019 --no-cache"

            MockCopy
            MockRemove

            New-PrtgBuild -Path "C:\Archives" -Force

            Assert-VerifiableMocks
        }

        It "builds with Hyper-V isolation" {

            MockExec `
                "14.1.2.3" `
                "image ls --format `"{{json . }}`"" `
                "pull mcr.microsoft.com/windows/servercore:ltsc2019" `
                "prtg:14.1.2 --build-arg BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2019 --isolation=hyperv"

            MockCopy
            MockRemove

            New-PrtgBuild -Path "C:\Archives" -HyperV

            Assert-VerifiableMocks
        }

        It "specifies a custom base image" {
            MockExec `
                "14.1.2.3" `
                "image ls --format `"{{json . }}`"" `
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
                "image ls --format `"{{json . }}`"" `
                "pull mcr.microsoft.com/windows/servercore:ltsc2019" `
                "prtg:14.1.2 --build-arg BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2019 --build-arg PRTG_LICENSEKEY=testName --build-arg PRTG_LICENSENAME=testName --build-arg PRTG_EMAIL=potato@example.com"

            MockCopy
            MockRemove

            New-PrtgBuild -Path "C:\Archives" -PrtgEmail "potato@example.com" -LicenseName "testName" -LicenseKey "testKey"

            Assert-VerifiableMocks
        }

        It "specifies a repository" {
            MockExec `
                "14.1.2.3" `
                "image ls --format `"{{json . }}`"" `
                "pull mcr.microsoft.com/windows/servercore:ltsc2019" `
                "lordmilko/prtg:14.1.2 --build-arg BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2019"

            MockCopy
            MockRemove

            New-PrtgBuild -Path "C:\Archives" -Repository "lordmilko/prtg"

            Assert-VerifiableMocks
        }

        It "specifies additional args" {
            MockExec `
                "14.1.2.3" `
                "image ls --format `"{{json . }}`"" `
                "pull mcr.microsoft.com/windows/servercore:ltsc2019" `
                "lordmilko/prtg:14.1.2 --build-arg BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2019 -m 4G"

            MockCopy
            MockRemove

            New-PrtgBuild -Path "C:\Archives" -Repository "lordmilko/prtg" -AdditionalArgs "-m","4G"

            Assert-VerifiableMocks
        }

        It "specifies additional installer args" {
            MockExec `
                "14.1.2.3" `
                "image ls --format `"{{json . }}`"" `
                "pull mcr.microsoft.com/windows/servercore:ltsc2019" `
                "prtg:14.1.2 --build-arg BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2019 --build-arg PRTG_INSTALLER_ADDITIONAL_ARGS=/foo /bar"

            MockCopy
            MockRemove
            MockFonts

            New-PrtgBuild -Path "C:\Archives" -AdditionalInstallerArgs "/foo","/bar"

            Assert-VerifiableMocks
        }

        It "uses a local web server" {

            MockExec `
                "14.1.2.3" `
                "image ls --format `"{{json . }}`"" `
                "pull mcr.microsoft.com/windows/servercore:ltsc2019" `
                "prtg:14.1.2 --build-arg BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2019 --build-arg PRTG_INSTALLER_URL=http://<wildcard>:<wildcard>/notepad+2006.exe"
            
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

                if($Path -like "C:\Windows\Fonts*")
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

        It "fixes the time" {
            MockExec `
                "14.1.2.3" `
                "image ls --format `"{{json . }}`"" `
                "pull mcr.microsoft.com/windows/servercore:ltsc2019" `
                "prtg:14.1.2 --build-arg BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2019"

            MockCopy
            MockRemove
            MockFonts

            Mock "__AdjustServerTime" {} -Verifiable

            New-PrtgBuild -Path "C:\Archives"

            Assert-VerifiableMocks
        }

        It "skips fixing the time" {

            MockExec `
                "14.1.2.3" `
                "image ls --format `"{{json . }}`"" `
                "pull mcr.microsoft.com/windows/servercore:ltsc2019" `
                "prtg:14.1.2 --build-arg BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2019"

            MockCopy
            MockRemove
            MockFonts

            Mock "__AdjustServerTime" {
                throw "__AdjustServerTime should not have been called"
            }

            New-PrtgBuild -Path "C:\Archives" -SkipTimeFix
        }

        It "doesn't pull base image when it already exists" {

            Mock "Get-PrtgImage" {
                return $true
            }

            MockInstaller "14.1.2.3"
            MockBuild "prtg:14.1.2 --build-arg BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2019"
            Mock "__AdjustServerTime" {}

            MockCopy
            MockRemove

            New-PrtgBuild -Path "C:\Archives"

            Assert-VerifiableMocks
        }

        It "throws when local Arial and Tahoma fonts can't be found" {
            Mock "__Exec" {}

            Mock "Get-ChildItem" {
                return
            } -ParameterFilter { $Path -eq "C:\Windows\Fonts" }

            { New-PrtgBuild -Path "C:\Archives" } | Should Throw "Cannot find any fonts for Arial and Tahoma under C:\Windows\Fonts"
        }
    }

    Context "Probe" {
        It "builds a probe" {

            MockExec -Probe `
                "14.1.2.3" `
                "image ls --format `"{{json . }}`"" `
                "pull mcr.microsoft.com/windows/servercore:ltsc2019" `
                "prtgprobe:14.1.2 --build-arg BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2019"

            MockCopy
            MockRemove
            MockFonts

            New-PrtgBuild -Probe

            Assert-VerifiableMocks
        }

        It "installs an executable that is not named in the default name format" {
        
            Mock "Copy-Item" {}
            Mock "__Exec" {}

            Mock "Get-ChildItem" {
                [PSCustomObject]@{
                    FullName = "C:\Archives\notepad 2006.exe"
                    Name = "notepad"
                    VersionInfo = [PSCustomObject]@{
                        ProductName = "PRTG Remote Probe"
                        FileVersion = "14.1.2.3"
                    }
                }
            }

            New-PrtgBuild -Probe
        }

        It "throws when Dockerfile.prtg is missing" {

            Mock "Copy-Item" {}
            Mock "__Exec" {}
            Mock "Get-ChildItem" {

                [PSCustomObject]@{
                    FullName = "C:\Archives\notepad 2006.exe"
                    Name = "notepad"
                    VersionInfo = [PSCustomObject]@{
                        ProductName = "PRTG Remote Probe"
                        FileVersion = "14.1.2.3"
                    }
                }
            }

            Mock "Test-Path" {
                if($Path -like "*Dockerfile.probe")
                {
                    return $false
                }

                return $true
            }

            { New-PrtgBuild -Probe } | Should Throw "Dockerfile.probe' is missing"
        }

        It "throws when no executables are found" {
            Mock "Copy-Item" {}
            Mock "__Exec" {}
            Mock "Get-ChildItem" {}
            Mock "Test-Path" { $true }

            { New-PrtgBuild -Probe } | Should Throw "No executable files exist"
        }

        It "throws when no probe installers are found" {
            Mock "Copy-Item" {}
            Mock "__Exec" {}
            Mock "Get-ChildItem" {

                [PSCustomObject]@{
                    FullName = "C:\Archives\notepad 2006.exe"
                    Name = "notepad"
                    VersionInfo = [PSCustomObject]@{
                        ProductName = "PRTG Network Monitor"
                        FileVersion = "14.1.2.3"
                    }
                }
            }

            { New-PrtgBuild -Probe } | Should THrow "Couldn't find any PRTG Remote Probe installers under the specified folder"
        }

        It "throws when multiple probe installers are found" {
            Mock "Copy-Item" {}
            Mock "__Exec" {}
            Mock "Get-ChildItem" {

                [PSCustomObject]@{
                    FullName = "C:\Archives\notepad 2006.exe"
                    Name = "notepad"
                    VersionInfo = [PSCustomObject]@{
                        ProductName = "PRTG Remote Probe"
                        FileVersion = "14.1.2.3"
                    }
                }

                [PSCustomObject]@{
                    FullName = "C:\Archives\notepad 2006.exe"
                    Name = "notepad"
                    VersionInfo = [PSCustomObject]@{
                        ProductName = "PRTG Remote Probe"
                        FileVersion = "17.1.2.3"
                    }
                }
            }

            $str = "Found multiple probe installers under 'D:\Programming\PowerShell\PrtgDocker' ('C:\Archives\notepad 2006.exe (14.1.2.3)', 'C:\Archives\notepad 2006.exe (17.1.2.3)'). Please specify only a single installer"

            { New-PrtgBuild -Probe } | Should Throw $str
        }
    }

    $env:DOCKER_HOST = $original
}