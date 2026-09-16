defmodule TravelingPoet.BookPdfsTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Books, Journal, Poets, Repo, Usage}
  alias TravelingPoet.Books.{Composer, Pdf, PdfRenderer}
  alias TravelingPoet.Books.Pdf.SpriteRunner

  setup do
    Application.put_env(:traveling_poet, :sprites_client, TravelingPoet.SpritesClientRecorder)
    Application.put_env(:traveling_poet, :fake_pdf_listener, self())
    Application.put_env(:traveling_poet, :sprites_client_listener, self())

    on_exit(fn ->
      for key <-
            ~w(sprites_client sprites_client_listener fake_pdf_listener fake_pdf_status fake_pdf_verify book_pdf_enabled)a,
          do: Application.delete_env(:traveling_poet, key)

      Application.put_env(:traveling_poet, :book_pdf_enabled, "all")
    end)

    user = agent_user_fixture(%{credits: 10})

    {:ok, user} =
      TravelingPoet.Accounts.update_user(user, %{sprite_name: "sandbox-test-#{user.id}"})

    poet = poet_fixture(user, %{name: "Wren"})
    {:ok, _} = Poets.move_to(poet, %{lat: 38.72, lng: -9.13, place_name: "Lisbon, Portugal"})
    entry = published_entry_fixture(poet, %{title: "Trams"})
    {:ok, _} = Journal.replace_sections(entry, [%{kind: "description", body: "Hills."}])

    %{user: user, poet: poet}
  end

  describe "request_pdf/3" do
    test "opens a rendering row with the chosen paper and records the attempt", %{
      user: user,
      poet: poet
    } do
      assert {:ok, %Pdf{status: "rendering", page_size: "a4", variant: "plain"}} =
               Books.request_pdf(user, poet, %{page_size: "a4", variant: "composed"})

      assert Usage.today_count(user.id, "book_pdf_attempt") == 1
      # no credits for a PDF
      assert TravelingPoet.Credits.balance(TravelingPoet.Accounts.get_user!(user.id)) == 10_000
    end

    test "a composed PDF binds the ready edition; an unknown paper is A5", %{
      user: user,
      poet: poet
    } do
      {:ok, edition} = Books.request_composition(user, poet)
      {:ok, _, _} = Books.put_matter(poet, %{"foreword" => "Before the road."})
      Composer.finish(edition.id, {:ok, "done"})

      assert {:ok, %Pdf{variant: "composed", edition_id: id, page_size: "a5"}} =
               Books.request_pdf(user, poet, %{page_size: "tabloid", variant: "composed"})

      assert id == edition.id
    end

    test "each blocker is named", %{user: user, poet: poet} do
      {:ok, _} = Books.request_pdf(user, poet)
      assert {:blocked, :already_rendering} = Books.request_pdf(user, poet)

      Application.put_env(:traveling_poet, :book_pdf_enabled, "admins")
      assert {:blocked, :pdf_disabled} = Books.request_pdf(user, poet)
      Application.put_env(:traveling_poet, :book_pdf_enabled, "all")

      empty_user = agent_user_fixture()
      assert {:blocked, :empty} = Books.request_pdf(empty_user, poet_fixture(empty_user))

      new = user_fixture()
      new_poet = poet_fixture(new)
      published_entry_fixture(new_poet)
      assert {:blocked, :no_sprite} = Books.request_pdf(new, new_poet)
    end

    test "admins only, when so configured" do
      Application.put_env(:traveling_poet, :book_pdf_enabled, "admins")
      refute Books.pdf_enabled?(%{is_admin: false})
      assert Books.pdf_enabled?(%{is_admin: true})
      Application.put_env(:traveling_poet, :book_pdf_enabled, "off")
      refute Books.pdf_enabled?(%{is_admin: true})
    end

    test "the daily cap counts attempts", %{user: user, poet: poet} do
      for _ <- 1..4, do: {:ok, _} = Usage.record(user.id, "book_pdf_attempt")
      assert {:blocked, :daily_cap} = Books.request_pdf(user, poet)
    end
  end

  describe "PdfRenderer.run/1" do
    test "starts the sprite render with a render link and an upload url, then settles ready",
         %{user: user, poet: poet} do
      {:ok, pdf} = Books.request_pdf(user, poet)
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "books")
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "user:#{user.id}")

      assert %Pdf{status: "ready", byte_size: 4096, pages: 12, s3_key: key} =
               PdfRenderer.run(pdf.id)

      assert key == "poets/#{poet.id}/books/book-#{pdf.id}.pdf"

      sprite = user.sprite_name
      assert_receive {:pdf_start, ^sprite, pdf_id, job}
      assert pdf_id == pdf.id
      assert job.upload_url =~ "https://bucket.example/put/#{key}"
      assert job.url =~ "/book/render/"
      [_, token] = String.split(job.url, "/book/render/")

      assert {:ok, %{pdf: ^pdf_id}} =
               Phoenix.Token.verify(TravelingPoetWeb.Endpoint, "book render", token, max_age: 60)

      assert_receive {:pdf_cleanup, ^sprite, ^pdf_id}
      assert_receive {:book_pdf_ready, user_id, ^pdf_id}
      assert user_id == user.id
      assert_receive {:book_pdf_updated, ^pdf_id}

      # the sprite was held awake for the render
      assert_receive {:sprites_exec, ^sprite, put_cmd}
      assert put_cmd =~ "tpoet-book-pdf-"

      # once ready, the token no longer opens the book
      assert {:error, :invalid} = Books.verify_render_token(token)
      assert Books.latest_ready_pdf(poet).id == pdf.id
    end

    test "a failed render keeps the error and the log", %{user: user, poet: poet} do
      Application.put_env(:traveling_poet, :fake_pdf_status, %{
        "state" => "failed",
        "error" => "chrome did not start"
      })

      {:ok, pdf} = Books.request_pdf(user, poet)

      assert %Pdf{status: "failed", error: "the render failed: chrome did not start", log: log} =
               PdfRenderer.run(pdf.id)

      assert log =~ "laid out"
      assert Books.latest_ready_pdf(poet) == nil
    end

    test "the app checks the upload itself: a sprite that says done is not enough", %{
      user: user,
      poet: poet
    } do
      Application.put_env(:traveling_poet, :fake_pdf_verify, {:error, :not_a_pdf})
      {:ok, pdf} = Books.request_pdf(user, poet)

      assert %Pdf{status: "failed", error: error} = PdfRenderer.run(pdf.id)
      assert error =~ "did not check out"
    end

    test "a render that never reports back is settled when next read", %{user: user, poet: poet} do
      {:ok, pdf} = Books.request_pdf(user, poet)

      old =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-26, :minute)
        |> NaiveDateTime.truncate(:second)

      Repo.update_all(from(p in Pdf, where: p.id == ^pdf.id), set: [inserted_at: old])

      assert %Pdf{status: "failed", error: "the render never reported back"} =
               Books.current_pdf(poet)
    end
  end

  describe "render tokens" do
    test "open only their own PDF while it renders", %{user: user, poet: poet} do
      {:ok, pdf} = Books.request_pdf(user, poet)
      token = Books.render_token(pdf)
      assert {:ok, %Pdf{}} = Books.verify_render_token(token)
      assert {:error, :invalid} = Books.verify_render_token(token <> "x")
      assert {:error, :invalid} = Books.verify_render_token(nil)
    end
  end

  test "the sprite runner writes a fresh script and job and starts it detached" do
    Application.put_env(:traveling_poet, :sprites_client_listener, self())

    :ok =
      SpriteRunner.start("sandbox-x", 7, %{
        url: "https://poet.travel/book/render/t",
        upload_url: "https://u",
        cookie: nil,
        timeout_ms: 1000,
        chrome_version: "stable"
      })

    assert_receive {:sprites_exec, "sandbox-x", cmd}
    assert cmd =~ "mkdir -p $HOME/.tpoet/render/7"
    assert cmd =~ Base.encode64(SpriteRunner.script())
    assert cmd =~ "setsid nohup node render-book.mjs job.json"
    assert cmd =~ "< /dev/null &"

    [_, job_b64] = Regex.run(~r/echo (\S+) \| base64 -d > job\.json/, cmd)
    job = job_b64 |> Base.decode64!() |> Jason.decode!()
    assert job["work_dir"] == ".tpoet/render/7"
    assert job["upload_url"] == "https://u"
  end

  test "an account purge also removes its PDFs from the bucket", %{user: user, poet: poet} do
    {:ok, pdf} = Books.request_pdf(user, poet)
    PdfRenderer.run(pdf.id)
    assert Books.pdf_keys(poet) == ["poets/#{poet.id}/books/book-#{pdf.id}.pdf"]
  end
end
