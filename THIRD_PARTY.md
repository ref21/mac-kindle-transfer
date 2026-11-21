Kindle Drive uses libmtp 1.1.22 (LGPL 2.1 or later) and libusb (LGPL 2.1 or later), dynamically linked as replaceable libraries in Contents/Frameworks.

libmtp source is included in Vendor/libmtp-1.1.22, with its copyright and license notices. Upstream: https://github.com/libmtp/libmtp/tree/v1.1.22
Kindle Drive modifies one file: src/libusb1-glue.c (2026-11-19), so that a failed USB reset during connection is reported instead of crashing. The change is marked "Kindle Drive change" in the source.
libusb source: https://github.com/libusb/libusb (the exact bundled versions are recorded inside the app at Contents/Resources/Licenses/VERSIONS.txt). Each GitHub release that includes a prebuilt app also includes the source of the libusb version bundled in it, such as libusb-1.0.29.tar.bz2.
License texts are included inside the application in Contents/Resources/Licenses.

You may replace the libraries with ABI-compatible builds and ad-hoc sign the changed libraries/application using codesign --force --sign -. Rebuild instructions for the application and libmtp are provided in scripts/build.sh. No Amazon code or services are used. Kindle is a trademark of Amazon; this is an independent application.
