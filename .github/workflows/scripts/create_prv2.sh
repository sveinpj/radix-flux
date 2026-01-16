#!/usr/bin/env bash

# Documentation about this script can be found here:
# https://github.com/equinor/radix-private/blob/master/docs/radix-platform/flux.md
# Please update the documentation if any changes are made to this script.

MAX_RETRIES=3

function create-pr() {
    pr_branch=$1
    pr_name=$2
    retry_nr=$3
    sleep_before_retry=$(($retry_nr * 2))

    if [[ $(git fetch origin && git branch --remotes) == *"origin/${pr_branch}"* ]]; then
        git switch "${pr_branch}"
        git pull
        PR_STATE=$(gh pr view ${pr_branch} --json state --jq '.state')
    else
        PR_STATE="NONEXISTENT"
    fi

    if [[ "${PR_STATE}" != "OPEN" ]]; then
        echo "Create PR: ${pr_name}"
        PR_URL=$(gh pr create --title "${pr_name}" --base master --body "**Automatic Pull Request**")
        if [[ ${PR_URL} ]]; then
            curl --request POST \
                --header 'Content-type: application/json' \
                --data '{"text":"@omnia-radix Please review PR '${PR_URL}'","link_names":1}' \
                --url ${SLACK_WEBHOOK_URL} \
                --fail
            return 0
        elif [ "$retry_nr" -lt $MAX_RETRIES ]; then
            sleep $sleep_before_retry
            create-pr "${pr_branch}" "${pr_name}" $(($retry_nr + 1))
        else
            curl --request POST \
                --header 'Content-type: application/json' \
                --data '{"text":"@omnia-radix Creating PR '${pr_name}' from '${GITHUB_REF_NAME}' to master failed. https://github.com/'${GITHUB_REPOSITORY}'/actions/runs/'${GITHUB_RUN_ID}'","link_names":1}' \
                --url ${SLACK_WEBHOOK_URL}
            return 1
        fi
    else
        echo "PR already exists and is open: ${pr_name}"
        return 0
    fi
}

function get-changed-versions() {
    # Get the diff between master and base branch
    git diff origin/master "${PR_BRANCH}" > /tmp/full_diff.txt
    
    # Parse diff to find version changes
    # Look for lines like: +BLOB_CSI_DRIVER=1.27.1 or -BLOB_CSI_DRIVER=1.27.0
    # or version: 1.2.3 in YAML files
    
    declare -A version_map
    
    # Pattern 1: Environment variable style (VAR_NAME=version)
    while IFS= read -r line; do
        if [[ "$line" =~ ^\+[[:space:]]*([A-Z_]+)=([0-9]+\.[0-9]+\.[0-9]+) ]]; then
            var_name="${BASH_REMATCH[1]}"
            var_version="${BASH_REMATCH[2]}"
            version_map["${var_name}"]="${var_version}"
        fi
    done < /tmp/full_diff.txt
    
    # Output format: VAR_NAME:VERSION
    for var in "${!version_map[@]}"; do
        echo "${var}:${version_map[$var]}"
    done
}

function get-files-with-version-change() {
    var_name=$1
    
    # Get all changed files
    changed_files=$(git diff --name-only origin/master "${PR_BRANCH}")
    
    # Check which files contain this variable
    result_files=""
    while IFS= read -r file; do
        if [[ -n "$file" && -f "$file" ]]; then
            # Check if this file has changes to this variable
            file_diff=$(git diff origin/master "${PR_BRANCH}" -- "$file")
            if echo "$file_diff" | grep -q "^\+.*${var_name}"; then
                result_files="${result_files}${file}\n"
            fi
        fi
    done <<< "$changed_files"
    
    echo -e "$result_files"
}

