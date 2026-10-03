#!/usr/bin/env bash
set -euo pipefail

ANDROID_DIR=build/Android
ANDROID_OUTPUT_DIR=$ANDROID_DIR/app/src/main/assets

cp -rv assets $ANDROID_OUTPUT_DIR

$ANDROID_DIR/gradlew -p $ANDROID_DIR assembleDebug
mv -v $ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk raylib-zig-example.apk
