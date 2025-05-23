#!/bin/bash

act-summary

out=$(mktemp)
err=$(mktemp)

command_v() {
  command -v $1 >/dev/null 2>/dev/null
}

call_gh_api() {
  if ! command_v gh; then
    if command_v apt-get; then
      apt-get update
      apt-get install -y --no-install-recommends gh
    elif command_v apk; then
      apk add github-cli
    fi
  fi
  call_gh_api() {
    if [ -n "$1" ]; then
      slash='/'
    else
      slash=''
    fi
    verb="/repos/$GITHUB_REPOSITORY$slash$1"
    (
      if [ -n "$2" ]; then
        gh api "$verb" --template "$2"
      else
        gh api "$verb"
      fi
    ) > "$out" 2> "$err"
  }
  call_gh_api "$@"
}

maybe_json() {
  echo
  if /usr/bin/file -b --mime "$1" | grep -q application/json; then
    echo '```json'
    cat "$1" | jq .
  else
    echo '```sh'
    cat "$1"
  fi
  echo
  echo '```'
}

summarize_gh_api_output() {
  echo '### debugging information used to make the preceding suggestion'
  echo '#### `gh api /repos/'"$GITHUB_REPOSITORY/$1"'`'
  echo
  echo "<details><summary>output</summary>"
  maybe_json "$out"
  echo "</details>"
  echo "<details><summary>error</summary>"
  maybe_json "$err"
  echo "</details>"
}

check_ssh_key() {
  if [ -n "$ssh_key" ]; then
    ssh_key_file=$(mktemp)
    chmod 0600 "$ssh_key_file"
    echo "$ssh_key" > "$ssh_key_file"
    ssh -i "$ssh_key_file" "$ssh_account" > "$out" 2> "$err" || true
    rm -f "$ssh_key_file"
    if grep -q "^$ssh_account" "$err"; then
      (
        echo '## Checkout Failed: Bad SSH Key?'
        echo 'Look for `with:`/`ssh_key: ...`'
        echo 'It should be something like `${{ secrets.CHECK_SPELLING }}`'
        echo '* If it is, you might be able to delete the secret and then follow the talk-to-the-bot instructions.'
        echo '* Otherwise, you probably need to regenerate your deploy key (or non deploy key) and recreate the secret containing the private key.'
        echo '```'
        cat "$out" "$err"
        echo '```'
      ) >> "$GITHUB_STEP_SUMMARY"
      exit 1
    fi
  fi
}

check_for_empty_github_token() {
  if [ -z "$GH_TOKEN" ]; then
    (
      if [ -n "$ACT" ]; then
        echo '## Checkout Failed: Repository is probably private or nonexistent'
        echo 'Please set `GITHUB_TOKEN`'
        echo 'See https://nektosact.com/usage/index.html?highlight=github_token#github_token'
      else
        echo '## Checkout Failed: github.token empty'
        echo 'This should never happen, please file a bug (empty-github-token)'
      fi
    ) >> "$GITHUB_STEP_SUMMARY"
    exit 1
  fi
}

