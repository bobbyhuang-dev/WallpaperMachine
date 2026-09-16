# Audio-responsive wallpapers

Scene wallpapers with authored audio effects can react to sound playing on the
Mac.

## Enabling it

Select the wallpaper, then turn on **General configuration -> Audio response**
in the inspector. The setting is saved per wallpaper and also applies to that
wallpaper's mirrored displays.

Capture starts only while an enabled wallpaper is active, and stops when its
final wallpaper is disabled or removed. Activation errors are reported rather
than silently ignored.

## Permission

macOS requests system audio recording permission at capture startup. If access
is denied, grant it in **System Settings -> Privacy & Security -> Screen &
System Audio Recording**, then retry the switch.

## What the input is

The input is sound playing in other apps. It is not the microphone, and it is
not the wallpaper's own playback. The wallpaper mute and volume controls stay
independent of audio response. Capture is downmixed to mono, so the left, right
and average buffers contain the same signal.

## Supported effect paths

| Path | Notes |
| --- | --- |
| Shader spectrum effects | Authored audio-reactive shaders |
| SceneScript `engine.registerAudioBuffers()` | 16, 32 and 64 bands |
| Particle emitters | Box and sphere emitters with audio frequency, bounds and exponent settings |

## Non-goals

- Pre-rendered video wallpapers do not gain reactive effects.
- This does not add web-wallpaper rendering.
- The [lock-screen extension](lock-screen.md) does not capture system audio.

## Verification

Synthetic offscreen checks cover audio-driven shader color and SceneScript
scale; live capture and desktop behavior require a separately authorized manual
check. See [Testing](../testing/README.md) and the
[verification log](../testing/verification-log.md).

Back to the [project README](../../README.md).
