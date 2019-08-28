ARG BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2016
FROM $BASE_IMAGE

SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

ARG PRTG_INSTALLER_URL
ARG PRTG_EMAIL="prtg@example.com"
ARG PRTG_LICENSENAME="prtgtrial"
ARG PRTG_LICENSEKEY="000014-250KFM-8FFN6H-31QZ6R-DD7ABX-GE8EQN-CXUU28-1W32K6-RPBM77-W2KV7Y"

COPY PrtgDocker.ps1 config.dat* *.exe C:/Installer/
RUN Set-ExecutionPolicy Unrestricted; C:/Installer/PrtgDocker.ps1 -Install

ENTRYPOINT ["powershell"]
CMD ["-command", "C:/Installer/PrtgDocker.ps1 -Wait"]