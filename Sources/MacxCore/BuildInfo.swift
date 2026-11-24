// The beta workflow (beta-build.yml) replaces the nil below with the commit it builds, so a dev build reports
// `dev-<commit>`. Releases and local builds leave it nil and report `macxVersion`. Keep it on one line.
public let macxBuildCommit: String? = nil
