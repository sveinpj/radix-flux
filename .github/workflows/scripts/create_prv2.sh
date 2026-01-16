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

function get-changed-components() {
    # Get all changed files in components/radix-platform
    changed_files=$(git diff --name-only origin/master)
    
    # Extract unique component names from changed files
    components=$(echo "$changed_files" | grep "^components/radix-platform/" | cut -d'/' -f3 | sort -u)
    
    echo "$components"
}

function create-component-branch() {
    component=$1
    base_branch=$2
    component_branch="${base_branch}-${component}"
    
    # Switch back to the base branch
    git switch "${base_branch}"
    
    # Create a new branch for this component
    git switch -c "${component_branch}"
    
    # Cherry-pick only the changes for this component
    git diff origin/master -- "components/radix-platform/${component}" | git apply --index
    
    # Check if there are any changes to commit
    if [[ -n $(git status --porcelain) ]]; then
        git add "components/radix-platform/${component}"
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
    
    # Switch back to the base branch
    git switch "${base_branch}"
    
    # Create a new branch for common changes
    git switch -c "${common_branch}"
    
    # Get all components that will have their own PRs
    components=$(get-changed-components)
    
    # Reset to match origin/master
    git reset --hard origin/master
    
    # Apply all changes from base branch except component-specific ones
    git diff origin/master "${base_branch}" -- . \
        $(for comp in $components; do echo ":(exclude)components/radix-platform/${comp}"; done) \
        | git apply --index
    
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

# Get list of changed components
components=$(get-changed-components)

if [[ -n "$components" ]]; then
    echo "Found changed components:"
    echo "$components"
    
    # Create PR for each component
    for component in $components; do
        echo "Processing component: ${component}"
        component_branch=$(create-component-branch "${component}" "${PR_BRANCH}")
        
        if [[ -n "${component_branch}" ]]; then
            pr_name="Automatic PR - ${component}"
            create-pr "${component_branch}" "${pr_name}" 0
        fi
    done
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
