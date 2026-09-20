defmodule TravelingPoet.Evals.ImagePage do
  @moduledoc """
  Writes the blind judging page for an image eval run: `page/index.html`,
  plus the images renamed by letter so neither the page nor its file names
  say which model drew what.

  The page is static and works from `file://`. Votes are kept in the
  browser's localStorage and leave it only through the "Export votes"
  button, as the JSON `mix tpoet.eval_images --report` reads.
  """

  def write(run_dir, manifest) do
    page_dir = Path.join(run_dir, "page")
    File.mkdir_p!(page_dir)
    results = Map.new(manifest["results"], &{{&1["prompt_id"], &1["candidate_id"]}, &1})

    prompts =
      Enum.map(manifest["prompts"], fn p ->
        images =
          manifest["blind"]
          |> Map.get(p["id"], %{})
          |> Enum.sort()
          |> Enum.map(fn {letter, cid} ->
            tile(run_dir, page_dir, p["id"], letter, results[{p["id"], cid}])
          end)

        %{
          id: p["id"],
          category: p["category"],
          kind: p["kind"],
          prompt: p["prompt"],
          images: images
        }
      end)

    data = %{run_id: manifest["run_id"], prompts: prompts}
    File.write!(Path.join(page_dir, "index.html"), html(data))
    Path.join(page_dir, "index.html")
  end

  defp tile(_run_dir, _page_dir, _pid, letter, nil), do: %{letter: letter, missing: true}

  defp tile(_run_dir, _page_dir, _pid, letter, %{"status" => "error"}),
    do: %{letter: letter, missing: true}

  defp tile(run_dir, page_dir, pid, letter, r) do
    src = Path.join(run_dir, r["file"])
    full = Path.join(["full", pid, letter <> Path.extname(r["file"])])
    thumb = Path.join(["thumb", pid, letter <> ".jpg"])

    copy(src, Path.join(page_dir, full))
    thumbnail(src, Path.join(page_dir, thumb))

    screen = r["screen"]

    %{
      letter: letter,
      full: full,
      thumb: if(File.exists?(Path.join(page_dir, thumb)), do: thumb, else: full),
      screen:
        screen &&
          %{pass: screen["pass"], issues: screen["issues"] || [], reason: screen["reason"]}
    }
  end

  defp copy(src, dest) do
    File.mkdir_p!(Path.dirname(dest))
    unless File.exists?(dest), do: File.cp!(src, dest)
  end

  # macOS sips keeps the page light (a Gemini PNG is over 1MB); without it
  # the page falls back to the full images.
  defp thumbnail(src, dest) do
    File.mkdir_p!(Path.dirname(dest))

    if not File.exists?(dest) and System.find_executable("sips") do
      System.cmd(
        "sips",
        ["-Z", "900", "-s", "format", "jpeg", "-s", "formatOptions", "82", src, "--out", dest],
        stderr_to_stdout: true
      )
    end
  end

  defp html(data) do
    json =
      data
      |> Jason.encode!()
      |> String.replace("</", "<\\/")

    String.replace(template(), "__DATA__", json)
  end

  defp template do
    ~S"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Image eval</title>
    <style>
    :root {
      --bg: #f7f5f0; --card: #ffffff; --ink: #1f1d1a; --muted: #6b665d;
      --line: #e3ded4; --accent: #2f5d50; --accent-soft: #e3eee9;
      --warn: #8a5a14; --warn-soft: #f6ecd9;
    }
    @media (prefers-color-scheme: dark) {
      :root:not([data-theme="light"]) {
        --bg: #161614; --card: #1f1f1c; --ink: #ece8df; --muted: #a39d91;
        --line: #34322d; --accent: #8cc4b0; --accent-soft: #1f302a;
        --warn: #e0b56a; --warn-soft: #33291a;
      }
    }
    :root[data-theme="dark"] {
      --bg: #161614; --card: #1f1f1c; --ink: #ece8df; --muted: #a39d91;
      --line: #34322d; --accent: #8cc4b0; --accent-soft: #1f302a;
      --warn: #e0b56a; --warn-soft: #33291a;
    }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--bg); color: var(--ink);
      font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    header { position: sticky; top: 0; z-index: 2; background: var(--bg);
      border-bottom: 1px solid var(--line); padding: 12px 16px;
      display: flex; flex-wrap: wrap; gap: 8px 16px; align-items: center; }
    header h1 { font-size: 17px; margin: 0; }
    header .meta { color: var(--muted); font-size: 13px; }
    header .spacer { flex: 1; }
    button, select { font: inherit; color: var(--ink); background: var(--card);
      border: 1px solid var(--line); border-radius: 8px; padding: 6px 12px; cursor: pointer; }
    button.primary { background: var(--accent); color: var(--bg); border-color: var(--accent); }
    main { max-width: 1280px; margin: 0 auto; padding: 16px; }
    .intro { color: var(--muted); font-size: 14px; margin: 0 0 16px; }
    section.prompt { background: var(--card); border: 1px solid var(--line);
      border-radius: 12px; padding: 16px; margin-bottom: 20px; }
    section.prompt.done { border-color: var(--accent); }
    .phead { display: flex; gap: 8px; align-items: baseline; flex-wrap: wrap; }
    .chip { font-size: 12px; padding: 1px 8px; border-radius: 999px;
      background: var(--accent-soft); color: var(--accent); }
    .pid { color: var(--muted); font-size: 13px; }
    details { margin: 8px 0 12px; font-size: 14px; color: var(--muted); }
    summary { cursor: pointer; }
    .grid { display: grid; gap: 12px; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); }
    @media (max-width: 600px) { .grid { grid-template-columns: 1fr 1fr; gap: 8px; } }
    .tile { border: 2px solid var(--line); border-radius: 10px; overflow: hidden;
      display: flex; flex-direction: column; background: var(--bg); }
    .tile.best { border-color: var(--accent); }
    .tile img { width: 100%; aspect-ratio: 1 / 1; object-fit: contain; background: #fff; display: block; cursor: zoom-in; }
    .tile .bar { display: flex; gap: 8px; align-items: center; padding: 8px; flex-wrap: wrap; font-size: 14px; }
    .tile .letter { font-weight: 700; width: 1.5em; }
    .tile label { display: inline-flex; gap: 4px; align-items: center; cursor: pointer; }
    .flag { background: var(--warn-soft); color: var(--warn); font-size: 13px; padding: 8px; }
    .folded img { display: none; }
    .missing { padding: 24px 8px; text-align: center; color: var(--muted); font-size: 14px; }
    .hidden { display: none; }
    </style>
    </head>
    <body>
    <header>
      <h1>Image eval</h1>
      <span class="meta" id="run"></span>
      <span class="meta" id="progress"></span>
      <span class="spacer"></span>
      <select id="filter" aria-label="Filter prompts">
        <option value="all">All prompts</option>
        <option value="todo">Not judged yet</option>
      </select>
      <button class="primary" id="export">Export votes</button>
    </header>
    <main>
      <p class="intro">For each prompt, pick the one drawing you would most want in the journal,
      and tick every drawing you would be happy to publish. Letters are shuffled per prompt.
      Drawings the pre-screen flagged are folded; open them if you disagree.
      Click a drawing for full size. Votes stay in this browser until you export them.</p>
      <div id="prompts"></div>
    </main>
    <script id="data" type="application/json">__DATA__</script>
    <script>
    (function () {
      var data = JSON.parse(document.getElementById("data").textContent);
      var key = "image-eval:" + data.run_id;
      var votes = {};
      try { votes = JSON.parse(localStorage.getItem(key) || "{}") || {}; } catch (e) { votes = {}; }
      function save() { try { localStorage.setItem(key, JSON.stringify(votes)); } catch (e) {} }
      function vote(pid) { return votes[pid] || (votes[pid] = { best: null, publishable: [] }); }

      document.getElementById("run").textContent = data.run_id;
      var root = document.getElementById("prompts");

      function el(tag, attrs, text) {
        var n = document.createElement(tag);
        for (var k in attrs || {}) { n.setAttribute(k, attrs[k]); }
        if (text != null) { n.textContent = text; }
        return n;
      }

      data.prompts.forEach(function (p) {
        var s = el("section", { "class": "prompt", "data-pid": p.id });
        var head = el("div", { "class": "phead" });
        head.appendChild(el("span", { "class": "chip" }, p.category));
        head.appendChild(el("span", { "class": "pid" }, p.id));
        s.appendChild(head);
        var d = el("details");
        d.appendChild(el("summary", {}, "Prompt"));
        d.appendChild(el("p", {}, p.prompt));
        s.appendChild(d);
        var grid = el("div", { "class": "grid" });

        p.images.forEach(function (img) {
          var t = el("div", { "class": "tile", "data-letter": img.letter });
          if (img.missing) {
            t.appendChild(el("div", { "class": "missing" }, img.letter + ": no image (generation failed)"));
            grid.appendChild(t);
            return;
          }
          if (img.screen && !img.screen.pass) {
            t.classList.add("folded");
            var f = el("div", { "class": "flag" },
              "Pre-screen: " + (img.screen.issues.join(", ") || "flagged") + ". " + (img.screen.reason || ""));
            var show = el("button", { type: "button" }, "Show");
            show.style.marginLeft = "8px";
            show.onclick = function () { t.classList.remove("folded"); show.remove(); };
            f.appendChild(show);
            t.appendChild(f);
          }
          var a = el("a", { href: img.full, target: "_blank", rel: "noopener" });
          a.appendChild(el("img", { src: img.thumb, alt: "Drawing " + img.letter, loading: "lazy" }));
          t.appendChild(a);
          var bar = el("div", { "class": "bar" });
          bar.appendChild(el("span", { "class": "letter" }, img.letter));
          var bl = el("label");
          var best = el("input", { type: "radio", name: "best-" + p.id, value: img.letter });
          best.onchange = function () { vote(p.id).best = img.letter; save(); refresh(); };
          bl.appendChild(best); bl.appendChild(document.createTextNode("Best"));
          var pl = el("label");
          var pub = el("input", { type: "checkbox", value: img.letter });
          pub.onchange = function () {
            var v = vote(p.id);
            v.publishable = v.publishable.filter(function (l) { return l !== img.letter; });
            if (pub.checked) { v.publishable.push(img.letter); }
            save(); refresh();
          };
          pl.appendChild(pub); pl.appendChild(document.createTextNode("Publishable"));
          bar.appendChild(bl); bar.appendChild(pl);
          t.appendChild(bar);
          grid.appendChild(t);
        });

        s.appendChild(grid);
        root.appendChild(s);
      });

      function refresh() {
        var done = 0;
        var filter = document.getElementById("filter").value;
        data.prompts.forEach(function (p) {
          var v = votes[p.id];
          var s = root.querySelector('section[data-pid="' + p.id + '"]');
          var isDone = !!(v && v.best);
          if (isDone) { done++; }
          s.classList.toggle("done", isDone);
          s.classList.toggle("hidden", filter === "todo" && isDone);
          s.querySelectorAll(".tile").forEach(function (t) {
            var l = t.getAttribute("data-letter");
            var radio = t.querySelector('input[type="radio"]');
            var box = t.querySelector('input[type="checkbox"]');
            if (radio) { radio.checked = !!(v && v.best === l); }
            if (box) { box.checked = !!(v && v.publishable.indexOf(l) >= 0); }
            t.classList.toggle("best", !!(v && v.best === l));
          });
        });
        document.getElementById("progress").textContent = done + " of " + data.prompts.length + " judged";
      }

      document.getElementById("filter").onchange = refresh;
      document.getElementById("export").onclick = function () {
        var blob = new Blob([JSON.stringify({ run_id: data.run_id, votes: votes }, null, 2)],
          { type: "application/json" });
        var a = document.createElement("a");
        a.href = URL.createObjectURL(blob);
        a.download = "votes-" + data.run_id + ".json";
        document.body.appendChild(a); a.click(); a.remove();
      };
      refresh();
    })();
    </script>
    </body>
    </html>
    """
  end
end
