# macOS Native Renderer

This helper renders `agent-shell-pet` in a transparent always-on-top AppKit
window. Emacs owns the agent-shell integration, frame timing, and state mapping.
The helper only receives newline-delimited JSON commands over stdin.

Build:

```bash
make -C renderers/macos
```

Then configure Emacs:

```elisp
(setq agent-shell-pet-renderer 'macos-native)
```

Protocol commands:

```json
{"type":"show","scale":1.0,"marginX":24,"marginY":24,"position":"bottom-right"}
{"type":"frame","path":"/tmp/frame.png","title":"Agent","body":"Thinking","cardStatus":"thinking","cardTheme":"dark","showBubble":true}
{"type":"frame","path":"/tmp/frame.png","showBubble":true,"notifications":[{"title":"Agent A","body":"Turn complete","cardStatus":"done"},{"title":"Agent B","body":"Thinking","cardStatus":"thinking"}]}
{"type":"hide"}
{"type":"quit"}
```

The window level is set to float above normal application windows and join all
Spaces. It is intentionally a small helper rather than a full app bundle for now.
