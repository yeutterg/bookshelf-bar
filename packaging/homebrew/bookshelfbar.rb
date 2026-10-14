cask "bookshelfbar" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/yeutterg/bookshelf-bar/releases/download/v#{version}/BookshelfBar-#{version}.dmg"
  name "BookshelfBar"
  desc "Menu bar controls for KEF LSX II and LSX II LT speakers"
  homepage "https://github.com/yeutterg/bookshelf-bar"

  depends_on macos: ">= :tahoe"

  app "BookshelfBar.app"

  zap trash: [
    "~/Library/Preferences/com.github.yeutterg.bookshelfbar.plist",
  ]
end
