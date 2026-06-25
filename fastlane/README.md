fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Mac

### mac fetch_metadata

```sh
[bundle exec] fastlane mac fetch_metadata
```

App Store Connect からメタデータをダウンロード（ASC レコード作成後）

### mac upload_metadata

```sh
[bundle exec] fastlane mac upload_metadata
```

メタデータを App Store Connect にアップロード（スクショは手動管理のためスキップ）

### mac build

```sh
[bundle exec] fastlane mac build
```

MAS 版を署名済み .pkg にビルド（検証済み scripts/release-mas.sh を実行）

### mac upload_build

```sh
[bundle exec] fastlane mac upload_build
```

ビルド済みの署名済み .pkg を App Store Connect にアップロード

### mac release

```sh
[bundle exec] fastlane mac release
```

ビルド → アップロード（release-mas.sh で .pkg を作り ASC へ送る）

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
