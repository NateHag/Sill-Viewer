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

Only one host should run: in Sill › Settings › General, turn off "Open at login" for Sill, and turn
it on for Sill Desktop Host.

Signing: the script uses your first "Apple Development" certificate, so the permissions stay
granted across rebuilds. SILL_SIGN_IDENTITY="…" picks another one.

PLANNED ADDITIONS
- Scale menu: the Mac redraws bigger for a small viewer screen.
- Files both ways, as with sill-linux.
- Match this screen.
- Works while the Mac is locked (a system service and a login window helper, macOS 14.4+).
