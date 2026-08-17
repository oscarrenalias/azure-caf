# caf

- install azure cli
- authenticate
- set your azure subscription with `az account set -s <guid>`
- choose a random number in `bootstrap.sh`
- update the gh org number and gh repo number in bootstrap.sh in the federated credential section
- run `bootstrap.sh`
- overwrite the environment variables in `global.env` & `global.tfvars` in the repo from the output
- update your ssh_public_key in global.tfvars 
- go to github, settings, actions, runners, choose 'new self hosted runner' - copy the token from the script and add a repository secret named `GH_RUNNER_PAT`
- update your private IP in vm.tf in the rule1 nsg
- run the workflow `terraform.yml`
- you can ssh to the public vm (jump host) 

## todo


- application gateway


