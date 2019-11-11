#!/bin/bash

# A script that uses configurator to create a YAML file, and then pushes that
# YAML file to k8s/test-infra's config/testgrids directory
#
# Used by teams that host different instances of Prow, but want to show their
# results on testgrid.k8s.io
#

set -o errexit
set -o nounset
set -o pipefail

main() {
  branch="transfigure-branch"

  if [[ $# -lt 5 ]]; then
    echo "Usage: $(basename "$0") [github_token] [prow_config] [prow_job_config] [testgrid_yaml] [repo_subdir] (remote_fork_repo)" >&2
    echo "All [] arguments are required paths" >&2
    exit 1
  fi

  parse-args "$@"
  user-from-token
  email-from-token

  echo "Ensuring kubernetes/test-infra repo"
  if [[ -d test-infra ]]; then
    echo "Directory 'test-infra' found; using as kubernetes/test-infra repository"
  else
    #TODO(chases2): Clone only the test-infra/config/testgrids subdirectory used
    git clone https://github.com/kubernetes/test-infra.git
    trap "cleanup-repository" EXIT
    echo "Created temporary repository"
  fi

  k8s_repo=$(readlink -f test-infra)
  testgrid_dir=$(readlink -f "test-infra/config/testgrids")

  echo "Checking out ${branch}"
  cd "${k8s_repo}"
  git checkout -B "${branch}"
  ensure-git-config

  if [[ ! -d "${testgrid_dir}/${testgrid_subdir}" ]]; then
    echo "Subdirectory ${testgrid_subdir} doesn't exist; creating it" >&2
    mkdir -p "${testgrid_dir}/${testgrid_subdir}"
  fi

  echo "Generating testgrid yaml"
  /configurator \
    --prow-config "${prow_config}" \
    --prow-job-config "${job_config}" \
    --output-yaml \
    --yaml "${testgrid_config}" \
    --oneshot \
    --output "${testgrid_dir}/${testgrid_subdir}/gen-config.yaml"

  git add --all

  if ! git diff --quiet ; then
    echo "Transfigure did not change anything. Aborting no-op bump"
    exit 0
  fi

  title="Update TestGrid for ${testgrid_subdir}"
  git commit -m "${title}"
  echo "Pushing commit to ${user}/${remote_fork_repo}:${branch}..."
  git push -f "https://${user}:$(cat "${token}")@github.com/${user}/${remote_fork_repo}" "HEAD:${branch}"

  echo "Creating PR to merge ${user}:${branch} into k8s/test-infra:master..."
  /pr-creator \
    --github-token-path="${token}" \
    --org="kubernetes" --repo="test-infra" --branch=master \
    --title="${title}" --match-title="${title}" \
    --body="Generated by transfigure.sh" \
    --source="${user}:${branch}" \
    --confirm

  echo "PR created successfully!"
  return 0
}

parse-args() {
  token=$(readlink -m "$1")
  prow_config=$(readlink -m "$2")
  job_config=$(readlink -m "$3")
  testgrid_config=$(readlink -m "$4")
  testgrid_subdir="$5"
  remote_fork_repo=${6:-"test-infra"}

  if [[ ! -f ${token} ]]; then
    echo "ERROR: [github_token] ${token} must be a file path." >&2
    exit 1
  elif [[ ! -f "${prow_config}" ]]; then
    echo "ERROR: [prow_config] ${prow_config} must be a file path." >&2
    exit 1
  elif [[ ! -e "${job_config}" ]]; then
    echo "ERROR: [prow_job_config] ${job_config} must exist." >&2
    exit 1
  elif [[ ! -e "${testgrid_config}" ]]; then
    echo "ERROR: [testgrid_yaml] ${testgrid_config} must exist." >&2
    exit 1
  elif [[ -z "${testgrid_subdir}" ]]; then
    echo "ERROR: [repo_subdir] must be specified." >&2
    exit 1
  elif [[ -z "${remote_fork_repo}" ]]; then
    echo "ERROR: [remote_fork_repo] cannot be empty" >&2
    exit 1
  fi
}

user-from-token() {
  user=$(curl -H "Authorization: token $(cat "${token}")" "https://api.github.com/user" 2>/dev/null | sed -n "s/\s\+\"login\": \"\(.*\)\",/\1/p")
  echo "Using user from GitHub: ${user}"
}

email-from-token() {
  email=$(curl -H "Authorization: token $(cat "${token}")" "https://api.github.com/user" 2>/dev/null | sed -n "s/\s\+\"email\": \"\(.*\)\",/\1/p")
  echo "Using email from GitHub: ${email}"
}

cleanup-repository() {
  echo "Cleaning temporary repository at ${k8s_repo}"
  cd ..
  rm -rf "${k8s_repo}"
}

ensure-git-config() {
  git config user.name ${user}
  git config user.email ${email}

  git config user.name &>/dev/null && git config user.email &>/dev/null && return 0
  echo "ERROR: git config user.name, user.email unset. No defaults provided" >&2
  return 1
}

main "$@"