Sill Desktop Host (unofficial)
==============================

An unofficial build of Sill's Mac host (https://github.com/Saffsanity/sill), for the Sill Desktop
viewers. It works like Sill on a Mac: the iPhone and iPad app and Sill Viewer connect to it.
Not made by the Sill team. See NOTICE for what changed.

BUILD AND INSTALL (on the Mac you want to view)
Needs Xcode (or Apple's Command Line Tools) and macOS 14 or later.

  cd ~/Sill-Viewer/mac-host
  Scripts/make-app.sh --install --open

It builds SillDesktopHost.app, puts it in /Applications, quits Sill.app if it runs, and starts.
First run: allow Screen Recording and Accessibility when it asks (System Settings ›
Privacy & Security). Pair your devices again: this app has its own identity.

Only one host may run. Best: delete Sill.app from this Mac (and from Login Items). Two hosts both
answer as this Mac, and the viewer can quietly reach Sill's own app, which has no Fit screen for the
desktop. Both write to the same log file (~/Library/Logs/Sill/Sill.log).

Screen Recording: SillDesktopHost must be in the UPPER list of System Settings › Privacy & Security
› Screen & System Audio Recording (not "System Audio Recording Only"). Turn it on, then quit and
open the app. Signs of a missing grant: "Waiting for picture", and "0 windows" in the log.

No Xcode? The Command Line Tools are enough (the app gets a plain icon):
  sudo softwareupdate -i "Command Line Tools for Xcode <version>"   (softwareupdate --list shows it)

Signing: the script uses your first "Apple Development" certificate, so the permissions stay
granted across rebuilds. SILL_SIGN_IDENTITY="…" picks another one (a name or the SHA-1 hash from
security find-identity -v -p codesigning), for example a "Developer ID Application" certificate.
A different certificate is a new app to macOS: allow Screen Recording and Accessibility again.

IF OTHER COMPUTERS CAN'T FIND THIS MAC
macOS ties the Local Network permission to the app's signature. An "ad hoc" build (no developer
certificate) is a new app to macOS after every rebuild, and it is quietly kept off the network.
1. Check:  codesign -dv /Applications/SillDesktopHost.app 2>&1 | grep Authority
   No "Apple Development: …" line means ad hoc. In Xcode › Settings › Accounts › Manage
   Certificates, add an Apple Development certificate, then build again.
2. System Settings › Privacy & Security › Local Network: turn SillDesktopHost off and on, then
   quit and open the app.
Test from another Mac:  dns-sd -B _sill._tcp   (this Mac's name must be listed)

ADDED
- Files both ways with Sill Viewer: drop files on the viewer window to save them in this Mac's
  Downloads; copy files in Finder (Cmd+C), then click "Get copied files" in the viewer.
  macOS asks once for access to Downloads (and to the folders you send from).

- Fit screen and Match this screen for the whole desktop (a virtual screen of the viewer's size
  becomes the main screen; the real screens come back when you turn it off or disconnect).
- Wakes the screens for a viewer and keeps them awake while one is connected.

PLANNED ADDITIONS
- Scale menu: the Mac redraws bigger for a small viewer screen.
- Works while the Mac is locked (a system service and a login window helper, macOS 14.4+).
