Sill Viewer
===========

An unofficial companion to Sill (https://getsill.app, https://github.com/Saffsanity/sill).
It is not made by the Sill team. "Sill" names the app this viewer works with.

A desktop app for Mac, Windows and Linux. It shows a computer that runs a Sill host:
a Mac with Sill, or Linux with sill-linux. You use it with your own mouse and keyboard.

USE
1. Open Sill Viewer. Computers on your network show in a list.
2. Click "Pair..." next to a computer. It shows a 12-digit code (and a QR window).
3. Type the code. You pair one time. After that, click Connect.

TRAY ICON
Sill Viewer puts an icon in the tray (Windows: by the clock; Mac: the menu bar; Linux: the top bar).
Its menu: Connect to a computer, Disconnect, Quality, Sharp, 120 fps, Fit screen, Full screen, Quit.
Closing the window only hides it. Click the tray icon (or "Show Sill Viewer") to get it back.
Use "Quit Sill Viewer" in the tray menu to quit.

In the stream window
- The bar at the top: pick the screen, the quality, Sharp (full resolution), 120 fps,
  and "Fit screen" (a virtual screen sized to this window, on hosts that have one).
- Match this screen: full screen, on a virtual screen with exactly your monitor's resolution, so
  one remote pixel is one pixel on your screen (hosts with virtual screens: sill-linux).
  The host also uses your screen's scale (a Retina Mac: 200%), so text keeps its normal size.
  On sill-linux the virtual screen replaces the computer's own monitors while you match: your
  windows and icons move to it, and its monitors go dark until you leave Match or disconnect.
- Full screen: click "Full screen" (Mac: the green window button). Ctrl+Alt+Shift+F leaves it.
- Files (sill-linux hosts): drop files or folders on the window to send them to the computer's
  Downloads folder. To get files from it, copy them there (Ctrl+C in Files), then click
  "Get copied files": they arrive in this computer's Downloads folder.
- Copy and paste work both ways (text, with sill-linux hosts). Text you copy on this computer
  goes to the host when you come back to the viewer window.
- Mouse, scroll wheel and keyboard go to the computer while the pointer is over the picture.
  Your own cursor shows where clicks land (with sill-linux 7 or later the host leaves its
  cursor out of the video for desktop viewers).
- Click outside the window to let go of every key and button.

WINDOWS
Unzip SillViewer-windows.zip anywhere. Run "Sill Viewer.exe". Keep the DLL files next to it.
Windows asks once to let it through the firewall: allow it on private networks.

MAC
In Terminal, in this folder:   ./build-mac.sh
It installs Homebrew's ffmpeg and Rust if needed, builds "Sill Viewer.app" and puts it in
/Applications. Open it from Launchpad or Spotlight. The app carries its own FFmpeg.
To build again after "git pull", run ./build-mac.sh again.

Sign with your Apple Developer ID (so it runs on other Macs without warnings):
  security find-identity -v -p codesigning          (copy the "Developer ID Application" name)
  SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build-mac.sh

NOTARIZE (one time setup, then the build does it):
  xcrun notarytool store-credentials sill --apple-id YOU@EXAMPLE.COM --team-id TEAMID
  (it asks for an app-specific password from appleid.apple.com)
  SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=sill ./build-mac.sh
The zip to share is target/SillViewer-mac.zip.

LINUX
Needs FFmpeg 6 or later (Ubuntu 24.04: sudo apt install libavcodec60 libavutil58).
Run ./sill-viewer

IF THE PICTURE NEVER SHOWS
The app uses the graphics card to decode video. If that hangs once, the app remembers
and decodes in software from then on. To force software decoding, set
SILL_SOFTWARE_DECODE=1 before you start it.

Settings and keys are kept in:
  Windows: %APPDATA%\sill-viewer    Mac: ~/Library/Application Support/sill-viewer
  Linux: ~/.config/sill-viewer
