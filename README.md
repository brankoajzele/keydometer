# Compile

```
mkdir -p build
swiftc src/*.swift -o build/Keydometer \
  -framework Cocoa \
  -framework ApplicationServices

```

# Run

```
./build/Keydometer
```

# Build a background `.app`

Running the binary directly opens a Terminal window. To create a double-clickable app bundle that runs in the background (no Terminal, only the menu-bar icon), use the helper script:

```
./build_app.sh
open build/Keydometer.app
```

The script compiles the binary into `build/Keydometer`, copies it plus `Info.plist` (which sets `LSUIElement=1` so the app has no Dock icon) into `build/Keydometer.app/Contents`, and leaves you with a bundle you can double-click from Finder like any other macOS menu-bar utility.

Be sure to set:

1) System Settings > Privacy & Security > Allow applications to monitor keyboard input > Keydometer.app

2) Allow assistive applicaitons to control the computer > Keydometer.app

# Add an app to auto-run on system login 

System Settings → General → Login Items

Then under “Open at Login”, click + and choose your .app.

# .vscode/tasks.json

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Build Keydometer (.app)",
      "type": "shell",
      "command": "${workspaceFolder}/build_app.sh",
      "options": {
        "cwd": "${workspaceFolder}"
      },
      "group": "build",
      "problemMatcher": []
    }
  ]
}
```

# .vscode/launch.json

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "swift",
      "name": "Debug Keydometer",
      "request": "launch",
      "program": "${workspaceFolder}/build/Keydometer",
      "cwd": "${workspaceFolder}",
      "preLaunchTask": "Build Keydometer (.app)"
    }
  ]
}
```
