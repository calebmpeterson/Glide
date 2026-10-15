# Glide — native Swift implementation

This is a source-only macOS 15+ Swift implementation of Glide. It starts enabled automatically on every launch. A one-finger vertical swipe that starts in the configured trackpad edge changes the default output device's virtual main volume.

The menu bar item displays the current system volume as a percentage beside a level-appropriate speaker symbol. It is also labeled `System volume: N percent` for VoiceOver.

## Build and test

```sh
make test
make
make run
```

`make` creates `build/Glide.app`; `make run` opens it. To remove the local build artifacts, run `make clean` and move the app bundle to Trash if you copied it elsewhere.

## Privacy and support boundary

When enabled, the app receives raw contact coordinates from the built-in trackpad only for the current gesture. It does not store or transmit contact coordinates, IDs, keyboard state, or application activity. It does not suppress cursor motion or macOS gestures. It has no networking, persistence mechanism beyond validated preferences, login item, launch agent, helper, or updater.

This experimental app dynamically loads Apple's unsupported `MultitouchSupport` private framework. It cannot be distributed through the Mac App Store and may break after a macOS update. Build and use it locally at your discretion. Compatible hardware is limited to built-in trackpads exposed by that framework; unsupported hardware is reported rather than guessed.

## Temporary timing trace

The current development build writes a bounded, rotating pipeline trace to `/tmp/Glide-pipeline.log`. It records only generated trace IDs, monotonic timestamps, and processing stage names; it never writes contact coordinates, contact IDs, keyboard state, volume values, or application activity. Delete the file when timing investigation is complete.
