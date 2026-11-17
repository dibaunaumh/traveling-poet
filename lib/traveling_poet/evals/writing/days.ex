defmodule TravelingPoet.Evals.Writing.Days do
  @moduledoc """
  Freezes real poet days for the writing eval (`TravelingPoet.Evals.Writing`).

  Runs on production over `rpc`, because it needs the Repo and the sprites.
  For each public poet it reads the poet's own conversation log on its
  sprite, finds a recent `/travel-and-journal` run that published a page,
  and keeps what the poet had that day:

    * the trigger the app sent, app notes included
    * the `get_poet_context` result
    * every `web_search` and `web_fetch` result, as the poet received it
    * the workspace files the poet writes under: OpenClaw's
      `instructions.md`, `AGENTS.md`, `IDENTITY.md`, `USER.md` and the
      travel-and-journal skill files

  The published page comes along as the reference readers got. Every model
  then writes from the same material, so the eval compares writing, not
  search luck.

  Public poets only, and the file stays out of git (`/evals/` is ignored):
  `USER.md` names the companion.

      Days.extract(per_language: 4, path: "/tmp/writing_days.json")
  """

  import Ecto.Query

  alias TravelingPoet.{Journal, Locale, Poets, Provisioner, Repo, SpritesClient, Topics}

  @research ~w(web_search web_fetch)

  # One research result is capped so a single long page cannot crowd the
  # day out; get_poet_context is kept whole.
  @result_cap 8_000

  # Reads the sprite's transcript store (OpenClaw 2026.10: one sqlite file,
  # events plain or zstd-compressed) and the workspace files, and prints one
  # gzipped, base64 JSON so the exec framing bytes cannot corrupt it.
  @script ~S"""
  const {DatabaseSync}=require('node:sqlite');const zlib=require('node:zlib');const fs=require('node:fs');
  const H=process.env.HOME,CAP=+process.argv[2]||8000;
  const db=new DatabaseSync(H+'/.openclaw/agents/main/agent/openclaw-agent.sqlite',{readOnly:true});
  const rows=db.prepare('select event_json,event_zstd from transcript_events order by created_at,seq').all();
  const txt=c=>typeof c==='string'?c:Array.isArray(c)?c.filter(p=>p.type==='text').map(p=>p.text).join('\n'):'';
  const runs=[];let cur=null;const calls={};
  for(const r of rows){let e;try{e=JSON.parse(r.event_json??zlib.zstdDecompressSync(Buffer.from(r.event_zstd)).toString())}catch(_){continue}
   if(e.type!=='message')continue;const m=e.message||{};
   if(m.role==='user'){cur={at:m.timestamp,prompt:txt(m.content).slice(0,4000),entry_date:null,results:[]};runs.push(cur);continue}
   if(!cur)continue;
   if(m.role==='assistant'&&Array.isArray(m.content))for(const p of m.content)if(p.type==='toolCall')calls[p.id]=p.arguments||{};
   if(m.role==='toolResult'){const res=(m.details||{}).result||{};
    if(m.toolName==='journal_upsert_entry'&&res.entry_date&&!cur.entry_date)cur.entry_date=res.entry_date;
    if(['get_poet_context','web_search','web_fetch'].includes(m.toolName))
     cur.results.push({tool:m.toolName,args:calls[m.toolCallId]||{},text:txt(m.content).slice(0,m.toolName==='get_poet_context'?60000:CAP)})}}
  const W=H+'/.openclaw/workspace/';const files={};
  const want=[[H+'/.openclaw/agents/main/agent/instructions.md','instructions.md'],[W+'AGENTS.md','AGENTS.md'],[W+'IDENTITY.md','IDENTITY.md'],[W+'USER.md','USER.md']];
  try{for(const f of fs.readdirSync(W+'skills/travel-and-journal'))want.push([W+'skills/travel-and-journal/'+f,'skills/travel-and-journal/'+f])}catch(_){}
  for(const [p,n] of want){try{files[n]=fs.readFileSync(p,'utf8')}catch(_){}}
  process.stdout.write(zlib.gzipSync(JSON.stringify({runs:runs.filter(r=>r.entry_date).slice(-10),files})).toString('base64'));
  """

  @doc """
  Writes the frozen days to `:path` and returns `[{day_id, language,
  research_count}]`. Takes up to `:per_language` days per language (default
  4), one per poet, preferring the days the poet researched most, from the
  last `:days` days (default 14).
  """
  def extract(opts \\ []) do
    per_language = Keyword.get(opts, :per_language, 4)
    path = Keyword.get(opts, :path, "/tmp/writing_days.json")
    since = Date.add(Date.utc_today(), -Keyword.get(opts, :days, 14))

    days =
      public_poets()
      |> Enum.flat_map(fn poet ->
        case day_for(poet, since) do
          nil -> []
          day -> [day]
        end
      end)
      |> Enum.group_by(& &1.language)
      |> Enum.flat_map(fn {_language, days} ->
        days |> Enum.sort_by(&(-length(&1.research))) |> Enum.take(per_language)
      end)

    File.write!(
      path,
      Jason.encode!(%{extracted_at: DateTime.utc_now(), days: days}, pretty: true)
    )

    Enum.map(days, &{&1.id, &1.language, length(&1.research)})
  end

  defp public_poets do
    from(p in Poets.Poet, where: p.is_public, preload: :user)
    |> Repo.all()
    |> Enum.filter(&(&1.user && &1.user.sprite_provisioned))
  end

  defp day_for(poet, since) do
    user = poet.user
    sprite = user.sprite_name || Provisioner.default_sprite_name(user.id)

    with {:ok, %{"runs" => runs, "files" => files}} <- read_sprite(sprite) do
      runs
      |> Enum.filter(&String.starts_with?(&1["prompt"] || "", "/travel-and-journal"))
      |> Enum.flat_map(fn run ->
        with {:ok, date} <- Date.from_iso8601(run["entry_date"]),
             true <- Date.compare(date, since) != :lt,
             %{status: "published"} = entry <- Journal.get_entry_preloaded(poet.id, date) do
          [{run, entry}]
        else
          _ -> []
        end
      end)
      |> Enum.max_by(fn {run, _} -> research_count(run) end, fn -> nil end)
      |> case do
        {run, entry} -> if research_count(run) > 0, do: build(poet, user, run, entry, files)
        nil -> nil
      end
    else
      _ -> nil
    end
  end

  defp research_count(run), do: Enum.count(run["results"], &(&1["tool"] in @research))

  defp read_sprite(sprite) do
    cmd =
      "echo #{Base.encode64(@script)} | base64 -d > /tmp/tp_writing_eval.js && " <>
        "/.sprite/bin/node /tmp/tp_writing_eval.js #{@result_cap}"

    with {:ok, out} <- SpritesClient.exec(sprite, cmd),
         {:ok, gz} <- out |> String.replace(~r/[^A-Za-z0-9+\/=]/, "") |> Base.decode64() do
      Jason.decode(:zlib.gunzip(gz))
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build(poet, user, run, entry, files) do
    {context, research} = Enum.split_with(run["results"], &(&1["tool"] == "get_poet_context"))

    %{
      id: "#{poet.id}-#{entry.entry_date}",
      poet: poet.name,
      language: Locale.normalize(user.locale) || "en",
      mission: Poets.Poet.mode(poet),
      excursion: Topics.excursion_of(entry) != nil,
      entry_date: entry.entry_date,
      trigger: run["prompt"],
      context: context |> List.first(%{}) |> Map.get("text"),
      research:
        Enum.map(research, fn r ->
          %{tool: r["tool"], ref: r["args"]["query"] || r["args"]["url"], text: r["text"]}
        end),
      files: files,
      published: %{
        title: entry.title,
        teaser: entry.teaser,
        sections:
          entry.sections
          |> Enum.reject(&(&1.kind == "illustration"))
          |> Enum.map(&%{kind: &1.kind, title: &1.title, body: &1.body})
      }
    }
  end
end
