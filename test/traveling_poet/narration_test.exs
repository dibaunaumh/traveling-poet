defmodule TravelingPoet.NarrationTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Journal, Narration, Poets, Usage}
  alias TravelingPoet.Narration.{Backfill, Mp3, Script}

  # MPEG-1 Layer III, 128 kbps, 44.1 kHz, stereo: 417-byte frames
  @frame_header <<0xFF, 0xFB, 0x90, 0x00>>

  defp mp3(seconds) do
    size = div(128_000 * seconds, 8)
    @frame_header <> :binary.copy(<<0>>, size - 4)
  end

  defp stub_speech(bytes) do
    Req.Test.stub(TravelingPoet.Narration, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:speech_request, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("audio/mpeg")
      |> Plug.Conn.send_resp(200, bytes)
    end)
  end

  setup do
    Application.put_env(:traveling_poet, :narration_storage_pid, self())
    # runtime.exs nils the fleet key in test; the stub answers in its place
    Application.put_env(:traveling_poet, :openrouter_api_key, "test-key")

    on_exit(fn ->
      Application.delete_env(:traveling_poet, :narration_storage_pid)
      Application.put_env(:traveling_poet, :openrouter_api_key, nil)
    end)

    user = user_fixture()

    poet =
      poet_fixture(user, %{
        name: "Wren",
        personality: "Dry-witted flâneur",
        settings: %{"narration" => true}
      })

    entry =
      published_entry_fixture(poet, %{title: "The smallest summit", entry_date: ~D[2026-10-14]})

    {:ok, _} =
      Journal.replace_sections(entry, [
        %{kind: "poem", title: "Bell", body: "one bell\n\ntwo hills"},
        %{
          kind: "description",
          body: "A short hike. See [the trail](https://parks.ca/tunnel). ![a pine](/media/9)"
        },
        %{kind: "illustration", body: nil},
        %{kind: "kindness", title: "A Tuesday door", body: "**Bring** _fifteen_ minutes."}
      ])

    %{user: user, poet: poet, entry: Journal.get_entry!(entry.id)}
  end

  describe "Script" do
    test "reads the title, the prose in order, then the poem, with markdown flattened", %{
      entry: entry
    } do
      text = Script.for_entry(Repo.preload(entry, :sections))

      assert text ==
               "The smallest summit.\n\n" <>
                 "A short hike. See the trail.\n\n" <>
                 "A Tuesday door.\n\nBring fifteen minutes.\n\n" <>
                 "Bell.\n\none bell\n\ntwo hills"
    end

    test "nothing to read is nil, and the hash follows the words" do
      assert Script.for_entry(%{title: nil, sections: []}) == nil
      assert Script.hash("a") != Script.hash("b")
      assert Script.estimated_seconds(String.duplicate("x", 1400)) == 100
    end
  end

  describe "Mp3.duration_seconds/1" do
    test "reads a constant bit rate file from its first frame" do
      assert Mp3.duration_seconds(mp3(10)) == 10

      assert Mp3.duration_seconds(
               "ID3" <> <<4, 0, 0, 0, 0, 0, 10>> <> :binary.copy(<<0>>, 10) <> mp3(7)
             ) == 7
    end

    test "is nil for bytes that are not an mp3" do
      assert Mp3.duration_seconds("not audio at all") == nil
    end
  end

  describe "generate/1" do
    test "narrates a published page: the speech call, the upload, the media row, the usage line",
         %{
           entry: entry,
           poet: poet,
           user: user
         } do
      stub_speech(mp3(120))
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "poet:#{poet.id}")

      assert {:ok, media} = Narration.generate(entry)

      assert_received {:speech_request, body}
      assert body["model"] == "test/narration-model"
      assert body["voice"] == "test-voice"
      assert body["response_format"] == "mp3"
      assert body["input"] =~ "The smallest summit."
      assert body["instructions"] =~ "Dry-witted"

      assert_received {:narration_upload, key, bytes}
      assert key =~ "media/narration-#{entry.id}-"
      assert byte_size(bytes) == 1_920_000

      assert media.kind == "narration"
      assert media.journal_entry_id == entry.id
      assert media.poet_id == poet.id
      assert media.content_type == "audio/mpeg"
      assert media.duration_seconds == 120
      assert media.alt_text == "Wren reads this page"
      assert Narration.narration_for(entry.id).id == media.id

      assert Usage.today_count(user.id, "narration") == 1
      assert_received {:narration_ready, entry_id}
      assert entry_id == entry.id
    end

    test "the same words narrate once; changed words replace the old reading", %{entry: entry} do
      stub_speech(mp3(60))
      {:ok, first} = Narration.generate(entry)
      assert_received {:narration_upload, _, _}
      assert {:skip, :unchanged} = Narration.generate(entry)
      refute_received {:narration_upload, _, _}

      {:ok, _} = Journal.replace_sections(entry, [%{kind: "description", body: "Rewritten."}])
      {:ok, second} = Narration.generate(Journal.get_entry!(entry.id))

      assert second.id != first.id
      assert_received {:narration_delete, key}
      assert key == first.s3_key
      assert Narration.narration_for(entry.id).id == second.id
      assert Repo.get(Journal.Media, first.id) == nil
    end

    test "a reader who never turned it on, or over the daily cap, gets no reading", %{
      entry: entry,
      poet: poet,
      user: user
    } do
      stub_speech(mp3(5))
      {:ok, poet} = Poets.update_poet(poet, %{settings: %{}})
      assert {:skip, :off} = Narration.generate(entry)
      {:ok, poet} = Poets.update_poet(poet, %{settings: %{"narration" => false}})
      assert {:skip, :off} = Narration.generate(entry)

      {:ok, _} = Poets.update_poet(poet, %{settings: %{"narration" => true}})
      # The cap is 10 a day by default (raised for on-demand readings of
      # old pages, 2026-10-15); pin it here so the test is about the gate.
      Application.put_env(:traveling_poet, :daily_narration_cap, 3)
      on_exit(fn -> Application.delete_env(:traveling_poet, :daily_narration_cap) end)
      for _ <- 1..3, do: Usage.record(user.id, "narration")
      assert {:skip, :cap} = Narration.generate(entry)
      # On request the opt-in does not apply, the cap still does.
      assert {:skip, :cap} = Narration.generate(entry, on_demand: true)
    end

    test "a speech error is returned, nothing is stored", %{entry: entry} do
      Req.Test.stub(TravelingPoet.Narration, fn conn ->
        Req.Test.json(%{conn | status: 502}, %{"error" => "down"})
      end)

      assert {:error, "speech API returned 502"} = Narration.generate(entry)
      refute_received {:narration_upload, _, _}
      assert Narration.narration_for(entry.id) == nil
    end
  end

  describe "Backfill.run/1" do
    test "a dry run counts and prices the pages not yet read; commit narrates them", %{
      entry: entry
    } do
      # a poet whose reader never opted in is not in the count
      published_entry_fixture(poet_fixture(user_fixture()), %{title: "Quiet"})

      report = Backfill.run()
      assert report.committed == false
      assert report.poets_opted_in == 1
      assert report.to_narrate == 1
      assert report.already_narrated == 0
      assert report.chars > 50
      assert report.estimated_usd > 0
      assert Narration.narration_for(entry.id) == nil

      stub_speech(mp3(30))
      report = Backfill.run(commit: true)
      assert [{_id, {:ok, 30}}] = report.results
      assert Backfill.run().already_narrated == 1
    end
  end
end
