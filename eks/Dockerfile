FROM mcr.microsoft.com/powershell:lts-debian-bullseye-slim AS base

SHELL ["pwsh", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

RUN Install-Module AWSPowerShell.NetCore -Confirm:$false -AcceptLicense -Force -RequiredVersion 4.0.5

FROM base

WORKDIR /work

ADD src/*.ps1 /work/

ENTRYPOINT ["pwsh", "-File", "./Query-CloudWatchLogs.ps1"]