# =====================================================================
# Cofre Digital Seguro - Azure (PowerShell + Azure CLI)
# Autor: Gabriel Lamata - RM562093 - FIAP
#
# Um processador automático (Container Apps Job) lê uma credencial do
# Key Vault e grava um relatório no Storage SEM senha no código e SEM
# expor nada na internet (acesso só por Private Endpoints).
#
# Rode um bloco por vez, no mesmo terminal (as variáveis ficam nele).
# =====================================================================

# ---------------------------------------------------------------------
# 1. PREPARAÇÃO
# ---------------------------------------------------------------------

# Conecta o terminal à conta Azure (abre o navegador para login)
az login

# Instala a extensão do Azure CLI com os comandos de Container Apps
az extension add --name containerapp --upgrade

# Variáveis com os nomes de todos os recursos.
# Key Vault, Storage e ACR precisam de nome único no mundo: por isso o sufixo aleatório.
$RG = "rg-cofre-seguro-2"
$LOC = "canadacentral"
$SUF = Get-Random -Minimum 1000 -Maximum 9999
$VNET = "cofre-vnet"
$SUB_APPS = "snet-apps"
$SUB_PE = "snet-private-endpoints"
$KV = "cofre-kv-$SUF"
$ST = "cofrest$SUF"
$ACR = "cofreacr$SUF"
$MI = "cofre-identity"
$LOGS = "cofre-logs"
$ENV_CA = "cofre-env"
$JOB = "cofre-processador"
Write-Host "SUFIXO: $SUF" -ForegroundColor Yellow

# Cria o Resource Group: a "pasta" que agrupa todos os recursos do projeto
az group create --name $RG --location $LOC -o table

# ---------------------------------------------------------------------
# 2. REDE
# ---------------------------------------------------------------------

# Rede virtual privada do projeto
az network vnet create -g $RG -n $VNET -l $LOC --address-prefixes 10.80.0.0/16 -o none

# Sub-rede da aplicação, delegada ao Container Apps (exigência do serviço)
az network vnet subnet create -g $RG --vnet-name $VNET -n $SUB_APPS --address-prefixes 10.80.0.0/23 --delegations Microsoft.App/environments -o none

# Sub-rede onde ficam os Private Endpoints (portas privadas do Key Vault e do Storage)
az network vnet subnet create -g $RG --vnet-name $VNET -n $SUB_PE --address-prefixes 10.80.2.0/24 -o none

# Validação: lista as duas sub-redes
az network vnet subnet list -g $RG --vnet-name $VNET --query "[].{Subnet:name, Faixa:addressPrefix}" -o table

# ---------------------------------------------------------------------
# 3. KEY VAULT TRANCADO
# ---------------------------------------------------------------------

# Cria o Key Vault com autorização RBAC (acesso controlado por funções)
az keyvault create -g $RG -n $KV -l $LOC --enable-rbac-authorization true --retention-days 7 -o none

# Guarda o ID do cofre e o ID do usuário logado
$KV_ID = az keyvault show -g $RG -n $KV --query id -o tsv
$MEU_ID = az ad signed-in-user show --query id -o tsv

# Dá ao próprio usuário permissão para gravar segredos (sem isso: Forbidden)
az role assignment create --assignee-object-id $MEU_ID --assignee-principal-type User --role "Key Vault Secrets Officer" --scope $KV_ID -o none

# Espera a permissão propagar
Start-Sleep -Seconds 60

# Grava a credencial do "sistema externo" no cofre
az keyvault secret set --vault-name $KV --name ChaveSistemaExterno --value "api-key-sistema-externo-2026" -o none

# Tranca o cofre: desabilita o acesso pela internet
az keyvault update -g $RG -n $KV --public-network-access Disabled -o none

# Validação: RBAC ligado e acesso público desabilitado
az keyvault show -g $RG -n $KV --query "{Cofre:name, RBAC:properties.enableRbacAuthorization, AcessoPublico:properties.publicNetworkAccess}" -o table

