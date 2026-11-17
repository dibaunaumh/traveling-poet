defmodule TravelingPoet.Evals.Writing.Page do
  @moduledoc """
  Writes the blind judging page for a writing eval run: `page/index.html`.

  One day at a time, every candidate's page side by side under a letter
  shuffled per day; `published` (what readers got) is one of them. The page
  is static and works from `file://`. Votes are kept in the browser's
  localStorage and leave it only through "Export votes", as the JSON
  `mix tpoet.eval_writing --report` reads.

  The automatic checks and the language judge show on each page as small
  notes, because "3 broken sentences" is what to look for; the model behind
  a letter does not.
  """

  def write(run_dir, manifest, days) do
    page_dir = Path.join(run_dir, "page")
    File.mkdir_p!(page_dir)
    results = Map.new(manifest["results"], &{{&1["day_id"], &1["candidate_id"]}, &1})
    research = Map.new(days, &{&1["id"], &1["research"]})

    data = %{
      run_id: manifest["run_id"],
      days:
        Enum.map(manifest["days"], fn d ->
          %{
            id: d["id"],
            poet: d["poet"],
            language: d["language"],
            mission: d["mission"],
            excursion: d["excursion"],
            date: d["entry_date"],
            research: Enum.map(research[d["id"]] || [], &%{tool: &1["tool"], ref: &1["ref"]}),
            pages:
              manifest["blind"]
              |> Map.get(d["id"], %{})
              |> Enum.sort()
              |> Enum.map(fn {letter, cid} -> card(letter, results[{d["id"], cid}]) end)
          }
        end)
    }

    path = Path.join(page_dir, "index.html")
    File.write!(path, html(data))
    path
  end

  defp card(letter, %{"status" => "ok", "page" => page} = r) do
    %{
      letter: letter,
      title: page["title"],
      teaser: page["teaser"],
      sections:
        Enum.map(page["sections"], fn s ->
          %{kind: s["kind"], title: s["title"], html: markdown(s["body"])}
        end),
      notes: notes(r["metrics"], r["judge"]),
      examples: (r["judge"] || %{})["examples"] || []
    }
  end

  defp card(letter, r) do
    %{letter: letter, missing: (r && r["error"]) || "not written"}
  end

  # Raw HTML in a model's markdown is dropped, not rendered.
  defp markdown(body), do: MDEx.to_html!(body || "")

  defp notes(m, judge) do
    [
      judge && "#{judge["broken"]} broken sentences, fluency #{judge["fluency"]}/5",
      m["disclaimers"] > 0 && "#{m["disclaimers"]} disclaimers",
      m["mixed_words"] > 0 && "#{m["mixed_words"]} mixed-script words",
      m["foreign_chars"] > 0 && "#{m["foreign_chars"]} letters in other scripts",
      m["hebrew_share"] && m["hebrew_share"] < 0.9 && "Hebrew #{round(m["hebrew_share"] * 100)}%",
      "#{m["words"]} words"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp html(data) do
    json = data |> Jason.encode!() |> String.replace("</", "<\\/")
    String.replace(template(), "__DATA__", json)
  end

  defp template do
    ~S"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Writing eval</title>
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
      font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    header { position: sticky; top: 0; z-index: 2; background: var(--bg);
      border-bottom: 1px solid var(--line); padding: 12px 16px;
      display: flex; flex-wrap: wrap; gap: 8px 16px; align-items: center; }
    header h1 { font-size: 17px; margin: 0; }
    header .meta { color: var(--muted); font-size: 13px; }
    header .spacer { flex: 1; }
    button, select { font: inherit; color: var(--ink); background: var(--card);
      border: 1px solid var(--line); border-radius: 8px; padding: 6px 12px; cursor: pointer; }
    button.primary { background: var(--accent); color: var(--bg); border-color: var(--accent); }
    main { padding: 16px; }
    .intro { color: var(--muted); font-size: 14px; margin: 0 0 16px; max-width: 70ch; }
    section.day { background: var(--card); border: 1px solid var(--line);
      border-radius: 12px; padding: 16px; margin-bottom: 20px; }
    section.day.done { border-color: var(--accent); }
    .dhead { display: flex; gap: 8px; align-items: baseline; flex-wrap: wrap; }
    .chip { font-size: 12px; padding: 1px 8px; border-radius: 999px;
      background: var(--accent-soft); color: var(--accent); }
    .did { color: var(--muted); font-size: 13px; }
    details.research { margin: 8px 0 12px; font-size: 13px; color: var(--muted); }
    details.research li { overflow-wrap: anywhere; }
    summary { cursor: pointer; }
    .row { display: grid; grid-auto-flow: column; grid-auto-columns: minmax(300px, 380px);
      gap: 12px; overflow-x: auto; padding-bottom: 8px; }
    .pg { border: 2px solid var(--line); border-radius: 10px; background: var(--bg);
      display: flex; flex-direction: column; min-width: 0; }
    .pg.best { border-color: var(--accent); }
    .pg .bar { display: flex; gap: 6px 10px; align-items: center; padding: 8px 10px;
      flex-wrap: wrap; font-size: 13px; border-bottom: 1px solid var(--line); }
    .pg .letter { font-weight: 700; font-size: 16px; width: 1.4em; }
    .pg label { display: inline-flex; gap: 4px; align-items: center; cursor: pointer; }
    .pg .notes { font-size: 12px; color: var(--warn); background: var(--warn-soft); padding: 6px 10px; }
    .pg .notes q { display: block; margin-top: 4px; color: var(--ink); }
    .pg .text { padding: 10px 12px; max-height: 75vh; overflow-y: auto; }
    .pg h3 { font-size: 17px; margin: 0 0 4px; }
    .pg .teaser { font-style: italic; color: var(--muted); margin: 0 0 10px; }
    .pg .kind { font-size: 11px; text-transform: uppercase; letter-spacing: .05em; color: var(--muted); margin-top: 12px; }
    .pg h4 { margin: 2px 0 4px; font-size: 15px; }
    .pg .body p { margin: 0 0 8px; }
    .missing { padding: 24px 8px; text-align: center; color: var(--muted); font-size: 14px; }
    .hidden { display: none; }
    </style>
    </head>
    <body>
    <header>
      <h1>Writing eval</h1>
      <span class="meta" id="run"></span>
      <span class="meta" id="progress"></span>
      <span class="spacer"></span>
      <select id="filter" aria-label="Filter days">
        <option value="all">All days</option>
        <option value="todo">Not judged yet</option>
        <option value="he">Hebrew days</option>
        <option value="en">English days</option>
      </select>
      <button class="primary" id="export">Export votes</button>
    </header>
    <main>
      <p class="intro">Each day is one real poet's real day: every page below was written from
      the same research. Pick the one page you would most want to read, tick every page you would
      be happy to publish, and mark pages with gibberish or with too many "I'm not really there"
      and source notes. Letters are shuffled per day; one of them is the page readers actually got.
      Scroll a row sideways for more pages. Votes stay in this browser until you export them.</p>
      <div id="days"></div>
    </main>
    <script id="data" type="application/json">__DATA__</script>
    <script>
    (function () {
      var data = JSON.parse(document.getElementById("data").textContent);
      var key = "writing-eval:" + data.run_id;
      var votes = {};
      try { votes = JSON.parse(localStorage.getItem(key) || "{}") || {}; } catch (e) { votes = {}; }
      function save() { try { localStorage.setItem(key, JSON.stringify(votes)); } catch (e) {} }
      function vote(id) {
        return votes[id] || (votes[id] = { best: null, publishable: [], gibberish: [], preachy: [] });
      }
      function toggle(id, field, letter, on) {
        var v = vote(id);
        v[field] = (v[field] || []).filter(function (l) { return l !== letter; });
        if (on) { v[field].push(letter); }
        save(); refresh();
      }

      document.getElementById("run").textContent = data.run_id;
      var root = document.getElementById("days");

      function el(tag, attrs, text) {
        var n = document.createElement(tag);
        for (var k in attrs || {}) { n.setAttribute(k, attrs[k]); }
        if (text != null) { n.textContent = text; }
        return n;
      }

      function box(d, p, field, label) {
        var l = el("label");
        var input = el("input", { type: "checkbox", "data-field": field });
        input.onchange = function () { toggle(d.id, field, p.letter, input.checked); };
        l.appendChild(input); l.appendChild(document.createTextNode(label));
        return l;
      }

      data.days.forEach(function (d) {
        var s = el("section", { "class": "day", "data-id": d.id, "data-lang": d.language });
        var head = el("div", { "class": "dhead" });
        head.appendChild(el("span", { "class": "chip" }, d.language === "he" ? "Hebrew" : "English"));
        head.appendChild(el("span", { "class": "chip" }, d.excursion ? "excursion" : d.mission));
        head.appendChild(el("strong", {}, d.poet));
        head.appendChild(el("span", { "class": "did" }, d.date));
        s.appendChild(head);
        var det = el("details", { "class": "research" });
        det.appendChild(el("summary", {}, "What the poet had: " + d.research.length + " searches and pages"));
        var ul = el("ul");
        d.research.forEach(function (r) { ul.appendChild(el("li", {}, r.tool + ": " + (r.ref || ""))); });
        det.appendChild(ul);
        s.appendChild(det);
        var row = el("div", { "class": "row" });

        d.pages.forEach(function (p) {
          var c = el("div", { "class": "pg", "data-letter": p.letter });
          if (p.missing) {
            c.appendChild(el("div", { "class": "missing" }, p.letter + ": no page (" + p.missing + ")"));
            row.appendChild(c);
            return;
          }
          var bar = el("div", { "class": "bar" });
          bar.appendChild(el("span", { "class": "letter" }, p.letter));
          var bl = el("label");
          var best = el("input", { type: "radio", name: "best-" + d.id });
          best.onchange = function () { vote(d.id).best = p.letter; save(); refresh(); };
          bl.appendChild(best); bl.appendChild(document.createTextNode("Best"));
          bar.appendChild(bl);
          bar.appendChild(box(d, p, "publishable", "Publishable"));
          bar.appendChild(box(d, p, "gibberish", "Gibberish"));
          bar.appendChild(box(d, p, "preachy", "Preachy"));
          c.appendChild(bar);
          if (p.notes.length) {
            var n = el("div", { "class": "notes" }, p.notes.join(" · "));
            p.examples.forEach(function (ex) { n.appendChild(el("q", { dir: "auto" }, ex)); });
            c.appendChild(n);
          }
          var t = el("div", { "class": "text", dir: d.language === "he" ? "rtl" : "ltr",
            lang: d.language });
          t.appendChild(el("h3", {}, p.title));
          if (p.teaser) { t.appendChild(el("p", { "class": "teaser" }, p.teaser)); }
          p.sections.forEach(function (sec) {
            t.appendChild(el("div", { "class": "kind" }, sec.kind));
            if (sec.title) { t.appendChild(el("h4", {}, sec.title)); }
            var b = el("div", { "class": "body" });
            b.innerHTML = sec.html;
            t.appendChild(b);
          });
          c.appendChild(t);
          row.appendChild(c);
        });

        s.appendChild(row);
        root.appendChild(s);
      });

      function refresh() {
        var done = 0;
        var filter = document.getElementById("filter").value;
        data.days.forEach(function (d) {
          var v = votes[d.id];
          var s = root.querySelector('section[data-id="' + d.id + '"]');
          var isDone = !!(v && v.best);
          if (isDone) { done++; }
          s.classList.toggle("done", isDone);
          s.classList.toggle("hidden",
            (filter === "todo" && isDone) || ((filter === "he" || filter === "en") && d.language !== filter));
          s.querySelectorAll(".pg").forEach(function (c) {
            var l = c.getAttribute("data-letter");
            var radio = c.querySelector('input[type="radio"]');
            if (radio) { radio.checked = !!(v && v.best === l); }
            c.querySelectorAll("input[data-field]").forEach(function (i) {
              var list = (v && v[i.getAttribute("data-field")]) || [];
              i.checked = list.indexOf(l) >= 0;
            });
            c.classList.toggle("best", !!(v && v.best === l));
          });
        });
        document.getElementById("progress").textContent = done + " of " + data.days.length + " days judged";
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
