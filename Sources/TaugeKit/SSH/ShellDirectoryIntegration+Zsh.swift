extension ShellDirectoryIntegration {
    // Restore ZDOTDIR in the first startup file so zsh itself still loads the
    // user's remaining profile, interactive settings and logout hooks.
    static let zsh = #"""
    if cat 2>/dev/null > "$integration/.zshenv" <<'TAUGE_ZSHENV'
    command rm -- "$ZDOTDIR/.zshenv" 2>/dev/null || :
    command rmdir -- "$ZDOTDIR" 2>/dev/null || :
    if [[ ${TAUGE_ZDOTDIR_SET-} == x ]]; then
        ZDOTDIR=$TAUGE_PREVIOUS_ZDOTDIR
    else
        unset ZDOTDIR
    fi
    unset TAUGE_ZDOTDIR_SET TAUGE_PREVIOUS_ZDOTDIR
    typeset -g __tauge_zsh_start_directory=${TAUGE_SHELL_START_DIRECTORY-}
    unset TAUGE_SHELL_START_DIRECTORY

    if [[ -r "${ZDOTDIR-$HOME}/.zshenv" ]]; then
        source "${ZDOTDIR-$HOME}/.zshenv"
    fi

    __tauge_report_zsh_directory() {
        (( ! ${+__tauge_zsh_start_directory} )) || return 0
        emulate -L zsh
        unsetopt multibyte
        local LC_ALL=C directory=$PWD encoded='' character hex index
        [[ $directory == /* && $directory != ${__tauge_zsh_directory-} ]] || return 0
        for (( index = 1; index <= ${#directory}; index++ )); do
            character=$directory[index]
            case "$character" in
                [a-zA-Z0-9._~/-]) encoded+=$character ;;
                *) builtin printf -v hex '%%%02X' "'$character"
                   encoded+=$hex ;;
            esac
        done
        typeset -g __tauge_zsh_directory=$directory
        builtin printf '\033]7;file://ssh.invalid%s\033\\' "$encoded"
    }

    __tauge_zsh_precmd() {
        if (( ${+__tauge_zsh_start_directory} )); then
            if [[ -n $__tauge_zsh_start_directory ]]; then
                builtin cd -q -- "$__tauge_zsh_start_directory" 2>/dev/null || :
            fi
            unset __tauge_zsh_start_directory
        fi
        __tauge_report_zsh_directory
    }

    typeset -ga precmd_functions chpwd_functions
    precmd_functions+=(__tauge_zsh_precmd)
    chpwd_functions+=(__tauge_report_zsh_directory)
    TAUGE_ZSHENV
    then
        TAUGE_ZDOTDIR_SET=${ZDOTDIR+x} TAUGE_PREVIOUS_ZDOTDIR=${ZDOTDIR-} ZDOTDIR="$integration" exec "$shell" -il
    fi
    """#
}