# ---------------------------------------------------------------------
# 4. STORAGE TRANCADO
# ---------------------------------------------------------------------

# Cria o Storage já trancado: TLS 1.2, sem blobs públicos, sem acesso pela internet
az storage account create -g $RG -n $ST -l $LOC --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 --allow-blob-public-access false --public-network-access Disabled -o none

# Cria o container "relatorios" pelo plano de gerenciamento (não depende de acesso aos dados)
az storage container-rm create -g $RG --storage-account $ST -n relatorios -o none

# Guarda o ID do Storage e valida as configurações de segurança
$ST_ID = az storage account show -g $RG -n $ST --query id -o tsv
az storage account show -g $RG -n $ST --query "{Conta:name, TLS:minimumTlsVersion, AcessoPublico:publicNetworkAccess}" -o table

# ---------------------------------------------------------------------
# 5. PRIVATE ENDPOINTS E DNS PRIVADO
# ---------------------------------------------------------------------

# Private Endpoint do Key Vault: dá ao cofre um IP dentro da VNet
az network private-endpoint create -g $RG -n pe-keyvault -l $LOC --vnet-name $VNET --subnet $SUB_PE --private-connection-resource-id $KV_ID --group-id vault --connection-name con-keyvault -o none

# Private Endpoint do Storage (Blob): dá ao Storage um IP dentro da VNet
az network private-endpoint create -g $RG -n pe-storage -l $LOC --vnet-name $VNET --subnet $SUB_PE --private-connection-resource-id $ST_ID --group-id blob --connection-name con-storage -o none

# Zonas de DNS privado: fazem os nomes dos serviços apontarem para os IPs privados
az network private-dns zone create -g $RG -n privatelink.vaultcore.azure.net -o none
az network private-dns zone create -g $RG -n privatelink.blob.core.windows.net -o none

# Liga as zonas de DNS à VNet (para quem está dentro da rede usar esses registros)
az network private-dns link vnet create -g $RG -z privatelink.vaultcore.azure.net -n link-kv --virtual-network $VNET --registration-enabled false -o none
az network private-dns link vnet create -g $RG -z privatelink.blob.core.windows.net -n link-blob --virtual-network $VNET --registration-enabled false -o none

# Registra automaticamente o IP de cada Private Endpoint na sua zona de DNS
az network private-endpoint dns-zone-group create -g $RG --endpoint-name pe-keyvault -n default --private-dns-zone privatelink.vaultcore.azure.net --zone-name kv -o none
az network private-endpoint dns-zone-group create -g $RG --endpoint-name pe-storage -n default --private-dns-zone privatelink.blob.core.windows.net --zone-name blob -o none

# Validação: os dois endpoints devem estar "Approved"
az network private-endpoint list -g $RG --query "[].{Endpoint:name, Status:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status}" -o table

# ---------------------------------------------------------------------
# 6. ACR, IDENTIDADE GERENCIADA E PERMISSÕES MÍNIMAS
# ---------------------------------------------------------------------

# Cria o registro de imagens com o usuário admin desligado (acesso só por identidade)
az acr create -g $RG -n $ACR -l $LOC --sku Basic --admin-enabled false -o none
$ACR_SERVER = az acr show -g $RG -n $ACR --query loginServer -o tsv
$ACR_ID = az acr show -g $RG -n $ACR --query id -o tsv

# Copia a imagem oficial do Azure CLI para o ACR como "processador:v1"
az acr import --name $ACR --source mcr.microsoft.com/azure-cli:latest --image processador:v1

# Cria a identidade gerenciada (o "crachá" do processador, sem senha)
az identity create -g $RG -n $MI -l $LOC -o none
$MI_ID = az identity show -g $RG -n $MI --query id -o tsv
$MI_PRINCIPAL = az identity show -g $RG -n $MI --query principalId -o tsv
$MI_CLIENT = az identity show -g $RG -n $MI --query clientId -o tsv

# Permissão 1: baixar a imagem do ACR
az role assignment create --assignee-object-id $MI_PRINCIPAL --assignee-principal-type ServicePrincipal --role AcrPull --scope $ACR_ID -o none

