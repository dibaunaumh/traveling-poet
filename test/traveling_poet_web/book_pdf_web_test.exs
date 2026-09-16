defmodule TravelingPoetWeb.BookPdfWebTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Books, Journal, Poets}
  alias TravelingPoet.Books.PdfRenderer

  setup do
    Application.put_env(:traveling_poet, :sprites_client, TravelingPoet.SpritesClientRecorder)

    on_exit(fn ->
      Application.delete_env(:traveling_poet, :sprites_client)
      Application.put_env(:traveling_poet, :book_pdf_enabled, "all")
    end)

    user = agent_user_fixture(%{onboarding_completed: true, name: "Udi Bauman"})
    {:ok, user} = Accounts.update_user(user, %{sprite_name: "sandbox-web-#{user.id}"})
    poet = poet_fixture(user, %{name: "Wren", is_public: false})
    {:ok, _} = Poets.move_to(poet, %{lat: 38.72, lng: -9.13, place_name: "Lisbon, Portugal"})
    entry = published_entry_fixture(poet, %{title: "Trams"})
    drawing = media_fixture(poet, %{journal_entry_id: entry.id})
    {:ok, _} = Journal.replace_sections(entry, [%{kind: "illustration", media_id: drawing.id}])

    %{user: user, poet: poet, drawing: drawing}
  end

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  test "the render link opens the book for the sprite, without a session or a toolbar",
       %{conn: conn, user: user, poet: poet, drawing: drawing} do
    {:ok, pdf} = Books.request_pdf(user, poet, %{page_size: "a4"})
    conn = get(conn, ~p"/book/render/#{Books.render_token(pdf)}")
    html = html_response(conn, 200)

    assert html =~ ~s(<body class="book">)
    assert html =~ "@page { size: A4; }"
    assert html =~ ~s(src="/media/#{drawing.id}")
    refute html =~ ~s(id="book-toolbar")
    assert conn.resp_cookies["tp_book_render"].path == "/media"

    # the cookie lets this private poet's drawings through (checked on
    # authorization alone: past it, show/2 would fetch from the bucket)
    with_cookie = build_conn() |> put_req_cookie("tp_book_render", Books.render_token(pdf))
    assert TravelingPoetWeb.MediaController.authorize(with_cookie, poet) == :ok

    # without it, a private poet's drawing stays private
    assert build_conn() |> get(~p"/media/#{drawing.id}") |> response(403)
  end

  test "an invalid or finished render link opens nothing", %{conn: conn, user: user, poet: poet} do
    assert conn |> get(~p"/book/render/nope") |> response(403)

    {:ok, pdf} = Books.request_pdf(user, poet)
    token = Books.render_token(pdf)
    PdfRenderer.run(pdf.id)
    assert build_conn() |> get(~p"/book/render/#{token}") |> response(403)
  end

  test "a render cookie for another poet opens nothing", %{user: user, poet: poet} do
    other = agent_user_fixture()
    {:ok, other} = Accounts.update_user(other, %{sprite_name: "sandbox-other"})
    other_poet = poet_fixture(other, %{is_public: false})
    other_entry = published_entry_fixture(other_poet)
    other_drawing = media_fixture(other_poet, %{journal_entry_id: other_entry.id})

    {:ok, pdf} = Books.request_pdf(user, poet)
    with_cookie = build_conn() |> put_req_cookie("tp_book_render", Books.render_token(pdf))

    assert TravelingPoetWeb.MediaController.authorize(with_cookie, other_poet) == :forbidden
    assert with_cookie |> get(~p"/media/#{other_drawing.id}") |> response(403)
  end

  test "downloading hands the owner a short-lived link; nobody else gets one",
       %{conn: conn, user: user, poet: poet} do
    {:ok, pdf} = Books.request_pdf(user, poet)
    PdfRenderer.run(pdf.id)

    conn = conn |> signed_in(user) |> get(~p"/journal/book/pdf/#{pdf.id}")

    assert redirected_to(conn) =~
             "https://bucket.example/get/poets/#{poet.id}/books/book-#{pdf.id}.pdf"

    assert redirected_to(conn) =~ "Wren"

    stranger = user_fixture(%{onboarding_completed: true})

    assert build_conn()
           |> signed_in(stranger)
           |> get(~p"/journal/book/pdf/#{pdf.id}")
           |> response(404)
  end

  test "Settings: make a PDF, see it render, download it", %{conn: conn, user: user, poet: poet} do
    {:ok, view, html} = live(signed_in(conn, user), ~p"/settings")
    assert html =~ "A PDF to keep"
    assert html =~ "Make the PDF"

    html = view |> form("#make-pdf-form", %{"page_size" => "letter"}) |> render_submit()
    assert html =~ ~s(id="book-pdf-rendering")
    refute html =~ ~s(id="make-pdf-form")

    pdf = Books.current_pdf(poet)
    assert pdf.page_size == "letter"
    PdfRenderer.run(pdf.id)

    html = render(view)
    assert html =~ ~s(id="book-pdf-download")
    assert html =~ "12 pages, Letter"
    assert html =~ "Make a new PDF"
  end

  test "Settings hides PDFs from non-admins while it is admins-only", %{conn: conn, user: user} do
    Application.put_env(:traveling_poet, :book_pdf_enabled, "admins")
    {:ok, _view, html} = live(signed_in(conn, user), ~p"/settings")
    refute html =~ "A PDF to keep"

    {:ok, admin} = Accounts.update_user(user, %{is_admin: true})
    {:ok, _view, html} = live(signed_in(build_conn(), admin), ~p"/settings")
    assert html =~ "A PDF to keep"
  end
end
