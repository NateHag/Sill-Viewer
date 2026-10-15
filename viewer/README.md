Sill Viewer
===========

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
- Full screen: click "Full screen". Press Ctrl+Alt+Shift+F to leave it.
- Mouse, scroll wheel and keyboard go to the computer while the pointer is over the picture.
  Your own cursor shows where clicks land (with sill-linux 7 or later the host leaves its
  cursor out of the video for desktop viewers).
- Click outside the window to let go of every key and button.

WINDOWS
Unzip SillViewer-windows.zip anywhere. Run "Sill Viewer.exe". Keep the DLL files next to it.
Windows asks once to let it through the firewall: allow it on private networks.

MAC
In Terminal, in this folder:   ./build-mac.sh
It installs Homebrew's ffmpeg and Rust if needed, then builds "target/Sill Viewer.app".

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
