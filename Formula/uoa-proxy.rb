class UoaProxy < Formula
  desc "Always-on University of Auckland Fortinet VPN control"
  homepage "https://github.com/JavaGT/uoa-proxy"
  url "https://github.com/JavaGT/uoa-proxy/archive/refs/tags/v1.0.0.tar.gz"
  version "1.0.0"
  license "MIT"

  depends_on macos: :sonoma
  depends_on "openconnect" => :build

  def install
    system "Scripts/package-release.sh", version
    archive = Dir["release/uoa-proxy-#{version}-*.tar.gz"].first
    odie "release archive was not created" unless archive
    system "tar", "-xzf", archive, "-C", buildpath
    payload = Dir["uoa-proxy-#{version}-*/"].first

    bin.install Dir["#{payload}bin/*"]
    share.install "#{payload}share/uoa-proxy"
    prefix.install "#{payload}Applications"
  end

  service do
    run [opt_bin / "uoa-proxyd"]
    keep_alive true
    log_path var / "log/uoa-proxy.log"
    error_log_path var / "log/uoa-proxy.log"
  end

  def caveats
    <<~EOS
      Start the daemon with:
        brew services start uoa-proxy

      The first connection requires the privileged VPN helper:
        uoa-proxy install-sudo

      The menu bar app is installed at:
        #{opt_prefix}/Applications/UoA Proxy.app
      Launch it with:
        uoa-proxy ui
    EOS
  end

  test do
    assert_match "uoa-proxyd", shell_output("#{bin}/uoa-proxyd --help")
    assert_predicate bin / "uoa-proxy", :exist?
  end
end
