# Binding lists

One app is one JSON file. The file name is the name of the app.

## Add an app

1. Copy `template.json` to `macos/<name>.json` or `linux/<name>.json`.
2. Fill it in.
3. Run `zig build test`. A broken file fails with its path, the rule and the
   id.
4. Run `zig build run -- <name>` to see the result.

The build finds the new file. There is no list to edit.

## Fields

| Field | Required | Rule |
|---|---|---|
| File name | Yes | Lowercase, no spaces. `vscode.json` is called with `seks vscode` |
| `full_name` | Yes | The name to show |
| `binding_groups` | Yes | The sections of the app |
| `aliases` | No | Lowercase, spaces allowed. No two apps of a platform share a name or an alias |
| `note` | No | One short line, on the app or on a group. Use it for a fact that the bindings need, such as a prefix key |
| `source` | No | The page the bindings come from |

Write each `effect` in your own words. Do not copy sentences from the
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
- A space separates keys pressed in order: `Ctrl+K Ctrl+S`, `g g`.
- Write the plus key as `Plus`: `Cmd+Plus`. The tool shows it as `Cmd++`.

A modifier has one spelling per platform. The check rejects every other one.

| Platform | Modifiers |
|---|---|
| macOS | `Cmd`, `Shift`, `Opt`, `Ctrl`, `Fn` |
| Linux | `Ctrl`, `Shift`, `Alt`, `Super` |