function create-version-branch() {
    var_name=$1
    var_version=$2
    base_branch=$3
    version_branch="${base_branch}-${var_name}"
    
    # Get files that contain this version change
    version_files=$(get-files-with-version-change "$var_name")
    
    if [[ -z "$version_files" ]]; then
        echo ""
        return
    fi
    
    # Delete the branch if it exists locally
    git branch -D "${version_branch}" 2>/dev/null || true
    
    # Create a new branch from master
    git switch master
    git pull origin master
    git switch -c "${version_branch}"
    
    # For each file, apply only the changes related to this variable
    echo -e "$version_files" | while IFS= read -r file; do
        if [[ -n "$file" && -f "$file" ]]; then
            # Get the full diff for this file
            git diff origin/master "${base_branch}" -- "$file" > /tmp/file_diff.txt
            
            # Try to extract only lines related to this variable
            # For simplicity, we'll check out the entire file if it contains the variable
            if grep -q "${var_name}" /tmp/file_diff.txt; then
                git checkout "${base_branch}" -- "$file" 2>/dev/null || true
            fi
        fi
    done
    
    # Check if there are any changes to commit
    if [[ -n $(git status --porcelain) ]]; then
        git add .
        git commit -m "Update ${var_name} to ${var_version}"
        git push -f origin "${version_branch}"
        echo "${version_branch}"
    else
        echo ""
    fi
}

function create-common-branch() {
    base_branch=$1
    common_branch="${base_branch}-common"
    
    # Get all version variables that have their own PRs
    version_changes=$(get-changed-versions)
    
    # Get all changed files
    changed_files=$(git diff --name-only origin/master "${base_branch}")
    
    # Find files that don't contain any of the version variables
    common_files=""
    while IFS= read -r file; do
        if [[ -n "$file" && -f "$file" ]]; then
            file_diff=$(git diff origin/master "${base_branch}" -- "$file")
            has_version_var=false
            
            while IFS=: read -r var_name var_version; do
                if [[ -n "$var_name" ]] && echo "$file_diff" | grep -q "^\+.*${var_name}"; then
                    has_version_var=true
                    break
                fi
            done <<< "$version_changes"
            
            if [[ "$has_version_var" == "false" ]]; then
                common_files="${common_files}${file}\n"
            fi
        fi
    done <<< "$changed_files"
    
    if [[ -z "$common_files" ]]; then
        echo ""
        return
    fi
    
    # Delete the branch if it exists locally
    git branch -D "${common_branch}" 2>/dev/null || true
    
    # Create a new branch from master
    git switch master
    git pull origin master
    git switch -c "${common_branch}"
    
    # Check out only common files
    echo -e "$common_files" | while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            git checkout "${base_branch}" -- "$file" 2>/dev/null || true
        fi
    done
    
    # Check if there are any changes to commit
    if [[ -n $(git status --porcelain) ]]; then
        git add .
        git commit -m "Update common infrastructure"
        git push -f origin "${common_branch}"
        echo "${common_branch}"
    else
        echo ""
    fi
}

# Main execution
if [[ -z "${PR_BRANCH}" ]]; then
    PR_BRANCH="flux-image-updates"
fi

# First, switch to the base branch to check what has changed
git fetch origin
if [[ $(git branch --remotes) == *"origin/${PR_BRANCH}"* ]]; then
    git switch "${PR_BRANCH}"
    git pull
else
    echo "Base branch ${PR_BRANCH} does not exist, exiting"
    exit 0
fi

# Get list of all version changes
version_changes=$(get-changed-versions)

if [[ -n "$version_changes" ]]; then
    echo "Found version changes:"
    echo "$version_changes"
    
    # Create PR for each version change
    while IFS=: read -r var_name var_version; do
        if [[ -n "$var_name" && -n "$var_version" ]]; then
            echo "Processing version: ${var_name} ${var_version}"
            version_branch=$(create-version-branch "${var_name}" "${var_version}" "${PR_BRANCH}")
            
            if [[ -n "${version_branch}" ]]; then
                pr_name="Automatic PR - ${var_name}: ${var_version}"
                create-pr "${version_branch}" "${pr_name}" 0
            fi
        fi
    done <<< "$version_changes"
fi

# Create PR for any remaining changes (files without version variables)
echo "Processing remaining changes"
common_branch=$(create-common-branch "${PR_BRANCH}")

if [[ -n "${common_branch}" ]]; then
    pr_name="Automatic PR - Other changes"
    create-pr "${common_branch}" "${pr_name}" 0
else
    # If no common changes and no version changes, create the standard PR
    if [[ -z "$version_changes" ]]; then
        echo "No version-specific changes found, creating standard PR"
        pr_name="Automatic Pull Request"
        create-pr "${PR_BRANCH}" "${pr_name}" 0
    fi
fi
