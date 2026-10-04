# seks

**Show Every Keyboard Shortcut.** Type the name of an app and get its key
bindings in the terminal, as pages. For macOS and Linux.

```
$ seks tmux

  tmux                                                                               page 1/11
  tmux 3.7c defaults; prefix = Ctrl+B; copy-mode keys depend on mode-keys.

  Sessions                                    Windows
  Press Ctrl+B, release it, then press the    Press Ctrl+B, release it, then press the
  remaining key.                              remaining key.
    Ctrl+B d ··· Detach client                  Ctrl+B c ··· New window
    Ctrl+B s ··· Choose session                 Ctrl+B n ··· Next window
    Ctrl+B $ ··· Rename session                 Ctrl+B p ··· Previous window

  Space next   b back   q quit
```

## Install

Build from source with [Zig](https://ziglang.org/download/) 0.17.0:

```sh
git clone https://github.com/DiscoLord/seks.git
cd seks
zig build -Doptimize=ReleaseSafe
```

The binary is `zig-out/bin/seks`. Copy it to a directory in your `PATH`.

## Usage

```sh
seks nvim                 # show the bindings of an app
seks visual studio code   # a name with spaces needs no quotes
seks --list               # list the apps
```

In the pager: `Space` next page, `b` previous page, `g` first page, `G` last
page, `q` quit. The arrow keys, `j` and `k`, and `PageUp` and `PageDown` turn
pages too.

In a pipe, `seks` prints plain text: `seks tmux | grep window`. Set
`NO_COLOR` to get plain text in the pager too.

Shell completions for zsh, bash and fish are in [`completions/`](completions).

## Contributing

- **Binding lists: yes.** Add an app or fix one. See [`data/README.md`](data/README.md).
- **Feature requests: yes.** Open an issue.
- **Code changes: no.** I do not accept pull requests that change the code.

## License

[MIT](LICENSE), for the code and for the data.
