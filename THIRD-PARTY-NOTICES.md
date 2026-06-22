# Third-Party Notices

NeatZip bundles the following third-party components. Their licenses are
included alongside the vendored sources and apply to those components.

## libdeflate
- Project: https://github.com/ebiggers/libdeflate
- Copyright 2016 Eric Biggers; Copyright 2024 Google LLC
- License: MIT
- License text: `Packages/CleanZipKit/Sources/Clibdeflate/src/COPYING`

## minizip-ng (v4.2.1, modified)
- Project: https://github.com/zlib-ng/minizip-ng
- Copyright (C) Nathan Moinvaziri and contributors; portions based on the
  original minizip by Gilles Vollant.
- License: zlib
- License text: `Packages/CleanZipKit/Sources/Cminizip/LICENSE`
- **Modified for NeatZip** (raw ZIP entry writes / AES key injection for the
  parallel libdeflate pipeline). Altered sources are marked per the zlib
  license; the patch is tracked in the project history
  (`prototype/minizip-ng.patch`).

## Sparkle
- Project: https://github.com/sparkle-project/Sparkle
- License: MIT (with bundled components under their own permissive licenses)
- Resolved as a Swift Package dependency (not vendored in this repository).
