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

function get-changed-files-by-component() {
    # Get all changed files between master and base branch
    git diff --name-only origin/master "${PR_BRANCH}"
}

function extract-component-from-path() {
    filepath=$1
    
    # Try to extract component name from path patterns
    # Pattern 1: components/radix-platform/{component}/
    if [[ "$filepath" =~ ^components/radix-platform/([^/]+)/ ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Pattern 2: components/flux/{component}/
    if [[ "$filepath" =~ ^components/flux/([^/]+)/ ]]; then
        echo "flux-${BASH_REMATCH[1]}"
        return
    fi
    
    # Pattern 3: components/third-party/{component}/
    if [[ "$filepath" =~ ^components/third-party/([^/]+)/ ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # If not in a component directory, it's common
    echo "COMMON"
}

function get-all-components() {
    changed_files=$(get-changed-files-by-component)
    
    declare -A component_map
    
    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            component=$(extract-component-from-path "$file")
            component_map["$component"]=1
        fi
    done <<< "$changed_files"
    
    # Return all components except COMMON
    for comp in "${!component_map[@]}"; do
        if [[ "$comp" != "COMMON" ]]; then
            echo "$comp"
        fi
    done
}

function get-files-for-component() {
    component=$1
    changed_files=$(get-changed-files-by-component)
    
    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            file_component=$(extract-component-from-path "$file")
            if [[ "$file_component" == "$component" ]]; then
                echo "$file"
            fi
        fi
    done <<< "$changed_files"
}

function create-component-branch() {
    component=$1
    base_branch=$2
    component_branch="${base_branch}-${component}"
    
    # Get files for this component
    component_files=$(get-files-for-component "$component")
    
    if [[ -z "$component_files" ]]; then
        echo ""
        return
    fi
    
    # Delete the branch if it exists locally
    git branch -D "${component_branch}" 2>/dev/null || true
    
    # Create a new branch from master
    git switch master
    git pull origin master
    git switch -c "${component_branch}"
    
    # Check out only the component files from the base branch
    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            git checkout "${base_branch}" -- "$file" 2>/dev/null || true
        fi
    done <<< "$component_files"
    
    # Check if there are any changes to commit
    if [[ -n $(git status --porcelain) ]]; then
        git add .
        git commit -m "Update ${component}"
        git push -f origin "${component_branch}"
        echo "${component_branch}"
    else
        echo ""
    fi
}

function create-common-branch() {
    base_branch=$1
    common_branch="${base_branch}-common"
    
    # Get all changed files
    changed_files=$(get-changed-files-by-component)
    
    # Get files that belong to COMMON
    common_files=""
    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            file_component=$(extract-component-from-path "$file")
            if [[ "$file_component" == "COMMON" ]]; then
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
    
    # Check out only common files from the base branch
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

# Get list of all unique components with changes
components=$(get-all-components | sort -u)

if [[ -n "$components" ]]; then
    echo "Found changed components:"
    echo "$components"
    
    # Create PR for each component
    while IFS= read -r component; do
        if [[ -n "$component" ]]; then
            echo "Processing component: ${component}"
            component_branch=$(create-component-branch "${component}" "${PR_BRANCH}")
            
            if [[ -n "${component_branch}" ]]; then
                pr_name="Automatic PR - ${component}"
                create-pr "${component_branch}" "${pr_name}" 0
            fi
        fi
    done <<< "$components"
fi

# Create PR for common changes (everything except component-specific changes)
echo "Processing common changes"
common_branch=$(create-common-branch "${PR_BRANCH}")

if [[ -n "${common_branch}" ]]; then
    pr_name="Automatic PR - Common"
    create-pr "${common_branch}" "${pr_name}" 0
else
    # If no common changes but no components either, create the standard PR
    if [[ -z "$components" ]]; then
        echo "No component-specific changes found, creating standard PR"
        pr_name="Automatic Pull Request"
        create-pr "${PR_BRANCH}" "${pr_name}" 0
    fi
fi
