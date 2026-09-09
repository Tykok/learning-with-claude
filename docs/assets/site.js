// Progressive enhancement, and nothing else: every .copy-line already shows the
// command in full, so a browser without the clipboard API loses a convenience,
// not a step. No button is added when there is nothing to add it for.
if (navigator.clipboard) {
  document.querySelectorAll(".copy-line").forEach(function (line) {
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "btn btn-ghost btn-sm copy-btn";
    btn.textContent = "Copy";
    btn.addEventListener("click", function () {
      navigator.clipboard.writeText(line.querySelector("code").textContent).then(function () {
        btn.textContent = "Copied";
        setTimeout(function () { btn.textContent = "Copy"; }, 1600);
      });
    });
    line.append(btn);
  });
}
