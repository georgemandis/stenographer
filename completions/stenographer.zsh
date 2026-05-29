#compdef stenographer

_stenographer() {
    local -a commands
    commands=(
        'transcribe:Transcribe an audio file'
        'listen:Transcribe from the microphone'
        'locales:List supported languages'
        'help:Show help message'
    )

    local -a options
    options=(
        '--locale=[Language locale (default\: en-US)]:locale:'
        '--on-device[Force on-device recognition]'
        '--duration=[Max listen duration in ms]:milliseconds:'
        '--silence=[Stop after ms of silence]:milliseconds:'
        '--no-stream[Do not print partial results]'
        '--verbose[Show debug info on stderr]'
        '--json[Output as JSON]'
        '--help[Show help message]'
        '--version[Show version]'
    )

    if (( CURRENT == 2 )); then
        _describe 'command' commands
        return
    fi

    case "${words[2]}" in
        transcribe)
            _arguments \
                '1:command:' \
                '2:audio file:_files' \
                ${options}
            ;;
        listen)
            _arguments \
                '1:command:' \
                ${options}
            ;;
        *)
            _arguments ${options}
            ;;
    esac
}

_stenographer "$@"
