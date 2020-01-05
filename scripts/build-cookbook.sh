#!/bin/bash

root_dir=$(pwd)
home_dir=${root_dir}/cookbook

set -e

usage () {
  echo -e "\nUSAGE: build-cookbook.sh -r|--recipe <RECIPE REPO PATH> \\"
  echo -e "    [-b|--git-branch <GIT_BRANCH_NAME>] \\"
  echo -e "    [-n|--name <RECIPE NAME>] [-i|--iaas <TARGET IAAS>] \\"
  echo -e "    [-o|--os-name <TARGET OS>] [-s|--single] [-c|--clean]] [-v|--verbose]\n"
  echo -e "    This utility script packages the terraform recipes or distribution with the service."
  echo -e "    The Terraform recipe should exist under the given repo path within a folder having a"
  echo -e "    <recipe name>/<iaas> folder. The 'recipe', 'name' and 'iaas' options are all required"
  echo -e "    when adding a recipe repo to the distribution.\n"
  echo -e "    -r|--recipe      <RECIPE REPO PATH>  (required) The path to the git repo."
  echo -e "                                         i.e https://github.com/<user>/<repo>/<path>."
  echo -e "    -b|--git-branch  <GIT_BRANCH_NAME>   The branch or tag of the git repository. Default is \"master\"."
  echo -e "    -n|--name        <RECIPE NAME>       The name of the recipe"
  echo -e "    -i|--iaas        <TARGET IAAS>       The target IaaS of this recipe."
  echo -e "    -o|--os-name     <TARGET OS>         The target OS for which recipe plugins should be download."
  echo -e "                                         Should be of \"Darwin\", \"Linux\" or \"Windows\"."
  echo -e "    -s|--single                          Only the recipe indicated shoud be added"
  echo -e "    -c|--clean                           Clean build before proceeding"
  echo -e "    -v|--verbose                         Trace shell execution"
}

recipe_git_branch_or_tag=master
recipe_iaas=""
target_os=$(uname)

if [[ $# -eq 0 ]]; then
  usage 
  exit 1
fi

while [[ $# -gt 0 ]]; do

  case "$1" in
    '-?'|--help|help)
      usage
      exit 0
      ;;
    -r|--recipe)
      recipe_git_project_url=$2
      has_recipe=1
      shift
      ;;
    -b|--git-branch)
      recipe_git_branch_or_tag=$2
      shift
      ;;
    -n|--name)
      recipe_name=$2
      shift
      ;;
    -i|--iaas)
      recipe_iaas=$2
      shift
      ;;
    -o|--os-name)
      target_os=$2
      shift
      ;;
    -s|--single)
      single=1
      ;;
    -c|--clean)
      clean=1
      ;;
    -v|--verbose)
      debug=1
      ;;
    *)
      usage 
      exit 1
      ;;
  esac

  shift
done

[[ -z $debug ]] || set -x

if [[ -z $recipe_git_project_url ]]; then
  usage
  exit 1
fi

current_os=$(echo "$(uname)" | tr '[:upper:]' '[:lower:]')_amd64
target_os=$(echo "$target_os" | tr '[:upper:]' '[:lower:]')_amd64

build_dir=${root_dir}/build
recipe_repo_dir=${build_dir}/repos
dist_dir=${build_dir}/dist
dest_dist_dir=${HOME_DIR:-$home_dir}/dist

[[ -z $clean ]] || (rm -fr $build_dir && rm -fr $dest_dist_dir)

cookbook_bin_dir=${dist_dir}/cookbook/bin
cookbook_plugins_dir=${dist_dir}/cookbook/bin/plugins/${target_os}
mkdir -p $cookbook_plugins_dir

terraform=${cookbook_bin_dir}/terraform
if [[ ! -e $terraform ]]; then

  version=${TERRAFORM_VERSION:-0.12.17}
  if [[ $(uname) == Darwin ]]; then
    DOWNLOAD_URL=https://releases.hashicorp.com/terraform/${version}/terraform_${version}_darwin_amd64.zip
  else
    DOWNLOAD_URL=https://releases.hashicorp.com/terraform/${version}/terraform_${version}_linux_amd64.zip
  fi
  curl -L $DOWNLOAD_URL -o $cookbook_bin_dir/terraform.zip
  
  pushd $cookbook_bin_dir
  unzip terraform.zip
  rm -f terraform.zip  
  popd
