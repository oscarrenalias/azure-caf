set -euo pipefail

source config/global.env

# Register all resource providers required by this repo and wait for completion
PROVIDERS=(
  Microsoft.Storage
  Microsoft.Network
  Microsoft.Compute
  Microsoft.Web
  Microsoft.CognitiveServices
  Microsoft.ManagedIdentity
  Microsoft.Authorization
  Microsoft.App
)

echo "=== Registering resource providers ==="
for ns in "${PROVIDERS[@]}"; do
  state=$(az provider show --namespace "$ns" --query registrationState -o tsv 2>/dev/null || echo "Unknown")
  if [[ "$state" != "Registered" ]]; then
    echo "Registering $ns..."
    az provider register --namespace "$ns"
  else
    echo "$ns: already registered"
  fi
done

echo "Waiting for all providers to reach Registered state..."
for ns in "${PROVIDERS[@]}"; do
  while true; do
    state=$(az provider show --namespace "$ns" --query registrationState -o tsv)
    if [[ "$state" == "Registered" ]]; then
      echo "$ns: Registered"
      break
    fi
    echo "$ns: $state — waiting..."
    sleep 5
  done
done

echo ""
echo "=== Creating resource groups ==="
az group create --name rgstate$NUMBER --location $LOCATION --output table
az group create --name rgmi$NUMBER --location $LOCATION --output table

echo ""
echo "=== Creating storage account and container for Terraform state ==="
az storage account create \
  --name sa$NUMBER \
  --resource-group rgstate$NUMBER \
  --location $LOCATION \
  --sku Standard_LRS \
  --output table

az storage container create \
  --name state \
  --account-name sa$NUMBER \
  --auth-mode login

echo ""
echo "=== Creating managed identity ==="
idplatform=$(az identity create --name mihubspoke$NUMBER --resource-group rgmi$NUMBER --query "principalId" -o tsv)
idplatformclientid=$(az identity show -g rgmi$NUMBER -n mihubspoke$NUMBER --query "clientId" -o tsv)

subscriptionid=$(az account show --query id -o tsv)

echo ""
echo "=== Assigning Owner role to managed identity at subscription scope ==="
az role assignment create \
  --assignee-object-id $idplatform \
  --assignee-principal-type ServicePrincipal \
  --role "Owner" \
  --scope "/subscriptions/$subscriptionid" \
  --output table

echo ""
echo "=== Creating OIDC federated credential for GitHub Actions ==="
# GitHub Actions OIDC tokens include numeric user/repo IDs in the subject:
# repo:<username>@<user_id>/<reponame>@<repo_id>:ref:refs/heads/main
GH_USER=$(echo "$GITHUB_REPO" | cut -d/ -f1)
GH_REPO_NAME=$(echo "$GITHUB_REPO" | cut -d/ -f2)
GH_USER_ID=$(gh api user --jq '.id')
GH_REPO_ID=$(gh api "repos/${GITHUB_REPO}" --jq '.id')
OIDC_SUBJECT="repo:${GH_USER}@${GH_USER_ID}/${GH_REPO_NAME}@${GH_REPO_ID}:ref:refs/heads/main"
echo "OIDC subject: $OIDC_SUBJECT"

az identity federated-credential create --name "github" \
  --identity-name mihubspoke$NUMBER -g rgmi$NUMBER \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "$OIDC_SUBJECT" \
  --audiences "api://AzureADTokenExchange"

echo ""
echo "=== Bootstrap complete ==="
echo "Copy the following values into config/global.env (outputs section):"
echo ""
echo "ARM_CLIENT_ID=$idplatformclientid"
echo "ARM_TENANT_ID=$(az account show --query tenantId -o tsv)"
echo "ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)"
echo "STORAGE_ACCOUNT_NAME=sa$NUMBER"
echo "STORAGE_RESOURCE_GROUP=rgstate$NUMBER"
echo ""
echo "Also ensure config/global.tfvars has:"
echo "number = $NUMBER"
