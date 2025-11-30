# Compile vs. Build

There are two ways to use Keydometer:

1. Build the command-line binary into `build/Keydometer` and launch it from Terminal. This is best while developing or debugging.
2. Build a `.app` bundle via the helper script so the app runs in the background and shows only the menu-bar item.

## Compile the CLI binary

```
mkdir -p build
swiftc src/*.swift -o build/Keydometer \
  -framework Cocoa \
  -framework ApplicationServices

./build/Keydometer
```

Running the binary directly launches Keydometer but keeps an attached Terminal window open.

## Build the background `.app`

Use the helper script to compile and wrap the binary inside a macOS app bundle:

```
./build_app.sh
open build/Keydometer.app
```

The script first compiles the binary into `build/Keydometer`, then copies it plus `Info.plist` (which sets `LSUIElement=1` so the app has no Dock icon) into `build/Keydometer.app/Contents`. Double-clicking `Keydometer.app` launches the same binary without any Terminal windows—perfect for daily use.

Be sure to set:

1) System Settings > Privacy & Security > Allow applications to monitor keyboard input > Keydometer.app

2) Allow assistive applicaitons to control the computer > Keydometer.app

# Add the app to auto-run on system login 

System Settings → General → Login Items

Then under “Open at Login”, click + and choose your .app.
