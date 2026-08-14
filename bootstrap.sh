
export location="swedencentral"
export number=15712567827395

az group create --name rgstate$number --location $location
az group create --name rgmi$number --location $location

az storage account create --name sa$number --resource-group rgstate$number --location $location --sku Standard_LRS
az storage container create --name state --account-name sa$number


idplatform=$(az identity create --name mihubspoke$number --resource-group rgmi$number --query "principalId" -o tsv)
idplatformclientid=$(az identity show -g rgmi$number -n mihubspoke$number --query "clientId" -o tsv)

subscriptionid=$(az account show| jq -r '.id')

az role assignment create --assignee-object-id $idplatform --assignee-principal-type ServicePrincipal --role "Owner" --scope "/subscriptions/$subscriptionid"

az identity federated-credential create --name "github" \
  --identity-name mihubspoke$number -g rgmi$number \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "repo:tvdvoorde@28575822/caf@1334094652:ref:refs/heads/main" \
  --audiences "api://AzureADTokenExchange"

echo ARM_CLIENT_ID=$idplatformclientid
echo ARM_TENANT_ID=$(az account show --query tenantId -o tsv)
echo ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
echo STORAGE_ACCOUNT_NAME=sa$number
echo STORAGE_RESOURCE_GROUP=rgstate$number
echo "number = $number"
