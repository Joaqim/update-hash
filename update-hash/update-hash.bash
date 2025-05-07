#!/usr/bin/env bash
set +eu

FAKE_HASH="sha256-$(printf "A%.0s" {1..43})="
BACKUP_HASH=""

validate_hash() {
    local hash_candidate="$1"

    if [ "$hash_candidate" != "$FAKE_HASH" ] && [[ "$hash_candidate" =~ ^sha256-[A-Za-z0-9\\/+]{43}= ]]; then
        return 0
    fi
    return 1
}

backup_hash() {
    local current_hash
    current_hash="$(awk '/"sha256-(.*)";/ {print $3}' flake.nix)"
    # Empty hash
    if [[ "$current_hash" =~ \"\" ]] || [ -z "$current_hash" ]; then
        BACKUP_HASH=""
        return 0
    fi

    current_hash="${current_hash//\";/}"

    if [ "$(wc -c <<< "$current_hash")" -ge 52 ]; then
        current_hash="$( echo "$current_hash" | tail -c 52)"
    fi
    if ! validate_hash "$current_hash"; then
        return 1
    fi
    BACKUP_HASH="$current_hash"
}

restore_backup_hash() {
    if [ -n "$BACKUP_HASH" ]; then
        sed -i "s;-hash = \".*\";-hash = \"$BACKUP_HASH\";g" flake.nix
    fi
}

verify_no_staged_changes() {
    if [ -n "$(git diff --cached)" ]; then
        echo "There are stashed changes, aborting"
        return 1
    fi
}
has_arg() {
    case "--$1" in
        "$2") return 0;;
        "$3") return 0;;
    esac
    return 1
}

stash_current_changes() {
    git stash save | grep 'No local changes to save'
}
restore_stashed_changes() {
    git stash pop
}
help() {
    printf "Usage: %s [run|list|help] [options]\n" "$0"
    printf "Commands:\n"
    printf "    run - Run the script\n"
    printf "    list - Equivalent to 'run --dry-run'\n"
    printf "    help - Display this help message\n"
    printf "\n"
    printf "Options for 'run':\n"
    printf "    --dry-run - Do not make any changes\n"
    printf "    --amend - Amend changed hash to last commit\n"
    printf "    --commit \"\$message\" - Commit changed hash as new commit\n"
    printf "    --help - Display this help message\n"
}
run() {
    if has_arg "help" "$@"; then
        help
        exit 0 
    fi

    if ! verify_no_staged_changes; then
        if stash_current_changes; then
            trap restore_stashed_changes EXIT
        else 
            echo "Failed to stash current changes"
            exit 1
        fi
    fi

    backup_hash || { echo "Failed to backup existing hash" ; exit 1; }

    # Replace current hash with empty hash
    sed -i "s;-hash = \"$BACKUP_HASH\";-hash = \"\";g" flake.nix
    
    local nix_flake_output
    nix_flake_output="$(nix flake check ./ --quiet 2>&1)"
    local nix_flake_exit_code="$?"
    if [ $nix_flake_exit_code -ne 0 ]; then
        local new_hash
        local old_hash 
        new_hash=$(echo "$nix_flake_output" | grep "got:    sha256-" | tail -c 52)
        old_hash=$(echo "$nix_flake_output" | grep "specified: sha256-" | tail -c 52)
        if validate_hash "$new_hash"; then
            # Replace / with \/ in old_hash
            local existing_hash_match="${old_hash//\//\\/}" 
            
            if [ "$existing_hash_match" == "$FAKE_HASH" ]; then
                existing_hash_match="";
            fi

            old_hash="${BACKUP_HASH:-$old_hash}"

            if [ "$old_hash" == "$new_hash" ]; then
                echo "Hash is already up to date."
                restore_backup_hash && exit 0 
            else
                printf "./flake.nix: %s -> %s\n" "$old_hash" "$new_hash"
                if ! has_arg "dry-run" "$@"; then
                    set +e
                    sed -i "s;-hash = \"$existing_hash_match\";-hash = \"$new_hash\";g" flake.nix
            
                    if has_arg "amend" "$@"; then
                        git add ./flake.nix
                        git commit --amend --no-edit --no-verify
                    elif has_arg "commit" "$@"; then
                        git add ./flake.nix
                        # TODO: Improve argument handling
                        if [ -z "$3" ]; then
                            echo "No commit message provided"
                            exit 1
                        fi
                        git commit -m "$3" ./flake.nix --no-verify
                    fi
                    exit 0
                fi
            fi
        fi
    fi

    restore_backup_hash
    
    echo "$nix_flake_output"
    exit "$nix_flake_exit_code"
}


# TODO: Improve handling of args
# Right now, --commit "$message" is a bit flaky
# TODO: Allow optional --no-verify for --commit and --amend
case "$1" in
    run) run "$@" ;;
    list) run --dry-run ;;
    help) help ; exit 0;;
    --help) help ; exit 0;;
    -h) help ; exit 0 ;;
esac
printf "Invalid command '%s'\n" "$1" && help && exit 1