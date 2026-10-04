# bash completion for seks. Source this file from `~/.bashrc`.

_seks() {
  local current=${COMP_WORDS[COMP_CWORD]}
  local word name
  COMPREPLY=()

  # Only the first argument is completed. More words belong to a name with
  # spaces.
  [[ $COMP_CWORD -eq 1 ]] || return 0

  if [[ $current == -* ]]; then
    for word in --list --help --version; do
      [[ $word == "$current"* ]] && COMPREPLY+=("$word")
    done
    return 0
  fi

  # `seks --list` prints "name<TAB>full name". Take the names that start
  # with the typed text.
  #
  # Never pass the names through `compgen -W`. It expands its word list, so
  # a name that holds `$(...)` would run as a command.
  while IFS=$'\t' read -r name _; do
    [[ $name == "$current"* ]] && COMPREPLY+=("$name")
  done < <(seks --list 2>/dev/null)
}

complete -F _seks seks
