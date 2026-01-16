#!/usr/bin/env bash

function create-pr() {
    retry_nr=$1
    sleep_before_retry=$(($retry_nr * 2))
    
    if [[ -z "${PR_BRANCH}" ]]; then
        echo "Error: PR_BRANCH not set"
        return 1
    fi

    if [[ -z "${PR_NAME}" ]]; then
        PR_NAME="Automatic Pull Request"
    fi

    if [[ $(git fetch origin && git branch --remotes) == *"origin/${PR_BRANCH}"* ]]; then
        PR_STATE=$(gh pr view ${PR_BRANCH} --json state --jq '.state' 2>/dev/null || echo "NONEXISTENT")
    else
        PR_STATE="NONEXISTENT"
    fi
    
    if [[ "${PR_STATE}" != "OPEN" ]]; then
        echo "Creating PR: ${PR_NAME} from ${PR_BRANCH} to master"
        PR_URL=$(gh pr create --head "${PR_BRANCH}" --title "${PR_NAME}" --base master --body "**Automatic Pull Request**")
        if [[ ${PR_URL} ]]; then
            curl --request POST \
                --header 'Content-type: application/json' \
                --data '{"text":"@omnia-radix Please review PR '${PR_URL}'","link_names":1}' \
                --url ${SLACK_WEBHOOK_URL} \
                --fail
            return 0
        elif [ "$retry_nr" -lt 3 ]; then
            sleep $sleep_before_retry
            create-pr $(($retry_nr + 1))
        else
            curl --request POST \
                --header 'Content-type: application/json' \
                --data '{"text":"@omnia-radix Creating PR '${PR_NAME}' failed. https://github.com/'${GITHUB_REPOSITORY}'/actions/runs/'${GITHUB_RUN_ID}'","link_names":1}' \
                --url ${SLACK_WEBHOOK_URL}
            return 1
        fi
    else
        echo "PR already exists for ${PR_BRANCH}"
        return 0
    fi
}

# Get all version variable changes from flux-image-updates branch
function get-version-changes() {
    git diff origin/master origin/flux-image-updates | grep -E '^\+[[:space:]]*[A-Z_]+=v?[0-9]+\.[0-9]+' | \
        sed -E 's/^\+[[:space:]]*([A-Z_]+)=(v?[0-9]+\.[0-9]+[0-9.]*).*/\1|\2/' | sort -u
}

# Get all files that changed for a specific variable
function get-files-for-variable() {
    local var_name=$1
    git diff --name-only origin/master origin/flux-image-updates | while read -r file; do
        if [[ -n "$file" ]] && git diff origin/master origin/flux-image-updates -- "$file" | grep -q "^+.*${var_name}="; then
            echo "$file"
        fi
    done
}

# Create a new branch for a specific version update (from master, with changes from flux-image-updates)
function create-branch-for-change() {
    local var_name=$1
    local var_version=$2
    local branch_name="flux-image-updates-${var_name}"
    
    echo "Creating branch ${branch_name} for ${var_name}=${var_version}"
    
    # Get files containing this variable change
    local files=$(get-files-for-variable "$var_name")
    
    if [[ -z "$files" ]]; then
        echo "No files found for ${var_name}"
        return 1
    fi
    
    # Create new branch from master
    git checkout master
    git pull origin master
    git checkout -B "${branch_name}"
    
    # Copy only the files with this variable change from flux-image-updates
    echo "$files" | while read -r file; do
        if [[ -n "$file" ]]; then
            git checkout origin/flux-image-updates -- "$file" 2>/dev/null || true
        fi
    done
    
    # Commit and push if there are changes
    if [[ -n $(git status --porcelain) ]]; then
        git add .
        git commit -m "Update ${var_name} to ${var_version}"
        git push -f origin "${branch_name}"
        echo "${branch_name}"
        return 0
    fi
    
    return 1
}

# Main execution
echo "Fetching latest changes..."
git fetch origin

if ! git show-ref --verify --quiet "refs/remotes/origin/flux-image-updates"; then
    echo "Branch flux-image-updates does not exist"
    exit 0
fi

echo "Looking for version changes in flux-image-updates..."
version_changes=$(get-version-changes)

if [[ -z "$version_changes" ]]; then
    echo "No version changes found"
    exit 0
fi

echo "Found version changes:"
echo "$version_changes"

# Process each version change - create separate branch and PR for each
while IFS='|' read -r var_name var_version; do
    if [[ -n "$var_name" && -n "$var_version" ]]; then
        if branch=$(create-branch-for-change "$var_name" "$var_version"); then
            PR_BRANCH="$branch"
            PR_NAME="Automatic PR - ${var_name}: ${var_version}"
            create-pr 0
        fi
    fi
done <<< "$version_changes"

echo "Done!"