defmodule TravelingPoetWeb.FeedbackLiveTest do
  @moduledoc "The feedback form at /feedback (card-137), signed in or not (card-63), and the admins' page."
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.Feedback

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  test "a visitor writes in with an email address", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/feedback?from=/")
    assert html =~ "Your email, so we can write back"

    view
    |> form("#feedback-form", feedback: %{kind: "missing", body: "An Android app"})
    |> render_submit()

    refute has_element?(view, "#feedback-sent")
    assert Feedback.list_messages() == []

    view
    |> form("#feedback-form",
      feedback: %{kind: "missing", body: "An Android app", email: "v@example.com"}
    )
    |> render_submit()

    assert has_element?(view, "#feedback-sent")

    assert [%{user_id: nil, email: "v@example.com", kind: "missing", page: "/", client: "web"}] =
             Feedback.list_messages()
  end

  test "a reader's note is theirs, with the page they came from", %{conn: conn} do
    user = user_fixture()
    {:ok, view, html} = live(sign_in(conn, user), ~p"/feedback?from=/guide&kind=broken")
    refute html =~ "Your email"

    view
    |> form("#feedback-form", feedback: %{kind: "broken", body: "The map is blank"})
    |> render_submit()

    assert has_element?(view, "#feedback-sent")
    assert [%{user_id: id, page: "/guide", body: "The map is blank"}] = Feedback.list_messages()
    assert id == user.id
  end

  test "only a path on this site is kept as where it came from", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _html} = live(sign_in(conn, user), ~p"/feedback?from=//evil.example")

    view |> form("#feedback-form", feedback: %{kind: "other", body: "hi"}) |> render_submit()
    assert [%{page: nil}] = Feedback.list_messages()
  end

  test "a script that fills the hidden field is thanked and forgotten", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/feedback")

    view
    |> render_submit("send", %{
      "feedback" => %{
        "kind" => "other",
        "body" => "buy now",
        "email" => "bot@example.com",
        "website" => "http://spam.example"
      }
    })

    assert has_element?(view, "#feedback-sent")
    assert Feedback.list_messages() == []
  end

  test "Settings, /support and the home page lead to it", %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true})
    poet_fixture(user)
    {:ok, _view, html} = live(sign_in(conn, user), ~p"/settings")
    assert html =~ ~s(id="settings-feedback")

    assert conn |> get(~p"/support") |> html_response(200) =~ ~s(id="support-feedback")
    assert build_conn() |> get(~p"/") |> html_response(200) =~ ~s(data-track="footer-feedback")
  end

  test "the admins see messages and answers, and mark a message done", %{conn: conn} do
    admin = user_fixture(%{is_admin: true})
    reader = user_fixture(%{name: "Wren"})
    {:ok, message} = Feedback.create_message(reader, %{"kind" => "broken", "body" => "Blank map"})
    {:ok, _} = Feedback.record_score(reader, 9)

    {:ok, view, html} = live(sign_in(conn, admin), ~p"/admin/feedback")
    assert html =~ "Blank map"
    assert html =~ "100"
    assert has_element?(view, "#nps-responses")

    view |> element("#feedback-#{message.id} button", "Done") |> render_click()
    refute has_element?(view, "#feedback-#{message.id}")
    assert [%{status: "done"}] = Feedback.list_messages()
  end

  test "the admin page is for admins only", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             live(sign_in(conn, user_fixture()), ~p"/admin/feedback")
  end
end
