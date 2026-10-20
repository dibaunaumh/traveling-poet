defmodule TravelingPoet.ReaderNoteTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Preferences, ReaderNote, Topics}
  alias TravelingPoet.ReaderNote.Extractor

  setup do
    poet = poet_fixture(user_fixture())
    %{poet: poet}
  end

  @draft "You travel for specialty coffee and modern local food. You would rather skip nightlife."

  describe "who writes it" do
    test "the poet drafts and may redraft its own draft, never the reader's", %{poet: poet} do
      assert ReaderNote.payload(poet.id).needs_draft

      {:ok, note} = ReaderNote.draft(poet.id, @draft)
      assert note.written_by == "poet"
      {:ok, _} = ReaderNote.draft(poet.id, @draft <> " You follow kit airplanes.")

      {:ok, note} = ReaderNote.save(poet.id, "I travel for coffee.")
      assert note.written_by == "reader"
      assert {:error, :reader_wrote_it} = ReaderNote.draft(poet.id, @draft)
      assert ReaderNote.get(poet.id).text == "I travel for coffee."

      payload = ReaderNote.payload(poet.id)
      refute payload.needs_draft
      assert payload.written_by == "reader"
    end

    test "a blank save clears the note, and the poet drafts again", %{poet: poet} do
      {:ok, _} = ReaderNote.save(poet.id, "I travel for coffee.")
      assert {:ok, nil} = ReaderNote.save(poet.id, "   ")
      assert ReaderNote.payload(poet.id).needs_draft
      assert {:ok, %{written_by: "poet"}} = ReaderNote.draft(poet.id, @draft)
    end
  end

  describe "suggested lines" do
    setup %{poet: poet} do
      {:ok, _} = ReaderNote.save(poet.id, @draft)
      :ok
    end

    test "an added line joins the note as the reader's", %{poet: poet} do
      {:ok, s} =
        ReaderNote.suggest(poet.id, %{
          kind: "add",
          text: "You follow kit airplanes",
          reason: "chat"
        })

      assert [%{kind: "add"}] = ReaderNote.payload(poet.id).pending_suggestions
      {:ok, _} = ReaderNote.accept(poet.id, s.id)

      note = ReaderNote.get(poet.id)
      assert note.text =~ "nightlife. You follow kit airplanes."
      assert note.written_by == "reader"
      assert ReaderNote.pending(poet.id) == []
    end

    test "a struck line must be in the note word for word, and leaves it clean", %{poet: poet} do
      assert {:error, :not_in_note} =
               ReaderNote.suggest(poet.id, %{kind: "strike", text: "You love opera."})

      {:ok, s} =
        ReaderNote.suggest(poet.id, %{kind: "strike", text: "You would rather skip nightlife."})

      {:ok, _} = ReaderNote.accept(poet.id, s.id)

      assert ReaderNote.get(poet.id).text ==
               "You travel for specialty coffee and modern local food."
    end

    test "a declined line is never offered again, and three wait at most", %{poet: poet} do
      {:ok, s} = ReaderNote.suggest(poet.id, %{kind: "add", text: "You love opera."})
      {:ok, _} = ReaderNote.decline(poet.id, s.id)

      assert {:error, :already_suggested} =
               ReaderNote.suggest(poet.id, %{kind: "add", text: "you love opera."})

      for line <- ["One.", "Two.", "Three."],
          do: {:ok, _} = ReaderNote.suggest(poet.id, %{kind: "add", text: "Line " <> line})

      assert {:error, :too_many} = ReaderNote.suggest(poet.id, %{kind: "add", text: "Line four."})
    end

    test "nothing to suggest on before there is a note" do
      other = poet_fixture(user_fixture())
      assert {:error, :no_note} = ReaderNote.suggest(other.id, %{kind: "add", text: "You hike."})
    end
  end

  describe "understanding the note" do
    setup do
      Application.put_env(:traveling_poet, :openrouter_api_key, "test-key")
      on_exit(fn -> Application.put_env(:traveling_poet, :openrouter_api_key, nil) end)

      Req.Test.stub(TravelingPoet.PlaceClassifier, &Req.Test.json(&1, %{"choices" => []}))
      :ok
    end

    test "adds tastes, topics and avoids it finds, and keeps the reading", %{poet: poet} do
      test_pid = self()

      Req.Test.stub(Extractor, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:asked, Jason.decode!(body)})

        Req.Test.json(conn, %{
          "choices" => [
            %{
              "message" => %{
                "content" =>
                  Jason.encode!(%{
                    "tastes" => [
                      %{"domain" => "food", "label" => "specialty coffee"},
                      %{"domain" => "dance", "label" => "tango"}
                    ],
                    "topics" => [%{"label" => "kit airplanes"}],
                    "avoids" => [%{"label" => "nightlife"}]
                  })
              }
            }
          ]
        })
      end)

      {:ok, proposed, _} = Topics.propose(poet.id, %{"label" => "kit airplanes"})
      assert proposed.status == "proposed"

      {:ok, _} =
        ReaderNote.save(poet.id, "I love specialty coffee and kit airplanes. No nightlife.")

      {:ok, note} = ReaderNote.understand(poet.id)

      assert_receive {:asked, %{"messages" => [_, %{"content" => "The note:\n\n" <> _}]}}

      assert note.understood["tastes"] == [%{"domain" => "food", "label" => "specialty coffee"}]
      assert note.understood["topics"] == [%{"label" => "kit airplanes"}]
      assert note.understood["avoids"] == [%{"label" => "nightlife"}]

      labels = poet.id |> Topics.list() |> Map.new(&{&1.label, {&1.status, &1.domain}})
      assert labels["specialty coffee"] == {"active", "food"}
      assert labels["kit airplanes"] == {"active", nil}

      assert [%{label: "nightlife", polarity: "avoid", source: "settings"}] =
               Preferences.list_active(poet.id)
    end

    test "is skipped when there is no model to read it", %{poet: poet} do
      Application.put_env(:traveling_poet, :openrouter_api_key, nil)
      {:ok, _} = ReaderNote.save(poet.id, "I love coffee.")
      assert {:ok, :skipped} = ReaderNote.understand(poet.id)
    end
  end

  describe "Extractor.parse_response/1" do
    test "fenced, partial or malformed replies come back as a clean reading" do
      assert Extractor.parse_response("not json") == %{tastes: [], topics: [], avoids: []}

      reading =
        Extractor.parse_response("""
        ```json
        {"tastes": [{"domain": "music", "label": " post-rock. "}, {"domain": "music", "label": "Post-rock"}],
         "topics": ["embodied minds", {"label": ""}],
         "avoids": "nightlife"}
        ```
        """)

      assert reading.tastes == [%{domain: "music", label: "post-rock"}]
      assert reading.topics == [%{label: "embodied minds"}]
      assert reading.avoids == []
    end
  end
end
