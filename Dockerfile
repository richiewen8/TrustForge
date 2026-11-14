# Build context is the parent directory containing TrustForge and TechnitiumLibrary.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

COPY TechnitiumLibrary/ ./TechnitiumLibrary/
COPY TrustForge/ ./TrustForge/

RUN dotnet build TrustForge/../TechnitiumLibrary/TechnitiumLibrary.ByteTree/TechnitiumLibrary.ByteTree.csproj -c Release \
    && dotnet build TrustForge/../TechnitiumLibrary/TechnitiumLibrary.Net/TechnitiumLibrary.Net.csproj -c Release \
    && dotnet build TrustForge/../TechnitiumLibrary/TechnitiumLibrary.Security.OTP/TechnitiumLibrary.Security.OTP.csproj -c Release

RUN dotnet publish TrustForge/TrustForge.Api/TrustForge.Api.csproj -c Release -o /out/publish

FROM mcr.microsoft.com/dotnet/aspnet:10.0
ADD --link https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb /
RUN dpkg -i packages-microsoft-prod.deb \
    && rm packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends libmsquic dnsutils curl \
    && mkdir -p /etc/trustforge/dns /var/log/technitium/dns \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/trustforge
COPY --from=build /out/publish/ ./

ENV ASPNETCORE_URLS=http://+:5000 \
    DnsServer__Enabled=true \
    DnsServer__ConfigDirectory=/etc/trustforge/dns \
    DNS_SERVER_WEB_SERVICE_LOCAL_ADDRESSES=0.0.0.0 \
    DNS_SERVER_LOG_FOLDER_PATH=/var/log/technitium/dns

EXPOSE 5000/tcp 5380/tcp 53/udp 53/tcp 853/udp 853/tcp 443/udp 443/tcp 80/tcp 8053/tcp 67/udp

ENTRYPOINT ["/bin/sh", "-c", "dotnet TrustForge.dll --migrate && exec dotnet TrustForge.dll"]
