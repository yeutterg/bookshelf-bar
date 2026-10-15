cask "bookshelfbar" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/yeutterg/bookshelf-bar/releases/download/v#{version}/BookshelfBar-#{version}.dmg"
  name "BookshelfBar"
  desc "Menu bar controls for KEF LSX II and LSX II LT speakers"
  homepage "https://github.com/yeutterg/bookshelf-bar"

  depends_on macos: ">= :tahoe"

  app "BookshelfBar.app"

  caveats <<~EOS
    BookshelfBar isn't notarized by Apple yet. If macOS says it can't be opened,
    allow it in System Settings → Privacy & Security (Open Anyway), or run:
      xattr -dr com.apple.quarantine #{appdir}/BookshelfBar.app
  EOS

  zap trash: [
    "~/Library/Preferences/com.github.yeutterg.bookshelfbar.plist",
  ]
end
