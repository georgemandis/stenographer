_stenographer() {
    local cur prev commands opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    commands="transcribe listen locales help"
    opts="--locale= --on-device --duration= --silence= --no-stream --verbose --json --help --version"

    # Complete commands at position 1
    if [[ ${COMP_CWORD} -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "${commands}" -- "${cur}") )
        return 0
    fi

    # Complete file paths after "transcribe"
    if [[ "${COMP_WORDS[1]}" == "transcribe" && ${COMP_CWORD} -eq 2 && "${cur}" != -* ]]; then
        COMPREPLY=( $(compgen -f -- "${cur}") )
        return 0
    fi

    # Complete options
    if [[ "${cur}" == -* ]]; then
        COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
        return 0
    fi

    return 0
}

complete -o default -F _stenographer stenographer
