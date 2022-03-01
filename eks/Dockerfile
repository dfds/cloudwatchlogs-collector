FROM mcr.microsoft.com/powershell:lts-debian-bullseye-slim AS base

SHELL ["pwsh", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

RUN Install-Module -Name AWS.Tools.Installer -Force && Install-AWSToolsModule AWS.Tools.CloudWatchLogs, AWS.Tools.S3, AWS.Tools.SecurityToken -Force

FROM base

WORKDIR /work

ADD src/*.ps1 /work/

ENTRYPOINT ["pwsh", "-File", "./Query-CloudWatchLogs.ps1"]