# Permissão 2: apenas LER segredos do Key Vault
az role assignment create --assignee-object-id $MI_PRINCIPAL --assignee-principal-type ServicePrincipal --role "Key Vault Secrets User" --scope $KV_ID -o none

# Permissão 3: escrever blobs SOMENTE no container "relatorios" (menor privilégio)
az role assignment create --assignee-object-id $MI_PRINCIPAL --assignee-principal-type ServicePrincipal --role "Storage Blob Data Contributor" --scope "$ST_ID/blobServices/default/containers/relatorios" -o none

# Validação: funções e escopos da identidade
az role assignment list --assignee $MI_PRINCIPAL --all --query "[].{Funcao:roleDefinitionName, Escopo:scope}" -o table

# ---------------------------------------------------------------------
# 7. AMBIENTE E JOB PROCESSADOR
# ---------------------------------------------------------------------

# A assinatura de estudante permite só 1 Container Apps Environment: deve vir vazio
az containerapp env list -o table

# Log Analytics: guarda os logs do ambiente
az monitor log-analytics workspace create -g $RG -n $LOGS -l $LOC -o none
$WS_CLIENTE = az monitor log-analytics workspace show -g $RG -n $LOGS --query customerId -o tsv
$WS_CHAVE = az monitor log-analytics workspace get-shared-keys -g $RG -n $LOGS --query primarySharedKey -o tsv

# Cria o Container Apps Environment dentro da sub-rede privada (5 a 15 minutos)
$SUB_APPS_ID = az network vnet subnet show -g $RG --vnet-name $VNET -n $SUB_APPS --query id -o tsv
az containerapp env create -g $RG -n $ENV_CA -l $LOC --infrastructure-subnet-resource-id $SUB_APPS_ID --logs-workspace-id $WS_CLIENTE --logs-workspace-key $WS_CHAVE -o none

# Gera o job.yaml a partir do modelo (job.template.yaml) com os nomes reais
$ENV_ID = az containerapp env show -g $RG -n $ENV_CA --query id -o tsv
$modelo = Get-Content -Raw -Path "job.template.yaml"
$conteudo = $modelo.Replace('__LOC__',$LOC).Replace('__MI_ID__',$MI_ID).Replace('__ENV_ID__',$ENV_ID).Replace('__ACR__',$ACR_SERVER).Replace('__KV__',$KV).Replace('__ST__',$ST).Replace('__CLIENT__',$MI_CLIENT)
[System.IO.File]::WriteAllText("$PWD\job.yaml", $conteudo)

# Cria o Job (gatilho manual) a partir do YAML
az containerapp job create -g $RG -n $JOB --yaml job.yaml -o none
az containerapp job show -g $RG -n $JOB --query "{Job:name, Gatilho:properties.configuration.triggerType, Estado:properties.provisioningState}" -o table

# ---------------------------------------------------------------------
# 8. DEMONSTRAÇÃO
# ---------------------------------------------------------------------

# DE FORA (seu computador, pela internet): o esperado é ACESSO NEGADO
az keyvault secret show --vault-name $KV --name ChaveSistemaExterno --query value -o tsv
az storage blob list --account-name $ST -c relatorios --auth-mode login -o table

# DE DENTRO (o Job na rede privada): dispara e acompanha os logs ao vivo
az containerapp job start -g $RG -n $JOB -o none
Start-Sleep -Seconds 20
az containerapp job logs show -g $RG -n $JOB --container processador --follow

# Status das execuções (o esperado é Succeeded)
az containerapp job execution list -g $RG -n $JOB --query "[].{Execucao:name, Status:properties.status}" -o table

# ---------------------------------------------------------------------
# 9. VALIDAÇÃO FINAL E LIMPEZA
# ---------------------------------------------------------------------

# Lista todos os recursos criados
az resource list -g $RG --query "[].{Nome:name, Tipo:type}" -o table

# Apaga tudo para não gerar custo (rode só no final)
# az group delete --name $RG --yes --no-wait
