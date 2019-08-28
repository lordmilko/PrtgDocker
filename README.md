# PrtgDocker

Have you ever wanted to run PRTG Network Monitor in Docker? No? Well now you can!

This repository contains all the steps and components required to containerize (theoretically) any version of PRTG. As of writing this project [has successfully been used](https://hub.docker.com/r/lordmilko/prtg) to create Docker images of all versions of PRTG from 14.4 to 19.2, and likely supports additional versions outside this range.

To simplify deployment, several cmdlets are provided to help validate your inputs and interface with the Docker CLI for you. For the brave of heart, instructions are also provided for those that wish to control the Docker build process manually.

## Quick Start

### PowerShell

1. Create a Windows Server 2016 1607 VM with at least 6gb RAM
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

1. Create a Windows Server 2016 1607 VM with at least 6gb RAM
2. Install Docker ¹
3. Clone this repo to your server (`git clone https://github.com/lordmilko/PrtgDocker`)
4. Please **a single installer** you wish to containerize into the repo
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

As of writing, PRTG only works on Windows Server 2016 based images, when utilizing (mainly) 64-bit executables. To achieve this you must
* Use any Server Core image from `ltsc2016` to `1803`; all images after this are based on Server 2019
* Make PRTG think the system has at least 6gb of RAM so that it registers the 64-bit version of `PRTG Server.exe` instead of the 32-bit version

Attempting to use PRTG in a 2019 based image will cause the web server to freeze upon visiting any page with a chart on it (due to a crash in the `ChartDirector` library), while attempting to use the 32-bit version of `PRTG Server` will cause immediate crashes upon starting when utilizing any version of PRTG using Themida anti-cracking software (PRTG [16.4.28+](https://www.paessler.com/prtg/history/prtg-16#16.4.28)).

### Hyper-V Isolation

If you have a Server 2019 based system and still wish to use these Server 2016 based images, this can still be achieved by using Hyper-V isolation. To build and deploy images with Hyper-V isolation:

1. Install Hyper-V on your Docker server
2. `New-PrtgBuild -HyperV`
3. `New-PrtgContainer -HyperV`

Note: If your Docker server is a virtual machine, you may need to enable [nested virtualization](https://www.settlersoman.com/how-to-installrun-hyper-v-host-as-a-vmnested-on-vsphere-5-or-6/) in order to install Hyper-V

## Installing Docker

So you want to check this project out. You setup a VM, had a go following [this extremely simple three-step process](https://docs.docker.com/install/windows/docker-ee/) for installing Docker, and to your absolute surprise it didn't work! Something about the hash of a file not being correct!

Congratulations! You've just successfully forayed into the nightmare that is using Docker on Windows. The amount of incompetence it takes to released a bungled *installer* is beyond me - *you had one job!*

You can workaround this issue by performing the following steps:

1. Execute the commands to install Docker on Windows as normal (if you haven't already)

```powershell
Install-Module DockerMsftProvider -Force
Install-Package Docker -ProviderName DockerMsftProvider -Force
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