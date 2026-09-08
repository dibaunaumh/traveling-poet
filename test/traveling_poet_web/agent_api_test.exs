defmodule TravelingPoetWeb.AgentApiTest do
  use TravelingPoetWeb.ConnCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Journal

  setup %{conn: conn} do
    user = agent_user_fixture()
    poet = poet_fixture(user)

    authed =
      conn
      |> put_req_header("authorization", "Bearer #{user.agent_api_token}")
      |> put_req_header("content-type", "application/json")

    %{conn: authed, anon: conn, user: user, poet: poet}
  end

  test "rejects missing/invalid bearer", %{anon: anon} do
    assert anon |> get(~p"/api/agent/context") |> json_response(401)

    assert anon
           |> put_req_header("authorization", "Bearer 1.not-the-token")
           |> get(~p"/api/agent/context")
           |> json_response(401)
  end

  test "GET /context returns poet profile and location", %{conn: conn, poet: poet} do
    body = conn |> get(~p"/api/agent/context") |> json_response(200)

    assert body["poet"]["name"] == poet.name
    assert body["location"]["place_name"] == "Lisbon, Portugal"
    assert body["today"]
  end

  test "context carries what the reader has asked for, and what they rejected",
       %{conn: conn, poet: poet} do
    alias TravelingPoet.Preferences

    {:ok, _} =
      Preferences.record(poet.id, %{
        label: "american stupid things",
        dimension: "topic",
        source: "chat"
      })

    {:ok, rejected} =
      Preferences.record(poet.id, %{label: "more museums", dimension: "topic", source: "tap"})

    {:ok, _} = Preferences.dismiss(rejected)

    body = conn |> get(~p"/api/agent/context") |> json_response(200)

    assert [%{"label" => "american stupid things", "polarity" => "seek"}] =
             body["learned_profile"]

    # what they removed is sent too, so the poet doesn't propose it again
    assert [%{"label" => "more museums"}] = body["dismissed"]
    assert is_map(body["engagement"])
    # the app decides when to ask; the agent is told, not trusted to judge
    assert is_boolean(body["ask_prompt"])
  end

  test "get_feedback carries the full picture for already-provisioned poets",
       %{conn: conn, poet: poet} do
    {:ok, _} =
      TravelingPoet.Preferences.record(poet.id, %{
        label: "less history",
        dimension: "topic",
        polarity: "avoid",
        source: "tap"
      })

    body = conn |> get(~p"/api/agent/feedback") |> json_response(200)

    # the old field is still there — existing sprites call this tool
    assert Map.has_key?(body, "reactions")
    assert [%{"label" => "less history", "polarity" => "avoid"}] = body["learned_profile"]
    assert Map.has_key?(body, "engagement")
    assert Map.has_key?(body, "prompt_answers")
    assert body["markers"] == []
    assert body["marker_counts"] == %{}
  end

  test "get_feedback carries the companion's markers", %{conn: conn, user: user, poet: poet} do
    entry = published_entry_fixture(poet)

    {:ok, _} =
      TravelingPoet.Markers.add_marker(user, entry, %{
        "kind" => "boring",
        "target" => "text",
        "quote" => "the usual",
        "section_kind" => "description",
        "section_position" => 0
      })

    body = conn |> get(~p"/api/agent/feedback") |> json_response(200)

    assert [%{"kind" => "boring", "quote" => "the usual", "sent_at" => nil}] = body["markers"]
    assert body["marker_counts"] == %{"boring" => 1}
  end

  test "GET /journal_entries/:date reads an entry back with its markers",
       %{conn: conn, user: user, poet: poet} do
    entry = published_entry_fixture(poet)

    {:ok, _} =
      Journal.replace_sections(entry, [
        %{
          kind: "description",
          body: "Steep streets.",
          metadata: %{"source_url" => "https://x.y"}
        },
        %{kind: "poem", body: "a verse"}
      ])

    {:ok, _} =
      TravelingPoet.Markers.add_marker(user, entry, %{
        "kind" => "more_details",
        "target" => "section",
        "section_kind" => "poem",
        "section_position" => 1
      })

    body =
      conn
      |> get(~p"/api/agent/journal_entries/#{Date.to_iso8601(entry.entry_date)}")
      |> json_response(200)

    assert body["entry"]["status"] == "published"

    assert [
             %{
               "kind" => "description",
               "position" => 0,
               "metadata" => %{"source_url" => "https://x.y"}
             },
             %{"kind" => "poem", "position" => 1, "body" => "a verse"}
           ] = body["sections"]

    assert [%{"kind" => "more_details", "ask" => ask}] = body["markers"]
    assert ask =~ "expand"

    assert conn |> get(~p"/api/agent/journal_entries/2020-01-01") |> json_response(404)
    assert conn |> get(~p"/api/agent/journal_entries/not-a-date") |> json_response(422)
  end

  test "a preference may be attributed to markers, but never to a tap",
       %{conn: conn, poet: poet} do
    conn
    |> post(~p"/api/agent/preferences", %{"label" => "more drawings", "source" => "marker"})
    |> json_response(200)

    assert [%{source: "marker"}] = TravelingPoet.Preferences.list_active(poet.id)
  end

  test "the poet can persist what its companion said in chat", %{conn: conn, poet: poet} do
    body =
      conn
      |> post(~p"/api/agent/preferences", %{
        "label" => "american stupid things",
        "dimension" => "topic",
        "polarity" => "seek",
        "quote" => "dont look for delightful culture, look for american stupid things"
      })
      |> json_response(200)

    assert body["ok"]
    assert body["times_heard"] == 1

    assert [pref] = TravelingPoet.Preferences.list_active(poet.id)
    # the companion's own words are kept so the settings panel can justify itself
    assert pref.evidence["quote"] =~ "american stupid things"
  end

  test "the poet cannot claim a preference came from the user's own tap",
       %{conn: conn, poet: poet} do
    conn
    |> post(~p"/api/agent/preferences", %{"label" => "more nightlife", "source" => "tap"})
    |> json_response(200)

    assert [pref] = TravelingPoet.Preferences.list_active(poet.id)
    # forced server-side: taps carry authority the agent must not borrow
    assert pref.source == "chat"
  end

  test "the poet cannot re-learn what the user removed", %{conn: conn, poet: poet} do
    alias TravelingPoet.Preferences

    {:ok, pref} =
      Preferences.record(poet.id, %{label: "more museums", dimension: "topic", source: "tap"})

    {:ok, _} = Preferences.dismiss(pref)

    conn
    |> post(~p"/api/agent/preferences", %{"label" => "more museums", "dimension" => "topic"})
    |> json_response(200)

    assert Preferences.list_active(poet.id) == []
  end

  test "malformed preferences are refused rather than half-stored", %{conn: conn, poet: poet} do
    assert conn
           |> post(~p"/api/agent/preferences", %{"label" => "  "})
           |> json_response(422)

    assert conn
           |> post(~p"/api/agent/preferences", %{"label" => "x", "dimension" => "vibes"})
           |> json_response(422)

    assert conn |> post(~p"/api/agent/preferences", %{}) |> json_response(422)
    assert TravelingPoet.Preferences.list_active(poet.id) == []
  end

  test "an agent-authored question replaces the app's, and a bad one is dropped",
       %{conn: conn, poet: poet} do
    alias TravelingPoet.Preferences

    good = %{
      "entry_date" => "2026-08-31",
      "title" => "Nara",
      "prompt" => %{
        "question" => "I skipped the temple for the deer park — more of that?",
        "options" => [
          %{"label" => "Yes, the odd corners", "dimension" => "topic", "polarity" => "seek"},
          %{"label" => "No, the famous places", "dimension" => "topic", "polarity" => "avoid"}
        ]
      }
    }

    assert %{"prompt_accepted" => true, "entry_id" => entry_id} =
             conn |> post(~p"/api/agent/journal_entries", good) |> json_response(200)

    prompt = TravelingPoet.Repo.get_by(Preferences.EntryPrompt, journal_entry_id: entry_id)
    assert prompt.source == "agent"
    assert prompt.question =~ "deer park"

    # A malformed prompt must never cost the poet its entry — the entry still
    # saves, and the app's own question fills the slot instead.
    bad = %{
      "entry_date" => "2026-08-30",
      "title" => "Kyoto",
      "prompt" => %{"question" => "Well?", "options" => [%{"label" => "only one option"}]}
    }

    assert %{"prompt_accepted" => false, "ok" => true} =
             conn |> post(~p"/api/agent/journal_entries", bad) |> json_response(200)

    assert poet.id
  end

  test "entry upsert + sections + publish round-trip", %{conn: conn, poet: poet} do
    date = Date.utc_today() |> Date.to_iso8601()

    assert %{"ok" => true} =
             conn
             |> post(~p"/api/agent/journal_entries", %{
               entry_date: date,
               title: "Morning in Alfama",
               place_name: "Lisbon",
               lat: 38.7,
               lng: -9.1
             })
             |> json_response(200)

    # upsert is idempotent by date
    assert %{"ok" => true} =
             conn
             |> post(~p"/api/agent/journal_entries", %{entry_date: date, title: "Revised title"})
             |> json_response(200)

    assert %{"ok" => true, "section_count" => 2} =
             conn
             |> put(~p"/api/agent/journal_entries/#{date}/sections", %{
               sections: [
                 %{kind: "description", body: "Steep streets, tiled walls."},
                 %{kind: "poem", title: "Tram 28", body: "yellow tram, patient hill"}
               ]
             })
             |> json_response(200)

    assert %{"ok" => true} =
             conn
             |> post(~p"/api/agent/journal_entries/#{date}/publish", %{})
             |> json_response(200)

    entry = Journal.get_entry(poet.id, Date.utc_today())
    assert entry.status == "published"
    assert entry.title == "Revised title"
  end

  test "POST /location moves the poet and appends a path point", %{conn: conn, poet: poet} do
    assert %{"ok" => true, "place_name" => "Sintra, Portugal"} =
             conn
             |> post(~p"/api/agent/location", %{
               lat: 38.8029,
               lng: -9.3817,
               place_name: "Sintra, Portugal",
               country_code: "PT"
             })
             |> json_response(200)

    points = TravelingPoet.Poets.list_path_points(poet.id)
    assert length(points) == 1
    assert hd(points).place_name == "Sintra, Portugal"
  end

  test "illustration generation validates prompt and config", %{conn: conn} do
    # no IMAGE_GEN_API_KEY in test env -> 503, never a crash
    assert %{"error" => _} =
             conn
             |> post(~p"/api/agent/illustrations", %{prompt: "a watercolor of Lisbon"})
             |> json_response(503)

    assert %{"error" => _} =
             conn |> post(~p"/api/agent/illustrations", %{}) |> json_response(422)
  end

  test "rejects bad dates", %{conn: conn} do
    assert %{"error" => _} =
             conn
             |> post(~p"/api/agent/journal_entries", %{entry_date: "not-a-date"})
             |> json_response(422)
  end

  test "rejects re-uploading byte-identical illustrations", %{conn: conn, poet: poet} do
    bytes = :crypto.strong_rand_bytes(64)
    hash = :crypto.hash(:md5, bytes) |> Base.encode16()

    {:ok, _existing} =
      Journal.create_media(%{
        poet_id: poet.id,
        s3_key: "poets/#{poet.id}/media/original.png",
        content_type: "image/png",
        kind: "illustration",
        content_hash: hash,
        sources: %{"items" => [%{"url" => "https://example.com/x", "label" => "x"}]}
      })

    # duplicate check fires before any storage call, so no S3 needed
    assert %{"error" => error} =
             conn
             |> post(~p"/api/agent/media", %{
               image_base64: Base.encode64(bytes),
               content_type: "image/png",
               kind: "illustration",
               sources: [%{url: "https://example.com/x", label: "x"}]
             })
             |> json_response(422)

    assert error =~ "byte-identical"
  end

  test "scout context exposes itinerary; location marks stop visited", %{conn: conn, poet: poet} do
    {:ok, _} =
      TravelingPoet.Poets.update_poet(poet, %{
        settings: Map.put(poet.settings || %{}, "mode", "scout")
      })

    {:ok, s1} =
      TravelingPoet.Poets.add_stop(poet.id, %{place_name: "Porto", lat: 41.15, lng: -8.61})

    {:ok, _s2} =
      TravelingPoet.Poets.add_stop(poet.id, %{place_name: "Coimbra", lat: 40.2, lng: -8.42})

    body = conn |> get(~p"/api/agent/context") |> json_response(200)
    assert body["poet"]["mode"] == "scout"
    assert [%{"place_name" => "Porto"}, %{"place_name" => "Coimbra"}] = body["itinerary"]
    assert body["next_stop"]["id"] == s1.id

    assert %{"ok" => true, "itinerary_stop_visited" => visited_id} =
             conn
             |> post(~p"/api/agent/location", %{
               lat: 41.15,
               lng: -8.61,
               place_name: "Porto, Portugal",
               itinerary_stop_id: s1.id
             })
             |> json_response(200)

    assert visited_id == s1.id
    assert TravelingPoet.Poets.next_pending_stop(poet.id).place_name == "Coimbra"
  end

  test "wander context has empty itinerary", %{conn: conn} do
    body = conn |> get(~p"/api/agent/context") |> json_response(200)
    assert body["poet"]["mode"] == "wander"
    assert body["itinerary"] == []
    assert body["next_stop"] == nil
  end
end
