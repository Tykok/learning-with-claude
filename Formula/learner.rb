# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-or-later
class Learner < Formula
  desc "Turns Claude Code into a learning loop: quizzes you on your own diffs"
  homepage "https://github.com/Tykok/learning-with-claude"
  url "https://github.com/Tykok/learning-with-claude/archive/refs/tags/v0.2.0.tar.gz"
  sha256 "5b4c5dd3c5da37eaf1fd3dffcea972ee005fd954361f30c73258957c7430cc8e"
  license "GPL-3.0-or-later"

  depends_on "jq"

  def install
    # "skills" ships every skill under it without naming one here — do not
    # narrow this to a per-skill path: that is the exact hand-maintained list
    # install.sh's copy loop exists to avoid.
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
