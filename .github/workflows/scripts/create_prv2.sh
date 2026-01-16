#!/usr/bin/env bash

function create-pr() {
  retry_nr=$1
  sleep_before_retry=$(($retry_nr * 2))
  if [[ -z "${PR_BRANCH}" ]]; then
        PR_BRANCH="flux-image-updates"
    fi

  if [[ -z "${PR_NAME}" ]]; then
      PR_NAME="Automatic Pull Request"
  fi

}

create-pr 0