# Contributing to local-whisper

Thanks for your interest in contributing! This project is small and focused — PRs and issues are welcome.

## Reporting bugs

1. Check the log file: `tail -50 $TMPDIR/whisper-dictate/whisper-dictate.log`
2. Open an issue with:
   - What you did (e.g., "held fn+left Ctrl, said X")
   - What happened vs. what you expected
   - Your macOS version and chip (Intel / Apple Silicon)
   - Relevant log output

## Suggesting features

Open an issue describing the use case. Voice command ideas are especially welcome.

## Pull requests

1. Fork the repo and create a branch
2. Make your changes — the entire runtime is in `~/.hammerspoon/init.lua`
3. Test by reloading Hammerspoon (click menu bar icon > Reload Config)
4. Check the log for errors
5. Open a PR with a short description of what and why

### Code style

- Lua: local variables, no globals, descriptive names
- Keep it simple — this is a single-file architecture by design
- Voice commands go in `local_whisper_actions.lua`, not in `init.lua`
- No Python, no network calls — everything stays local

### Project structure

```
hammerspoon/init.lua                    # Main runtime (all logic)
hammerspoon/local_whisper_actions.example.lua  # Example voice commands
install.sh                              # Automated installer
setup.sh                                # Interactive setup wizard
uninstall.sh                            # Clean removal
docs/VOICE_COMMANDS.md                  # Voice commands guide
```

### Testing

There's no automated test suite — this is a UI tool. Test manually:

1. Reload Hammerspoon after changes
2. Hold trigger key, dictate, release
3. Check `$TMPDIR/whisper-dictate/whisper-dictate.log`
4. Test voice commands: "voice command note test", "voice command cancel"
5. Verify menu bar icon and settings overlay work

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
