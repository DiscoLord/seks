# fish completion for seks. Put this file in `~/.config/fish/completions/`.

# Never complete file names.
complete -c seks -f

# Only the first argument is completed. More words belong to a name with
# spaces.
#
# `seks --list` prints "name<TAB>full name". fish reads that as a completion
# and its description.
complete -c seks -n __fish_is_first_token -a "(seks --list 2>/dev/null)"
complete -c seks -n __fish_is_first_token -l list -d "List the apps"
complete -c seks -n __fish_is_first_token -l help -d "Show the help"
complete -c seks -n __fish_is_first_token -l version -d "Show the version"
