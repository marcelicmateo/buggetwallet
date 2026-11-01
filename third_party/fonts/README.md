# Fonts (Inter and IBM Plex Mono)

Used by the app (Clean neutral theme, UX-C1): **Inter** for text and **IBM Plex Mono** for amounts, Regular, Medium and SemiBold, six static
TrueType files in `app/assets/fonts/`. The files are unmodified copies from the official releases. (IBM Plex Sans was dropped in UX-C1.)

## Inter
- Source: the rsms/inter GitHub release v4.1, `Inter-4.1.zip`, `extras/ttf/Inter-{Regular,Medium,SemiBold}.ttf`.
  The release page lists no checksum; `Inter-4.1.zip` sha256 as downloaded: `9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e`.
- Licence: SIL Open Font License 1.1, `app/assets/fonts/OFL-Inter.txt` (verbatim `LICENSE.txt` of the zip; Copyright 2016 The Inter Project Authors).
- sha256 (first 16 hex digits):
```
40d692fce188e447  Inter-Regular.ttf
97ad806f526e4154  Inter-Medium.ttf
78a843fade9d4612  Inter-SemiBold.ttf
```

## IBM Plex Mono
- Source: https://github.com/IBM/plex/releases
  - `@ibm/plex-mono@2.5.0`, `ibm-plex-mono.zip`, `fonts/complete/ttf/IBMPlexMono-{Regular,Medium,SemiBold}.ttf`
- Licence: SIL Open Font License 1.1, copy in `app/assets/fonts/OFL.txt` (verbatim `LICENSE.txt` from the release zip).
  Copyright 2017 IBM Corp. with Reserved Font Name "Plex". The files are not modified or renamed.
- sha256 (first 16 hex digits):
```
98fbd727aae340b2  IBMPlexMono-Medium.ttf
7c6fbddca4b700be  IBMPlexMono-Regular.ttf
f04d7c488ddf7d1f  IBMPlexMono-SemiBold.ttf
```

Both licences are registered in `main()` (`registerFontLicense`), so they show on the app's licences page.
