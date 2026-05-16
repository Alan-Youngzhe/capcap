cask "capcap" do
  version "1.1.3"
  sha256 "7a51ab0dad4167b57938cdc64e20b16610caa346c424a7a17f0fd300a6000ff2"

  url "https://github.com/realskyrin/capcap/releases/download/release-v#{version}/capcap-#{version}-macos.zip"
  name "capcap"
  desc "Lightweight native macOS menu bar screenshot tool"
  homepage "https://github.com/realskyrin/capcap"

  depends_on macos: ">= :sonoma"

  app "capcap.app"

  uninstall quit: "cn.skyrin.capcap"

  zap trash: [
    "~/Library/Preferences/cn.skyrin.capcap.plist",
  ]
end
