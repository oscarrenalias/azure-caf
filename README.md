# caf

- install azure cli
- authenticate
- set your azure subscription with `az account set -s <guid>`
- choose a random number in `bootstrap.sh`
- update the gh org number and gh repo number in bootstrap.sh in the federated credential section
- run `bootstrap.sh`
- overwrite the environment variables in `global.env` & `global.tfvars` in the repo from the output
- update your ssh_public_key in global.tfvars
- add a repository secret named `GH_RUNNER_PAT` containing a fine-grained GitHub PAT with repository Administration read/write access
- run the workflow `terraform.yml`

## todo

- app service
- private endpoint
- application gateway


