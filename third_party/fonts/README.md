# IBM Plex fonts

Used by the app (Ledger theme): IBM Plex Sans and IBM Plex Mono, Regular, Medium and SemiBold, six static TrueType files in
`app/assets/fonts/`. The files are unmodified copies from the official releases.

- Source: https://github.com/IBM/plex/releases
  - `@ibm/plex-sans@1.1.0`, `ibm-plex-sans.zip`, `fonts/complete/ttf/IBMPlexSans-{Regular,Medium,SemiBold}.ttf`
  - `@ibm/plex-mono@2.5.0`, `ibm-plex-mono.zip`, `fonts/complete/ttf/IBMPlexMono-{Regular,Medium,SemiBold}.ttf`
- Licence: SIL Open Font License 1.1, copy in `app/assets/fonts/OFL.txt` (verbatim `LICENSE.txt` from the release zips).
  Copyright 2017 IBM Corp. with Reserved Font Name "Plex". The files are not modified or renamed.
- The licence is registered in `main()` (`registerFontLicense`), so it shows on the app's licences page.
- Size: 1,127,260 bytes in total.

sha256 (first 16 hex digits):
```
331c8639d7598b2c  IBMPlexSans-Medium.ttf
975dcda37d80f038  IBMPlexSans-Regular.ttf
a20caf8286023a6a  IBMPlexSans-SemiBold.ttf
98fbd727aae340b2  IBMPlexMono-Medium.ttf
7c6fbddca4b700be  IBMPlexMono-Regular.ttf
f04d7c488ddf7d1f  IBMPlexMono-SemiBold.ttf
```
