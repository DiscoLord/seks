# seks

**Show Every Keyboard Shortcut.** Type the name of an app and get its key
bindings in the terminal, as pages. For macOS and Linux.

```
$ seks tmux

  tmux                                                                           page 1/33
  tmux 3.7c defaults. Press the prefix Ctrl+B, release it, then press the next key. Copy
  mode starts with Ctrl+B [. Its keys need no prefix and depend on mode-keys.

  Sessions                                    Windows
    Ctrl+B d ··· Detach client                  Ctrl+B c ··· New window
    Ctrl+B s ··· Choose session                 Ctrl+B n ··· Next window
    Ctrl+B $ ··· Rename session                 Ctrl+B p ··· Previous window
    Ctrl+B ( ··· Switch to previous client      Ctrl+B l ··· Last window
    Ctrl+B ) ··· Switch to next client          Ctrl+B w ··· Choose window

  Space next   b back   g first   G last   q quit
```

## Install

With [Homebrew](https://brew.sh), on macOS or Linux:

```sh
brew install discolord/seks/seks
```

Or download the archive for your computer from the
[latest release](https://github.com/DiscoLord/seks/releases/latest):

| Computer | Archive |
|---|---|
| macOS, Apple silicon | `seks-macos-arm64.tar.gz` |
| macOS, Intel | `seks-macos-x86_64.tar.gz` |
| Linux, ARM | `seks-linux-arm64.tar.gz` |
| Linux, x86 | `seks-linux-x86_64.tar.gz` |

```sh
curl -L https://github.com/DiscoLord/seks/releases/latest/download/seks-macos-arm64.tar.gz | tar xz
sudo mv seks-macos-arm64/seks /usr/local/bin/
```

The archive also holds the shell completions. If you download it with a
browser on macOS, remove the quarantine mark before the first run:
`xattr -d com.apple.quarantine seks`.

Or build from source with [Zig](https://ziglang.org/download/) 0.17.0:

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
