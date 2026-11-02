# UI regression scenarios

Run `just test-ui` on a Mac with an idle, logged-in graphical session. SSH works when that
user has a graphical session. To reuse a bundle or select a case:

```sh
just test-ui --no-build scripts/ui-tests/folder-drag-delete.json
```

The shell runner starts a fresh process for each JSON file in this directory, with its own
layout and randomly named `com.sglavoie.launchgrid.uitest.*` preferences domain. It removes
that domain on exit. It bypasses the normal scan, watchers, bookmark restoration and shortcut
registration. Fixtures use synthetic apps; nothing needs to be installed or opened. The tests
still use the real overlay, SwiftUI gestures, event monitors, keyboard handling and menu actions.
Held-menu steps capture the actual menu callbacks without entering macOS's menu tracking loop.

Each file needs a name, fixture and sequence of steps:

```json
{
  "name": "Escape clears a search",
  "fixture": {
    "rows": 3,
    "columns": 4,
    "pages": [["Tools", "Delta"]],
    "pageTitles": ["First"],
    "folders": {"Tools": ["Alpha", "Beta"]}
  },
  "steps": [
    {"run": "show"},
    {"expect": {"keyWindow": true, "pagerReady": true}},
    {"run": "keys:b,e,t,a"},
    {"expect": {"query": "beta", "searchResults": ["Beta"]}},
    {"run": "keys:53"},
    {"expect": {"query": "", "shown": true}}
  ]
}
```

An optional `actions` array holds actions in the layout's JSON form (`name`, `keywords`,
`kind`, `showsOnGrid`). One shown on the grid is placed where its name appears in `pages`;
a search-only one (`"showsOnGrid": false`) is kept off every page.

An optional `files` object maps plain file names to text. They are written into a `files`
folder in the scenario's artifacts before the first step, and `${FILES}` anywhere in the
scenario stands for that folder's path, e.g. a link action whose template is
`file://${FILES}/note.txt`. Running it opens the file in its default app (TextEdit for
`.txt`) without any network access. The path must not contain spaces, which a link can't hold.

Fixture names must be unique, including folder names, their apps and search-only actions. A name in `pages`
whose key exists in `folders` represents that folder. Page titles correspond to pages in order.
Every page must fit the specified rows and columns.

A step has exactly one of `run` or `expect`. Each scenario needs at least one nonempty
assertion. Unknown commands, unknown assertion fields and missing held-menu actions fail.
Commands use the existing `DebugScript.swift` syntax, one per step:

| Commands | Purpose |
| --- | --- |
| `show`, `hide` | Show/hide the overlay |
| `windowsize:718,534` | Resize the overlay window in points to cover compact layouts |
| `keys:cmd+e@14`, `keys:125`, `keys: @49` | Post keyboard events: edit mode, Down, Space |
| `click:0`, `press:0`, `fpress:0` | Click or long-press a page/folder cell |
| `drag:0,2`, `fdrag:1,1`, `finside:0,2`, `merge:0,1`, `edge:0,0` | Send mouse events through the gesture path |
| `hold:0,2`, `fhold:1,1`, `release` | Hold/release a mouse drag; Escape can cancel it |
| `page:1`, `folder`, `focus:0`, `edit`, `select:0,1`, `fselect:0` | Set up a specific interaction context |
| `search:beta`, `type:beta` | Set search directly or insert text at its caret |
| `group`, `undo`, `redo`, `deletepage`, `movetopage:1` | Invoke app-state actions directly |
| `menuhold`, `pagemenuhold`, `menurun:Sort This Page` | Capture an item/page menu, then run a captured callback |
| `fakeinstall:Echo`, `autoadd:on` | Simulate a catalog update using the reconciler |
| `pagetitle:First`, `titleedit` | Set a page title or open its editor |
| `addaction:{"name": "X", "kind": {...}}`, `runaction:X,argument` | Add an action from its layout JSON (no `;` inside), or run one by name |

Prefer events for the behavior under test; direct state commands are useful for setup.
Indices are zero-based. Key codes are macOS virtual key codes; literal characters can include
an explicit code after `@`. Menu titles use the app's English text, including punctuation.

Assertions compare only the supplied fields, with exact JSON types and array order. They
poll every 50 ms, require two consecutive matching samples, and fail after three seconds:

| Field | Value |
| --- | --- |
| `pages` | Array of pages, each containing top-level item names in order |
| `pageTitles` | Page titles in order; `""` for an untitled page |
| `folders` | Object mapping folder names to their app names in order |
| `apps` | All app names sorted, including those in folders |
| `selection` | Selected item/app names sorted |
| `focus`, `folder` | Focused item or open folder name; `""` for none |
| `currentPage` | Zero-based page index |
| `query`, `searchResults` | Search text and every ranked result name |
| `searchArguments` | The argument each ranked result carries, `""` for none |
| `toast` | The toast shown, `""` for none |
| `editing`, `shown`, `dragging` | Booleans |
| `textEdit` | `"item:Alpha"`, `"page:First"` or `""` |
| `keyWindow`, `pagerReady`, `folderReady` | Window focus and measured layout readiness |

The driver retains its event/dwell timing to exercise gestures. Use readiness/state
assertions between actions instead of adding arbitrary sleeps to scenarios. The shell runner
also bounds each process to 60 seconds (`UI_TEST_TIMEOUT` overrides it), detects crashes and
missing results, and continues to the other cases after a failure. It exits nonzero if any fail.

Artifacts stay under `build/ui-tests/<run>/<scenario>`: `run.log`, the input `scenario.json`,
`state.json`, `grid.json` and `result.json`. Failed assertions include expected and actual
state, plus `failure-*.png` snapshots of any constructed app windows. A timeout before the
app can report retains its log and `timeout.txt`; a stuck event loop cannot take a snapshot.
CI uploads the run directory when a check fails.