fi

cookbook_recipes_dir=${dist_dir}/cookbook/recipes
[[ -z $single ]] || rm -fr $cookbook_recipes_dir

if [[ -n $recipe_git_project_url ]]; then

  if [[ $recipe_git_project_url == https://* ]]; then
    url_path=${recipe_git_project_url#https://*}
  else
    url_path=${recipe_git_project_url#http://*}
  fi
  
  git_server=${url_path%%/*}
  repo_path=${url_path#*/} 

  if [[ $git_server == http* || $repo_path == http* ]]; then
    echo "Unable to determine repo path. Please provide the git server name to allow the path to parsed properly."
    exit 1
  fi

  repo_org=${repo_path%%/*}
  repo_org_path=${repo_path#*/}
  repo_name=${repo_org_path%%/*}
  repo_folder=${repo_path#$repo_org/$repo_name/}

  if [[ -e ${recipe_repo_dir}/${repo_name} ]]; then
    pushd ${recipe_repo_dir}/${repo_name}
    git checkout $recipe_git_branch_or_tag
    git pull
  else
    git clone https://${git_server}/${repo_org}/${repo_name} ${recipe_repo_dir}/${repo_name}
    pushd ${recipe_repo_dir}/${repo_name}
    git checkout $recipe_git_branch_or_tag
  fi
  popd

  recipe_list=${recipe_name:-$(ls ${recipe_repo_dir}/${repo_name}/${repo_folder})}
  for recipe in $recipe_list; do

    iaas_list=${recipe_iaas:-$(ls ${recipe_repo_dir}/${repo_name}/${repo_folder}/${recipe})}
    for iaas in $iaas_list; do
      echo "Adding iaas \"${iaas}\" for recipe \"${recipe}\"..."

      recipe_folder=${recipe_repo_dir}/${repo_name}/${repo_folder}/${recipe}/${iaas}
      if [[ ! -e $recipe_folder ]]; then
        echo -e "\nERROR! Recipe folder '$recipe_folder' does not exist.\n"
        exit 1
      fi

      set +e
      ls $recipe_folder/*.tf >/dev/null 2>&1
      if [[ $? -ne 0 ]]; then
        echo -e "\nERROR! No Terraform templates found at '$recipe_folder'.\n"
        exit 1
      fi
      set -e
      cd 

      # initialize terraform templates in order to 
      # download the dependent plugins and modules
      pushd $recipe_folder
      $terraform init -backend=false
      popd

      # consolidate download terraform plugins in 
      # plugins folder
      pushd $cookbook_plugins_dir
      for f in $(ls ${recipe_folder}/.terraform/plugins/${current_os}/terraform-provider-*); do
        name=$(basename $f)
        name=${name%*_x4}
        provider_name=${name%%_*}
        version=${name#*_}
        version=${version#v*}

        plugin_file_name=${provider_name}_v${version}_x4
        if [[ ! -e ${cookbook_plugins_dir}/${plugin_file_name} ]]; then

          if [[ $target_os == $current_os ]]; then
            cp $f $cookbook_plugins_dir
          else
            curl \
              -L https://releases.hashicorp.com/${provider_name}/${version}/${provider_name}_${version}_${target_os}.zip \
              -o terraform-provider.zip

            unzip terraform-provider.zip
            rm terraform-provider.zip
          fi
        fi
      done
      popd

      rm -fr ${cookbook_recipes_dir}/${recipe}/${iaas}
      mkdir -p ${cookbook_recipes_dir}/${recipe}/${iaas}
      cp -r $recipe_folder ${cookbook_recipes_dir}/${recipe}
      rm -f ${cookbook_recipes_dir}/${recipe}/${iaas}/.terraform/terraform.tfstate
      rm -fr ${cookbook_recipes_dir}/${recipe}/${iaas}/.terraform/plugins
    done
  done
fi

mkdir -p ${dest_dist_dir}
rm -fr ${dest_dist_dir}/cookbook.zip
pushd ${dist_dir}/cookbook
zip -ur ${dest_dist_dir}/cookbook.zip .
stat -t "%s" -f "%Sm" ${dest_dist_dir}/cookbook.zip > ${dest_dist_dir}/cookbook-mod-time
popd
