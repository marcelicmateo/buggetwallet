# Budget Wallet dev environment: Flutter + Android SDK in a Linux container.
# Can do: run tests, build Android APKs, Linux desktop and web builds.
# Cannot do: iOS / macOS builds — those need a Mac with Xcode (Apple's rule, not a Docker limit).
FROM ghcr.io/cirruslabs/flutter:stable

# Linux desktop build tools + SQLite (the app's local database, Drift) for tests
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libsqlite3-dev sqlite3 \
 && rm -rf /var/lib/apt/lists/*

RUN flutter config --no-analytics \
 && dart --disable-analytics \
 && flutter precache --android --linux --web \
 && git config --global --add safe.directory '*'

WORKDIR /work
CMD ["bash"]
