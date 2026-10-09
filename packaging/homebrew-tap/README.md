# f1lcry/homebrew-tap

Homebrew casks for apps by [f1lcry](https://github.com/f1lcry).

## NotchGram

[NotchGram](https://github.com/f1lcry/notchgram) is a Telegram client that
lives in the MacBook notch. Requires macOS 26 Tahoe on Apple silicon.

```sh
brew install --cask f1lcry/tap/notchgram
```

NotchGram updates itself (Sparkle), so `brew upgrade` leaves it alone unless
you pass `--greedy`. To remove the app together with its local data — the
Telegram cache and settings on this Mac, not your Telegram account:

```sh
brew uninstall --zap --cask notchgram
```

## Maintenance

`Casks/notchgram.rb` is bumped by NotchGram's release script
(`make release VERSION=x.y.z` in the app repository), which rewrites
`version` and `sha256` and pushes here. The template it starts from lives in
the app repository at `packaging/homebrew-tap/`.
