# bash completion for seks. Source this file from `~/.bashrc`.

_seks() {
  local current=${COMP_WORDS[COMP_CWORD]}
  COMPREPLY=()

  # Only the first argument is completed. More words belong to a name with
  # spaces.
  [[ $COMP_CWORD -eq 1 ]] || return 0

  if [[ $current == -* ]]; then
    COMPREPLY=($(compgen -W "--list --help --version" -- "$current"))
    return 0
  fi

  # `seks --list` prints "name<TAB>full name". Take the names.
  COMPREPLY=($(compgen -W "$(seks --list 2>/dev/null | cut -f1)" -- "$current"))
}

complete -F _seks seks
