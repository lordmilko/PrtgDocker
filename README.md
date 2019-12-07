# PrtgDocker

Have you ever wanted to run PRTG Network Monitor in Docker? No? Well now you can!

This repository contains all the steps and components required to containerize (theoretically) any version of PRTG. As of writing this project [has successfully been used](https://hub.docker.com/r/lordmilko/prtg) to create Docker images of all versions of PRTG from 14.4 to 19.4, and likely supports additional versions outside this range.

To simplify deployment, several cmdlets are provided to help validate your inputs and interface with the Docker CLI for you. For the brave of heart, instructions are also provided for those that wish to control the Docker build process manually.

## Quick Start

### PowerShell

1. Create a Windows Server 2019 LTSC (1809, 17763.864) VM with at least 6gb RAM
2. Install Docker ¹
3. Clone this repo to your server (`git clone https://github.com/lordmilko/PrtgDocker`)
4. Place any installers you wish to containerize into the repo
5. Open `build.cmd` and run the following commands

   ```powershell
   New-PrtgBuild
   New-PrtgContainer
   ```

6. Visit `http://<hostname>:8080` in your web browser!

¹ See instructions below if you can't get Docker to install

### Docker CLI

1. Create a Windows Server 2019 LTSC (1809, 17763.864) VM with at least 6gb RAM
2. Install Docker ¹
3. Clone this repo to your server (`git clone https://github.com/lordmilko/PrtgDocker`)
4. Place **a single installer** you wish to containerize into the repo
5. Change the date on your server as required ;)
6. Run the following commands under the repo folder

   ```powershell
   docker build . -t prtg
   docker run -m 4G -it -p 8080:80 prtg
   ```

7. Visit `http://<hostname>:8080` in your web browser!

¹ See instructions below if you can't get Docker to install

## Advanced

*PrtgDocker* provides three cmdlets that can be used for creating and deploying PRTG images

| Name                | Docker Function | Description                                                            |
| ------------------- | --------------- | ---------------------------------------------------------------------- |
| `New-PrtgBuild`     | `docker build`  | Builds docker images for installers in a specified directory           |
| `New-PrtgContainer` | `docker run`    | Creates a new container from a previously built PRTG image             |
| `Get-PrtgImage`     | `docker images` | Lists all images previously built by `New-PrtgBuild` or `docker build` |

Each cmdlet contains several arguments that can be specified to control how they behave. For more information on each cmdlet, please run `Get-Help <cmdlet>` under `build.cmd`

The following examples demonstrate some of the additional capabilities of the cmdlets

```powershell
# Create images for all installers under a folder
New-PrtgBuild -Path C:\Installers
```

```powershell
# Create installers for only PRTG 18.x installers under a folder
New-PrtgBuild *18* C:\Installers -Server
```

```powershell
# Create a container for version 14.4.* with a persistent volume for the
# "C:\ProgramData\Paessler\PRTG Network Monitor" folder
New-PrtgContainer *14.4* -Volume
```

### Image Compatibility

PRTG is compatible with both Windows Server 2016 and 2019 based images when utilizing (mainly) 64-bit executables. When installing in Server Core 2019 based images, PrtgDocker will
automatically install the required fonts (Arial and Tahoma) required for PRTG's chart drawing library (Chart Director) that have been stripped from the base installation.

Attempting to use the 32-bit version of `PRTG Server` will cause immediate crashes upon starting when utilizing any version of PRTG using Themida anti-cracking software (PRTG [16.4.28+](https://www.paessler.com/prtg/history/prtg-16#16.4.28)).
### Hyper-V Isolation

If you wish to run your images on a system that does not match the system the image was built on, you [may be able to do](https://docs.microsoft.com/en-us/virtualization/windowscontainers/deploy-containers/version-compatibility) so using Hyper-V isolation.
Images can be built and deployed using Hyper-V isolation by specifying the `-HyperV` parameter to `New-PrtgBuild` or `New-PrtgContainer` respectively.

1. Install Hyper-V on your Docker server
2. `New-PrtgBuild -HyperV`
3. `New-PrtgContainer -HyperV`

Note: If your Docker server is a virtual machine, you may need to enable [nested virtualization](https://www.settlersoman.com/how-to-installrun-hyper-v-host-as-a-vmnested-on-vsphere-5-or-6/) in order to install Hyper-V

## Installing Docker

In theory installing Docker should be as simple as following [this extremely simple three-step process](https://docs.docker.com/install/windows/docker-ee/).

In the event you run into issues verifying the integrity of the Docker installer's zip file, you can work around this by executing the following steps

1. Execute the commands to install Docker on Windows as normal (if you haven't already)

```powershell
Install-Module DockerMsftProvider -Force
Install-Package Docker -ProviderName DockerMsftProvider -Force -Verbose
```

2. Take note of the name of the file that couldn't be verified (as of writing `Docker-19-03-1.zip`), then execute the following commands, substituting `19-03-1` for whatever the latest version is

```powershell
mkdir $env:temp\DockerMsftProvider
cd $env:temp\DockerMsftProvider
Start-BitsTransfer -Source https://dockermsft.blob.core.windows.net/dockercontainer/docker-19-03-1.zip 
Get-FileHash -Path $env:temp\DockerMsftProvider\Docker-19-03-1.zip -Algorithm SHA256
Install-Package -Name docker -ProviderName DockerMsftProvider -Verbose
```

When the `docker` package is installed this time, it will see the package has already been downloaded and will use it without re-downloading it.