# Datasets

Curated site data that shipped with the earlier feature-identification
build. Kept here, outside `LidarExplorer/`, so it is preserved in the repo
but **not** copied into the app bundle.

The target uses a `PBXFileSystemSynchronizedRootGroup` rooted at
`LidarExplorer/`, which means every file under that folder is bundled
automatically — including documentation and unused data. These four files
totalled ~73 KB of payload the viewer never reads.

Move a file back under `LidarExplorer/` to ship it again.
