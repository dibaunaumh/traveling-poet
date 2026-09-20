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

  test "context carries the journey so far, and says when today's place is a return",
       %{conn: conn, poet: poet} do
    alias TravelingPoet.Poets

    {:ok, poet} =
      Poets.move_to(poet, %{
        lat: 38.8,
        lng: -9.39,
        place_name: "Sintra, Portugal",
        country_code: "PT"
      })

    {:ok, poet} =
      Poets.move_to(poet, %{
        lat: 37.39,
        lng: -5.99,
        place_name: "Seville, Spain",
        country_code: "ES"
      })

    body = conn |> get(~p"/api/agent/context") |> json_response(200)
    names = Enum.map(body["journey"]["visited"], & &1["place_name"])
    assert "Sintra, Portugal" in names
    refute "Seville, Spain" in names
    assert body["journey"]["returning"] == false
    assert "Sintra, Portugal" in body["travel"]["visited"]
    refute Poets.returning?(poet)

    # back to Sintra: the app knows, even if the poet forgot
    {:ok, poet} =
      Poets.move_to(poet, %{
        lat: 38.8,
        lng: -9.39,
        place_name: "sintra, portugal",
        country_code: "PT"
      })

    body = conn |> get(~p"/api/agent/context") |> json_response(200)
    assert body["journey"]["returning"] == true
    assert Poets.returning?(poet)
    assert Enum.count(body["journey"]["visited"]) >= 2
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

  test "POST /topics proposes a topic that waits for the reader, and never more than that",
       %{conn: conn, poet: poet} do
    alias TravelingPoet.Topics

    body =
      conn
      |> post(~p"/api/agent/topics", %{
        "label" => "Kit airplanes",
        "kind" => "personal",
        "quote" => "I build them on weekends",
        # the agent cannot claim the reader typed it
        "status" => "active",
        "source" => "settings"
      })
      |> json_response(200)

    assert body["ok"]
    assert body["already_known"] == false
    assert body["topic"]["label"] == "Kit airplanes"
    assert body["topic"]["status"] == "proposed"

    [topic] = Topics.list(poet.id)
    assert topic.status == "proposed"
    assert topic.source == "chat"
    assert topic.evidence["quote"] == "I build them on weekends"

    # a repeat is reported, not duplicated; a paused topic stays paused
    {:ok, _} = Topics.pause(topic)

    body =
      conn
      |> post(~p"/api/agent/topics", %{"label" => "kit airplanes"})
      |> json_response(200)

    assert body["already_known"] == true
    assert body["topic"]["status"] == "paused"
    assert body["note"] =~ "paused"
    assert length(Topics.list(poet.id)) == 1

    assert conn |> post(~p"/api/agent/topics", %{"label" => " "}) |> json_response(422)

    assert conn
           |> post(~p"/api/agent/topics", %{"label" => "x", "kind" => "hobby"})
           |> json_response(422)

    assert conn |> post(~p"/api/agent/topics", %{}) |> json_response(422)
  end

  describe "excursions" do
    alias TravelingPoet.{Poets, Topics}

    setup %{poet: poet} do
      one_day_ago = DateTime.add(DateTime.utc_now(), -1, :day)
      {:ok, poet} = Poets.update_poet(poet, %{arrived_at: one_day_ago})
      topic = topic_fixture(poet, %{label: "Kit airplanes"})
      # every link a find cites is checked; the stub answers for the internet
      Req.Test.stub(TravelingPoet.LinkCheck, &Req.Test.text(&1, "ok"))
      %{poet: poet, topic: topic}
    end

    defp today_str, do: Date.to_iso8601(Date.utc_today())

    defp upsert_excursion(conn, params) do
      conn
      |> post(~p"/api/agent/journal_entries", Map.merge(%{"entry_date" => today_str()}, params))
      |> json_response(200)
    end

    defp put_finds(conn, params) do
      put(conn, ~p"/api/agent/journal_entries/#{today_str()}/finds", params)
    end

    test "the context says it is an excursion day and which topic", %{conn: conn, topic: topic} do
      body = conn |> get(~p"/api/agent/context") |> json_response(200)

      assert body["travel"]["day"] == "excursion"
      assert body["travel"]["travel_today"] == false
      assert body["travel"]["excursion"]["topic_id"] == topic.id
      assert body["travel"]["excursion"]["label"] == "Kit airplanes"

      assert [%{"label" => "Kit airplanes", "excursions_count" => 0, "last_answer" => nil}] =
               body["topics"]
    end

    test "POST /excursions queues a chat request and says when it happens",
         %{conn: conn, poet: poet, topic: topic} do
      body =
        conn
        |> post(~p"/api/agent/excursions", %{
          "topic" => "kit AIRPLANES",
          "venue" => "Oshkosh AirVenture",
          "url" => "https://example.com/oshkosh"
        })
        |> json_response(200)

      assert body["ok"]
      assert body["excursion"]["topic"]["id"] == topic.id
      assert body["excursion"]["venue"] == "Oshkosh AirVenture"
      assert body["dropped_url"] == nil
      assert body["travel"]["day"] == "excursion"
      assert body["travel"]["excursion"]["id"] == body["excursion"]["id"]
      assert body["travel"]["excursion"]["requested_venue"] == "Oshkosh AirVenture"

      [queued] = Topics.list_queued(poet.id)
      assert queued.requested_url == "https://example.com/oshkosh"

      # an unknown topic is proposed alongside, and a dead link is dropped, not fatal
      body =
        conn
        |> post(~p"/api/agent/excursions", %{
          "topic" => "Embodied minds",
          "venue" => "Machine Consciousness 0001",
          "url" => "http://localhost:9/nope"
        })
        |> json_response(200)

      assert body["excursion"]["topic"]["status"] == "proposed"
      assert body["dropped_url"] == "http://localhost:9/nope"
      assert length(Topics.list_queued(poet.id)) == 2

      assert conn |> post(~p"/api/agent/excursions", %{"venue" => "x"}) |> json_response(422)
      assert conn |> post(~p"/api/agent/excursions", %{"topic" => "a"}) |> json_response(422)
    end

    test "an excursion entry links to its topic, loses its place, and publishes as taken",
         %{conn: conn, poet: poet, topic: topic} do
      body =
        upsert_excursion(conn, %{
          "title" => "The RV-15 reveal",
          "topic_id" => topic.id,
          "place_name" => "Lisbon",
          "lat" => 1.0,
          "lng" => 2.0,
          "prompt" => %{
            "question" => "More?",
            "options" => [%{"label" => "Yes"}, %{"label" => "No"}]
          }
        })

      assert body["excursion_linked"] == true
      # the app asks its own question under an excursion; the poet's is refused
      assert body["prompt_accepted"] == false

      entry = Journal.get_entry!(body["entry_id"])
      assert is_nil(entry.place_name)
      assert is_nil(entry.lat)
      excursion = Topics.get_excursion_for_entry(entry.id)
      assert excursion.status == "written"
      assert excursion.scheduled_for == Date.utc_today()

      # a retry the same day gives the same excursion id
      assert Poets.travel_plan(poet).excursion.id == excursion.id

      conn
      |> post(~p"/api/agent/journal_entries/#{today_str()}/publish", %{})
      |> json_response(200)

      assert Topics.get_excursion_for_entry(entry.id).status == "published"

      # a wrong id is loud but the entry is kept
      body =
        conn
        |> post(~p"/api/agent/journal_entries", %{"entry_date" => today_str(), "topic_id" => 999})
        |> json_response(422)

      assert body["error"] =~ "unknown_topic"
      assert body["entry_id"] == entry.id
    end

    test "PUT finds records what came back; places are refused on an excursion day",
         %{conn: conn, poet: poet, topic: topic} do
      %{"entry_id" => entry_id} = upsert_excursion(conn, %{"topic_id" => topic.id})

      body =
        conn
        |> put_finds(%{
          "venue_name" => "Oshkosh AirVenture",
          "venue_url" => "https://example.com/oshkosh",
          "finds" => [
            %{
              "name" => "RV-15 talk",
              "url" => "https://example.com/rv15",
              "kind" => "talk",
              "poet_rating" => 4
            },
            %{"name" => "Ghost page", "url" => "http://localhost:9/nope"},
            %{
              "name" => "Kit prices",
              "url" => "https://example.com/prices",
              "kind" => "pricelist"
            }
          ]
        })
        |> json_response(200)

      assert body["ok"]
      assert body["find_count"] == 2
      assert body["dropped"] == ["Ghost page"]
      assert Map.keys(body["find_ids"]) |> Enum.sort() == ["Kit prices", "RV-15 talk"]

      [talk, prices] = Topics.list_finds_for_entry(entry_id)
      assert talk.kind == "talk"
      assert talk.poet_rating == 4
      assert prices.kind == "other"

      excursion = Topics.get_excursion_for_entry(entry_id)
      assert excursion.venue_name == "Oshkosh AirVenture"
      assert excursion.venue_url == "https://example.com/oshkosh"

      # a find without a URL is not a find
      assert conn
             |> put_finds(%{"finds" => [%{"name" => "No link"}]})
             |> json_response(422)

      body =
        conn
        |> put(~p"/api/agent/journal_entries/#{today_str()}/places", %{
          "places" => [%{"name" => "Cafe", "category" => "cafe"}]
        })
        |> json_response(422)

      assert body["error"] =~ "journal_put_finds"
      assert TravelingPoet.Guide.list_places(poet.id, published_only: false) == []
    end

    test "a call whose every find is dropped keeps the finds already saved",
         %{conn: conn, topic: topic} do
      %{"entry_id" => entry_id} = upsert_excursion(conn, %{"topic_id" => topic.id})

      conn
      |> put_finds(%{
        "finds" => [
          %{"name" => "RV-15 talk", "url" => "https://example.com/rv15"},
          %{"name" => "Kit prices", "url" => "https://example.com/prices"}
        ]
      })
      |> json_response(200)

      # the retry of one dropped find, sent alone
      body =
        conn
        |> put_finds(%{"finds" => [%{"name" => "Ghost page", "url" => "http://localhost:9/nope"}]})
        |> json_response(200)

      assert body["kept_existing"] == true
      assert body["dropped"] == ["Ghost page"]
      assert body["find_count"] == 2
      assert body["note"] =~ "do not re-send it alone"
      assert length(Topics.list_finds_for_entry(entry_id)) == 2

      # an empty list sent on purpose still clears
      body = conn |> put_finds(%{"finds" => []}) |> json_response(200)
      assert body["find_count"] == 0
      assert Topics.list_finds_for_entry(entry_id) == []
    end

    test "finds are refused on a day at the place, and need an entry first", %{conn: conn} do
      body =
        conn
        |> put_finds(%{"finds" => [%{"name" => "x", "url" => "https://example.com/x"}]})
        |> json_response(404)

      assert body["error"] =~ "journal_upsert_entry"

      conn
      |> post(~p"/api/agent/journal_entries", %{"entry_date" => today_str()})
      |> json_response(200)

      body =
        conn
        |> put_finds(%{"finds" => [%{"name" => "x", "url" => "https://example.com/x"}]})
        |> json_response(422)

      assert body["error"] =~ "journal_put_places"
    end

    # Storage is not reachable in test, so only the resolution is pinned here:
    # a find id is scoped to the poet and checked before any upload, the way
    # place_id is. Attaching itself is covered in excursions_test.
    test "a drawing aimed at a find the poet does not own is refused before upload",
         %{conn: conn, topic: topic} do
      upsert_excursion(conn, %{"topic_id" => topic.id})
      other = poet_fixture(user_fixture())
      other_entry = entry_fixture(other)
      foreign = find_fixture(other, other_entry)

      body =
        conn
        |> post(~p"/api/agent/media", %{
          "image_base64" => Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10, 0>>),
          "content_type" => "image/png",
          "entry_date" => today_str(),
          "find_id" => foreign.id,
          "sources" => [%{"url" => "https://example.com/hangar", "label" => "the hangar"}]
        })
        |> json_response(404)

      assert body["error"] =~ "no such find"
      assert is_nil(Topics.get_find(other.id, foreign.id).media_id)
    end
  end

  test "context carries the reader's topics, without the paused ones", %{conn: conn, poet: poet} do
    alias TravelingPoet.Topics

    {:ok, active} = Topics.create(poet.id, %{label: "Embodied minds", kind: "professional"})
    {:ok, paused} = Topics.create(poet.id, %{label: "Ceramics"})
    {:ok, _} = Topics.pause(paused)
    {:ok, _proposed, false} = Topics.propose(poet.id, %{label: "Kit airplanes"})

    body = conn |> get(~p"/api/agent/context") |> json_response(200)
    topics = body["topics"]

    assert Enum.map(topics, & &1["label"]) == ["Embodied minds", "Kit airplanes"]
    assert hd(topics)["id"] == active.id
    assert hd(topics)["kind"] == "professional"
    assert hd(topics)["every_days"] == 7
    assert List.last(topics)["status"] == "proposed"
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

  test "re-putting a marked published entry keeps the unmarked sections as written",
       %{conn: conn, user: user, poet: poet} do
    # the products section below cites a link; the stub stands in for its host
    Req.Test.stub(TravelingPoet.LinkCheck, &Req.Test.text(&1, "ok"))
    entry = published_entry_fixture(poet)

    {:ok, _} =
      Journal.replace_sections(entry, [
        %{kind: "description", body: "Steep streets and a long day."},
        %{kind: "poem", body: "a verse"},
        %{kind: "products", body: "Liberty Public Market sells honey."}
      ])

    {:ok, _} =
      TravelingPoet.Markers.add_marker(user, entry, %{
        "kind" => "beautiful",
        "target" => "text",
        "section_kind" => "poem",
        "section_position" => 1,
        "quote" => "a verse"
      })

    {:ok, _} =
      TravelingPoet.Markers.add_marker(user, entry, %{
        "kind" => "link_needed",
        "target" => "text",
        "section_kind" => "products",
        "section_position" => 2,
        "quote" => "Liberty Public Market"
      })

    date = Date.to_iso8601(entry.entry_date)

    body =
      conn
      |> put(~p"/api/agent/journal_entries/#{date}/sections", %{
        sections: [
          %{kind: "description", body: "Rewritten from the ground up."},
          %{kind: "poem", body: "a rewritten verse"},
          %{
            kind: "products",
            body: "Liberty Public Market sells honey.",
            metadata: %{
              source_url: "https://libertypublicmarketsd.com/",
              source_label: "Liberty Public Market"
            }
          }
        ]
      })
      |> json_response(200)

    assert body["ok"]
    assert body["kept_as_written"] == ["description", "poem"]
    assert body["note"] =~ "kept exactly"

    saved = Journal.get_entry_preloaded(poet.id, entry.entry_date).sections

    assert Enum.map(saved, & &1.body) == [
             "Steep streets and a long day.",
             "a verse",
             "Liberty Public Market sells honey."
           ]

    assert Enum.at(saved, 2).metadata["source_url"] == "https://libertypublicmarketsd.com/"
  end

  test "a teaser is stored, cut to 140 characters rather than rejected, and read back with the day",
       %{conn: conn, poet: poet} do
    date = Date.utc_today() |> Date.to_iso8601()
    long = String.duplicate("swifts at dusk ", 20)

    assert %{"ok" => true} =
             conn
             |> post(~p"/api/agent/journal_entries", %{
               entry_date: date,
               title: "Rooftop",
               teaser: long
             })
             |> json_response(200)

    stored = Journal.get_entry(poet.id, Date.utc_today())
    # cut on a whole word with an ellipsis, never mid-word ("I wasn'")
    assert String.length(stored.teaser) <= 140
    assert String.ends_with?(stored.teaser, "dusk…")

    assert %{"entry" => %{"teaser" => teaser, "journey_day" => 1}} =
             conn |> get(~p"/api/agent/journal_entries/#{date}") |> json_response(200)

    assert teaser == stored.teaser
    # today's context tells the poet which day it is, so it never counts,
    # and how many spot drawings the entry gets (balanced verbosity: 2)
    assert %{"journey_day" => 1, "drawings" => %{"spots" => 2}} =
             conn |> get(~p"/api/agent/context") |> json_response(200)
  end

  test "reading an entry back lists its spot drawings with the markdown that places them",
       %{conn: conn, poet: poet} do
    entry = entry_fixture(poet, %{entry_date: ~D[2026-09-01]})
    spot = media_fixture(poet, %{journal_entry_id: entry.id, kind: "spot", alt_text: "a cup"})

    assert %{"media" => [%{"id" => id, "kind" => "spot", "markdown" => markdown}]} =
             conn |> get(~p"/api/agent/journal_entries/2026-09-01") |> json_response(200)

    assert id == spot.id
    assert markdown == "![a cup](/media/#{spot.id})"
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

  test "a spot asks the spot model, a main illustration the main one", %{conn: conn} do
    Application.put_env(:traveling_poet, :openrouter_api_key, "test-key")
    on_exit(fn -> Application.put_env(:traveling_poet, :openrouter_api_key, nil) end)

    test_pid = self()

    Req.Test.stub(TravelingPoet.Illustrations, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:image_request, conn.request_path, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "data" => [%{"b64_json" => Base.encode64("png-bytes"), "media_type" => "image/png"}]
      })
    end)

    # the upload half needs S3, which no test can reach; the model choice is
    # what this pins, and it is made before any bytes are stored
    generate = fn params ->
      try do
        post(conn, ~p"/api/agent/illustrations", params)
      catch
        :exit, _ -> :no_s3
      end
    end

    generate.(%{prompt: "a door knocker", kind: "spot"})

    assert_receive {:image_request, "/api/v1/images",
                    %{"model" => "test/spot-image-model"} = body}

    # the app's own ink rules still ride along
    assert body["prompt"] =~ "a door knocker"
    assert body["prompt"] =~ "pure white"

    Req.Test.stub(TravelingPoet.Illustrations, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:image_request, conn.request_path, Jason.decode!(body)})
      Req.Test.json(conn, %{"choices" => []})
    end)

    generate.(%{prompt: "the harbour at dusk"})

    assert_receive {:image_request, "/api/v1/chat/completions", %{"model" => model}}
    assert model == TravelingPoet.Illustrations.model()
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

  test "context carries the app's travel decision", %{conn: conn} do
    body = conn |> get(~p"/api/agent/context") |> json_response(200)
    assert %{"travel_today" => false, "reason" => reason, "destination" => nil} = body["travel"]
    assert reason =~ "day 1 of"
    assert body["travel"]["scouting"] == false
    assert body["travel"]["trip"] == nil
    assert body["itinerary"] == []
    assert body["next_stop"] == nil
  end

  test "on a trip day a wanderer's context is a scout's: the trip, its stops, the next one",
       %{conn: conn, poet: poet} do
    trip =
      trip_fixture(poet, %{
        start_date: Date.add(Date.utc_today(), 3),
        end_date: Date.add(Date.utc_today(), 6)
      })

    {:ok, trip} = TravelingPoet.Trips.accept(poet, trip)
    assert trip.status == "scouting"

    body = conn |> get(~p"/api/agent/context") |> json_response(200)
    assert body["poet"]["mode"] == "wander"
    assert body["travel"]["scouting"] == true
    assert body["travel"]["trip"]["name"] == "Rome"
    assert body["travel"]["trip"]["destinations"] == ["Rome, Italy"]
    assert body["travel"]["travel_today"] == true
    assert body["travel"]["destination"]["place_name"] == "Rome, Italy"
    assert [%{"place_name" => "Rome, Italy", "trip_id" => trip_id}] = body["itinerary"]
    assert trip_id == trip.id
    assert body["next_stop"]["place_name"] == "Rome, Italy"
  end

  test "the poet can hold and add a detour from chat", %{conn: conn, poet: poet} do
    body = conn |> post(~p"/api/agent/hold", %{"days" => 2}) |> json_response(200)
    assert body["ok"]
    assert body["hold_until"] == Date.to_iso8601(Date.add(Date.utc_today(), 2))
    assert body["travel"]["travel_today"] == false

    body =
      conn
      |> post(~p"/api/agent/itinerary_stops", %{
        "place_name" => "Catalina Island",
        "lat" => 33.39,
        "lng" => -118.42
      })
      |> json_response(200)

    assert body["stop"]["place_name"] == "Catalina Island"

    assert [%{place_name: "Catalina Island", source: "chat"}] =
             TravelingPoet.Poets.list_stops(poet.id)

    # still held, so the detour waits
    assert body["travel"]["travel_today"] == false

    # geocoding is switched off in test, so a bare name cannot be resolved
    assert conn
           |> post(~p"/api/agent/itinerary_stops", %{"place_name" => "Nowhere"})
           |> json_response(422)

    assert conn |> post(~p"/api/agent/itinerary_stops", %{}) |> json_response(422)
  end

  test "wander context has empty itinerary", %{conn: conn} do
    body = conn |> get(~p"/api/agent/context") |> json_response(200)
    assert body["poet"]["mode"] == "wander"
    assert body["itinerary"] == []
    assert body["next_stop"] == nil
  end
end
