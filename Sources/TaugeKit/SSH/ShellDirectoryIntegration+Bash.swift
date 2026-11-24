extension ShellDirectoryIntegration {
    // Bash --rcfile only runs for a non-login shell. Read the usual login
    // profiles here so the prompt hook is installed after their setup.
    static let bash = #"""
    if cat > "$integration/bashrc" <<'TAUGE_BASH_RC'
    command rm -f -- "${BASH_SOURCE[0]}"
    command rmdir -- "${BASH_SOURCE[0]%/*}" 2>/dev/null || :

    __tauge_start_directory=${TAUGE_SHELL_START_DIRECTORY-}
    unset TAUGE_SHELL_START_DIRECTORY
    if [[ -r /etc/profile ]]; then builtin source /etc/profile; fi
    for __tauge_profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
        if [[ -r $__tauge_profile ]]; then
            builtin source "$__tauge_profile"
            break
        fi
    done
    unset __tauge_profile
    if [[ -n $__tauge_start_directory ]]; then
        builtin cd -- "$__tauge_start_directory" 2>/dev/null || :
    fi
    unset __tauge_start_directory

    __tauge_report_directory() {
        local status=$? directory=${PWD-}
        if [[ $directory != /* || $directory == "${__tauge_reported_directory-}" ]]; then
            return "$status"
        fi
        local LC_ALL=C encoded= character byte escape index
        for ((index=0; index<${#directory}; index++)); do
            character=${directory:index:1}
            case $character in
                [a-zA-Z0-9.~_/-]) encoded+=$character;;
                *) builtin printf -v byte '%d' "'$character"
                   builtin printf -v escape '%%%02X' "$((byte & 255))"
                   encoded+=$escape;;
            esac
        done
        builtin printf '\e]7;file://ssh.invalid%s\a' "$encoded"
        __tauge_reported_directory=$directory
        return "$status"
    }

    __tauge_install_directory_hook() {
        local attributes
        attributes=$(builtin declare -p PROMPT_COMMAND 2>/dev/null) || attributes=
        attributes=${attributes#declare }
        attributes=${attributes%% *}
        case $attributes in *r*|*A*) return;; esac
        if [[ $attributes == *a* ]] && ((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1))); then
            PROMPT_COMMAND+=(__tauge_report_directory)
        else
            PROMPT_COMMAND=${PROMPT_COMMAND-}${PROMPT_COMMAND:+$'\n'}__tauge_report_directory
        fi
    }
    __tauge_install_directory_hook
    unset -f __tauge_install_directory_hook
    TAUGE_BASH_RC
    then
        exec "$shell" --rcfile "$integration/bashrc" -i
    fi
    """#
}
