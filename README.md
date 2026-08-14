# caf

- install azure cli
- authenticate
- set your azure subscription with `az account set -s <guid>`
- choose a random number in `bootstrap.sh`
- update the gh org number and gh repo number in bootstrap.sh in the federated credential section
- run `bootstrap.sh`
- overwrite the environment variables in `global.env` & `global.tfvars` in the repo from the output
- run the workflow `terraform.yml`

## todo

- https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners
- app service
- private endpoint
- application gateway


