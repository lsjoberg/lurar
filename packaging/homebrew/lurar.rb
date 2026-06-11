cask "lurar" do
  version "0.9.1"
  sha256 "0235bcfd9aa359fac94dda74277cc64b8d817312c8a95cee00bcb6f1ee3482a4"

  url "https://github.com/lsjoberg/lurar/releases/download/v#{version}/Lurar-#{version}.dmg",
      verified: "github.com/lsjoberg/lurar/"
  name "Lurar"
  desc "System-wide parametric headphone EQ with the AutoEq catalog built in"
  homepage "https://lurar.app/"

  livecheck do
    url "https://lurar.app/appcast.xml"
    strategy :sparkle do |item|
      item.short_version
    end
  end

  auto_updates true
  depends_on macos: :sonoma

  app "Lurar.app"

  zap trash: [
    "~/Library/Application Support/Lurar",
    "~/Library/Caches/app.lurar.Lurar",
    "~/Library/HTTPStorages/app.lurar.Lurar",
    "~/Library/Preferences/app.lurar.Lurar.plist",
  ]
end