check_wiki() {
  if [ "${GITHUB_REPOSITORY#*/*.wiki}" = '' ]; then
    full_github_repository="$GITHUB_REPOSITORY"
    GITHUB_REPOSITORY=${GITHUB_REPOSITORY%*.wiki}
    if call_gh_api '' '{{.has_wiki}}'; then
      if [ "$(cat "$out" 2>/dev/null)" = false ]; then
        (
          echo '## Checkout Failed: wiki is probably disabled for repository'
          echo "See gh api '/repos/$GITHUB_REPOSITORY' --template '{{.has_wiki}}'"
        ) >> "$GITHUB_STEP_SUMMARY"
        exit 1
      fi
    fi
  fi
}
check_repository_existence() {
  if call_gh_api 'properties/values'; then
    repo_is_public_and_token_is_probably_bad=1
  fi
  if ! GH_TOKEN="${CHECKOUT_TOKEN:-$GH_TOKEN}" call_gh_api 'properties/values'; then
    (
      if [ -n "$repo_is_public_and_token_is_probably_bad" ]; then
        echo '## Checkout Failed: checkout token was rejected by server'
        echo 'Try replacing the token.'
        echo 'Look for `with:`/`checkout-token: ...`'
        echo 'It should be something like `${{ secrets.CHECK_SPELLING }}`'
        echo '* If it is a raw secret, you are doing things very wrong and should replace it (including rotating the secret wherever it is used).'
        echo '* Otherwise, you probably need to generate a new token and then replace the secret value.'
      elif [ -n "$ACT" ]; then
        echo '## Checkout Failed: Repository is probably private or nonexistent'
        echo 'You probably need to adjust your `GITHUB_TOKEN` secret to include `contents: read` for this repository.'
      else
        echo '## Checkout Failed: Repository is probably private or nonexistent'
        echo 'Try replacing the token.'
        echo 'Look for `with:`/`checkout-token: ...`'
        echo 'It should be something like `${{ secrets.CHECK_SPELLING }}`'
        echo '* If it is a raw secret, you are doing things very wrong and should replace it (including rotating the secret wherever it is used).'
        echo '* Otherwise, you probably need to generate a new token and then replace the secret value.'
      fi
      summarize_gh_api_output 'properties/values'
    ) >> "$GITHUB_STEP_SUMMARY"
    exit 1
  fi
}

check_repository_read_permission() {
  if ! call_gh_api 'activity'; then
    (
      echo '## Checkout Failed: GitHub Token is missing `contents: read`'
      echo 'You probably need to add this to your workflow file:'
      echo '```yaml'
      echo 'permissions:'
      echo '  contents: read'
      echo '```'
      echo 'If you are using a [fine-grained PAT](https://docs.github.com/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#fine-grained-personal-access-tokens), then the token needs `contents: read`.'
      summarize_gh_api_output 'activity'
    ) >> "$GITHUB_STEP_SUMMARY"
    exit 1
  fi
}

check_for_not_our_ref() {
  if git fetch origin "$1" 2>&1 | grep -q 'not our ref'; then
  (
    echo '## Checkout Failed: Current commit is not present in remote repository'
    echo "Current git remote: $(git remote get-url origin)"
    echo "Checked commit: $1"
    if [ -n "$ACT" ]; then
      echo '* You may need to change which remote repository act is working from.'
      echo '* You may want to push the commit to the active git repository.'
      echo
      echo 'To verify:'
      echo 'pushd $(mktemp -d) && git init && git remote add origin '"'$(git remote get-url origin)' && (git fetch origin --negotiate-only --negotiation-tip=$1; git fetch origin '$1')"
    fi
  ) >> "$GITHUB_STEP_SUMMARY"
  exit 1
  fi
}

check_for_submodules() {
  submodules=$(mktemp)
  if git ls-files --stage|grep ^160000 > "$submodules"; then
    (
      echo '## git submodules'
      echo 'actions/checkout has code for `persist-credentials: false` which relies on `git` to play nice...'
      echo 'if your .gitmodules list does not cover your submodules, that could be the problem'
      echo
      echo '### `.gitmodules`'
      if [ -s .gitmodules ]; then
        echo '```ini'
        cat .gitmodules
        echo
        echo '```'
      elif [ -f .gitmodules ]; then
        echo 'Empty file...'
      else
        echo 'Did not find `.gitmodules`'
      fi
      echo
      echo '### modules'
      echo 'These objects were reported by `git` as being a commit (roughly a submodule).'
      echo 'In order for `git submodule` to be happy, each item here needs to correspond to an entry in `.gitmodules`, if it does not, that could explain a checkout failure.'
      echo 'Please review the items below:'
      echo '```'
      cat "$submodules"
      echo
      echo '```'
    ) >> "$GITHUB_STEP_SUMMARY"
  fi
}

check_ssh_key
check_for_empty_github_token
check_wiki
check_repository_existence
check_repository_read_permission
check_for_not_our_ref "$GITHUB_SHA"
check_for_submodules

(
  echo '## Checkout Failed'
  echo '😕 check-spelling is not familiar with this failure case, please file a 🐛 bug (checkout-failed-unknown-cause)'
) >> "$GITHUB_STEP_SUMMARY"
exit 1
