#!/bin/sh
# LoopCtrl Pair .deb: make the new udev rule take effect for iPhones that
# are plugged in already. Never fails the install.
if command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload-rules >/dev/null 2>&1 || true
  udevadm trigger --subsystem-match=usb --attr-match=idVendor=05ac >/dev/null 2>&1 || true
fi
exit 0
