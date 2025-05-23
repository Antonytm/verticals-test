$ErrorActionPreference = "Stop";

. .\upFunctions.ps1

Validate-LicenseExpiry

$envContent = Get-Content .env -Encoding UTF8
$xmCloudHost = $envContent | Where-Object { $_ -imatch "^CM_HOST=.+" }
$sitecoreDockerRegistry = $envContent | Where-Object { $_ -imatch "^SITECORE_DOCKER_REGISTRY=.+" }
$sitecoreVersion = $envContent | Where-Object { $_ -imatch "^SITECORE_VERSION=.+" }
$ClientCredentialsLogin = $envContent | Where-Object { $_ -imatch "^SITECORE_FedAuth_dot_Auth0_dot_ClientCredentialsLogin=.+" }
$xmcloudDockerToolsImage = ($envContent | Where-Object { $_ -imatch "^TOOLS_IMAGE=.+" }).Split("=")[1]
# DEMO TEAM CUSTOMIZATION - Removed reading the dynamic Sitecore API key. We use a static API key.

$xmCloudHost = $xmCloudHost.Split("=")[1]
$sitecoreDockerRegistry = $sitecoreDockerRegistry.Split("=")[1]
$sitecoreVersion = $sitecoreVersion.Split("=")[1]
$ClientCredentialsLogin = $ClientCredentialsLogin.Split("=")[1]
if ($ClientCredentialsLogin -eq "true") {
	$xmCloudClientCredentialsLoginDomain = $envContent | Where-Object { $_ -imatch "^SITECORE_FedAuth_dot_Auth0_dot_Domain=.+" }
	$xmCloudClientCredentialsLoginAudience = $envContent | Where-Object { $_ -imatch "^SITECORE_FedAuth_dot_Auth0_dot_ClientCredentialsLogin_Audience=.+" }
	$xmCloudClientCredentialsLoginClientId = $envContent | Where-Object { $_ -imatch "^SITECORE_FedAuth_dot_Auth0_dot_ClientCredentialsLogin_ClientId=.+" }
	$xmCloudClientCredentialsLoginClientSecret = $envContent | Where-Object { $_ -imatch "^SITECORE_FedAuth_dot_Auth0_dot_ClientCredentialsLogin_ClientSecret=.+" }
	$xmCloudClientCredentialsLoginDomain = $xmCloudClientCredentialsLoginDomain.Split("=")[1]
	$xmCloudClientCredentialsLoginAudience = $xmCloudClientCredentialsLoginAudience.Split("=")[1]
	$xmCloudClientCredentialsLoginClientId = $xmCloudClientCredentialsLoginClientId.Split("=")[1]
	$xmCloudClientCredentialsLoginClientSecret = $xmCloudClientCredentialsLoginClientSecret.Split("=")[1]
}

#set nuget version
$xmCloudBuild = Get-Content "xmcloud.build.json" | ConvertFrom-Json
$nodeVersion = $xmCloudBuild.renderingHosts.xmcloudpreview.nodeVersion
if (![string]::IsNullOrWhitespace($nodeVersion)) {
    Set-EnvFileVariable "NODEJS_VERSION" -Value $xmCloudBuild.renderingHosts.xmcloudpreview.nodeVersion
}

# Double check whether init has been run
$envCheckVariable = "SITECORE_ADMIN_PASSWORD"
$envCheck = $envContent | Where-Object { $_ -imatch "^$envCheckVariable=.+" }
if (-not $envCheck) {
    # DEMO TEAM CUSTOMIZATION - Auto run init.ps1 if not run.
    if (Test-Path "C:\License") {
        Write-Host "Initializing environment using default values" -ForegroundColor Yellow
        & .\init.ps1 -InitEnv -AdminPassword b -LicenseXmlPath C:\License\license.xml
    }
    else {
        throw "$envCheckVariable does not have a value. Did you run 'init.ps1 -InitEnv'?"
    }
    # END CUSTOMIZATION
}

Write-Host "Keeping XM Cloud base image up to date" -ForegroundColor Green
docker pull "$($sitecoreDockerRegistry)sitecore-xmcloud-cm:$($sitecoreVersion)"

