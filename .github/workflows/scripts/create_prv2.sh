#!/usr/bin/env bash

# Documentation about this script can be found here:
# https://github.com/equinor/radix-private/blob/master/docs/radix-platform/flux.md
# Please update the documentation if any changes are made to this script.

MAX_RETRIES=3
BASE_BRANCH="${PR_BRANCH:-flux-image-updates}"

# Create a PR with retries
function create-pr() {
    local branch=$1
    local title=$2
    local retry=$3
    
    PR_STATE=$(gh pr view "$branch" --json state --jq '.state' 2>/dev/null || echo "NONEXISTENT")
    
    if [[ "${PR_STATE}" == "OPEN" ]]; then
        echo "PR already exists for branch ${branch}"
        return 0
    fi
    
    echo "Creating PR: ${title}"
    PR_URL=$(gh pr create --head "${branch}" --base master --title "${title}" --body "**Automatic Pull Request**" 2>&1)
    
    if [[ $? -eq 0 ]]; then
        curl --request POST \
            --header 'Content-type: application/json' \
            --data '{"text":"@omnia-radix Please review PR '"${PR_URL}"'","link_names":1}' \
            --url "${SLACK_WEBHOOK_URL}" \
            --fail
        return 0
    elif [[ $retry -lt $MAX_RETRIES ]]; then
        sleep $((retry * 2))
        create-pr "$branch" "$title" $((retry + 1))
    else
        curl --request POST \
            --header 'Content-type: application/json' \
            --data '{"text":"@omnia-radix Failed to create PR '"${title}"' https://github.com/'"${GITHUB_REPOSITORY}"'/actions/runs/'"${GITHUB_RUN_ID}"'","link_names":1}' \
            --url "${SLACK_WEBHOOK_URL}"
        return 1
    fi
}

# Find all version variables that changed
function find-version-changes() {
    git diff origin/master "${BASE_BRANCH}" | grep -E '^\+[[:space:]]*[A-Z_]+=v?[0-9]+\.[0-9]+' | \
        sed -E 's/^\+[[:space:]]*([A-Z_]+)=(v?[0-9]+\.[0-9]+[0-9.]*).*/\1|\2/' | \
        sort -u
}

# Get all files that changed for a specific variable
function get-files-for-variable() {
    local var_name=$1
    local files=()
    
    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            if git diff origin/master "${BASE_BRANCH}" -- "$file" | grep -q "^+.*${var_name}="; then
                files+=("$file")
            fi
        fi
    done < <(git diff --name-only origin/master "${BASE_BRANCH}")
    
    printf '%s\n' "${files[@]}"
}

# Create a branch for a specific version update
function create-branch-for-version() {
    local var_name=$1
    local var_version=$2
    local new_branch="${BASE_BRANCH}-${var_name}"
    
    echo "Creating branch ${new_branch} for ${var_name}=${var_version}"
    
    # Get files that contain this variable change
    local files=($(get-files-for-variable "$var_name"))
    
    if [[ ${#files[@]} -eq 0 ]]; then
        echo "No files found for ${var_name}"
        return 1
    fi
    
    # Switch to master and create new branch
    git checkout master
    git pull origin master
    git checkout -B "${new_branch}"
    
    # Copy changed files from base branch
    for file in "${files[@]}"; do
        git checkout "${BASE_BRANCH}" -- "$file"
    done
    
    # Commit and push if there are changes
    if [[ -n $(git status --porcelain) ]]; then
        git add .
        git commit -m "Update ${var_name} to ${var_version}"
        git push -f origin "${new_branch}"
        echo "${new_branch}"
        return 0
    fi
    
    return 1
}

# Main execution
echo "Fetching latest changes..."
git fetch origin

if ! git show-ref --verify --quiet "refs/remotes/origin/${BASE_BRANCH}"; then
    echo "Base branch ${BASE_BRANCH} does not exist"
    exit 0
fi

git checkout "${BASE_BRANCH}"
git pull origin "${BASE_BRANCH}"

echo "Looking for version changes..."
version_changes=$(find-version-changes)

if [[ -z "$version_changes" ]]; then
    echo "No version changes found"
    exit 0
fi

echo "Found version changes:"
echo "$version_changes"

# Process each version change
while IFS='|' read -r var_name var_version; do
    if [[ -n "$var_name" && -n "$var_version" ]]; then
        if branch=$(create-branch-for-version "$var_name" "$var_version"); then
            pr_title="Automatic PR - ${var_name}: ${var_version}"
            create-pr "$branch" "$pr_title" 0
        fi
    fi
done <<< "$version_changes"

echo "Done!"
