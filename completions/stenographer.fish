# Fish completions for stenographer

# Disable file completions by default
complete -c stenographer -f

# Commands
complete -c stenographer -n "__fish_use_subcommand" -a "transcribe" -d "Transcribe an audio file"
complete -c stenographer -n "__fish_use_subcommand" -a "listen" -d "Transcribe from the microphone"
complete -c stenographer -n "__fish_use_subcommand" -a "locales" -d "List supported languages"
complete -c stenographer -n "__fish_use_subcommand" -a "help" -d "Show help message"

# File completion for transcribe
complete -c stenographer -n "__fish_seen_subcommand_from transcribe" -F

# Options (available for all subcommands)
complete -c stenographer -l locale -d "Language locale (default: en-US)" -r
complete -c stenographer -l on-device -d "Force on-device recognition"
complete -c stenographer -l duration -d "Max listen duration in ms" -r
complete -c stenographer -l silence -d "Stop after ms of silence" -r
complete -c stenographer -l no-stream -d "Don't print partial results"
complete -c stenographer -l verbose -d "Show debug info on stderr"
complete -c stenographer -l json -d "Output as JSON"
complete -c stenographer -l help -d "Show help message"
complete -c stenographer -l version -d "Show version"
