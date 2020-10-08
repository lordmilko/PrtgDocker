# PrtgDocker

Have you ever wanted to run PRTG Network Monitor in Docker? No? Well now you can!

This repository contains all the steps and components required to containerize (theoretically) any version of PRTG, including both the PRTG Core Server and PRTG Probe components. As of writing this project [has successfully been used](https://hub.docker.com/r/lordmilko/prtg) to create Docker images of all versions of PRTG from 14.4 to 19.4, and likely supports additional versions outside this range.

To simplify deployment, several cmdlets are provided to help validate your inputs and interface with the Docker CLI for you. For the brave of heart, instructions are also provided for those that wish to control the Docker build process manually.

## Quick Start

The following illustrates how you can easily create an image containing the PRTG Core Server. For information on containerizing PRTG Probes as well as advanced configuration options, please see the [wiki](https://github.com/lordmilko/PrtgDocker/wiki).

### PowerShell

1. Create a Windows Server 2019 LTSC (1809, 17763.864) VM with at least 6gb RAM and apply the latest updates ([very important](https://github.com/lordmilko/PrtgDocker/wiki/Image-Compatibility#windows-updates))
2. [Install Docker](https://github.com/lordmilko/PrtgDocker/wiki/Installing-Docker)
3. Clone this repo to your server (`git clone https://github.com/lordmilko/PrtgDocker`)
4. Place any installers you wish to containerize into the repo
5. Open `build.cmd` and run the following commands

   ```powershell
   New-PrtgBuild
   New-PrtgContainer
   ```

6. Visit `http://<hostname>:8080` in your web browser!

### Docker CLI

1. Create a Windows Server 2019 LTSC (1809, 17763.864) VM with at least 6gb RAM and apply the latest updates ([very important](https://github.com/lordmilko/PrtgDocker/wiki/Image-Compatibility#windows-updates))
2. [Install Docker](https://github.com/lordmilko/PrtgDocker/wiki/Installing-Docker)
3. Clone this repo to your server (`git clone https://github.com/lordmilko/PrtgDocker`)
4. Place **a single installer** you wish to containerize into the repo
5. Change the date on your server as required ;)
6. Run the following commands under the repo folder

   ```powershell
   docker build . -t prtg
   docker run -m 4G -it -p 8080:80 prtg
   ```

7. Visit `http://<hostname>:8080` in your web browser!

For more information on using PrtgDocker, including creating PRTG Probe containers and advanced configuration options, please see the [wiki](https://github.com/lordmilko/PrtgDocker/wiki).