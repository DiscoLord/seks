# Binding lists

One app is one JSON file. The file name is the name of the app.

## Add an app

1. Copy `template.json` to `macos/<name>.json` or `linux/<name>.json`.
2. Fill it in.
3. Run `zig build`. The build checks every file. A broken file stops it with
   the path, the rule, the group, the binding and the text.
4. Run `zig build run -- <name>` to see the result.

The build finds the new file. There is no list to edit.

## Fields

| Field | Required | Rule |
|---|---|---|
| File name | Yes | The letters `a` to `z`, the digits, `.`, `_` and `-`. Not `-` at the start. `vscode.json` is called with `seks vscode` |
| `full_name` | Yes | The name to show |
| `binding_groups` | Yes | The sections of the app |
| `aliases` | No | Words with the same characters as the file name, with one space between two words. No two apps of a platform share a name or an alias |
| `note` | No | One short line, on the app or on a group. Use it for a fact that the bindings need, such as a prefix key |
| `source` | No | The page the bindings come from |

A group has `id`, `title`, `bindings`, and an optional `note`. A binding has
`id`, `keys` and `effect`.

- **A field that is not in this list is an error.** This catches a
  misspelled field, such as `"Dead"`.
- **Text holds no control characters, no invisible characters and no space
  at either end.** A text copied from a web page can hold a no-break space.
  Type the space again.
- **Write each `effect` in your own words.** Do not copy sentences from the
  documentation of the app.

## Ids

- A group id is unique among the groups of the file.
- A binding id is unique in the whole file, not only in its group.
- A new entry takes the highest id plus one.
- Never change an id and never reuse one.
- To remove an entry, add `"dead": true` to it. Do not delete it. The id
  then stays taken.

## Keys

`keys` is a list. Each item is one way to trigger the effect. The tool joins
the items with a bold `OR`.

- `+` joins keys held together: `Ctrl+Shift+N`.
- One space separates keys pressed in order: `Ctrl+K Ctrl+S`, `g g`.
- Write the plus key as `Plus`: `Cmd+Plus`. The tool shows it as `Cmd++`.
- A combination ends in a key, not in a modifier, and has no modifier twice.

A modifier has one spelling per platform:

| Platform | Modifiers |
|---|---|
| macOS | `Cmd`, `Shift`, `Opt`, `Ctrl`, `Fn` |
| Linux | `Ctrl`, `Shift`, `Alt`, `Super` |

A named key has one spelling:

`Enter`, `Esc`, `Tab`, `Space`, `Backspace`, `Delete`, `Insert`, `Up`,
`Down`, `Left`, `Right`, `Home`, `End`, `PageUp`, `PageDown`, `Plus`, and
`F1` to `F12`.

The check rejects other spellings, such as `Return`, `Escape`, `Del`, `PgUp`
and `Command`. One limit: a lowercase word with no modifier passes, because
it can be literal text in a command. So `Ctrl+enter` is rejected, and
`enter` alone is not.
