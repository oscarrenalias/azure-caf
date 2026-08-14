# caf

```bash

export location="swedencentral"
export number=1000

az group 

az storage account create --name sa$number --resource-group rgstate$number --location $location --sku Standard_LRS
az storage container create --name state --account-name sa$number

idrgstate=$(az group create -g rgstate$number --location $location --query "id" -o tsv)
idrgidentity=$(az group create -g rgidentity$number --location $location --query "id" -o tsv)
idrgplatform=$(az group create -g rgplatform$number --location $location --query "id" -o tsv)

# platform

idplatform=$(az identity create --name miplatform$number --resource-group rgidentity$number --query "principalId" -o tsv)
idplatformclientid=$(az identity show -g rgidentity$number -n miplatform$number --query "clientId" -o tsv)
az role assignment create --assignee-object-id $idplatform --role "Contributor" --scope $idrgstate
az role assignment create --assignee-object-id $idplatform --role "Reader" --scope $idrgidentity
az role assignment create --assignee-object-id $idplatform --role "Owner" --scope $idrgplatform
az identity federated-credential create --name "github" --identity-name miplatform$number -g rgidentity$number --issuer "https://token.actions.githubusercontent.com" --subject "repo:tvdvoorde/secureaks:ref:refs/heads/main" --audiences "api://AzureADTokenExchange"

# admin

idadmin=$(az identity create --name miadmin$number --resource-group rgidentity$number --query "principalId" -o tsv)
idadminclientid=$(az identity show -g rgidentity$number -n miadmin$number --query "clientId" -o tsv)
az role assignment create --assignee-object-id $idadmin --role "Contributor" --scope $idrgplatform
az role assignment create --assignee-object-id $idadmin --role "Azure Kubernetes Service RBAC Cluster Admin" --scope $idrgplatform
az identity federated-credential create --name "github" --identity-name miadmin$number -g rgidentity$number --issuer "https://token.actions.githubusercontent.com" --subject "repo:tvdvoorde/secureaks:ref:refs/heads/main" --audiences "api://AzureADTokenExchange"

# developer

iddeveloper=$(az identity create --name mideveloper$number --resource-group rgidentity$number --query "principalId" -o tsv)
iddeveloperclientid=$(az identity show -g rgidentity$number -n mideveloper$number --query "clientId" -o tsv)
az role assignment create --assignee-object-id $iddeveloper --role "Reader" --scope $idrgplatform
az role assignment create --assignee-object-id $iddeveloper --role "Azure Kubernetes Service RBAC Reader" --scope $idrgplatform
az role assignment create --assignee-object-id $iddeveloper --role "Azure Kubernetes Service Cluster User Role" --scope $idrgplatform
az identity federated-credential create --name "github" --identity-name mideveloper$number -g rgidentity$number --issuer "https://token.actions.githubusercontent.com" --subject "repo:tvdvoorde/secureaks:ref:refs/heads/main" --audiences "api://AzureADTokenExchange"

echo "PLATFORM CLENT ID: $idplatformclientid"
echo "ADMIN CLENT ID: $idadminclientid"
echo "DEVELOPER CLIENT ID:" $iddeveloperclientid

# az role assignment create --role "Azure Kubernetes Service RBAC Reader" --assignee <AAD-ENTITY-ID> --scope $AKS_ID/namespaces/<namespace-name>




```

