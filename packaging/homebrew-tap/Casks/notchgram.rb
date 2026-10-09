cask "notchgram" do
  version "0.1.0"
  sha256 "44f974922e416371c4e1f78ec9ef1634cb473767108cc4c2de0c978b738f8214"

  url "https://github.com/f1lcry/notchgram/releases/download/v#{version}/NotchGram-#{version}.dmg"
  name "NotchGram"
  desc "Telegram client that lives in the notch"
  homepage "https://github.com/f1lcry/notchgram"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :tahoe # minimum: macOS 26 or newer

  app "NotchGram.app"

  # A graceful quit: the app closes its encrypted Telegram database first.
  uninstall quit: "com.f1lcry.notchgram"

  zap trash: [
    "~/Library/Application Support/NotchGram",
    "~/Library/Caches/com.f1lcry.notchgram",
    "~/Library/HTTPStorages/com.f1lcry.notchgram",
    "~/Library/Preferences/com.f1lcry.notchgram.plist",
    "~/Library/Saved Application State/com.f1lcry.notchgram.savedState",
  ]
end
