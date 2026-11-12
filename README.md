# Cofre Digital Seguro — Azure

Projeto da disciplina de Cloud Computing (FIAP), baseado no laboratório **lab-popovici-01**.
**Autor:** Gabriel Lamata — RM562093

Um processador automático (Azure Container Apps Job) lê uma credencial do **Key Vault** e grava um relatório no **Storage**, **sem nenhuma senha no código** e **sem expor nada na internet**. O Key Vault e o Storage ficam com o acesso público desabilitado e só respondem pela rede privada, por meio de **Private Endpoints**.

## Arquitetura

```
            Internet (acesso público bloqueado)
                         |
+---------------- VNet cofre-vnet (10.80.0.0/16) ----------------+
|  snet-apps (delegada)            snet-private-endpoints        |
|  +----------------------+        +------------------------+    |
|  | Container Apps Env   |------->| Private Endpoint KV    |----+--> Key Vault (RBAC)
|  |  Job "processador"   |        | Private Endpoint Blob  |----+--> Storage (relatorios)
|  +----------^-----------+        +------------------------+    |
+-------------|---------------------------------------------------+
         ACR (imagem via Managed Identity)        Log Analytics (logs)
```

## Conceitos aplicados

| Conceito | Como aparece no projeto |
|---|---|
| Managed Identity | o processador faz login sem senha |
| RBAC e menor privilégio | só AcrPull, Key Vault Secrets User e Blob Data Contributor **restrito ao container `relatorios`** |
| Key Vault | guarda a credencial, com acesso público desabilitado |
| Storage | recebe os relatórios, com acesso público desabilitado e TLS 1.2 |
| Private Endpoints + DNS privado | Key Vault e Storage acessados por IPs 10.80.2.x, dentro da VNet |
| ACR | imagem baixada pela identidade, usuário admin desligado |
| VNet com subnets delegadas | isolamento da aplicação |
| Container Apps Jobs | execução sob demanda (gatilho manual) |
| Log Analytics | evidência da execução |

## Arquivos

| Arquivo | Descrição |
|---|---|
| `cofre-seguro.ps1` | todos os comandos, em ordem, com comentários explicando cada um |
| `job.template.yaml` | modelo do Job; o script gera o `job.yaml` com os nomes reais |

## Pré-requisitos

- Azure CLI instalado (`winget install -e --id Microsoft.AzureCLI`)
- PowerShell (testado no terminal do VS Code)
- Assinatura Azure (testado em **Azure for Students**, região `canadacentral`)
- Nenhum Container Apps Environment existente na assinatura (a de estudante permite só 1)

## Como executar

Abra o terminal **na pasta do repositório** e rode os blocos do `cofre-seguro.ps1` **um por vez, no mesmo terminal** (as variáveis ficam na sessão).

### Etapas e comandos

| # | Etapa | Principais comandos | O que fazem |
|---|---|---|---|
| 1 | Preparação | `az login`, `az extension add`, `az group create` | Login, extensão de Container Apps, variáveis e Resource Group |
| 2 | Rede | `az network vnet create`, `az network vnet subnet create` | VNet e duas subnets: `snet-apps` (delegada) e `snet-private-endpoints` |
| 3 | Key Vault | `az keyvault create`, `az role assignment create`, `az keyvault secret set`, `az keyvault update --public-network-access Disabled` | Cria o cofre com RBAC, grava a `ChaveSistemaExterno` e tranca o acesso público |
| 4 | Storage | `az storage account create --public-network-access Disabled`, `az storage container-rm create` | Storage já trancado e container `relatorios` |
| 5 | Private Endpoints | `az network private-endpoint create`, `az network private-dns zone create`, `... link vnet create`, `... dns-zone-group create` | Portas privadas e DNS privado para Key Vault e Storage |
| 6 | ACR e identidade | `az acr create`, `az acr import`, `az identity create`, `az role assignment create` | Imagem `processador:v1`, identidade gerenciada e as 3 permissões mínimas |
| 7 | Ambiente e Job | `az containerapp env create`, `az containerapp job create --yaml` | Ambiente na subnet privada e Job com gatilho manual |
| 8 | Demonstração | `az keyvault secret show`, `az storage blob list`, `az containerapp job start`, `az containerapp job logs show --follow` | De fora: acesso negado. De dentro: o Job conclui tudo |
| 9 | Validação e limpeza | `az resource list`, `az group delete` | Lista os recursos e apaga o ambiente |

## Resultado esperado

**De fora (seu computador):** as leituras do Key Vault e do Storage são **negadas**.

**De dentro (logs do Job):**

```
[COFRE] Processador seguro iniciado
[COFRE] DNS Key Vault: 10.80.2.4  cofre-kv-XXXX.privatelink.vaultcore.azure.net
[COFRE] DNS Storage:   10.80.2.5  cofrestXXXX.privatelink.blob.core.windows.net
[COFRE] Login com Managed Identity OK (nenhuma senha usada)
[COFRE] Credencial lida do Key Vault (28 caracteres, valor nao exibido)
[COFRE] Relatorio gravado no Storage: relatorio-AAAAMMDD-HHMMSS.txt
[COFRE] Processamento concluido com sucesso
```

## Limpeza

```powershell
az group delete --name rg-cofre-seguro-2 --yes --no-wait
```

## Observações

- O valor do segredo no script é apenas de laboratório.
- O `job.yaml` gerado está no `.gitignore`, porque contém IDs da assinatura.