Write-Host "Keeping XM Cloud Tools image up to date" -ForegroundColor Green
docker pull "$($xmcloudDockerToolsImage):$($sitecoreVersion)"

# Build all containers in the Sitecore instance, forcing a pull of latest base containers
Write-Host "Building containers..." -ForegroundColor Green
docker compose build
if ($LASTEXITCODE -ne 0) {
    Write-Error "Container build failed, see errors above."
}

# Start the Sitecore instance
Write-Host "Starting Sitecore environment..." -ForegroundColor Green
docker compose up -d

# Wait for Traefik to expose CM route
Write-Host "Waiting for CM to become available..." -ForegroundColor Green
$startTime = Get-Date
do {
    Start-Sleep -Milliseconds 100
    try {
        $status = Invoke-RestMethod "http://localhost:8079/api/http/routers/cm-secure@docker"
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -ne "404") {
            throw
        }
    }
} while ($status.status -ne "enabled" -and $startTime.AddSeconds(15) -gt (Get-Date))
if (-not $status.status -eq "enabled") {
    $status
    Write-Error "Timeout waiting for Sitecore CM to become available via Traefik proxy. Check CM container logs."
}

Write-Host "Restoring Sitecore CLI..." -ForegroundColor Green
    dotnet tool restore
Write-Host "Installing Sitecore CLI Plugins..."
dotnet sitecore --help | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "Unexpected error installing Sitecore CLI Plugins"
}

#####################################

Write-Host "Logging into Sitecore..." -ForegroundColor Green
if ($ClientCredentialsLogin -eq "true") {
    dotnet sitecore cloud login --client-id $xmCloudClientCredentialsLoginClientId --client-secret $xmCloudClientCredentialsLoginClientSecret --client-credentials true
    dotnet sitecore login --authority $xmCloudClientCredentialsLoginDomain --audience $xmCloudClientCredentialsLoginAudience --client-id $xmCloudClientCredentialsLoginClientId --client-secret $xmCloudClientCredentialsLoginClientSecret --cm https://$xmCloudHost --client-credentials true --allow-write true
}
else {
    dotnet sitecore cloud login
    dotnet sitecore connect --ref xmcloud --cm https://$xmCloudHost --allow-write true -n default
}

if ($LASTEXITCODE -ne 0) {
    Write-Error "Unable to log into Sitecore, did the Sitecore environment start correctly? See logs above."
}

# Populate Solr managed schemas to avoid errors during item deploy
Write-Host "Populating Solr managed schema..." -ForegroundColor Green
dotnet sitecore index schema-populate
if ($LASTEXITCODE -ne 0) {
    Write-Error "Populating Solr managed schema failed, see errors above."
}

Write-Host "Pushing Sitecore items" -ForegroundColor Green
dotnet sitecore ser push

docker compose restart rendering
docker compose restart renderingastro


# Rebuild indexes
Write-Host "Rebuilding indexes ..." -ForegroundColor Green
dotnet sitecore index rebuild

if ($ClientCredentialsLogin -ne "true") {
    Write-Host "Opening site..." -ForegroundColor Green
    
    Start-Process https://xmcloudcm.localhost/sitecore/
    Start-Process https://basic.sxastarter.localhost.astro/
}

$containerId = docker ps --filter ancestor=sxastarter-xmcloud-cm:1.0.1 --format "{{.ID}}"
$ip = Get-NetIPAddress | Where-Object -FilterScript {$_.IPAddress.StartsWith("192")}
$ipAddress = $ip.IPAddress
Write-Host "Adding DNS record to container $containerId. Host: host.docker.internal. IP: $ipAddress"
$command = "'$ipAddress host.docker.internal' | Out-File -Append -Encoding ASCII -FilePath '$($Env:windir)\\system32\\drivers\\etc\\hosts'"
docker exec -it $containerId powershell $command

Write-Host ""
Write-Host "Use the following command to monitor your Rendering Host:" -ForegroundColor Green
Write-Host "docker compose logs -f rendering"
Write-Host ""
