# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-or-later
class Learner < Formula
  desc "Turns Claude Code into a learning loop: quizzes you on your own diffs"
  homepage "https://github.com/Tykok/learning-with-claude"
  url "https://github.com/Tykok/learning-with-claude/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "2eceec46e587c6e7a3f9bc2c3fd4b7056705f2e2510345f598a791c7982676ee"
  license "GPL-3.0-or-later"

  depends_on "jq"

  def install
    pkgshare.install "hooks", "skills", "install.sh", "uninstall.sh", "VERSION", "LICENSE"

    (bin/"learner-install").write <<~SH
      #!/bin/sh
      exec "#{pkgshare}/install.sh" --origin brew "$@"
    SH
    (bin/"learner-uninstall").write <<~SH
      #!/bin/sh
      exec "#{pkgshare}/uninstall.sh" "$@"
    SH
    chmod 0755, bin/"learner-install"
    chmod 0755, bin/"learner-uninstall"
  end

  def caveats
    <<~EOS
      Learner is staged but not yet active. Wire it into ~/.claude with:
        learner-install --level S --synthesis normal --blanks 2
      See `learner-install --help` for every flag.
    EOS
  end

  test do
    system "#{bin}/learner-install", "--help"
  end
end
