# Lite-XL Plugins Repository

A curated repository of plugins for the [Lite-XL](https://lite-xl.com) text editor, fully compatible with [`use-package`](plugins/use_package).

---

## Installation via `use-package`

Register this repository in your `init.lua` (or `configs/plugins/init.lua`):

```lua
local up = require 'plugins.use_package'

up.repos {
  '~/Work/github/lite-xl-plugins',
  -- Or when published remotely:
  -- 'https://github.com/<username>/lite-xl-plugins.git:main',
}
```

Then declare the plugins you want:

```lua
up.use 'avy'
up.use 'bufferex'
up.use 'emacs'
up.use 'fd-files'
up.use 'indentguideex'
up.use 'isearch'
up.use 'killring'
up.use 'rgsearch'
up.use 'thither'   -- bundled with the stonewell fork; the repo copy wins when newer
up.use 'whichkey'
```

Run `use-package:install` from Lite-XL's command palette (`Ctrl+Shift+P`) to install declared plugins.

### Enabling and Disabling Plugins

You can enable or disable individual plugins declaratively:

```lua
-- Disable a plugin in config:
up.use('whichkey', { enabled = false })
-- Or concisely:
up.disable 'whichkey'

-- Re-enable:
up.use('whichkey', { enabled = true })
```

Or interactively through Lite-XL commands:
- `use-package:disable-plugin`: Pick an enabled plugin to disable.
- `use-package:enable-plugin`: Pick a disabled plugin to enable.
- `use-package:toggle-plugin`: Toggle a plugin's state.

---

## Included Plugins

| Plugin | Version | Description | Dependencies |
|---|---|---|---|
| [`avy`](plugins/avy) | 0.1.0 | Jump-to-char/word/line navigation with label overlays. | - |
| [`bufferex`](plugins/bufferex) | 0.1.0 | Helm-mini style buffer and recent-file switcher with fuzzy filtering. | `shared` |
| [`emacs`](plugins/emacs) | 0.1.0 | Emacs navigation utilities (`push_mark`, `universal_argument`). | - |
| [`fd-files`](plugins/fd-files) | 0.1.0 | Fast file finder overlay powered by `fd`. | `shared` |
| [`indentguideex`](plugins/indentguideex) | 0.1.0 | Enhanced indentation guides with active scope highlighting. | - |
| [`isearch`](plugins/isearch) | 0.1.0 | Emacs-style incremental search with live multi-match highlighting. | - |
| [`killring`](plugins/killring) | 0.1.0 | Emacs-style clipboard history with searchable listview overlay. | `shared` |
| [`rgsearch`](plugins/rgsearch) | 0.1.0 | Fast project-wide search overlay powered by `ripgrep`. | `shared` |
| [`shared`](plugins/shared) | 0.1.0 | Shared `listview` overlay base class and search helpers. | - |
| [`thither`](plugins/thither) | 0.1.0 | Remote editing over ssh through `thither-server` (needs the [stonewell Lite XL fork](https://github.com/stonewell/lite-xl)). | - |
| [`use_package`](plugins/use_package) | 0.2.0 | Declarative package and plugin manager for Lite-XL. | - |
| [`whichkey`](plugins/whichkey) | 0.1.0 | Key continuation popup panel after prefix key combinations. | - |

---

## License

MIT License. See [LICENSE](LICENSE) for details.
