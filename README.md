# raylib-zig Android build template

This is a template for building a raylib-zig game for android, please note that the solution is extremely wacky and anything can fail.

## Requirements

- [Android NDK](https://developer.android.com/ndk/)
- [Gradle](https://gradle.org/)
- A [Raylib](https://github.com/raysan5/raylib) .a file compiled for Android (Depending on target archtitecture)

> [!NOTE]
> armv7 is not properly tested since i don't have an armv7 android 10+ device (see below) 

## Android requirements

- Android 10 or higher
  - It may probably run on older devices, but LLVM builds and expects `native thread-local storage`, so runtime crash with `unknown reloc type 17 @ 0x9c436c64 (531)`, and even assigning __gshared to everything, not even the simplest example runs, failing with `dlopen failed: cannot locate symbol "pthread_attr_setinheritsched"` (Android 9+).

## Prepare

### Compile Raylib

1. Clone and build raylib

```
git clone https://github.com/raysan5/raylib
cd raylib/src
```

```
make PLATFORM=PLATFORM_ANDROID \
     ANDROID_NDK=/path/to/your/android-ndk \
     ANDROID_ARCH=arm64 \
     ANDROID_API_VERSION=29
```

> Replace `aarch64` to `x86_64` or `arm` if needed

2. Place your raylib in `raylib-android` according to the desired archtitecture, for example:

```
-> tree raylib-android/
raylib-android/
├── arm64-v8a
│   └── libraylib.a
└── x86_64
    └── libraylib.a
```

3. Add submodule


```
git submodule add https://github.com/zariep-software/raylib-zig-android-template.git vendor/raylib-zig-android
```

4. Define environment variables

```
export ANDROID_NDK_HOME=/opt/android-ndk
export RAYLIB_LIB_DIR=/home/user/raylib-android/
export ANDROID_OUTPUT_DIR=/path/to/your/apk/setup/
```

> Replace those paths with the actual paths, or copy `asetup.example` to
> `asetup.sh` and edit it. `build-android.zig` loads simple `KEY=VALUE`
> lines from `asetup.sh` automatically if the file exists, and expands
> `$VAR`, `${VAR}`, and a leading `~` (e.g. `$USER`, `$HOME`) the same
> way a shell would.

5. Copy `examples/build.zig` or adapt it to your project

### Try to build

```shell
zig build android -Dabi=arm64-v8a
```

> To build for multiple architectures in one go just call it once per ABI, Each run writes its output to `android/app/src/main/jniLibs/<ABI>/libmain.so`, so subsequent runs for different ABIs don't overwrite each other. The resulting `jniLibs/` tree can then be picked up as is by a single Gradle build producing a multi-ABI APK/AAB.


```
gradle wrapper # You may need to get gradlew jar first time
```

```
./gradlew assembleDebug
```

## More Information

More information about setting up a game for android in raylib-zig (e.g. Setting up / troubleshoot things like rotation, Touch screen or screen size) available on [the wiki](https://github.com/Zariep-Software/raylib-zig-android-template/wiki)
